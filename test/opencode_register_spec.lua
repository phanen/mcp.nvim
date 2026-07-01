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

  -- We test `attach_opencode` against a stubbed-out opencode.state
  -- module. Because attach_opencode calls `require('opencode.state')`
  -- eagerly, we have to inject our stub into `package.loaded`
  -- before setup runs.
  it(
    'attach_opencode wires up an EventManager subscription that fires opencode_register',
    function()
      local out = exec_lua(function()
        package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p')
          .. ';'
          .. vim.fn.fnamemodify('./lua/?/init.lua;', ':p')
          .. ';'
          .. package.path

        -- Build a fake opencode.state whose `event_manager` field
        -- is an EventManager-shaped object with `subscribe`, and whose
        -- `store` exposes a `subscribe` channel for current_cwd /
        -- active_session updates.
        local fake_em = {
          _subs = {},
        }
        fake_em.subscribe = function(self, event, cb) fake_em._subs[event] = cb end
        local fake_store = {
          _store_subs = {},
        }
        fake_store.subscribe = function(key, cb) fake_store._store_subs[key] = cb end
        package.loaded['opencode.state'] = {
          event_manager = fake_em,
          store = fake_store,
          current_cwd = '/home/phan/b/proj',
        }

        local http = require('mcp.util.http_client')
        http.post_json = function(url, body, _opts)
          _G.__attach_captured = { url = url, body = body }
          return { status = 200, body = '{"nvim":{"status":"connected"}}' }, nil
        end

        local mcp = require('mcp')
        mcp.setup({})
        mcp.attach_opencode({ name = 'my-nvim' })

        -- Calling attach twice is idempotent.
        mcp.attach_opencode({ name = 'my-nvim' })

        -- Simulate the EventManager firing the server_ready event
        -- by calling the registered callback directly. We do the
        -- assertion outside the exec_lua sandbox because the chunk's
        -- upvalues do not survive string.dump the way file-local
        -- `eq` expects.
        local cb = fake_em._subs['custom.server_ready']
        if type(cb) ~= 'function' then
          return { error = 'no callback registered for custom.server_ready' }
        end
        cb({ url = 'http://127.0.0.1:4096' })

        return {
          captured = _G.__attach_captured,
          -- Compute the expected encoded directory inside the
          -- sandbox; vim.uri_encode is not available in the test
          -- runner.
          expected_dir = vim.uri_encode('/home/phan/b/proj', 'rfc3986'),
        }
      end)

      eq(nil, out.error, 'attach_opencode did not register the callback')
      eq(
        true,
        out.captured.body:find('"name":"my%-nvim"') ~= nil,
        'expected custom name: ' .. tostring(out.captured.body)
      )
      eq(true, out.captured.body:find('"type":"remote"') ~= nil)
      eq(
        true,
        out.captured.url:find('http://127.0.0.1:4096/mcp%?directory=') ~= nil,
        'expected POST to opencode /mcp with ?directory=..., got: ' .. tostring(out.captured.url)
      )
      eq(
        true,
        out.captured.url:find('directory=' .. out.expected_dir) ~= nil,
        'expected directory query to be rfc3986-encoded, got: ' .. tostring(out.captured.url)
      )
    end
  )

  it('attach_opencode re-registers when state.current_cwd changes', function()
    local out = exec_lua(function()
      package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p')
        .. ';'
        .. vim.fn.fnamemodify('./lua/?/init.lua;', ':p')
        .. ';'
        .. package.path

      local fake_em = {
        _subs = {},
      }
      fake_em.subscribe = function(self, event, cb) fake_em._subs[event] = cb end
      local store_subs = {}
      local fake_store = {
        -- The production opencode.nvim state store is a plain module
        -- table whose subscribe uses dot-call (no implicit self), so
        -- we mirror that signature.
        subscribe = function(key, cb) store_subs[key] = cb end,
      }
      package.loaded['opencode.state'] = {
        event_manager = fake_em,
        store = fake_store,
        current_cwd = '/home/phan/b/projA',
      }

      local calls = {}
      local http = require('mcp.util.http_client')
      http.post_json = function(url, body, _opts)
        table.insert(calls, { url = url, body = body })
        return { status = 200, body = '{"nvim":{"status":"connected"}}' }, nil
      end

      local mcp = require('mcp')
      mcp.setup({})
      mcp.attach_opencode({ name = 'nvim' })

      fake_em._subs['custom.server_ready']({ url = 'http://127.0.0.1:4096' })
      -- Simulate opencode.nvim emitting on its state store. The
      -- callback signature is cb(key, new_val, old_val); we ignore
      -- the key/old_val args.
      store_subs['current_cwd']('current_cwd', '/home/phan/b/projB', '/home/phan/b/projA')

      -- And active_session changing to a session anchored elsewhere.
      store_subs['active_session'](
        'active_session',
        { id = 's1', directory = '/home/phan/b/projC' },
        nil
      )

      return {
        calls = calls,
        -- Compute the expected encoded directories inside the
        -- sandbox; vim.uri_encode is not available in the test
        -- runner.
        enc_a = vim.uri_encode('/home/phan/b/projA', 'rfc3986'),
        enc_b = vim.uri_encode('/home/phan/b/projB', 'rfc3986'),
        enc_c = vim.uri_encode('/home/phan/b/projC', 'rfc3986'),
      }
    end)

    eq(3, #out.calls)
    -- First POST: triggered by custom.server_ready with cwd=projA.
    eq(
      true,
      out.calls[1].url:find('directory=' .. out.enc_a) ~= nil,
      'first POST should target projA, got: ' .. out.calls[1].url
    )
    -- Second: cwd changed to projB.
    eq(
      true,
      out.calls[2].url:find('directory=' .. out.enc_b) ~= nil,
      'second POST should target projB, got: ' .. out.calls[2].url
    )
    -- Third: active_session switched to a session in projC.
    eq(
      true,
      out.calls[3].url:find('directory=' .. out.enc_c) ~= nil,
      'third POST should target projC, got: ' .. out.calls[3].url
    )
  end)

  it('attach_opencode is a no-op when opencode.nvim is not installed', function()
    local out = exec_lua(function()
      package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p')
        .. ';'
        .. vim.fn.fnamemodify('./lua/?/init.lua;', ':p')
        .. ';'
        .. package.path
      package.loaded['opencode.state'] = nil
      local mcp = require('mcp')
      mcp.setup({})
      local ok = pcall(mcp.attach_opencode)
      return { ok = ok, attached = mcp._state.opencode_attached }
    end)
    eq(true, out.ok)
    eq(false, out.attached)
  end)

  it(
    'attach_opencode reports a warning when opencode.nvim is loaded but the EventManager is not ready',
    function()
      local out = exec_lua(function()
        package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p')
          .. ';'
          .. vim.fn.fnamemodify('./lua/?/init.lua;', ':p')
          .. ';'
          .. package.path
        -- opencode.state without an event_manager field
        package.loaded['opencode.state'] = {}
        local mcp = require('mcp')
        mcp.setup({})
        local ok = pcall(mcp.attach_opencode)
        return { ok = ok, attached = mcp._state.opencode_attached }
      end)
      eq(true, out.ok)
      eq(false, out.attached)
    end
  )
end)
