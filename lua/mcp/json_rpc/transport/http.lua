-- mcp.json_rpc.transport.http
--
-- Streamable-HTTP transport for MCP. Spawns a `vim.uv.new_tcp` server
-- on a localhost port, accepts HTTP/1.1 requests, and turns each one
-- into a single JSON-RPC message dispatched synchronously to a user
-- callback.
--
-- Scope:
--   * POST /mcp: parse the JSON body, dispatch via `on_request`,
--     respond with Content-Type: application/json. Notifications
--     (no `id`) and pure responses get a 202 Accepted with no body.
--   * GET /mcp: open a `text/event-stream` response that the server
--     can push JSON-RPC notifications and requests down. The stream
--     stays open until the client disconnects or the server is
--     terminated. Per the MCP spec, this is how clients subscribe to
--     server-initiated messages; refusing it (HTTP 405) breaks the
--     handshake even if POST works fine.
--   * DELETE /mcp: 204 No Content. We do not implement session
--     teardown in v1.
--   * Origin header: validated against the `allowed_origins` list
--     when present. Requests with a missing Origin are allowed
--     (CLI tools do not send one).
--
-- Out of scope (deliberately deferred): `Mcp-Session-Id` session
-- management, `Last-Event-ID` resumability, TLS, POST responses that
-- upgrade to SSE (we keep the simpler JSON response for POST and use
-- SSE only on GET). Use a reverse proxy if exposing outside localhost.
--
-- This transport does not compose with `mcp.json_rpc.wrap`. HTTP is a
-- request-response protocol; the Connection abstraction assumes a
-- stream of messages. Instead, callers pass an `on_request` callback
-- at bind time and receive synchronous responses.

local framing = require('mcp.json_rpc.transport.framing')

local M = {}

--- Parse an HTTP/1.1 request from a raw byte buffer. Returns
--- `{ method, path, version, headers, body }` or `nil` if the buffer
--- does not yet contain a complete request.
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

  local cl = tonumber(headers['content-length']) or 0
  if #body < cl then return nil end
  body = body:sub(1, cl)

  return { method = method, path = path, version = version, headers = headers, body = body }
end

