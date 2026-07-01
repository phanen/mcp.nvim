-- mcp.util.http_client
--
-- Minimal blocking HTTP client used by the opencode registration
-- helper. We deliberately do not pull in a dependency on curl, the
-- MCP SDK, or any other library: a single POST with JSON body is
-- the only thing we need to send, and `vim.uv` + a hand-written
-- HTTP request keeps this plugin self-contained.
--
-- Scope: this client only does POST with a JSON body and a fixed
-- timeout. It does not do TLS, redirects, retries, or chunked
-- encoding. The opencode server we target is on localhost over a
-- plain HTTP connection, so none of that is needed.

local M = {}

---@class mcp.util.http_client.Result
---@field status integer
---@field body string

--- Send a POST request with a JSON body to the given URL, blocking
--- until the response is received or the timeout fires. Returns
--- `result, err`. `result.status` is the HTTP status code; `result.body`
--- is the raw response body.
---
--- The URL must be of the form `http://host:port/path`. HTTPS is not
--- implemented (the opencode server we target is plaintext localhost).
---
---@param url string
---@param body string  serialised JSON
---@param opts? { timeout_ms?: integer, headers?: table<string, string> }
---@return mcp.util.http_client.Result
---@return string? err
function M.post_json(url, body, opts)
  opts = opts or {}
  local timeout_ms = opts.timeout_ms or 3000
  local extra_headers = opts.headers or {}

  -- Parse http://host[:port][/path]. The path component is
  -- optional so that bare-host URLs (e.g. http://127.0.0.1:4096)
  -- are accepted; we default to '/' in that case.
  local host, port, path = url:match('^http://([^:/]+):(%d+)(/.*)$')
  if not host then
    host, port, path = url:match('^http://([^:/]+):?(%d*)(/?.*)$')
  end
  if not host then return nil, 'unsupported URL scheme: ' .. url end
  if port == nil or port == '' then
    port = 80
  else
    port = tonumber(port)
  end
  if path == nil or path == '' then path = '/' end

  local uv = vim.uv or vim.loop
  local client = uv.new_tcp()
  local ok, err = pcall(function() client:bind('127.0.0.1', 0) end)
  if not ok then return nil, 'failed to bind source port: ' .. tostring(err) end

  local chunks = {}
  local done = false
  local connect_err
  local timed_out = false

  local timer = uv.new_timer()
  timer:start(timeout_ms, 0, function()
    timed_out = true
    if not client:is_closing() then client:close() end
    done = true
  end)

  local result = { status = 0, body = '' }

  client:connect(host, port, function(cerr)
    if cerr then
      connect_err = cerr
      done = true
      if not timer:is_closing() then timer:close() end
      if not client:is_closing() then client:close() end
      return
    end

    -- Build the request line and headers.
    local lines = {
      'POST ' .. path .. ' HTTP/1.1',
      'Host: ' .. host .. ':' .. tostring(port),
      'Content-Type: application/json',
      'Content-Length: ' .. tostring(#body),
      'Connection: close',
    }
    for k, v in pairs(extra_headers) do
      table.insert(lines, k .. ': ' .. v)
    end
    table.insert(lines, '')
    table.insert(lines, body)
    local req = table.concat(lines, '\r\n')

    client:read_start(function(rerr, data)
      if rerr then
        done = true
        if not timer:is_closing() then timer:close() end
        return
      end
      if data then
        table.insert(chunks, data)
      else
        done = true
        if not timer:is_closing() then timer:close() end
      end
    end)
    client:write(req)
  end)

  -- Block until the request completes. We use `vim.wait` (not
  -- `uv.run('once')`) so that vim.schedule callbacks fire on
  -- both sides of the connection: read_start / write callbacks
  -- land on the scheduler, not the libuv loop.
  vim.wait(timeout_ms, function() return done end)

  if not timer:is_closing() then timer:close() end
  if not client:is_closing() then client:close() end

  if timed_out then return nil, 'request timed out after ' .. tostring(timeout_ms) .. 'ms' end
  if connect_err then return nil, 'connect failed: ' .. tostring(connect_err) end

  local raw = table.concat(chunks)
  -- Split status line from headers from body.
  local hdr_end = raw:find('\r\n\r\n', 1, true)
  if not hdr_end then return nil, 'malformed response (no header terminator)' end
  local head = raw:sub(1, hdr_end - 1)
  result.body = raw:sub(hdr_end + 4)
  local _, code = head:match('^(HTTP/[%d%.]+)%s+(%d+)%s')
  if not code then return nil, 'malformed status line in: ' .. head:sub(1, 80) end
  result.status = tonumber(code)
  return result, nil
end
return M
