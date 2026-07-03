-- mcp.tests.post_async_smoke_spec
--
-- Diagnostic tests written right after the http_client.lua async rewrite
-- to confirm (a) the basic MCP wire protocol still works end to end and
-- (b) SSE connections can be re-opened after one is closed (the opencode
-- picker disconnect->reconnect cycle routes through here).

local h = require('test.helpers')

local eq = h.eq
local exec_lua = h.exec_lua

--- Drive a single raw HTTP/1.1 request and return the full raw response.
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

--- Open a raw SSE GET. The handle is stashed in `_G.__last_sse`, the
--- accumulated chunks table is stashed in `_G.__last_sse_chunks`, and
--- the chunks table is also returned. We cannot pass a libuv handle
--- across the exec_lua boundary.
local function open_sse(exec_lua, port)
  return exec_lua(function(p)
    local uv = vim.uv or vim.loop
    local c = uv.new_tcp()
    local chunks = {}
    c:connect('127.0.0.1', p, function(err)
      if err then return end
      c:read_start(function(_, data)
        if data then table.insert(chunks, data) end
      end)
      c:write(
        'GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          .. 'Accept: text/event-stream\r\nOrigin: null\r\n'
          .. 'Connection: keep-alive\r\n\r\n'
      )
    end)
    _G.__last_sse = c
    _G.__last_sse_chunks = chunks
    return chunks
  end, port)
end

local function close_last_sse()
  exec_lua(function()
    local c = _G.__last_sse
    if c and not c:is_closing() then c:close() end
    _G.__last_sse = nil
  end)
end

--- `vim.wait` is only available inside `exec_lua` chunks in this test
--- runner; poll the SSE stream count until it matches `target`.
local function wait_stream_count(target, timeout_ms)
  return exec_lua(function(t, ms)
    return vim.wait(ms, function()
      local srv = require('mcp')._state.http_server
      if not srv then return t == -1 end
      local n = 0
      for _ in pairs(srv.streams or {}) do
        n = n + 1
      end
      return n == t
    end)
  end, target, timeout_ms or 2000)
end

--- Poll the accumulated chunks of the SSE stream we just opened for a
--- substring; returns true once found, false on timeout.
local function wait_chunks_contains(needle, timeout_ms)
  return exec_lua(function(s, ms)
    local chunks = _G.__last_sse_chunks or {}
    return vim.wait(ms, function() return table.concat(chunks):find(s, 1, true) ~= nil end)
  end, needle, timeout_ms or 2000)
end

