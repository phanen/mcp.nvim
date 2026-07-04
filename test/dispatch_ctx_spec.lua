-- mcp.tests.dispatch_ctx_spec
--
-- Unit tests for `mcp.json_rpc.dispatch_ctx`. The module is pure logic
-- (no Neovim editor state, no transport), so the tests construct a tiny
-- mock transport and assert on the recorded calls.

local h = require('test.helpers')

local eq = h.eq
local exec_lua = h.exec_lua

describe('dispatch_ctx', function()
  before_each(function() h.setup() end)

  it('ok: writes a successful envelope exactly once', function()
    local r = exec_lua(function()
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
      ctx:ok({ { type = 'text', text = 'hello' } })
      ctx:ok({ { type = 'text', text = 'ignored' } })
      return mock.responses
    end)
    eq(1, #r)
    eq(7, r[1].id)
    eq(false, r[1].env.isError)
    eq(1, #r[1].env.content)
    eq('hello', r[1].env.content[1].text)
  end)

  it('err(string): wraps the string in a text content item', function()
    local r = exec_lua(function()
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
    end)
    eq(true, r.isError)
    eq(1, #r.content)
    eq('text', r.content[1].type)
    eq('boom', r.content[1].text)
  end)

  it('err(table[]): uses the table directly as content', function()
    local r = exec_lua(function()
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
    end)
    eq(true, r.isError)
    eq(2, #r.content)
    eq('first', r.content[1].text)
    eq('second', r.content[2].text)
  end)

  it('ok then err: err is a no-op (idempotent finish)', function()
    local r = exec_lua(function()
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        responses = {},
        write_response = function(self, id, env) table.insert(self.responses, env) end,
      }
      local ctx = dc.make_ctx({
        request_id = 1,
        tool_name = 'demo',
        transport = mock,
        timeout_ms = 0,
      })
      ctx:ok({ { type = 'text', text = 'first' } })
      ctx:err('second')
      return mock.responses
    end)
    eq(1, #r)
    eq(false, r[1].isError)
    eq('first', r[1].content[1].text)
  end)

  it('progress: skipped when no progress_token was provided', function()
    local r = exec_lua(function()
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
    end)
    eq(0, #r)
  end)

  it('progress: emits notifications/progress with token + fields', function()
    local r = exec_lua(function()
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
    end)
    eq(1, #r)
    eq('notifications/progress', r[1].method)
    eq('tok-42', r[1].params.progressToken)
    eq(50, r[1].params.progress)
    eq(100, r[1].params.total)
    eq('halfway', r[1].params.message)
  end)

  it('progress: skipped after ctx:ok (timer/_done path)', function()
    local r = exec_lua(function()
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        notifications = {},
        write_response = function() end,
        send_notification = function(self, method, params) table.insert(self.notifications, params) end,
      }
      local ctx = dc.make_ctx({
        request_id = 1,
        tool_name = 'demo',
        transport = mock,
        progress_token = 'tok',
        timeout_ms = 0,
      })
      ctx:ok({ { type = 'text', text = 'done' } })
      ctx:progress(99, 100)
      return mock.notifications
    end)
    eq(0, #r)
  end)

  it('timeout_ms: fires cancel_fn then ctx:err after the timeout', function()
    local r = exec_lua(function()
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        responses = {},
        cancel_calls = {},
        write_response = function(self, _, env) table.insert(self.responses, env) end,
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
    end)
    eq(1, #r.responses)
    eq(true, r.responses[1].isError)
    eq('text', r.responses[1].content[1].type)
    eq(1, #r.cancel_calls)
    eq('tool timed out', r.cancel_calls[1].reason)
    -- cancel_fn is invoked before ctx:err, so _done is still false there
    eq(false, r.cancel_calls[1].done)
  end)

  it('timeout_ms = 0: never fires', function()
    local r = exec_lua(function()
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        responses = {},
        write_response = function(self, _, env) table.insert(mock.responses, env) end,
      }
      local ctx = dc.make_ctx({
        request_id = 9,
        tool_name = 'slow',
        transport = mock,
        timeout_ms = 0,
      })
      vim.wait(100, function() return #mock.responses > 0 end)
      return #mock.responses
    end)
    eq(0, r)
  end)

  it('timeout_ms omitted: does not arm a timer; caller must call start_timeout', function()
    local r = exec_lua(function()
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = { fired = false, write_response = function() mock.fired = true end }
      local ctx = dc.make_ctx({
        request_id = 1,
        tool_name = 'no-timeout',
        transport = mock,
      })
      vim.wait(100, function() return mock.fired end)
      return {
        fired = mock.fired,
        timer_alive = ctx._timer ~= nil,
        default_ms = dc.DEFAULT_TOOL_TIMEOUT_MS,
      }
    end)
    eq(false, r.fired)
    eq(false, r.timer_alive)
    eq(30000, r.default_ms)
  end)

  it('missing cancel_fn: timeout still produces a ctx:err', function()
    local r = exec_lua(function()
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        responses = {},
        write_response = function(self, _, env) table.insert(self.responses, env) end,
      }
      local ctx = dc.make_ctx({
        request_id = 9,
        tool_name = 'noisy',
        transport = mock,
        timeout_ms = 50,
      })
      vim.wait(300, function() return #mock.responses > 0 end)
      return mock.responses
    end)
    eq(1, #r)
    eq(true, r[1].isError)
  end)

  it('on_done callback fires when ctx finishes', function()
    local r = exec_lua(function()
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
      ctx:ok({ { type = 'text', text = 'hi' } })
      ctx:ok({ { type = 'text', text = 'again' } })
      return mock.done_calls
    end)
    eq(1, r)
  end)

  it('start_timeout: arms a timer after the ctx was constructed without one', function()
    local r = exec_lua(function()
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = { last = nil, write_response = function(self, _, env) self.last = env end }
      local ctx = dc.make_ctx({
        request_id = 1,
        tool_name = 'late-arm',
        transport = mock,
        timeout_ms = 0,
      })
      ctx:start_timeout(50)
      vim.wait(300, function() return mock.last ~= nil end)
      return mock.last
    end)
    eq(true, r.isError)
    eq('text', r.content[1].type)
    eq(true, r.content[1].text:find('timed out', 1, true) ~= nil)
  end)

  it('start_timeout: idempotent — a second call does not re-arm the timer', function()
    local r = exec_lua(function()
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = { calls = 0, write_response = function(self) self.calls = self.calls + 1 end }
      local ctx = dc.make_ctx({
        request_id = 1,
        tool_name = 'double-arm',
        transport = mock,
        timeout_ms = 50,
      })
      ctx:start_timeout(50)
      vim.wait(200, function() return mock.calls > 0 end)
      return mock.calls
    end)
    eq(1, r)
  end)

  it('set_cancel: a timeout that fires after set_cancel invokes the new cancel fn', function()
    local r = exec_lua(function()
      local dc = require('mcp.json_rpc.dispatch_ctx')
      local mock = {
        cancel_calls = {},
        write_response = function(self, _, env) self.cancel_calls[#self.cancel_calls + 1] = env end,
      }
      local ctx = dc.make_ctx({
        request_id = 1,
        tool_name = 'late-cancel',
        transport = mock,
        timeout_ms = 50,
      })
      ctx:set_cancel(function(reason) return reason end)
      vim.wait(300, function() return #mock.cancel_calls > 0 end)
      return mock.cancel_calls
    end)
    eq(1, #r)
    eq(true, r[1].isError)
  end)
end)
