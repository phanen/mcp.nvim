-- mcp.tests.opencode_register_spec
--
-- Tests for the opencode `mcp.add` integration. The
-- `mcp.opencode_register` helper does an HTTP POST. To keep the
-- test independent of network and libuv/event-pump plumbing, we
-- stub `vim.fn.system` so the helper synchronously receives the
-- fake response. This is the easiest way to test the wire format
-- without having to bootstrap a real opencode server.

local n = require('nvim-test.helpers')

local eq = n.eq
local clear = n.clear
local exec_lua = n.exec_lua

--- Install `vim.fn.system` shims that the helper will use. In
--- production the helper goes through `mcp.util.http_client.post_json`
--- (vim.uv + vim.schedule), but for unit testing we replace it
--- with a synchronous stub so the test does not have to drive the
--- libuv + scheduler event pumps of the real implementation.
local function with_http_stub(stub_lua, body)
  return exec_lua([[
      _G.__orig_system = vim.fn.system
      _G.__orig_systemlist = vim.fn.systemlist
    ]] .. stub_lua .. '\n' .. body)
end

describe('opencode_register', function()
  before_each(function()
    clear()
    exec_lua(function()
      package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p')
        .. ';'
        .. vim.fn.fnamemodify('./lua/?/init.lua;', ':p')
        .. ';'
        .. package.path

      local mcp = require('mcp')
      mcp.stop()
      mcp._state.setup_done = false
      mcp._state.registry = nil
      mcp._state.server = nil
      mcp._state.http_server = nil
      mcp._state.http_port = nil
    end)
  end)

  after_each(function()
    exec_lua(function()
      if _G.__orig_system then
        vim.fn.system = _G.__orig_system
        vim.fn.systemlist = _G.__orig_systemlist
      end
    end)
  end)

  -- Install a stub for `vim.fn.system` that returns a canned HTTP
  -- response. The helper uses `vim.fn.system({'curl', ...})` only
  -- when the user opts into that code path; in our case we patch
  -- the helper's POST path directly via package.loaded.
  local function stub_http(result)
    return string.format(
      [[
        -- Redirect mcp.util.http_client.post_json to a synchronous stub
        -- by replacing the module's post_json entry point.
        local http = require('mcp.util.http_client')
        http.post_json = function(_url, body, _opts)
          return { status = %d, body = %q }, nil
        end
      ]],
      result.status,
      result.body
    )
  end

  -- Install a stub that simulates an HTTP transport error.
  local function stub_http_err(err)
    return string.format(
      [[
      local http = require('mcp.util.http_client')
      http.post_json = function(_url, _body, _opts) return nil, %q end
    ]],
      err
    )
  end

  it('returns {ok=false, error=...} when the HTTP server is not running', function()
    local out = exec_lua(function()
      local mcp = require('mcp')
      return mcp.opencode_register('http://127.0.0.1:1')
    end)
    eq(false, out.ok)
    eq(true, out.error:find('not running') ~= nil, tostring(out.error))
  end)

  it('sends a POST with name + remote config pointing at our URL', function()
    with_http_stub(
      stub_http({ status = 200, body = '{"nvim":{"status":"connected"}}' }),
      [[
        local mcp = require('mcp')
        mcp.setup({})
        _G.__our_url = mcp.url()
        _G.__result = mcp.opencode_register('http://127.0.0.1:4096')
        return {
          result = _G.__result,
          url = _G.__our_url,
        }
      ]]
    )
    -- The two exec_lua calls share _G through the test process; the
    -- second call reads back what the first one captured.
    local out = exec_lua(function() return { result = _G.__result, url = _G.__our_url } end)

    eq(true, out.result.ok)
    eq(200, out.result.status)
    eq('table', type(out.result.body))
    eq('connected', out.result.body.nvim.status)

    -- The URL the helper sends must equal mcp.url().
    eq(true, type(out.url) == 'string', tostring(out.url))
  end)

  it('uses a custom name when supplied', function()
    local captured_url = nil
    local captured_body = nil
    local stub = string.format([[
        local http = require('mcp.util.http_client')
        http.post_json = function(url, body, _opts)
          _G.__captured = { url = url, body = body }
          return { status = 200, body = '' }, nil
        end
      ]])
    with_http_stub(
      stub,
      [[
      local mcp = require('mcp')
      mcp.setup({})
      mcp.opencode_register('http://127.0.0.1:4096', { name = 'my-nvim' })
    ]]
    )
    local captured = exec_lua(function() return _G.__captured end)
    eq(
      true,
      captured.body:find('"name":"my%-nvim"') ~= nil,
      'expected name: ' .. tostring(captured.body)
    )
  end)

  it('propagates a 4xx response as {ok=false, status=400, error=...}', function()
    with_http_stub(
      stub_http({ status = 400, body = '{"error":"bad config"}' }),
      [[
        local mcp = require('mcp')
        mcp.setup({})
        _G.__result = mcp.opencode_register('http://127.0.0.1:4096')
        return _G.__result
      ]]
    )
    local out = exec_lua(function() return _G.__result end)
    eq(false, out.ok)
    eq(400, out.status)
    eq(true, out.error:find('bad config') ~= nil, tostring(out.error))
  end)

  it('returns {ok=false, error=...} when the HTTP transport errors', function()
    with_http_stub(
      stub_http_err('connect refused'),
      [[
        local mcp = require('mcp')
        mcp.setup({})
        _G.__result = mcp.opencode_register('http://127.0.0.1:1', { timeout_ms = 200 })
        return _G.__result
      ]]
    )
    local out = exec_lua(function() return _G.__result end)
    eq(false, out.ok)
    eq(true, out.error:find('refused') ~= nil, tostring(out.error))
  end)
end)
