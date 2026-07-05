-- mcp.tests.end_to_end_async_spec
--
-- End-to-end coverage of async tool dispatch: progress / cancel / timeout
-- all exercise the full transport -> server -> handler -> ctx -> response
-- path.

local h = require('test.helpers')

local eq = h.eq
local exec_lua = h.exec_lua

describe('end-to-end async tool dispatch', function()
  before_each(function() h.setup() end)

  it('progress: tool emits notifications/progress on the SSE stream', function()
    local r = exec_lua(function()
      local mcp = require('mcp')
      mcp.setup({
        tools = {
          {
            name = 'slow_count',
            description = 'Reports progress while counting to N.',
            timeout_ms = 5000,
            inputSchema = { type = 'object' },
            handler = function(_args, ctx)
              for i = 1, 5 do
                vim.defer_fn(function()
                  if ctx._done then return end
                  ctx:progress(i, 5, 'step ' .. i)
                end, i * 5)
              end
              vim.defer_fn(function()
                if ctx._done then return end
                ctx:ok({ { type = 'text', text = 'counted 5' } })
              end, 30)
            end,
          },
        },
        http = { allowed_origins = { 'null' } },
      })
      local port = mcp.http_port()
      local uv = vim.uv or vim.loop

      local function post(body_str)
        local p = uv.new_tcp()
        local buf, done = '', false
        p:connect('127.0.0.1', port, function()
          p:read_start(function(_, data)
            if data then buf = buf .. data end
            if not data then
              done = true
              p:close()
            end
          end)
          p:write(body_str)
        end)
        vim.wait(2000, function() return done end)
        return buf
      end

      post(
        'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          .. 'Content-Length: 146\r\nContent-Type: application/json\r\n'
          .. 'Accept: application/json\r\nOrigin: null\r\n\r\n'
          .. '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
      )
      post(
        'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          .. 'Content-Length: 54\r\nContent-Type: application/json\r\n'
          .. 'Accept: application/json\r\nOrigin: null\r\n\r\n'
          .. '{"jsonrpc":"2.0","method":"notifications/initialized"}'
      )

      local sse_chunks = {}
      local sse_connected = false
      local sse = uv.new_tcp()
      sse:connect('127.0.0.1', port, function()
        sse_connected = true
        sse:read_start(function(_, data)
          if data then table.insert(sse_chunks, data) end
        end)
        sse:write(
          'GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
            .. 'Accept: text/event-stream\r\nOrigin: null\r\nConnection: keep-alive\r\n\r\n'
        )
      end)

      vim.wait(500, function() return sse_connected end)

      local http_body = post(
        'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          .. 'Content-Length: 111\r\nContent-Type: application/json\r\n'
          .. 'Accept: application/json\r\nOrigin: null\r\n\r\n'
          .. '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow_count","_meta":{"progressToken":"tok-1"}}}'
      )

      vim.wait(2000, function() return http_body:find('counted 5', 1, true) ~= nil end)
      sse:close()
      mcp.stop()

      return {
        sse_body = table.concat(sse_chunks),
        http_body = http_body,
      }
    end)

    eq(true, r.sse_body:find('notifications/progress', 1, true) ~= nil)
    eq(true, r.sse_body:find('"progressToken":"tok-1"', 1, true) ~= nil)
    eq(true, r.sse_body:find('"progress":5', 1, true) ~= nil)
    eq(true, r.sse_body:find('"total":5', 1, true) ~= nil)
    eq(true, r.http_body:find('"isError":false', 1, true) ~= nil)
    eq(true, r.http_body:find('counted 5', 1, true) ~= nil)
  end)

  it('cancel: notifications/cancelled invokes the tool cancel hook', function()
    local r = exec_lua(function()
      local mcp = require('mcp')
      local cancel_log = _G.__cancel_log or {}
      mcp.setup({
        tools = {
          {
            name = 'hang',
            description = 'Hangs until cancelled.',
            timeout_ms = 10000,
            cancel = function(reason, c)
              _G.__cancel_log = _G.__cancel_log or {}
              _G.__cancel_log[#_G.__cancel_log + 1] = { reason = reason, tool_name = c.tool_name }
            end,
            handler = function(_args, _ctx)
              -- Truly async: schedule a callback that never fires, so
              -- the ctx stays live until cancel / timeout completes it.
              vim.defer_fn(function()
                if ctx._done then return end
                ctx:ok({ { type = 'text', text = 'finished naturally' } })
              end, 60 * 60 * 1000)
            end,
          },
        },
        http = { allowed_origins = { 'null' } },
      })
      local port = mcp.http_port()
      local uv = vim.uv or vim.loop

      local function post(body_str)
        local p = uv.new_tcp()
        local buf, done = '', false
        p:connect('127.0.0.1', port, function()
          p:read_start(function(_, data)
            if data then buf = buf .. data end
            if not data then
              done = true
              p:close()
            end
          end)
          p:write(body_str)
        end)
        vim.wait(2000, function() return done end)
        return buf
      end

      post(
        'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          .. 'Content-Length: 146\r\nContent-Type: application/json\r\n'
          .. 'Accept: application/json\r\nOrigin: null\r\n\r\n'
          .. '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
      )
      post(
        'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          .. 'Content-Length: 54\r\nContent-Type: application/json\r\n'
          .. 'Accept: application/json\r\nOrigin: null\r\n\r\n'
          .. '{"jsonrpc":"2.0","method":"notifications/initialized"}'
      )
      post(
        'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          .. 'Content-Length: 71\r\nContent-Type: application/json\r\n'
          .. 'Accept: application/json\r\nOrigin: null\r\n\r\n'
          .. '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"hang"}}'
      )
      vim.wait(200, function() return false end)
      post(
        'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          .. 'Content-Length: 97\r\nContent-Type: application/json\r\n'
          .. 'Accept: application/json\r\nOrigin: null\r\n\r\n'
          .. '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"user-esc"}}'
      )

      vim.wait(500, function() return #_G.__cancel_log > 0 end)
      mcp.stop()

      return _G.__cancel_log
    end)

    eq(1, #r)
    eq('user-esc', r[1].reason)
  end)

  it('timeout: a handler that never finishes gets ctx:err from the timer', function()
    local r = exec_lua(function()
      local mcp = require('mcp')
      local cancel_log = {}
      mcp.setup({
        tools = {
          {
            name = 'never',
            description = 'Never finishes.',
            timeout_ms = 100,
            cancel = function(reason, _c) table.insert(cancel_log, { reason = reason }) end,
            handler = function(_args, _ctx)
              -- Truly async: never returns and never calls ctx:ok.
              vim.defer_fn(function()
                if ctx._done then return end
                ctx:ok({ { type = 'text', text = 'finished naturally' } })
              end, 60 * 60 * 1000)
            end,
          },
        },
        http = { allowed_origins = { 'null' } },
      })
      local port = mcp.http_port()
      local uv = vim.uv or vim.loop

      local function post(body_str)
        local p = uv.new_tcp()
        local buf, done = '', false
        p:connect('127.0.0.1', port, function()
          p:read_start(function(_, data)
            if data then buf = buf .. data end
            if not data then
              done = true
              p:close()
            end
          end)
          p:write(body_str)
        end)
        vim.wait(2000, function() return done end)
        return buf
      end

      post(
        'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          .. 'Content-Length: 146\r\nContent-Type: application/json\r\n'
          .. 'Accept: application/json\r\nOrigin: null\r\n\r\n'
          .. '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
      )
      post(
        'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          .. 'Content-Length: 54\r\nContent-Type: application/json\r\n'
          .. 'Accept: application/json\r\nOrigin: null\r\n\r\n'
          .. '{"jsonrpc":"2.0","method":"notifications/initialized"}'
      )
      local http_body = post(
        'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          .. 'Content-Length: 72\r\nContent-Type: application/json\r\n'
          .. 'Accept: application/json\r\nOrigin: null\r\n\r\n'
          .. '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"never"}}'
      )

      vim.wait(500, function() return #cancel_log > 0 end)

      return {
        body = http_body,
        cancel = cancel_log,
      }
    end)

    eq(true, r.body:find('"isError":true', 1, true) ~= nil)
    eq(true, r.body:find('timed out', 1, true) ~= nil)
    eq(1, #r.cancel)
    eq('tool timed out', r.cancel[1].reason)
  end)
end)