describe('post-async-smoke', function()
  before_each(function() h.setup() end)

  it('full MCP wire protocol: initialize -> tools/list -> tools/call', function()
    local port = exec_lua(function()
      local mcp = require('mcp')
      mcp.setup({
        tools = {
          {
            name = 'echo',
            description = 'Echo back the input',
            handler = function(args) return { { type = 'text', text = args.msg or '' } } end,
          },
        },
        http = { allowed_origins = { 'null' } },
      })
      return mcp.http_port()
    end)

    -- 1. initialize
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
    eq(true, init_resp.ok, 'initialize transport error: ' .. tostring(init_resp.error))
    eq(
      true,
      init_resp.body:find('HTTP/1.1 200') ~= nil,
      'initialize status; got: ' .. init_resp.body:sub(1, 200)
    )
    eq(true, init_resp.body:find('"serverInfo"') ~= nil, 'initialize response missing serverInfo')

    -- 2. initialized notification (no body expected, just 202)
    local notif_resp = http_request(
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
    eq(true, notif_resp.ok)
    eq(true, notif_resp.body:find('HTTP/1.1 202') ~= nil, 'initialized notification should be 202')

    -- 3. tools/list
    local list_resp = http_request(
      '127.0.0.1',
      port,
      'POST',
      '/mcp',
      '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}',
      {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json, text/event-stream',
        ['Origin'] = 'null',
      }
    )
    eq(true, list_resp.ok)
    eq(true, list_resp.body:find('HTTP/1.1 200') ~= nil)
    eq(
      true,
      list_resp.body:find('"name":"echo"', 1, true) ~= nil,
      'tools/list should advertise echo'
    )

    -- 4. tools/call
    local call_resp = http_request(
      '127.0.0.1',
      port,
      'POST',
      '/mcp',
      '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"msg":"hello"}}}',
      {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json, text/event-stream',
        ['Origin'] = 'null',
      }
    )
    eq(true, call_resp.ok, 'tools/call transport error: ' .. tostring(call_resp.error))
    eq(
      true,
      call_resp.body:find('HTTP/1.1 200') ~= nil,
      'tools/call status; got: ' .. call_resp.body:sub(1, 200)
    )
    eq(
      true,
      call_resp.body:find('"text":"hello"', 1, true) ~= nil,
      'tools/call should echo "hello"; got body: ' .. call_resp.body:sub(1, 400)
    )
  end)

  it(
    'SSE reconnection: a new SSE stream after the previous one is closed still receives broadcasts',
    function()
      local port = exec_lua(function()
        local mcp = require('mcp')
        mcp.setup({
          tools = {},
          http = { allowed_origins = { 'null' } },
        })
        return mcp.http_port()
      end)
      eq(true, port > 0, 'mcp HTTP server did not bind')

      -- Open stream A
      local a_chunks = open_sse(exec_lua, port)
      local a_registered = wait_stream_count(1, 2000)
      eq(true, a_registered, 'stream A did not register within 2s')
      local a_open = wait_chunks_contains(': open', 2000)
      eq(true, a_open, 'stream A did not see : open heartbeat')

      -- Disconnect stream A by closing the handle from our side, exactly
      -- the way opencode.nvim would when the user clicks Disconnect.
      close_last_sse()

      -- Wait until srv.streams drops to 0. If our server never removes the
      -- dead stream, srv.streams would stay at 1 and the reconnect below
      -- would either (a) silently reuse the dead stream or (b) hang
      -- waiting for room in some bounded table.
      local drained = wait_stream_count(0, 2000)
      eq(true, drained, 'closed stream A was not reaped within 2s; srv.streams still has entries')

      -- Open stream B
      local b_chunks = open_sse(exec_lua, port)
      local b_registered = wait_stream_count(1, 2000)
      eq(
        true,
        b_registered,
        'stream B did not register; srv.streams stayed at 0 after reconnect attempt'
      )
      local b_open = wait_chunks_contains(': open', 2000)
      eq(true, b_open, 'stream B did not see : open heartbeat')

      -- Now broadcast. Only the live stream B should receive it; if the
      -- dead handle from A was still registered, the broadcast would
      -- either (a) error trying to write to it or (b) silently swallow
      -- the frame.
      exec_lua(function()
        local mcp = require('mcp')
        mcp._state.http_server:notify('notifications/test_after_reconnect', { ok = true })
      end)

      local delivered = wait_chunks_contains('notifications/test_after_reconnect', 3000)
      eq(
        true,
        delivered,
        'reconnected stream B did not receive the broadcast; reconnect path is broken'
      )

      close_last_sse()
    end
  )

  it(
    'reconnect lifecycle: connect-SSE + initialize-POST works on the FIRST and SECOND attempts',
    function()
      local port = exec_lua(function()
        local mcp = require('mcp')
        mcp.setup({
          tools = {
            {
              name = 'echo',
              description = 'Echo back the input',
              handler = function(args) return { { type = 'text', text = args.msg or '' } } end,
            },
          },
          http = { allowed_origins = { 'null' } },
        })
        return mcp.http_port()
      end)
      eq(true, port > 0, 'mcp HTTP server did not bind')

      local function full_connect_cycle(label)
        local sse_chunks = open_sse(exec_lua, port)
        local registered = wait_stream_count(1, 2000)
        eq(true, registered, label .. ': SSE did not register within 2s')
        local heartbeat = wait_chunks_contains(': open', 2000)
        eq(true, heartbeat, label .. ': SSE did not see : open heartbeat')

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
        eq(
          true,
          init_resp.ok,
          label .. ': initialize POST transport error: ' .. tostring(init_resp.error)
        )
        eq(
          true,
          init_resp.body:find('HTTP/1.1 200') ~= nil,
          label .. ': initialize should be 200; got: ' .. init_resp.body:sub(1, 200)
        )
        eq(
          true,
          init_resp.body:find('"serverInfo"') ~= nil,
          label
            .. ': initialize response missing serverInfo. raw body: '
            .. init_resp.body:sub(1, 600)
        )

        return sse_chunks
      end

      local function state_after_close()
        return exec_lua(function()
          local mcp = require('mcp')
          return mcp._state.server.state
        end)
      end

      local first_sse = full_connect_cycle('first connect')
      close_last_sse()
      local drained = wait_stream_count(0, 2000)
      eq(true, drained, 'cycle 1: stream was not reaped after close')
      local post_close_state = state_after_close()
      eq(
        'Created',
        post_close_state,
        'cycle 1: expected server state back to Created after SSE drop, got '
          .. tostring(post_close_state)
      )

      local second_sse = full_connect_cycle('reconnect')
      close_last_sse()
      drained = wait_stream_count(0, 2000)
      eq(true, drained, 'cycle 2: stream was not reaped after close')
    end
  )
end)
