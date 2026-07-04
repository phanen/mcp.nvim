-- mcp.tests.dispatch_ctx_spec
--
-- Unit tests for `mcp.json_rpc.dispatch_ctx`. The module is pure logic
-- (no Neovim editor state, no transport), so the tests construct a tiny
-- mock transport and assert on the recorded calls.

local h = require('test.helpers')

local eq = h.eq

describe('dispatch_ctx', function()
  before_each(function() h.setup() end)

  local function sandbox(body) return h.in_sandbox('\n' .. body) end

  it('ok: writes a successful envelope exactly once', function()
    local r = sandbox([[
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        responses = {},
        write_response = function(self, id, env)
          table.insert(self.responses, { id = id, env = env })
        end,
      }
      local ctx = dc.make_ctx({
        request_id = 7,
        tool_name = 'demo',
        transport = mock,
        timeout_ms = 0,
      })
      ctx:ok({{ type = 'text', text = 'hello' }})
      ctx:ok({{ type = 'text', text = 'ignored' }})
      return mock.responses
    ]])
    eq(1, #r)
    eq(7, r[1].id)
    eq(false, r[1].env.isError)
    eq(1, #r[1].env.content)
    eq('hello', r[1].env.content[1].text)
  end)

  it('err(string): wraps the string in a text content item', function()
    local r = sandbox([[
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = { last = nil, write_response = function(self, id, env) self.last = env end }
      local ctx = dc.make_ctx({
        request_id = 1,
        tool_name = 'demo',
        transport = mock,
        timeout_ms = 0,
      })
      ctx:err('boom')
      return mock.last
    ]])
    eq(true, r.isError)
    eq(1, #r.content)
    eq('text', r.content[1].type)
    eq('boom', r.content[1].text)
  end)

  it('err(table[]): uses the table directly as content', function()
    local r = sandbox([[
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = { last = nil, write_response = function(self, _, env) self.last = env end }
      local ctx = dc.make_ctx({
        request_id = 1,
        tool_name = 'demo',
        transport = mock,
        timeout_ms = 0,
      })
      ctx:err({
        { type = 'text', text = 'first' },
        { type = 'text', text = 'second' },
      })
      return mock.last
    ]])
    eq(true, r.isError)
    eq(2, #r.content)
    eq('first', r.content[1].text)
    eq('second', r.content[2].text)
  end)

  it('ok then err: err is a no-op (idempotent finish)', function()
    local r = sandbox([[
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        responses = {},
        write_response = function(self, id, env)
          table.insert(self.responses, env)
        end,
      }
      local ctx = dc.make_ctx({
        request_id = 1,
        tool_name = 'demo',
        transport = mock,
        timeout_ms = 0,
      })
      ctx:ok({{ type = 'text', text = 'first' }})
      ctx:err('second')
      return mock.responses
    ]])
    eq(1, #r)
    eq(false, r[1].isError)
    eq('first', r[1].content[1].text)
  end)

  it('progress: skipped when no progress_token was provided', function()
    local r = sandbox([[
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        notifications = {},
        write_response = function() end,
        send_notification = function(self, method, params)
          table.insert(self.notifications, { method = method, params = params })
        end,
      }
      local ctx = dc.make_ctx({
        request_id = 1,
        tool_name = 'demo',
        transport = mock,
        timeout_ms = 0,
      })
      ctx:progress(50, 100, 'halfway')
      return mock.notifications
    ]])
    eq(0, #r)
  end)

  it('progress: emits notifications/progress with token + fields', function()
    local r = sandbox([[
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        notifications = {},
        write_response = function() end,
        send_notification = function(self, method, params)
          table.insert(self.notifications, { method = method, params = params })
        end,
      }
      local ctx = dc.make_ctx({
        request_id = 1,
        tool_name = 'demo',
        transport = mock,
        progress_token = 'tok-42',
        timeout_ms = 0,
      })
      ctx:progress(50, 100, 'halfway')
      return mock.notifications
    ]])
    eq(1, #r)
    eq('notifications/progress', r[1].method)
    eq('tok-42', r[1].params.progressToken)
    eq(50, r[1].params.progress)
    eq(100, r[1].params.total)
    eq('halfway', r[1].params.message)
  end)

  it('progress: skipped after ctx:ok (timer/_done path)', function()
    local r = sandbox([[
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        notifications = {},
        write_response = function() end,
        send_notification = function(self, method, params)
          table.insert(self.notifications, params)
        end,
      }
      local ctx = dc.make_ctx({
        request_id = 1,
        tool_name = 'demo',
        transport = mock,
        progress_token = 'tok',
        timeout_ms = 0,
      })
      ctx:ok({{ type = 'text', text = 'done' }})
      ctx:progress(99, 100)
      return mock.notifications
    ]])
    eq(0, #r)
  end)

  it('timeout_ms: fires cancel_fn then ctx:err after the timeout', function()
    local r = sandbox([[
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        responses = {},
        cancel_calls = {},
        write_response = function(self, _, env)
          table.insert(self.responses, env)
        end,
      }
      local ctx = dc.make_ctx({
        request_id = 9,
        tool_name = 'slow',
        transport = mock,
        cancel_fn = function(reason, c)
          table.insert(mock.cancel_calls, { reason = reason, done = c._done })
        end,
        timeout_ms = 50,
      })
      vim.wait(300, function() return #mock.responses > 0 end)
      return { responses = mock.responses, cancel_calls = mock.cancel_calls }
    ]])
    eq(1, #r.responses)
    eq(true, r.responses[1].isError)
    eq('text', r.responses[1].content[1].type)
    eq(1, #r.cancel_calls)
    eq('tool timed out', r.cancel_calls[1].reason)
    -- cancel_fn is invoked before ctx:err, so _done is still false there
    eq(false, r.cancel_calls[1].done)
  end)

  it('timeout_ms = 0: never fires', function()
    local r = sandbox([[
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        responses = {},
        write_response = function(self, _, env)
          table.insert(mock.responses, env)
        end,
      }
      local ctx = dc.make_ctx({
        request_id = 9,
        tool_name = 'slow',
        transport = mock,
        timeout_ms = 0,
      })
      vim.wait(100, function() return #mock.responses > 0 end)
      return #mock.responses
    ]])
    eq(0, r)
  end)

  it(
    'timeout_ms omitted: uses DEFAULT_TOOL_TIMEOUT_MS but does not fire in the test window',
    function()
      local r = sandbox([[
      local dc = require('mcp.json_rpc.dispatch_ctx')
      return dc.DEFAULT_TOOL_TIMEOUT_MS
    ]])
      eq(30000, r)
    end
  )

  it('missing cancel_fn: timeout still produces a ctx:err', function()
    local r = sandbox([[
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        responses = {},
        write_response = function(self, _, env)
          table.insert(self.responses, env)
        end,
      }
      local ctx = dc.make_ctx({
        request_id = 9,
        tool_name = 'noisy',
        transport = mock,
        timeout_ms = 50,
      })
      vim.wait(300, function() return #mock.responses > 0 end)
      return mock.responses
    ]])
    eq(1, #r)
    eq(true, r[1].isError)
  end)

  it('on_done callback fires when ctx finishes', function()
    local r = sandbox([[
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        done_calls = 0,
        write_response = function() end,
      }
      local ctx = dc.make_ctx({
        request_id = 1,
        tool_name = 'demo',
        transport = mock,
        timeout_ms = 0,
        on_done = function() mock.done_calls = mock.done_calls + 1 end,
      })
      ctx:ok({{ type = 'text', text = 'hi' }})
      ctx:ok({{ type = 'text', text = 'again' }})
      return mock.done_calls
    ]])
    eq(1, r)
  end)
end)
