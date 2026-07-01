-- mcp.json_rpc.transport.http
--
-- Streamable-HTTP transport for MCP. Spawns a `vim.uv.new_tcp` server
-- on a localhost port, accepts HTTP/1.1 requests, and turns each one
-- into a single JSON-RPC message dispatched synchronously to a user
-- callback.
--
-- Scope (v1):
--   * POST /mcp: parse the JSON body, dispatch via `on_request`,
--     respond with Content-Type: application/json. Notifications
--     (no `id`) and pure responses get a 202 Accepted with no body.
--   * GET /mcp: 405 Method Not Allowed. We do not implement
--     server-to-client SSE streaming in v1.
--   * DELETE /mcp: 204 No Content. We do not implement session
--     teardown in v1.
--   * Origin header: validated against the `allowed_origins` list
--     when present. Requests with a missing Origin are allowed
--     (CLI tools do not send one).
--
-- Out of scope (deliberately deferred): SSE server-to-client streaming,
-- `Mcp-Session-Id` session management, `Last-Event-ID` resumability,
-- TLS. Use a reverse proxy if exposing outside localhost.
--
-- This transport does not compose with `mcp.json_rpc.wrap`. HTTP is a
-- request-response protocol; the Connection abstraction assumes a
-- stream of messages. Instead, callers pass an `on_request` callback
-- at bind time and receive synchronous responses.

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

--- Format an HTTP/1.1 response. Always includes `Content-Length` and
--- `Connection: close` (we do not implement keep-alive).
---@param status integer
---@param reason string
---@param body string?
---@param extra table<string, string>?
---@return string
local function format_response(status, reason, body, extra)
  body = body or ''
  local parts = {
    string.format('HTTP/1.1 %d %s\r\n', status, reason),
    'Content-Length: ' .. tostring(#body) .. '\r\n',
    'Connection: close\r\n',
  }
  for k, v in pairs(extra or {}) do
    table.insert(parts, k .. ': ' .. v .. '\r\n')
  end
  table.insert(parts, '\r\n')
  table.insert(parts, body)
  return table.concat(parts)
end

---@class mcp.json_rpc.transport.http.Server
---@field private handle uv_tcp_t
---@field private host string
---@field private port integer
---@field private endpoint string
---@field private allowed_origins table<string, true>
---@field on_request fun(method: string, params?: table): any?, mcp.json_rpc.Error?
---@field private clients table<userdata, true>
local HttpServer = {}
HttpServer.__index = HttpServer

function HttpServer:terminate()
  for client, _ in pairs(self.clients) do
    if not client:is_closing() then client:close() end
  end
  self.clients = {}
  if not self.handle:is_closing() then self.handle:close() end
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
    -- We do not implement server-to-client SSE streaming in v1.
    client:write(format_response(405, 'Method Not Allowed', '', {
      Allow = 'POST, DELETE',
    }))
    client:shutdown()
    client:close()
    self.clients[client] = nil
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
    if self.on_request then
      -- Notifications still get dispatched, but we do not produce a
      -- response body (per JSON-RPC 2.0 spec).
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

  local ok2, result_or_err = pcall(self.on_request, msg.method, msg.params)
  local response_body
  if not ok2 then
    -- on_request itself raised an exception: report as internal error.
    response_body = vim.json.encode({
      jsonrpc = '2.0',
      id = msg.id,
      error = { code = -32603, message = tostring(result_or_err) },
    })
  else
    local result, err = result_or_err, nil
    -- The convention is `return result, err` but `pcall` collapses
    -- that into a single return value. We instead expect on_request
    -- to return a tuple when called normally; here we treat the
    -- single return value as result.
    response_body = vim.json.encode({
      jsonrpc = '2.0',
      id = msg.id,
      result = result,
    })
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
    clients = {},
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
          if self.clients[client] then
            self.clients[client] = nil
            client:close()
          end
          return
        end
        if not data then
          if self.clients[client] then
            self.clients[client] = nil
            client:close()
          end
          return
        end
        self:_on_data(client, data)
      end))
    end)
  )

  return self, actual_port
end

return M
