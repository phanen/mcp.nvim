-- mcp.tests.plugin_spec
--
-- End-to-end tests of the mcp.nvim public API: setup(), start/stop,
-- and a full round-trip HTTP request through the live plugin instance.

local h = require('test.helpers')

local eq = h.eq
local exec_lua = h.exec_lua

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
    h.setup(function()
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

  it(
    'GET /mcp through setup() opens an SSE stream and tool registration broadcasts to it',
    function()
      local out = exec_lua(function()
        local mcp = require('mcp')
        local uv = vim.uv or vim.loop

        mcp.setup({
          http = { enabled = true, allowed_origins = { 'null' } },
          tools = {},
        })
        local port = mcp.http_port()

        -- Open an SSE stream against the live plugin instance.
        local client = uv.new_tcp()
        local chunks = {}
        client:connect('127.0.0.1', port, function(err)
          if err then return end
          client:read_start(function(_, data)
            if data then table.insert(chunks, data) end
          end)
          client:write(
            'GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
              .. 'Accept: text/event-stream\r\nOrigin: null\r\n'
              .. 'Connection: keep-alive\r\n\r\n'
          )
        end)

        -- Wait for the GET response + heartbeat to land so we know
        -- the server has registered the stream before we register a
        -- tool.
        vim.wait(
          500,
          function() return table.concat(chunks):find('text/event-stream', 1, true) ~= nil end
        )

        -- Register a fresh tool post-setup. The registry's
        -- `notifications/tools/list_changed` notification should
        -- ride the SSE stream we just opened.
        mcp.registry():register({
          name = 'late_added',
          description = 'Registered after the SSE stream was open',
          handler = function() return {} end,
        })

        -- Wait for the list_changed event to arrive on the SSE
        -- stream. TCP may split it across reads, so check the
        -- concatenation rather than individual chunks.
        local function has_list_changed()
          return table.concat(chunks):find('notifications/tools/list_changed', 1, true) ~= nil
        end
        -- Older Neovim releases have slower libuv under the test
        -- runner; leave plenty of headroom.
        local arrived = vim.wait(5000, has_list_changed)

        local payload = table.concat(chunks)
        client:close()
        mcp.stop()

        return {
          got_sse_headers = payload:find('text/event-stream', 1, true) ~= nil,
          got_list_changed = payload:find('notifications/tools/list_changed', 1, true) ~= nil,
          wait_exit = arrived,
        }
      end)

      eq(true, out.got_sse_headers, 'GET did not return text/event-stream')
      eq(true, out.wait_exit, 'list_changed notification did not arrive within 2s')
      eq(true, out.got_list_changed)
    end
  )

  it('register() errors before setup() is called', function()
    local ok, err = exec_lua(function()
      local mcp = require('mcp')
      return pcall(function()
        mcp.register({ name = 'x', description = 'x', handler = function() end })
      end)
    end)
    eq(false, ok)
    eq(true, type(err) == 'string' and err:find('setup') ~= nil, tostring(err))
  end)

  it('register({ mod = "..." }) registers a built-in tool module', function()
    local out = exec_lua(function()
      local mcp = require('mcp')
      mcp.setup({ http = { enabled = false } })
      mcp.register({ mod = 'mcp.tools.lsp.definition' })
      local def = mcp.registry():get('lsp_definition')
      return {
        name = def and def.name or nil,
        has_handler = type(def and def.handler) == 'function',
      }
    end)
    eq('lsp_definition', out.name)
    eq(true, out.has_handler)
  end)

  it('register({ mod = "..." }) works for a module that returns a ToolDef table', function()
    local ok, err = exec_lua(function()
      local mcp = require('mcp')
      mcp.setup({ http = { enabled = false } })
      return pcall(function() mcp.register({ mod = 'mcp.tools.lsp.definition' }) end)
    end)
    eq(true, ok, tostring(err))
  end)

  it('register({ name = ..., handler = ... }) registers an inline tool', function()
    local out = exec_lua(function()
      local mcp = require('mcp')
      mcp.setup({ http = { enabled = false } })
      mcp.register({
        name = 'greet',
        description = 'Say hi',
        handler = function(args) return { { type = 'text', text = 'hi ' .. args.name } } end,
      })
      local def = mcp.registry():get('greet')
      local result = def.handler({ name = 'world' })
      return { name = def.name, text = result[1].text }
    end)
    eq('greet', out.name)
    eq('hi world', out.text)
  end)

  it('register() with the same name overrides the previous tool', function()
    local out = exec_lua(function()
      local mcp = require('mcp')
      mcp.setup({ http = { enabled = false } })
      mcp.register({
        name = 'greet',
        description = 'first',
        handler = function() return { { type = 'text', text = 'first' } } end,
      })
      mcp.register({
        name = 'greet',
        description = 'second',
        handler = function() return { { type = 'text', text = 'second' } } end,
      })
      local def = mcp.registry():get('greet')
      local result = def.handler({})
      return { description = def.description, text = result[1].text }
    end)
    eq('second', out.description)
    eq('second', out.text)
  end)

  it('register({ mod = "..." }) still supports a factory (opts) -> ToolDef module', function()
    -- For backward compat, modules may export `(opts) -> ToolDef` factories.
    -- `opts` from the spec is forwarded; modules returning a plain
    -- ToolDef table ignore `opts`.
    local out = exec_lua(function()
      local mcp = require('mcp')
      mcp.setup({ http = { enabled = false } })
      package.loaded['mcp_test_factory_tool'] = nil
      package.loaded['mcp_test_factory_tool'] = function(opts)
        return {
          name = 'greet',
          description = 'factory-built',
          handler = function() return { { type = 'text', text = opts and opts.greeting or 'hi' } } end,
        }
      end
      mcp.register({
        mod = 'mcp_test_factory_tool',
        opts = { greeting = 'hello' },
      })
      local def = mcp.registry():get('greet')
      return def.handler({})[1].text
    end)
    eq('hello', out)
  end)

  it('register({ spec1, spec2, ... }) registers multiple tools at once', function()
    local out = exec_lua(function()
      local mcp = require('mcp')
      mcp.setup({ http = { enabled = false } })
      mcp.register({
        { mod = 'mcp.tools.lsp.definition' },
        { mod = 'mcp.tools.lsp.hover' },
        { name = 'custom', description = 'custom tool', handler = function() return {} end },
      })
      local names = {}
      for _, t in ipairs(mcp.registry():list()) do
        table.insert(names, t.name)
      end
      table.sort(names)
      return names
    end)
    eq('custom', out[1])
    eq('lsp_definition', out[2])
    eq('lsp_hover', out[3])
  end)

  it(
    'register({ mod = "..." }) errors when the module export is not a function or a ToolDef-shaped table',
    function()
      local ok, err = exec_lua(function()
        local mcp = require('mcp')
        mcp.setup({ http = { enabled = false } })
        package.loaded['mcp_test_bogus'] = nil
        package.loaded['mcp_test_bogus'] = 42
        return pcall(function() mcp.register({ mod = 'mcp_test_bogus' }) end)
      end)
      eq(false, ok)
      eq(
        true,
        type(err) == 'string' and (err:find('table') ~= nil or err:find('function') ~= nil),
        tostring(err)
      )
    end
  )
end)
