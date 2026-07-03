-- mcp.tests.server_spec
--
-- Unit tests for the MCP protocol layer (initialize, tools/list,
-- tools/call, ping). These tests poke Server._dispatch directly
-- rather than going through a live Connection, so they can assert
-- on handler return values without racing against vim.schedule.

local h = require('test.helpers')

local eq = h.eq
local exec_lua = h.exec_lua

describe('server', function()
  before_each(function() h.setup() end)

  it('returns -32603 if tools/list is called before initialize', function()
    local out = exec_lua(function()
      local server = require('mcp.server')
      local registry = require('mcp.tool_registry').new()
      local fake_conn = {
        on_request = function() end,
        on_notify = function() end,
        on_exit = function() end,
        on_error = function() end,
        is_closing = function() return false end,
        notify = function() end,
      }
      local s = server.new(fake_conn, registry)
      local _, err = s:_dispatch('tools/list', nil)
      return err
    end)
    eq(-32603, out.code)
  end)

  it('responds to initialize with protocol version, capabilities, serverInfo', function()
    local out = exec_lua(function()
      local server = require('mcp.server')
      local registry = require('mcp.tool_registry').new()
      local fake_conn = {
        on_request = function() end,
        on_notify = function() end,
        on_exit = function() end,
        on_error = function() end,
        is_closing = function() return false end,
        notify = function() end,
      }
      local s = server.new(fake_conn, registry)
      local result = s:_dispatch('initialize', {
        protocolVersion = '2025-03-26',
        capabilities = { roots = { listChanged = true } },
        clientInfo = { name = 'test-client', version = '1.0.0' },
      })
      return result
    end)
    eq('2025-03-26', out.protocolVersion)
    eq('mcp.nvim', out.serverInfo.name)
    eq(true, out.capabilities.tools.listChanged)
    eq(true, out.capabilities.logging ~= nil)
  end)

  it('rejects a second initialize call', function()
    local out = exec_lua(function()
      local server = require('mcp.server')
      local registry = require('mcp.tool_registry').new()
      local fake_conn = {
        on_request = function() end,
        on_notify = function() end,
        on_exit = function() end,
        on_error = function() end,
        is_closing = function() return false end,
        notify = function() end,
      }
      local s = server.new(fake_conn, registry)
      s:_dispatch('initialize', { protocolVersion = '2025-03-26' })
      local _, err = s:_dispatch('initialize', { protocolVersion = '2025-03-26' })
      return err
    end)
    eq(-32603, out.code)
  end)

  it('lists tools registered before initialize', function()
    local out = exec_lua(function()
      local server = require('mcp.server')
      local registry = require('mcp.tool_registry').new()
      local fake_conn = {
        on_request = function() end,
        on_notify = function() end,
        on_exit = function() end,
        on_error = function() end,
        is_closing = function() return false end,
        notify = function() end,
      }
      local s = server.new(fake_conn, registry)

      registry:register({
        name = 'echo',
        description = 'Echo a message back',
        inputSchema = {
          type = 'object',
          properties = { msg = { type = 'string' } },
          required = { 'msg' },
        },
        handler = function(args) return { { type = 'text', text = args.msg } } end,
      })
      registry:register({
        name = 'sum',
        description = 'Add two numbers',
        inputSchema = {
          type = 'object',
          properties = {
            a = { type = 'number' },
            b = { type = 'number' },
          },
          required = { 'a', 'b' },
        },
        handler = function(args) return { { type = 'text', text = tostring(args.a + args.b) } } end,
      })

      s:_dispatch('initialize', { protocolVersion = '2025-03-26' })
      s:_on_notify('notifications/initialized', nil)
      local result = s:_dispatch('tools/list', nil)
      -- Return serializable summary.
      local names = {}
      for _, t in ipairs(result.tools) do
        table.insert(names, t.name)
      end
      return names
    end)
    eq(2, #out)
    eq(true, out[1] == 'echo' or out[1] == 'sum')
    eq(true, out[2] == 'echo' or out[2] == 'sum')
    eq(true, out[1] ~= out[2])
  end)

  it('tools/list JSON-encodes without empty-table -> [] pitfalls', function()
    -- Empty Lua tables serialise as `[]` via `vim.json.encode`, but the
    -- MCP SDK's `ToolSchema` requires `inputSchema.properties` to be a
    -- plain JSON object. Tools with no arguments must omit `properties`
    -- (or use `vim.empty_dict()`); never leave `properties = {}`.
    local out = exec_lua(function()
      local server = require('mcp.server')
      local registry = require('mcp.tool_registry').new()
      local s = server.new({
        on_request = function() end,
        on_notify = function() end,
        on_exit = function() end,
        on_error = function() end,
        is_closing = function() return false end,
        notify = function() end,
      }, registry)

      -- Use the module directly; this test guards the shape the
      -- tool author ships, not the `register()` flow.
      registry:register(require('mcp.tools.nvim.quickfix'))
      s:_dispatch('initialize', { protocolVersion = '2025-03-26' })
      s:_on_notify('notifications/initialized', nil)
      local result = s:_dispatch('tools/list', nil)

      local encoded = vim.json.encode(result)
      local offending = {}
      for _, tool in ipairs(result.tools) do
        local props = tool.inputSchema and tool.inputSchema.properties
        if type(props) == 'table' and not props[1] and next(props) == nil then
          -- empty Lua table: harmless in memory, but encodes as `[]`
          offending[#offending + 1] = tool.name
        end
      end
      return { offending = offending, encoded = encoded }
    end)
    eq(0, #out.offending, 'tools encode empty properties as `[]`: ' .. vim.inspect(out.offending))
    -- belt-and-braces: assert the literal string never appears either.
    eq(
      true,
      not out.encoded:find('"properties":[]', 1, true),
      'encoded JSON contains "properties":[]'
    )
  end)

  it('invokes a registered tool and wraps the return value', function()
    local out = exec_lua(function()
      local server = require('mcp.server')
      local registry = require('mcp.tool_registry').new()
      local fake_conn = {
        on_request = function() end,
        on_notify = function() end,
        on_exit = function() end,
        on_error = function() end,
        is_closing = function() return false end,
        notify = function() end,
      }
      local s = server.new(fake_conn, registry)

      registry:register({
        name = 'echo',
        description = 'Echo a message',
        handler = function(args) return { { type = 'text', text = 'you said: ' .. args.msg } } end,
      })

      s:_dispatch('initialize', { protocolVersion = '2025-03-26' })
      s:_on_notify('notifications/initialized', nil)
      local result = s:_dispatch('tools/call', {
        name = 'echo',
        arguments = { msg = 'hello' },
      })
      return result
    end)
    eq(false, out.isError)
    eq(1, #out.content)
    eq('text', out.content[1].type)
    eq('you said: hello', out.content[1].text)
  end)

  it('returns isError=true when a handler throws', function()
    local out = exec_lua(function()
      local server = require('mcp.server')
      local registry = require('mcp.tool_registry').new()
      local fake_conn = {
        on_request = function() end,
        on_notify = function() end,
        on_exit = function() end,
        on_error = function() end,
        is_closing = function() return false end,
        notify = function() end,
      }
      local s = server.new(fake_conn, registry)

      registry:register({
        name = 'broken',
        description = 'Always throws',
        handler = function() error('something went wrong') end,
      })

      s:_dispatch('initialize', { protocolVersion = '2025-03-26' })
      s:_on_notify('notifications/initialized', nil)
      local result = s:_dispatch('tools/call', { name = 'broken', arguments = {} })
      return result
    end)
    eq(true, out.isError)
    eq(true, out.content[1].text:find('something went wrong') ~= nil)
  end)

  it('returns invalid_params when calling an unknown tool', function()
    local out = exec_lua(function()
      local server = require('mcp.server')
      local registry = require('mcp.tool_registry').new()
      local fake_conn = {
        on_request = function() end,
        on_notify = function() end,
        on_exit = function() end,
        on_error = function() end,
        is_closing = function() return false end,
        notify = function() end,
      }
      local s = server.new(fake_conn, registry)

      s:_dispatch('initialize', { protocolVersion = '2025-03-26' })
      s:_on_notify('notifications/initialized', nil)
      local _, err = s:_dispatch('tools/call', { name = 'no-such-tool', arguments = {} })
      return err
    end)
    eq(-32602, out.code)
  end)

  it('answers ping regardless of state', function()
    local out = exec_lua(function()
      local server = require('mcp.server')
      local registry = require('mcp.tool_registry').new()
      local fake_conn = {
        on_request = function() end,
        on_notify = function() end,
        on_exit = function() end,
        on_error = function() end,
        is_closing = function() return false end,
        notify = function() end,
      }
      local s = server.new(fake_conn, registry)
      -- pre-initialize
      local result = s:_dispatch('ping', nil)
      return result
    end)
    eq('table', type(out))
  end)
end)
