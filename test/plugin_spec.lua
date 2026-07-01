-- mcp.tests.plugin_spec
--
-- End-to-end tests of the mcp.nvim public API: setup(), start/stop,
-- and a full round-trip HTTP request through the live plugin instance.

local n = require('nvim-test.helpers')

local eq = n.eq
local clear = n.clear
local exec_lua = n.exec_lua

--- Drive a raw HTTP/1.1 request via `vim.uv.new_tcp`.
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

describe('plugin', function()
  before_each(function()
    clear()
    exec_lua(function()
      package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p')
        .. ';'
        .. vim.fn.fnamemodify('./lua/?/init.lua;', ':p')
        .. ';'
        .. package.path
      -- Reset plugin state so tests do not bleed.
      local mcp = require('mcp')
      mcp.stop()
      mcp._state.setup_done = false
      mcp._state.registry = nil
      mcp._state.server = nil
      mcp._state.http_server = nil
      mcp._state.http_port = nil
    end)
  end)

  it('setup() with no arguments starts the HTTP server on an ephemeral port', function()
    local port = exec_lua(function()
      local mcp = require('mcp')
      mcp.setup({})
      return mcp.http_port()
    end)
    eq(true, port > 0 and port < 65536)
  end)

  it('registers tools passed in opts.tools', function()
    local out = exec_lua(function()
      local mcp = require('mcp')
      mcp.setup({
        http = { enabled = false },
        tools = {
          {
            name = 'greet',
            description = 'Say hello',
            handler = function(args) return { { type = 'text', text = 'hi ' .. args.name } } end,
          },
        },
      })
      local tools = mcp.registry():list()
      local names = {}
      for _, t in ipairs(tools) do
        table.insert(names, t.name)
      end
      return { setup = mcp._state.setup_done, names = names, count = #tools }
    end)
    eq(true, out.setup)
    eq(1, out.count)
    eq('greet', out.names[1])
  end)

  it('stop() closes the HTTP server', function()
    local out = exec_lua(function()
      local mcp = require('mcp')
      mcp.setup({})
      local before = mcp.http_port()
      mcp.stop()
      local after = mcp.http_port()
      return { before = before, after = after }
    end)
    eq(true, out.before > 0)
    eq(nil, out.after)
  end)

  it(
    'a full POST /mcp round-trip through setup() returns a JSON-RPC initialize response',
    function()
      local port = exec_lua(function()
        local mcp = require('mcp')
        mcp.setup({
          http = { enabled = true, allowed_origins = { 'null' } },
          tools = {
            {
              name = 'greet',
              description = 'Say hello',
              handler = function(args) return { { type = 'text', text = 'hi ' .. args.name } } end,
            },
          },
        })
        return mcp.http_port()
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

      eq(true, resp.ok)
      eq(true, resp.body:match('HTTP/1.1 200') ~= nil)
      eq(true, resp.body:match('"serverInfo"') ~= nil)
      eq(true, resp.body:match('"name":"mcp%.nvim"') ~= nil)
    end
  )

  it('POST /mcp tools/call invokes a registered tool end-to-end', function()
    local port = exec_lua(function()
      local mcp = require('mcp')
      mcp.setup({
        http = { enabled = true, allowed_origins = { 'null' } },
        tools = {
          {
            name = 'greet',
            description = 'Say hello',
            handler = function(args) return { { type = 'text', text = 'hi ' .. args.name } } end,
          },
        },
      })
      return mcp.http_port()
    end)

    -- Drive the full lifecycle: initialize (Created -> Negotiating),
    -- then send the initialized notification (Negotiating -> Ready),
    -- then call a tool. The state machine refuses tool calls until
    -- both have happened.
    local init_resp = http_request(
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
    eq(true, init_resp.ok)
    eq(true, init_resp.body:match('"protocolVersion"') ~= nil)

    local ready_resp = http_request(
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
    eq(true, ready_resp.ok)
    eq(true, ready_resp.body:match('HTTP/1.1 202') ~= nil)

    local resp = http_request(
      '127.0.0.1',
      port,
      'POST',
      '/mcp',
      '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"greet","arguments":{"name":"world"}}}',
      {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json, text/event-stream',
        ['Origin'] = 'null',
      }
    )

    eq(true, resp.ok)
    eq(true, resp.body:match('HTTP/1.1 200') ~= nil)
    eq(
      true,
      resp.body:match('hi world') ~= nil,
      'expected tool output in response, got: ' .. tostring(resp.body)
    )
  end)

  it('restart() rebinds the server with the same options', function()
    local out = exec_lua(function()
      local mcp = require('mcp')
      mcp.setup({})
      local port1 = mcp.http_port()
      mcp.restart()
      local port2 = mcp.http_port()
      return { port1 = port1, port2 = port2 }
    end)
    eq(true, out.port1 > 0 and out.port2 > 0)
  end)

  it(':checkhealth mcp reports the number of registered tools', function()
    local ok = exec_lua(function()
      local mcp = require('mcp')
      mcp.setup({
        http = { enabled = false },
        tools = {
          { name = 'a', description = 'A', handler = function() return {} end },
          { name = 'b', description = 'B', handler = function() return {} end },
        },
      })

      local rows = require('mcp.health').check()
      local count_text = nil
      for _, r in ipairs(rows) do
        if r[2] and r[2]:match('tool%(s%) registered') then count_text = r[2] end
      end
      return count_text
    end)
    eq('2 tool(s) registered', ok)
  end)
end)
