local framing = require('mcp.json_rpc.transport.framing')

local M = {}

---@class mcp.json_rpc.transport.http.BindOpts
---@field endpoint? string
---@field allowed_origins? string[]
---@field on_request? fun(method: string, params?: table): any?, mcp.json_rpc.Error?
---@field on_notify? fun(method: string, params?: table)
---@field on_sse_closed? fun()

---@param buf string
---@return table?
local function parse_request(buf)
  local hdr_end = buf:find('\r\n\r\n', 1, true)
  if not hdr_end then return nil end
  local head = buf:sub(1, hdr_end - 1)
  local body = buf:sub(hdr_end + 4)

  local lines = vim.split(head, '\r\n', { plain = true })
  local request_line = lines[1]
  if not request_line then return nil end
  local method, path, version = request_line:match('^(%S+)%s+(%S+)%s+(%S+)$')
  if not method then return nil end

  local headers = {}
  for i = 2, #lines do
    local k, v = lines[i]:match('^([^:]+):%s*(.*)$')
    if k then headers[k:lower()] = v end
  end

  local cl = tonumber(headers['content-length']) or 0 ---@cast cl integer
  if #body < cl then return nil end
  body = body:sub(1, cl)

  return { method = method, path = path, version = version, headers = headers, body = body }
end

