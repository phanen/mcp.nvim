local h = require('test.helpers')

local eq = h.eq
local exec_lua = h.exec_lua

describe('attach_opencode', function()
  before_each(function()
    h.setup(function()
      local mcp = require('mcp')
      mcp.stop()
      mcp._state.setup_done = false
      mcp._state.registry = nil
      mcp._state.server = nil
      mcp._state.http_server = nil
      mcp._state.http_port = nil
      require('mcp.integrations.opencode').reset()
    end)
  end)

  it('is a no-op when opencode.nvim is not installed', function()
    local out = exec_lua(function()
      package.loaded['opencode.state'] = nil
      local mcp = require('mcp')
      mcp.setup({})
      local ok = pcall(function() return require('mcp.integrations.opencode').attach() end)
      return { ok = ok, attached = require('mcp.integrations.opencode').is_attached() }
    end)

    eq(true, out.ok)
    eq(false, out.attached)
  end)

  it('is a no-op when opencode.nvim server URL is not set', function()
    local out = exec_lua(function()
      package.loaded['opencode.state'] = { opencode_server = nil }
      local mcp = require('mcp')
      mcp.setup({})
      local ok = pcall(function() return require('mcp.integrations.opencode').attach() end)
      return { ok = ok, attached = require('mcp.integrations.opencode').is_attached() }
    end)

    eq(true, out.ok)
    eq(false, out.attached)
  end)

  it('waits for custom.server_ready when opencode server URL is not yet known', function()
    local out = exec_lua(function()
      local fake_em = { _subs = {} }
      fake_em.subscribe = function(self, event, cb) self._subs[event] = cb end
      fake_em.unsubscribe = function(self, event, cb)
        if self._subs[event] == cb then self._subs[event] = nil end
      end
      package.loaded['opencode.state'] = {
        event_manager = fake_em,
        opencode_server = nil,
        current_cwd = '/home/phan/b/proj',
      }

      local http = require('mcp.util.http_client')
      local calls = {}
      http.post_json = function(url, body, _opts, on_done)
        table.insert(calls, { url = url, body = body })
        on_done({ status = 200, body = '{"nvim":{"status":"connected"}}' }, nil)
      end

      local mcp = require('mcp')
      local oc = require('mcp.integrations.opencode')
      mcp.setup({})
      oc.attach({ name = 'my-nvim' })
      local attached_before_ready = oc.is_attached()
      local calls_before_ready = #calls

      fake_em._subs['custom.server_ready']({ url = 'http://127.0.0.1:4096' })

      return {
        calls = calls,
        attached_before_ready = attached_before_ready,
        attached_after_ready = oc.is_attached(),
        calls_before_ready = calls_before_ready,
      }
    end)

    eq(0, out.calls_before_ready, 'no POST before server_ready fires')
    eq(false, out.attached_before_ready, 'flag stays false before server_ready')
    eq(true, out.attached_after_ready, 'flag flips on the deferred POST')
    eq(1, #out.calls, 'expected one POST after server_ready')
    eq(
      true,
      out.calls[1].url:find('http://127.0.0.1:4096/mcp%?directory=') ~= nil,
      'POST should target the URL from server_ready, got: ' .. tostring(out.calls[1].url)
    )
  end)

  it('POSTs once with the current cwd and options.name', function()
    local out = exec_lua(function()
      package.loaded['opencode.state'] = {
        opencode_server = { url = 'http://127.0.0.1:4096', port = 4096 },
        current_cwd = '/home/phan/b/proj',
      }

      local http = require('mcp.util.http_client')
      local calls = {}
      http.post_json = function(url, body, _opts, on_done)
        table.insert(calls, { url = url, body = body })
        on_done({ status = 200, body = '{"nvim":{"status":"connected"}}' }, nil)
      end

      local mcp = require('mcp')
      local oc = require('mcp.integrations.opencode')
      mcp.setup({})
      oc.attach({ name = 'my-nvim' })

      return {
        calls = calls,
        attached = oc.is_attached(),
        expected_dir = vim.uri_encode('/home/phan/b/proj', 'rfc3986'),
      }
    end)

    eq(true, out.attached)
    eq(1, #out.calls, 'expected exactly one POST')
    local call = out.calls[1]
    eq(
      true,
      call.body:find('"name":"my%-nvim"') ~= nil,
      'body should carry name=my-nvim, got: ' .. tostring(call.body)
    )
    eq(true, call.body:find('"type":"remote"') ~= nil)
    eq(
      true,
      call.url:find('http://127.0.0.1:4096/mcp%?directory=') ~= nil,
      'expected POST to opencode /mcp with ?directory=..., got: ' .. tostring(call.url)
    )
    eq(
      true,
      call.url:find('directory=' .. out.expected_dir) ~= nil,
      'expected directory query to be rfc3986-encoded, got: ' .. tostring(call.url)
    )
  end)

  it('is idempotent — second call does not POST again', function()
    local out = exec_lua(function()
      package.loaded['opencode.state'] = {
        opencode_server = { url = 'http://127.0.0.1:4096', port = 4096 },
        current_cwd = '/home/phan/b/proj',
      }

      local http = require('mcp.util.http_client')
      local calls = {}
      http.post_json = function(url, body, _opts, on_done)
        table.insert(calls, { url = url, body = body })
        on_done({ status = 200, body = '{"nvim":{"status":"connected"}}' }, nil)
      end

      local mcp = require('mcp')
      local oc = require('mcp.integrations.opencode')
      mcp.setup({})
      oc.attach({ name = 'my-nvim' })
      oc.attach({ name = 'my-nvim' })

      return {
        calls = calls,
        attached = oc.is_attached(),
      }
    end)

    eq(true, out.attached)
    eq(1, #out.calls, 'expected exactly one POST across two calls')
  end)

  it('logs a warning and allows retry when the POST fails', function()
    local out = exec_lua(function()
      package.loaded['opencode.state'] = {
        opencode_server = { url = 'http://127.0.0.1:4096', port = 4096 },
        current_cwd = '/home/phan/b/proj',
      }

      local http = require('mcp.util.http_client')
      local calls = {}
      http.post_json = function(url, body, _opts, on_done)
        table.insert(calls, { url = url, body = body })
        on_done({ status = 500, body = 'kaboom' }, nil)
      end

      local mcp = require('mcp')
      local oc = require('mcp.integrations.opencode')
      mcp.setup({})
      oc.attach({ name = 'my-nvim' })
      local attached_after_failure = oc.is_attached()

      http.post_json = function(url, body, _opts, on_done)
        table.insert(calls, { url = url, body = body })
        on_done({ status = 200, body = '{"nvim":{"status":"connected"}}' }, nil)
      end
      oc.attach({ name = 'my-nvim' })

      return {
        calls = calls,
        attached_after_failure = attached_after_failure,
        attached_after_retry = oc.is_attached(),
      }
    end)

    eq(false, out.attached_after_failure, 'flag should not stick after a failure')
    eq(true, out.attached_after_retry, 'flag should set on the successful retry')
    eq(2, #out.calls, 'expected two POSTs (failure + retry)')
  end)
end)
