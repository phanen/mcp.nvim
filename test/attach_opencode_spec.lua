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
        http.post_json = function(url, body, _opts, on_done)
          _G.__captured = { url = url, body = body }
          vim.schedule(
            function() on_done({ status = 200, body = '{"nvim":{"status":"connected"}}' }, nil) end
          )
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
      http.post_json = function(url, body, _opts, on_done)
        table.insert(calls, { url = url, body = body })
        vim.schedule(
          function() on_done({ status = 200, body = '{"nvim":{"status":"connected"}}' }, nil) end
        )
      end

      local mcp = require('mcp')
      mcp.setup({})
      mcp.attach_opencode({ name = 'nvim' })

      fake_em._subs['custom.server_ready']({ url = 'http://127.0.0.1:4096' })
      -- Simulate opencode.nvim emitting on its state store. The
      -- callback signature is cb(key, new_val, old_val); we ignore
      -- the key/old_val args. These two fire back-to-back inside the
      -- 200ms debounce window; the cwd change gets suppressed by the
      -- last_registered_directory check (its value is the same as
      -- the initial server_ready POST), and the active_session
      -- change carries a *different* directory so it wins and gets
      -- posted.
      store_subs['current_cwd']('current_cwd', '/home/phan/b/projA', '/home/phan/b/projA')
      store_subs['active_session'](
        'active_session',
        { id = 's1', directory = '/home/phan/b/projC' },
        nil
      )

      -- Wait past the 200ms debounce so the coalesced POST fires.
      vim.wait(500, function() return #calls >= 2 end)

      return {
        calls = calls,
        -- Compute the expected encoded directories inside the sandbox;
        -- vim.uri_encode is not available in the test runner.
        enc_a = vim.uri_encode('/home/phan/b/projA', 'rfc3986'),
        enc_b = vim.uri_encode('/home/phan/b/projB', 'rfc3986'),
        enc_c = vim.uri_encode('/home/phan/b/projC', 'rfc3986'),
      }
    end)

    -- server_ready fires immediately, the cwd change is suppressed
    -- (same directory as the server_ready POST), and the active_session
    -- change (different directory) collapses with the debounce into
    -- one debounced POST.
    eq(2, #out.calls, 'expected 2 POSTs total (server_ready + debounced)')
    -- First POST: triggered by custom.server_ready with cwd=projA.
    eq(
      true,
      out.calls[1].url:find('directory=' .. out.enc_a) ~= nil,
      'first POST should target projA, got: ' .. out.calls[1].url
    )
    -- Second: the debounced POST should carry projC, the directory
    -- the active_session event pushed (cwd was suppressed as no-op).
    eq(
      true,
      out.calls[2].url:find('directory=' .. out.enc_c) ~= nil,
      'debounced POST should target projC, got: ' .. out.calls[2].url
    )
  end)

  it('is a no-op when opencode.nvim is not installed', function()
    local out = exec_lua(function()
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

  it(
    'defers until the opencode.nvim EventManager becomes available and then completes the wire',
    function()
      local out = exec_lua(function()
        local fake_em = { _subs = {}, _calls = {} }
        fake_em.subscribe = function(self, event, cb) fake_em._subs[event] = cb end

        -- The store has to be able to deliver changes synchronously
        -- for the test; we mirror the opencode.nvim store API
        -- (subscribe + mutate-by-callback).
        local store_listeners = {}
        local store_state = { event_manager = nil, current_cwd = '/home/x' }
        local function fire(key)
          for _, cb in ipairs(store_listeners[key] or {}) do
            cb(key, store_state[key], nil)
          end
          for _, cb in ipairs(store_listeners['*'] or {}) do
            cb(key, store_state[key], nil)
          end
        end
        local store = {}
        function store.subscribe(key, cb)
          store_listeners[key] = store_listeners[key] or {}
          table.insert(store_listeners[key], cb)
        end
        function store.set(key, value)
          store_state[key] = value
          fire(key)
        end
        function store.get(key) return store_state[key] end

        -- opencode.nvim's first call sees EventManager == nil; the
        -- second time the store fires we should auto-wire.
        package.loaded['opencode.state'] = {
          event_manager = nil,
          store = store,
        }

        local http = require('mcp.util.http_client')
        http.post_json = function(url, body, _opts, on_done)
          vim.schedule(
            function() on_done({ status = 200, body = '{"nvim":{"status":"connected"}}' }, nil) end
          )
        end

        local mcp = require('mcp')
        mcp.setup({})
        mcp.attach_opencode({ name = 'my-nvim' })

        local first_state = mcp._state.opencode_attached
        -- Simulate opencode.nvim publishing the EventManager after its
        -- final setup step.
        store.set('event_manager', fake_em)
        local second_state = mcp._state.opencode_attached

        return {
          first_state = first_state,
          second_state = second_state,
        }
      end)

      eq(false, out.first_state, 'should not be attached until EventManager is published')
      eq(true, out.second_state, 'should auto-attach once EventManager is published')
    end
  )

  it('debounces bursts of cwd changes into a single POST', function()
    local out = exec_lua(function()
      local fake_em = { _subs = {} }
      fake_em.subscribe = function(self, event, cb) fake_em._subs[event] = cb end

      local store_listeners = {}
      local store_state = { event_manager = nil, current_cwd = '/home/a' }
      local function fire(key)
        for _, cb in ipairs(store_listeners[key] or {}) do
          cb(key, store_state[key], nil)
        end
        for _, cb in ipairs(store_listeners['*'] or {}) do
          cb(key, store_state[key], nil)
        end
      end
      local store = {}
      function store.subscribe(key, cb)
        store_listeners[key] = store_listeners[key] or {}
        table.insert(store_listeners[key], cb)
      end
      function store.set(key, value)
        store_state[key] = value
        fire(key)
      end
      function store.get(key) return store_state[key] end

      local calls = {}
      package.loaded['opencode.state'] = {
        event_manager = fake_em,
        store = store,
      }
      local http = require('mcp.util.http_client')
      http.post_json = function(url, body, _opts, on_done)
        table.insert(calls, { url = url, body = body })
        vim.schedule(
          function() on_done({ status = 200, body = '{"nvim":{"status":"connected"}}' }, nil) end
        )
      end

      local mcp = require('mcp')
      mcp.setup({})
      mcp.attach_opencode({ name = 'my-nvim' })
      store.set('event_manager', fake_em)

      -- First POST: triggered by custom.server_ready.
      fake_em._subs['custom.server_ready']({ url = 'http://127.0.0.1:4096' })

      -- A burst of cwd changes (e.g. opencode.nvim's init path
      -- calling set_current_cwd a couple of times). Within the
      -- 200ms debounce window, only one POST should fire.
      store.set('current_cwd', '/home/a')
      store.set('current_cwd', '/home/b')
      store.set('current_cwd', '/home/c')

      -- Wait past the 200ms debounce.
      vim.wait(500, function() return #calls >= 2 end)

      return { calls = calls }
    end)

    eq(2, #out.calls, 'expected server_ready + one debounced cwd POST')
    -- The single debounced POST should target the LAST cwd value.
    -- The directory is encoded into the URL query string, so the URL
    -- for the debounced POST should reference /home/c.
    eq(true, out.calls[2].url:find('/home/c') ~= nil, out.calls[2].url)
  end)

  it(
    'POSTs directly when opencode.nvim is already connected (no custom.server_ready fires again)',
    function()
      local out = exec_lua(function()
        local fake_em = { _subs = {}, _calls = 0 }
        fake_em.subscribe = function(self, event, cb)
          fake_em._subs[event] = cb
          fake_em._calls = fake_em._calls + 1
        end

        local store_listeners = {}
        local store_state = {
          -- The Scenario 1 signature: opencode.nvim is already
          -- connected to its server before mcp.nvim's attach_opencode
          -- runs. state.opencode_server.url is populated; only the
          -- store and event_manager are exposed.
          event_manager = fake_em,
          opencode_server = { url = 'http://127.0.0.1:4096', port = 4096 },
          current_cwd = '/home/phan/b/proj',
        }
        local function fire(key)
          for _, cb in ipairs(store_listeners[key] or {}) do
            cb(key, store_state[key], nil)
          end
        end
        local store = {}
        function store.subscribe(key, cb)
          store_listeners[key] = store_listeners[key] or {}
          table.insert(store_listeners[key], cb)
        end
        function store.set(key, value)
          store_state[key] = value
          fire(key)
        end
        function store.get(key) return store_state[key] end
        store_state.store = store

        local calls = {}
        package.loaded['opencode.state'] = store_state
        local http = require('mcp.util.http_client')
        http.post_json = function(url, body, _opts, on_done)
          table.insert(calls, { url = url, body = body })
          vim.schedule(
            function() on_done({ status = 200, body = '{"nvim":{"status":"connected"}}' }, nil) end
          )
        end

        local mcp = require('mcp')
        mcp.setup({})
        -- attach_opencode runs AFTER :Opencode toggle. custom.server_ready
        -- has already fired in opencode.nvim; no new emission will happen.
        mcp.attach_opencode({ name = 'my-nvim' })

        return {
          calls = calls,
          attached = mcp._state.opencode_attached,
          -- The fast path should NOT have subscribed to custom.server_ready
          -- (otherwise the second call from opencode.nvim's later event
          -- would be a no-op since we already registered, but a stale
          -- subscription would still live).
          subscribe_count = fake_em._calls,
          -- Expose the raw URL for debugging the test itself; the
          -- printable form below also shows it on failure.
          raw_url = calls[1] and calls[1].url or '',
        }
      end)

      eq(true, out.attached)
      eq(
        1,
        #out.calls,
        'expected exactly one POST (the direct read of state.opencode_server.url), got calls='
          .. vim.inspect(out.calls)
      )
      local v = out.calls[1]
        and out.calls[1].url
        and (out.calls[1].url:find('127.0.0.1:4096', 1, true) ~= nil)
      eq(
        true,
        v,
        'expected URL to contain 127.0.0.1:4096, got: '
          .. (out.calls[1] and out.calls[1].url or 'no call')
      )
      -- Body carries the mcp server URL and the workspace directory.
      -- Body carries name + the mcp server URL + type=remote. (The
      -- `?directory=` query param is in the URL, not the body.)
      eq(
        true,
        out.calls[1]
          and out.calls[1].body
          and out.calls[1].body:find('"name":"my-nvim"', 1, true) ~= nil,
        'body should carry name=my-nvim, got: '
          .. tostring(out.calls[1] and out.calls[1].body or 'no body')
      )
      eq(
        true,
        out.calls[1]
          and out.calls[1].body
          and out.calls[1].body:find('"type":"remote"', 1, true) ~= nil,
        'body should carry type=remote, got: '
          .. tostring(out.calls[1] and out.calls[1].body or 'no body')
      )
    end
  )
end)