---@param status integer
---@param reason string
---@param body string?
---@param extra table<string, string>?
---@return string
local function format_response(status, reason, body, extra)
  body = body or ''
  local parts = { string.format('HTTP/1.1 %d %s\r\n', status, reason) }
  -- Content-Length is omitted for empty bodies so SSE responses stay
  -- open without being mistaken for a completed response.
  if #body > 0 then parts[#parts + 1] = 'Content-Length: ' .. #body .. '\r\n' end
  if not (extra and extra.Connection) then parts[#parts + 1] = 'Connection: close\r\n' end
  for k, v in pairs(extra or {}) do
    parts[#parts + 1] = k .. ': ' .. v .. '\r\n'
  end
  parts[#parts + 1] = '\r\n'
  parts[#parts + 1] = body
  return table.concat(parts)
end

---@class mcp.json_rpc.transport.http.SseStream
---@field private client uv.uv_tcp_t
local SseStream = {}
SseStream.__index = SseStream

---@param client uv.uv_tcp_t
---@return mcp.json_rpc.transport.http.SseStream
function SseStream.new(client) return setmetatable({ client = client }, SseStream) end

---@return boolean
function SseStream:is_open() return self.client ~= nil and not self.client:is_closing() end

---@param payload string
---@return boolean ok
function SseStream:write(payload)
  if not self:is_open() then return false end
  local ok = pcall(function() self.client:write(payload) end)
  if not ok then return false end
  return true
end

function SseStream:close()
  if self.client and not self.client:is_closing() then
    pcall(function() self.client:shutdown() end)
    pcall(function() self.client:close() end)
  end
end

---@class mcp.json_rpc.transport.http.Server
---@field private handle uv.uv_tcp_t
---@field private host string
---@field private port integer
---@field private endpoint string
---@field private allowed_origins table<string, true>
---@field on_request fun(method: string, params?: table): any?, mcp.json_rpc.Error?
---@field on_notify fun(method: string, params?: table)
---@field on_sse_closed? fun()
---@field private clients table<userdata, true>
---@field private streams table<mcp.json_rpc.transport.http.SseStream, true>
---@field private event_seq integer
local HttpServer = {}
HttpServer.__index = HttpServer

---@return boolean
function HttpServer:is_closing() return self.handle:is_closing() == true end

function HttpServer:terminate()
  for stream, _ in pairs(self.streams) do
    stream:close()
    self.streams[stream] = nil
  end
  for client, _ in pairs(self.clients) do
    if not client:is_closing() then client:close() end
    self.clients[client] = nil
  end
  if not self.handle:is_closing() then self.handle:close() end
end

---@param client uv.uv_tcp_t
---@return mcp.json_rpc.transport.http.SseStream?
function HttpServer:_open_sse(client)
  local response = format_response(200, 'OK', '', {
    ['Content-Type'] = 'text/event-stream',
    ['Cache-Control'] = 'no-cache',
    ['Connection'] = 'keep-alive',
    ['X-Accel-Buffering'] = 'no',
  })
  local ok = pcall(function() client:write(response) end)
  if not ok then return nil end

  -- Leading comment event flushes the headers so buffered clients
  -- see the stream is live before the first real event arrives.
  pcall(function() client:write(': open\n\n') end)

  -- SSE clients do not send additional requests; if they do, the
  -- next read hits `clients[client] == nil` and is dropped.
  self.clients[client] = nil

  local stream = SseStream.new(client)
  self.streams[stream] = true
  return stream
end

---@param method string
---@param params? table
function HttpServer:notify(method, params)
  local payload = vim.json.encode({ jsonrpc = '2.0', method = method, params = params })
  self:broadcast_event(payload)
end

---@param payload string
function HttpServer:broadcast_event(payload)
  self.event_seq = (self.event_seq or 0) + 1
  local frame = framing.sse_encode(self.event_seq, payload)
  for stream, _ in pairs(self.streams) do
    if stream:is_open() and stream:write(frame) then
      -- ok
    else
      self.streams[stream] = nil
    end
  end
end

---@param client uv.uv_tcp_t
function HttpServer:_drop_client(client)
  local was_stream = false
  for stream, _ in pairs(self.streams) do
    if stream.client == client then
      self.streams[stream] = nil
      stream:close()
      was_stream = true
      break
    end
  end
  if self.clients[client] then
    self.clients[client] = nil
    if not client:is_closing() then client:close() end
  end
  if was_stream and not next(self.streams) and self.on_sse_closed then self.on_sse_closed() end
end

function HttpServer:_on_data(client, data)
  if not self.clients[client] then return end

  local req = parse_request(data)
  if not req then
    client:write(format_response(400, 'Bad Request', '{"error":"malformed request"}', {
      ['Content-Type'] = 'application/json',
    }))
    client:shutdown()
    client:close()
    self.clients[client] = nil
    return
  end

  local origin = req.headers['origin']
  if origin and not self.allowed_origins[origin] then
    client:write(format_response(403, 'Forbidden', '{"error":"origin not allowed"}', {
      ['Content-Type'] = 'application/json',
    }))
    client:shutdown()
    client:close()
    self.clients[client] = nil
    return
  end

  if req.method == 'GET' then
    local stream = self:_open_sse(client)
    if not stream then self:_drop_client(client) end
    return
  end

  if req.method == 'DELETE' then
    client:write(format_response(204, 'No Content', ''))
    client:shutdown()
    client:close()
    self.clients[client] = nil
    return
  end

  if req.method ~= 'POST' then
    client:write(format_response(405, 'Method Not Allowed', '', { Allow = 'POST, DELETE' }))
    client:shutdown()
    client:close()
    self.clients[client] = nil
    return
  end

  if req.path ~= self.endpoint then
    client:write(format_response(404, 'Not Found', '{"error":"unknown endpoint"}', {
      ['Content-Type'] = 'application/json',
    }))
    client:shutdown()
    client:close()
    self.clients[client] = nil
    return
  end

  local ok, msg = pcall(vim.json.decode, req.body)
  if not ok or type(msg) ~= 'table' then
    client:write(
      format_response(
        400,
        'Bad Request',
        '{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"}}',
        {
          ['Content-Type'] = 'application/json',
        }
      )
    )
    client:shutdown()
    client:close()
    self.clients[client] = nil
    return
  end

  local has_id = msg.id ~= nil and msg.id ~= vim.NIL
  local has_method = type(msg.method) == 'string'
  local has_result = msg.result ~= nil or msg.error ~= nil

  if not has_method and not has_result then
    client:write(
      format_response(
        400,
        'Bad Request',
        '{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid Request"}}',
        {
          ['Content-Type'] = 'application/json',
        }
      )
    )
    client:shutdown()
    client:close()
    self.clients[client] = nil
    return
  end

  if has_method and not has_id then
    -- Distinguishing matters for `notifications/initialized` which
    -- must drive the server's lifecycle, not be treated as a request.
    if self.on_notify then
      pcall(self.on_notify, msg.method, msg.params)
    elseif self.on_request then
      pcall(self.on_request, msg.method, msg.params)
    end
    client:write(format_response(202, 'Accepted', ''))
    client:shutdown()
    client:close()
    self.clients[client] = nil
    return
  end

  if not self.on_request then
    client:write(
      format_response(
        500,
        'Internal Server Error',
        '{"jsonrpc":"2.0","error":{"code":-32603,"message":"no dispatcher"}}',
        {
          ['Content-Type'] = 'application/json',
        }
      )
    )
    client:shutdown()
    client:close()
    self.clients[client] = nil
    return
  end

  -- xpcall collapses multi-return; we need both result and err, so
  -- capture them in an upvalue array. Index 1 is reserved for the
  -- error string.
  local results = { nil, nil, nil }
  ok = xpcall(function()
    local r1, r2 = self.on_request(msg.method, msg.params)
    results[2] = r1
    results[3] = r2
  end, function(err) results[1] = err end)
  local response_body
  if not ok then
    response_body = vim.json.encode({
      jsonrpc = '2.0',
      id = msg.id,
      error = { code = -32603, message = tostring(results[1]) },
    })
  else
    local result, err = results[2], results[3]
    if err then
      response_body = vim.json.encode({
        jsonrpc = '2.0',
        id = msg.id,
        error = err,
      })
    else
      response_body = vim.json.encode({
        jsonrpc = '2.0',
        id = msg.id,
        result = result,
      })
    end
  end
  client:write(format_response(200, 'OK', response_body, {
    ['Content-Type'] = 'application/json',
  }))
  client:shutdown()
  client:close()
  self.clients[client] = nil
end

---@param host string
---@param port integer
---@param opts? mcp.json_rpc.transport.http.BindOpts
---@return mcp.json_rpc.transport.http.Server, integer actual_port
function M.bind(host, port, opts)
  opts = opts or {}
  local handle = assert(vim.uv.new_tcp())
  handle:bind(host, port)
  local actual_port = assert(handle:getsockname()).port

  local allowed = {}
  for _, o in ipairs(opts.allowed_origins or {}) do
    allowed[o] = true
  end
  -- Browsers send `Origin: null` for cross-origin requests; allow it
  -- always. CLI tools send no Origin header and skip this branch.
  allowed['null'] = true

  local self = setmetatable({
    handle = handle,
    host = host,
    port = actual_port,
    endpoint = opts.endpoint or '/mcp',
    allowed_origins = allowed,
    on_request = opts.on_request,
    on_notify = opts.on_notify,
    on_sse_closed = opts.on_sse_closed,
    clients = {},
    streams = {},
    event_seq = 0,
  }, HttpServer)

  handle:listen(
    128,
    vim.schedule_wrap(function(err)
      if err then return end
      local client = assert(vim.uv.new_tcp())
      local ok = pcall(function() handle:accept(client) end)
      if not ok then return end
      self.clients[client] = true
      client:read_start(vim.schedule_wrap(function(read_err, data)
        if read_err then
          self:_drop_client(client)
          return
        end
        if not data then
          self:_drop_client(client)
          return
        end
        self:_on_data(client, data)
      end))
    end)
  )

  return self, actual_port
end

return M
