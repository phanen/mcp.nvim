-- mcp.tests.attach_opencode_spec
--
-- Tests for `mcp.attach_opencode`. We stub `mcp.util.http_client.post_json`
-- via package.loaded so the test does not have to drive the real
-- libuv + scheduler event pump of the helper. This exercises the
-- auto-wire flow end to end: subscription on the opencode.nvim
-- EventManager, store-driven re-registration on `current_cwd` /
-- `active_session` changes, and the missing-opencode.nvim fallbacks.

local n = require('nvim-test.helpers')

local eq = n.eq
local clear = n.clear
local exec_lua = n.exec_lua

describe('attach_opencode', function()
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
      mcp._state.opencode_attached = false
    end)
  end)

  it(
    'wires up an EventManager subscription that fires opencode_register on server_ready',
    function()
      local out = exec_lua(function()
        package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p')
          .. ';'
          .. vim.fn.fnamemodify('./lua/?/init.lua;', ':p')
          .. ';'
          .. package.path

        local fake_em = { _subs = {} }
        fake_em.subscribe = function(self, event, cb) fake_em._subs[event] = cb end
        local fake_store = { _store_subs = {} }
        fake_store.subscribe = function(key, cb) fake_store._store_subs[key] = cb end
        package.loaded['opencode.state'] = {
          event_manager = fake_em,
          store = fake_store,
          current_cwd = '/home/phan/b/proj',
        }

        local http = require('mcp.util.http_client')
        http.post_json = function(url, body, _opts)
          _G.__captured = { url = url, body = body }
          return { status = 200, body = '{"nvim":{"status":"connected"}}' }, nil
        end

        local mcp = require('mcp')
        mcp.setup({})
        mcp.attach_opencode({ name = 'my-nvim' })

        -- Calling attach twice is idempotent.
        mcp.attach_opencode({ name = 'my-nvim' })

        -- Simulate the EventManager firing the server_ready event by
        -- calling the registered callback directly.
        local cb = fake_em._subs['custom.server_ready']
        if type(cb) ~= 'function' then
          return { error = 'no callback registered for custom.server_ready' }
        end
        cb({ url = 'http://127.0.0.1:4096' })

        return {
          captured = _G.__captured,
          -- Compute the expected encoded directory inside the sandbox;
          -- vim.uri_encode is not available in the test runner.
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

  it('re-registers when state.current_cwd changes', function()
    local out = exec_lua(function()
      package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p')
        .. ';'
        .. vim.fn.fnamemodify('./lua/?/init.lua;', ':p')
        .. ';'
        .. package.path

      local fake_em = { _subs = {} }
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
        -- Compute the expected encoded directories inside the sandbox;
        -- vim.uri_encode is not available in the test runner.
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

  it('is a no-op when opencode.nvim is not installed', function()
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

  it('reports a warning when opencode.nvim is loaded but the EventManager is not ready', function()
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
  end)
end)
