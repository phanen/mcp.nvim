-- mcp.tests.http_transport_spec
--
-- End-to-end tests for the streamable-HTTP transport. Each test
-- binds a server on an ephemeral localhost port, drives a raw TCP
-- HTTP request against it, and asserts on the response.

local n = require('nvim-test.helpers')

local eq = n.eq
local clear = n.clear
local exec_lua = n.exec_lua

--- Drive a raw HTTP/1.1 request via `vim.uv.new_tcp`. Returns the
--- complete raw response as a single string.
local function http_request(host, port, method, path, body, headers)
  headers = headers or {}
  headers['Host'] = headers['Host'] or (host .. ':' .. port)
  headers['Content-Length'] = headers['Content-Length'] or tostring(body and #body or 0)

  local req_lines = { method .. ' ' .. path .. ' HTTP/1.1' }
  for k, v in pairs(headers) do
    table.insert(req_lines, k .. ': ' .. v)
  end
  table.insert(req_lines, '')
  table.insert(req_lines, body or '')
  local req = table.concat(req_lines, '\r\n')

  return exec_lua(function(req_str, h, p)
    local uv = vim.uv or vim.loop
    local client = uv.new_tcp()
    local chunks = {}
    local done = false
    local ret = { ok = false, body = '' }
    client:connect(h, p, function(err)
      if err then
        ret.error = err
        done = true
        return
      end
      client:read_start(function(rerr, data)
        if rerr then
          ret.error = rerr
          done = true
          client:close()
          return
        end
        if data then
          table.insert(chunks, data)
        else
          done = true
          client:close()
        end
      end)
      client:write(req_str)
    end)
    vim.wait(2000, function() return done end)
    ret.body = table.concat(chunks)
    ret.ok = done
    return ret
  end, req, host, port)
end

describe('http_transport', function()
  before_each(function()
    clear()
    exec_lua(
      function() package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p') .. ';' .. package.path end
    )
  end)

  it('binds an ephemeral port when port=0 and returns the chosen port', function()
    local out = exec_lua(function()
      local http = require('mcp.json_rpc.transport.http')
      local server, port = http.bind('127.0.0.1', 0, {})
      server:terminate()
      return { port = port }
    end)
    eq(true, out.port > 0)
    eq(true, out.port < 65536)
  end)

  it('responds 200 application/json to a POST request that produces a result', function()
    local port = exec_lua(function()
      local http = require('mcp.json_rpc.transport.http')
      local server = require('mcp.server')
      local registry = require('mcp.tool_registry').new()
      registry:register({
        name = 'echo',
        description = 'Echo',
        handler = function(args) return { { type = 'text', text = args.msg } } end,
      })

      local srv
      srv, port = http.bind('127.0.0.1', 0, {
        endpoint = '/mcp',
        allowed_origins = { 'null' },
      })

      local mcp_server = server.new({
        on_request = function() return nil end,
        on_notify = function() end,
        on_exit = function() end,
        on_error = function() end,
        is_closing = function() return false end,
        notify = function() end,
      }, registry)

      srv.on_request = function(method, params) return mcp_server:_dispatch(method, params) end

      return port
    end)

    local resp = http_request(
      '127.0.0.1',
      port,
      'POST',
      '/mcp',
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}',
      {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json, text/event-stream',
        ['Origin'] = 'null',
      }
    )

    eq(true, resp.ok, 'connection error: ' .. tostring(resp.error))
    eq(
      true,
      resp.body:match('HTTP/1.1 200') ~= nil,
      'expected 200, got: ' .. tostring(resp.body):sub(1, 200)
    )
    eq(true, resp.body:match('[Cc]ontent%-[Tt]ype: application/json') ~= nil)
    eq(true, resp.body:match('"protocolVersion":"2025%-03%-26"') ~= nil)
    eq(true, resp.body:match('"serverInfo"') ~= nil)
  end)

  it('responds 202 Accepted to a notification POST', function()
    local port = exec_lua(function()
      local http = require('mcp.json_rpc.transport.http')
      local srv
      srv, port = http.bind('127.0.0.1', 0, {
        endpoint = '/mcp',
        allowed_origins = { 'null' },
      })

      srv.on_request = function(method, _params)
        -- Capture the dispatched notification so we can verify it ran.
        _G.__last_notif = method
      end

      return port
    end)

    local resp = http_request(
      '127.0.0.1',
      port,
      'POST',
      '/mcp',
      '{"jsonrpc":"2.0","method":"notifications/initialized"}',
      {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json, text/event-stream',
        ['Origin'] = 'null',
      }
    )

    eq(true, resp.ok)
    eq(
      true,
      resp.body:match('HTTP/1.1 202') ~= nil,
      'expected 202, got: ' .. tostring(resp.body):sub(1, 200)
    )

    local last = exec_lua(function() return _G.__last_notif end)
    eq('notifications/initialized', last)
  end)

  it('responds 405 Method Not Allowed to a GET', function()
    local port = exec_lua(function()
      local http = require('mcp.json_rpc.transport.http')
      local srv
      srv, port = http.bind('127.0.0.1', 0, {
        endpoint = '/mcp',
        allowed_origins = { 'null' },
      })
      return port
    end)

    local resp = http_request('127.0.0.1', port, 'GET', '/mcp', '', {
      ['Accept'] = 'text/event-stream',
      ['Origin'] = 'null',
    })

    eq(true, resp.ok)
    eq(
      true,
      resp.body:match('HTTP/1.1 405') ~= nil,
      'expected 405, got: ' .. tostring(resp.body):sub(1, 200)
    )
  end)

  it('rejects requests whose Origin header is not in the allow list', function()
    local port = exec_lua(function()
      local http = require('mcp.json_rpc.transport.http')
      local srv
      srv, port = http.bind('127.0.0.1', 0, {
        endpoint = '/mcp',
        allowed_origins = { 'https://allowed.example' },
      })
      return port
    end)

    local resp =
      http_request('127.0.0.1', port, 'POST', '/mcp', '{"jsonrpc":"2.0","id":1,"method":"ping"}', {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json',
        ['Origin'] = 'https://attacker.example',
      })

    eq(true, resp.ok)
    eq(
      true,
      resp.body:match('HTTP/1.1 403') ~= nil,
      'expected 403, got: ' .. tostring(resp.body):sub(1, 200)
    )
  end)
end)