--- Format an HTTP/1.1 response. The defaults below are tuned for the
--- one-request-per-connection model that POST / DELETE handlers use:
--- a `Content-Length` is emitted only when the body is non-empty,
--- and `Connection: close` is emitted only when the caller has not
--- supplied its own `Connection` header via `extra`. The SSE handler
--- passes `Connection: keep-alive` and an empty body, so it gets a
--- well-formed streaming response without the duplicate-header
--- rejection that strict HTTP clients (reqwest, curl) apply.
---@param status integer
---@param reason string
---@param body string?
---@param extra table<string, string>?
---@return string
local function format_response(status, reason, body, extra)
  body = body or ''
  local parts = { string.format('HTTP/1.1 %d %s\r\n', status, reason) }
  -- Content-Length is omitted for an empty body. SSE uses empty-body
  -- responses to keep the stream open, and a misleading `Content-
  -- Length: 0` makes some clients treat the response as terminated
  -- even though we are about to keep writing events.
  if #body > 0 then parts[#parts + 1] = 'Content-Length: ' .. #body .. '\r\n' end
  if not (extra and extra.Connection) then parts[#parts + 1] = 'Connection: close\r\n' end
  for k, v in pairs(extra or {}) do
    parts[#parts + 1] = k .. ': ' .. v .. '\r\n'
  end
  parts[#parts + 1] = '\r\n'
  parts[#parts + 1] = body
  return table.concat(parts)
end

--- One half of a persistent `text/event-stream` connection. The HTTP
--- server owns a set of these; each one wraps the underlying TCP
--- client plus a monotonically-increasing event id so the client can
--- resume from `Last-Event-ID` if it reconnects (resumability itself
--- is not implemented in v1, but the ids are emitted so the wire
--- format is correct).
---@class mcp.json_rpc.transport.http.SseStream
---@field private client uv_tcp_t
local SseStream = {}
SseStream.__index = SseStream

---@param client uv_tcp_t
---@return mcp.json_rpc.transport.http.SseStream
function SseStream.new(client) return setmetatable({ client = client }, SseStream) end

---@return boolean
function SseStream:is_open() return self.client ~= nil and not self.client:is_closing() end

--- Write a fully-formatted SSE event (already including trailing
--- blank line) to the underlying socket. Returns false if the
--- socket is no longer writable so the caller can evict the stream.
---@param payload string
---@return boolean ok
function SseStream:write(payload)
  if not self:is_open() then return false end
  local ok = pcall(function() self.client:write(payload) end)
  if not ok then return false end
  return true
end

--- Close the underlying TCP client. Idempotent.
function SseStream:close()
  if self.client and not self.client:is_closing() then
    pcall(function() self.client:shutdown() end)
    pcall(function() self.client:close() end)
  end
end

---@class mcp.json_rpc.transport.http.Server
---@field private handle uv_tcp_t
---@field private host string
---@field private port integer
---@field private endpoint string
---@field private allowed_origins table<string, true>
---@field on_request fun(method: string, params?: table): any?, mcp.json_rpc.Error?
---@field on_notify fun(method: string, params?: table)
---@field private clients table<userdata, true>
---@field private streams table<mcp.json_rpc.transport.http.SseStream, true>
---@field private event_seq integer
local HttpServer = {}
HttpServer.__index = HttpServer

---@return boolean
function HttpServer:is_closing() return self.handle:is_closing() end

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

--- Open a `text/event-stream` response on `client` and register the
--- resulting stream so that subsequent broadcasts reach it. Returns
--- the stream on success or `nil` if the headers could not be written.
---@param client uv_tcp_t
---@return mcp.json_rpc.transport.http.SseStream?
function HttpServer:_open_sse(client)
  local response = format_response(200, 'OK', '', {
    ['Content-Type'] = 'text/event-stream',
    ['Cache-Control'] = 'no-cache',
    ['Connection'] = 'keep-alive',
    -- Disable proxy buffering in case the user puts nginx in front.
    ['X-Accel-Buffering'] = 'no',
  })
  local ok = pcall(function() client:write(response) end)
  if not ok then return nil end

  -- A leading comment event flushes the response headers immediately
  -- so the client knows the stream is live before we ever need to
  -- send data. Some SSE clients buffer until the first real event.
  pcall(function() client:write(': open\n\n') end)

  -- Promote the client: it is now a long-lived SSE stream, not a
  -- single request. Remove it from `self.clients` so the early
  -- bail-out in `_on_data` filters out any stray bytes that the
  -- server might still receive on the socket (SSE clients do not
  -- send additional HTTP requests; if one does we drop the stream
  -- via `_drop_client` rather than corrupting the protocol).
  self.clients[client] = nil

  local stream = SseStream.new(client)
  self.streams[stream] = true
  return stream
end

--- Push a JSON-RPC notification to every open SSE stream. Streams
--- that fail to write are evicted so we do not retry on a dead
--- socket.
---@param method string
---@param params? table
function HttpServer:notify(method, params)
  local payload = vim.json.encode({ jsonrpc = '2.0', method = method, params = params })
  self:broadcast_event(payload)
end

--- Push an arbitrary JSON-RPC message to every open SSE stream.
--- The payload must already be a JSON-encoded string.
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

--- Drop a client from tracking. Called from the read callback on
--- EOF / read error so that crashed peers do not leak. If the
--- client is also wrapped in an SSE stream, that stream is removed
--- too.
---@param client uv_tcp_t
function HttpServer:_drop_client(client)
  if self.clients[client] then
    self.clients[client] = nil
    if not client:is_closing() then client:close() end
  end
  for stream, _ in pairs(self.streams) do
    if stream.client == client then
      self.streams[stream] = nil
      stream:close()
    end
  end
end

function HttpServer:_on_data(client, data)
  if not self.clients[client] then return end

  -- One HTTP request per TCP connection in v1. We do not implement
  -- keep-alive pipelining; clients should open a fresh connection
  -- per request if they need to.
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
    -- The MCP Streamable HTTP transport expects GET to open a
    -- server-to-client SSE stream. We write the response headers
    -- and register the client as a stream; the read callback stays
    -- subscribed so we notice when the client disconnects.
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

  -- Notification or pure response (client -> server): accept, no body.
  if has_method and not has_id then
    -- Dispatch through on_notify when present; fall back to
    -- on_request for handlers that do not distinguish. This split
    -- matters for the lifecycle notification
    -- `notifications/initialized` which must drive the server's
    -- state machine forward, not be treated as a request.
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

  -- Request: dispatch and return a response.
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

  -- Capture multiple return values via the table-collect idiom.
  -- `pcall` collapses multi-return into a single value; we want both
  -- `result` and `err`, so wrap manually with xpcall.
  local results = { nil, nil, nil }
  local ok = xpcall(function()
    -- Re-call on_request from inside xpcall to preserve multi-return.
    local r1, r2 = self.on_request(msg.method, msg.params)
    -- Stash results into the upvalues array. Index 1 is reserved by
    -- xpcall for the error string, so use 2 and 3.
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

--- Bind a streamable-HTTP server on `host:port`. Pass `port = 0` to
--- let the OS pick an ephemeral port; the chosen port is returned
--- in the second value.
---@param host string
---@param port integer
---@param opts? { endpoint?: string, allowed_origins?: string[], on_request?: fun(method, params) }
---@return mcp.json_rpc.transport.http.Server, integer actual_port
function M.bind(host, port, opts)
  opts = opts or {}
  local handle = vim.uv.new_tcp()
  handle:bind(host, port)
  local actual_port = handle:getsockname().port

  local allowed = {}
  for _, o in ipairs(opts.allowed_origins or {}) do
    allowed[o] = true
  end
  -- Browsers send `Origin: null` for cross-origin requests; allow it
  -- always. CLI tools send no Origin header at all (treated as
  -- allowed by the missing-Origin branch in _on_data).
  allowed['null'] = true

  local self = setmetatable({
    handle = handle,
    host = host,
    port = actual_port,
    endpoint = opts.endpoint or '/mcp',
    allowed_origins = allowed,
    on_request = opts.on_request,
    on_notify = opts.on_notify,
    clients = {},
    streams = {},
    event_seq = 0,
  }, HttpServer)

  handle:listen(
    128,
    vim.schedule_wrap(function(err)
      if err then return end
      local client = vim.uv.new_tcp()
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
