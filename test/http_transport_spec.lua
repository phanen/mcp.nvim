-- mcp.tests.http_transport_spec
--
-- End-to-end tests for the streamable-HTTP transport. Each test
-- binds a server on an ephemeral localhost port, drives a raw TCP
-- HTTP request against it, and asserts on the response.

local h = require('test.helpers')

local eq = h.eq
local exec_lua = h.exec_lua

--- Drive a raw HTTP/1.1 request via `vim.uv.new_tcp`. Returns the
--- complete raw response as a single string.
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

describe('http_transport', function()
  before_each(function() h.setup() end)
  it('binds an ephemeral port when port=0 and returns the chosen port', function()
    local out = exec_lua(function()
      local http = require('mcp.json_rpc.transport.http')
      local server, port = http.bind('127.0.0.1', 0, {})
      server:terminate()
      return { port = port }
    end)
    eq(true, out.port > 0)
    eq(true, out.port < 65536)
  end)

  it('responds 200 application/json to a POST request that produces a result', function()
    local port = exec_lua(function()
      local http = require('mcp.json_rpc.transport.http')
      local server = require('mcp.server')
      local registry = require('mcp.tool_registry').new()
      registry:register({
        name = 'echo',
        description = 'Echo',
        handler = function(args) return { { type = 'text', text = args.msg } } end,
      })

      local srv
      srv, port = http.bind('127.0.0.1', 0, {
        endpoint = '/mcp',
        allowed_origins = { 'null' },
      })

      local mcp_server = server.new({
        on_request = function() return nil end,
        on_notify = function() end,
        on_exit = function() end,
        on_error = function() end,
        is_closing = function() return false end,
        notify = function() end,
      }, registry)

      srv.on_request = function(method, params) return mcp_server:_dispatch(method, params) end

      return port
    end)

    local resp = http_request(
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

    eq(true, resp.ok, 'connection error: ' .. tostring(resp.error))
    eq(
      true,
      resp.body:match('HTTP/1.1 200') ~= nil,
      'expected 200, got: ' .. tostring(resp.body):sub(1, 200)
    )
    eq(true, resp.body:match('[Cc]ontent%-[Tt]ype: application/json') ~= nil)
    eq(true, resp.body:match('"protocolVersion":"2025%-03%-26"') ~= nil)
    eq(true, resp.body:match('"serverInfo"') ~= nil)
  end)

  it('responds 202 Accepted to a notification POST', function()
    local port = exec_lua(function()
      local http = require('mcp.json_rpc.transport.http')
      local srv
      srv, port = http.bind('127.0.0.1', 0, {
        endpoint = '/mcp',
        allowed_origins = { 'null' },
      })

      srv.on_request = function(method, _params)
        -- Capture the dispatched notification so we can verify it ran.
        _G.__last_notif = method
      end

      return port
    end)

    local resp = http_request(
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

    eq(true, resp.ok)
    eq(
      true,
      resp.body:match('HTTP/1.1 202') ~= nil,
      'expected 202, got: ' .. tostring(resp.body):sub(1, 200)
    )

    local last = exec_lua(function() return _G.__last_notif end)
    eq('notifications/initialized', last)
  end)

  it('responds 200 + text/event-stream to a GET, opening an SSE stream', function()
    local out = exec_lua(function()
      local http = require('mcp.json_rpc.transport.http')
      local uv = vim.uv or vim.loop
      local srv, port = http.bind('127.0.0.1', 0, {
        endpoint = '/mcp',
        allowed_origins = { 'null' },
      })

      local client = uv.new_tcp()
      local chunks = {}
      local finished = false
      local resp = { ok = false, body = '', status = 0 }

      client:connect('127.0.0.1', port, function(err)
        if err then
          resp.error = err
          finished = true
          return
        end
        client:read_start(function(rerr, data)
          if rerr then
            resp.error = rerr
            finished = true
            client:close()
            return
          end
          if data then
            table.insert(chunks, data)
          else
            finished = true
            client:close()
          end
        end)
        client:write(
          'GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
            .. 'Accept: text/event-stream\r\n'
            .. 'Origin: null\r\nConnection: keep-alive\r\n\r\n'
        )
      end)
      -- We expect the server to write a response and the leading
      -- ": open\n\n" heartbeat within 500ms, then the connection
      -- stays open. Don't wait for EOF (there isn't one).
      vim.wait(500, function()
        local body = table.concat(chunks)
        return body:find('HTTP/1.1 200') ~= nil and body:find('text/event-stream') ~= nil
      end)
      resp.body = table.concat(chunks)
      resp.status_line = resp.body:match('^(HTTP/1%.1 %d+[^\r\n]*)') or ''
      resp.ok = true
      -- Before tearing down, capture how many SSE streams the
      -- server is tracking so we can verify registration worked.
      resp.stream_count = 0
      for _ in pairs(srv.streams) do
        resp.stream_count = resp.stream_count + 1
      end
      client:close()
      srv:terminate()
      return resp
    end)

    eq(true, out.ok, 'connect error: ' .. tostring(out.error))
    eq(true, out.status_line:match('HTTP/1%.1 200') ~= nil, out.status_line)
    eq(true, out.body:find('[Cc]ontent%-[Tt]ype: text/event%-stream') ~= nil)
    -- The optional `: open\n\n` heartbeat should be present; tests
    -- rely on it as proof that the stream is actually live.
    eq(true, out.body:find(': open\n\n') ~= nil)
    -- The response must not advertise a fixed length on an SSE
    -- stream; doing so makes strict HTTP clients (reqwest, curl)
    -- treat the response as terminated even though we keep
    -- writing events. It also must not carry a duplicate
    -- `Connection` header, which RFC 7230 §3.2.2 forbids and most
    -- clients reject with a protocol error.
    eq(nil, out.body:find('[Cc]ontent%-[Ll]ength:'))
    eq(1, select(2, out.body:gsub('\n[Cc]onnection:', '\n')) --[[ count Connection: headers ]])
    eq(1, out.stream_count)
  end)

  it('broadcasts a JSON-RPC notification to every open SSE stream', function()
    local out = exec_lua(function()
      local http = require('mcp.json_rpc.transport.http')
      local framing = require('mcp.json_rpc.transport.framing')
      local uv = vim.uv or vim.loop
      local srv, port = http.bind('127.0.0.1', 0, {
        endpoint = '/mcp',
        allowed_origins = { 'null' },
      })

      local function open_client()
        local c = uv.new_tcp()
        local chunks = {}
        c:connect('127.0.0.1', port, function(err)
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
        return { handle = c, chunks = chunks }
      end

      local a, b = open_client(), open_client()

      -- Wait for both streams to register (their `: open\n\n`
      -- heartbeats land before they are observable via srv.streams).
      vim.wait(500, function()
        local n = 0
        for _ in pairs(srv.streams) do
          n = n + 1
        end
        return n == 2
      end)

      srv:notify('notifications/test_event', { greeting = 'hi' })

      -- Wait until both clients have received the JSON-RPC frame.
      -- TCP may deliver it split across multiple chunks, so we
      -- check the concatenated buffer rather than each chunk.
      local function has_event(chunks)
        return table.concat(chunks):find('notifications/test_event', 1, true) ~= nil
      end
      -- Give it up to 5 seconds; in practice both clients receive
      -- well within a few hundred ms, but older Neovim releases
      -- have noticeably slower libuv event loops under the test
      -- runner, so we leave plenty of headroom.
      local done = vim.wait(5000, function() return has_event(a.chunks) and has_event(b.chunks) end)
      if not done then
        -- Diagnostic dump if the broadcast didn't land in time.
        return {
          wait_timed_out = true,
          a_chunk_count = #a.chunks,
          b_chunk_count = #b.chunks,
          a_body = table.concat(a.chunks),
          b_body = table.concat(b.chunks),
        }
      end

      local payload_a, payload_b = table.concat(a.chunks), table.concat(b.chunks)
      a.handle:close()
      b.handle:close()
      srv:terminate()

      -- Strip the HTTP response headers so the decoder sees only
      -- the SSE payload. The first event on the wire is the `: open`
      -- heartbeat (a comment with no data), so we drain through
      -- empty events until we hit the actual JSON-RPC payload.
      local function strip_http_headers(body)
        local _, hdr_end = body:find('\r\n\r\n', 1, true)
        return hdr_end and body:sub(hdr_end + 1) or body
      end
      local function first_data_event(sse_body)
        local cur = sse_body
        while #cur > 0 do
          local body, consumed = framing.sse_decode({ cur }, #cur)
          if not body then break end
          cur = cur:sub((consumed or 0) + 1)
          if body ~= '' then return body end
        end
        return nil
      end

      local sse_a = strip_http_headers(payload_a)
      local sse_b = strip_http_headers(payload_b)
      local decoded_a = first_data_event(sse_a)
      local decoded_b = first_data_event(sse_b)

      -- Surface the raw payloads to the busted runner so any
      -- assertion failure has the wire bytes attached as context.
      -- Note: vim.json.encode does not preserve key order, so we
      -- match each piece of the broadcast independently instead
      -- of asserting on a fixed substring position.
      return {
        a_has_method = payload_a:find('"notifications/test_event"', 1, true) ~= nil,
        b_has_method = payload_b:find('"notifications/test_event"', 1, true) ~= nil,
        a_has_data = payload_a:find('data: {"', 1, true) ~= nil
          and payload_a:find('"jsonrpc":"2.0"', 1, true) ~= nil,
        b_has_data = payload_b:find('data: {"', 1, true) ~= nil
          and payload_b:find('"jsonrpc":"2.0"', 1, true) ~= nil,
        decoded_a = decoded_a,
        decoded_b = decoded_b,
      }
    end)

    eq(true, out.a_has_method)
    eq(true, out.b_has_method)
    eq(true, out.a_has_data)
    eq(true, out.b_has_data)

    -- Both clients should receive the same JSON-RPC body. Drain
    -- past the leading `: open` heartbeat and verify the actual
    -- payload round-trips back to a well-formed notification.
    eq('string', type(out.decoded_a))
    eq('string', type(out.decoded_b))
    eq(true, out.decoded_a:sub(1, 1) == '{')
    eq(out.decoded_a, out.decoded_b)
    eq(true, out.decoded_a:find('notifications/test_event', 1, true) ~= nil)
    eq(true, out.decoded_a:find('"greeting":"hi"', 1, true) ~= nil)
  end)

  it('rejects requests whose Origin header is not in the allow list', function()
    local port = exec_lua(function()
      local http = require('mcp.json_rpc.transport.http')
      local srv
      srv, port = http.bind('127.0.0.1', 0, {
        endpoint = '/mcp',
        allowed_origins = { 'https://allowed.example' },
      })
      return port
    end)

    local resp =
      http_request('127.0.0.1', port, 'POST', '/mcp', '{"jsonrpc":"2.0","id":1,"method":"ping"}', {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json',
        ['Origin'] = 'https://attacker.example',
      })

    eq(true, resp.ok)
    eq(
      true,
      resp.body:match('HTTP/1.1 403') ~= nil,
      'expected 403, got: ' .. tostring(resp.body):sub(1, 200)
    )
  end)

  it(
    'synchronous tools/call: handler returns a result envelope, response body carries it',
    function()
      -- This is the regression path: when on_request returns synchronously,
      -- transport must still serialize the envelope correctly (the same code
      -- path that produced every prior transport test).
      local resp = http_request(
        '127.0.0.1',
        exec_lua(function()
          local http = require('mcp.json_rpc.transport.http')
          local srv
          srv, _ = http.bind('127.0.0.1', 0, {
            endpoint = '/mcp',
            allowed_origins = { 'null' },
          })
          srv.on_request = function(_, params)
            local args = params and params.arguments or {}
            return {
              content = { { type = 'text', text = 'sync-ok:' .. (args.tag or '') } },
              isError = false,
            },
              nil
          end
          return srv.port
        end),
        'POST',
        '/mcp',
        '{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"x","arguments":{"tag":"hi"}}}',
        {
          ['Content-Type'] = 'application/json',
          ['Accept'] = 'application/json',
          ['Origin'] = 'null',
        }
      )

      eq(true, resp.ok, 'connection error: ' .. tostring(resp.error))
      eq(true, resp.body:match('HTTP/1.1 200') ~= nil, 'expected 200')
      local _, json_start = resp.body:find('\r\n\r\n', 1, true)
      local json_body = json_start and resp.body:sub(json_start + 1) or resp.body
      eq(
        true,
        json_body:find('"id":42', 1, true) ~= nil,
        'response id should be 42; json=' .. json_body
      )
      eq(true, json_body:find('"isError":false', 1, true) ~= nil, 'json=' .. json_body)
      eq(true, json_body:find('sync-ok:hi', 1, true) ~= nil, 'json=' .. json_body)
    end
  )

  it('async tools/call via ctx:ok: handler defers to ctx, response carries the envelope', function()
    -- on_request itself is the async finish signal: it builds a ctx
    -- implicitly via the transport's make_ctx, then hands it to the
    -- handler. We probe ctx by ignoring the synchronous return path
    -- and asserting that ctx:ok wrote the right envelope.
    local resp = http_request(
      '127.0.0.1',
      exec_lua(function()
        local http = require('mcp.json_rpc.transport.http')
        local srv
        srv, _ = http.bind('127.0.0.1', 0, {
          endpoint = '/mcp',
          allowed_origins = { 'null' },
        })
        srv.on_request = function(_, _params, ctx) ctx:ok({ { type = 'text', text = 'async-ok' } }) end
        return srv.port
      end),
      'POST',
      '/mcp',
      '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"x"}}',
      {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json',
        ['Origin'] = 'null',
      }
    )

    eq(true, resp.ok, 'connection error: ' .. tostring(resp.error))
    eq(true, resp.body:match('HTTP/1.1 200') ~= nil, 'expected 200')
    local _, json_start = resp.body:find('\r\n\r\n', 1, true)
    local json_body = json_start and resp.body:sub(json_start + 1) or resp.body
    eq(true, json_body:find('"id":7', 1, true) ~= nil, 'json=' .. json_body)
    eq(true, json_body:find('"isError":false', 1, true) ~= nil)
    eq(true, json_body:find('async-ok', 1, true) ~= nil)
  end)

  it('async tools/call via ctx:err: response body carries isError=true', function()
    local resp = http_request(
      '127.0.0.1',
      exec_lua(function()
        local http = require('mcp.json_rpc.transport.http')
        local srv
        srv, _ = http.bind('127.0.0.1', 0, {
          endpoint = '/mcp',
          allowed_origins = { 'null' },
        })
        srv.on_request = function(_, _params, ctx) ctx:err('boom-async') end
        return srv.port
      end),
      'POST',
      '/mcp',
      '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"x"}}',
      {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json',
        ['Origin'] = 'null',
      }
    )

    eq(true, resp.ok, 'connection error: ' .. tostring(resp.error))
    eq(true, resp.body:match('HTTP/1.1 200') ~= nil, 'expected 200')
    local _, json_start = resp.body:find('\r\n\r\n', 1, true)
    local json_body = json_start and resp.body:sub(json_start + 1) or resp.body
    eq(true, json_body:find('"id":9', 1, true) ~= nil, 'json=' .. json_body)
    eq(true, json_body:find('"isError":true', 1, true) ~= nil, 'expected isError=true')
    eq(true, json_body:find('boom-async', 1, true) ~= nil)
  end)

  it('async ctx:progress: notifications/progress is broadcast to a parallel SSE stream', function()
    -- Open an SSE stream first, then issue a tools/call whose handler
    -- calls ctx:progress. The server must broadcast the progress notice
    -- even though the request-response cycle is a separate HTTP POST.
    local out = exec_lua(function()
      local http = require('mcp.json_rpc.transport.http')
      local framing = require('mcp.json_rpc.transport.framing')
      local uv = vim.uv or vim.loop
      local srv, port = http.bind('127.0.0.1', 0, {
        endpoint = '/mcp',
        allowed_origins = { 'null' },
      })

      local sse_client = uv.new_tcp()
      local sse_chunks = {}
      sse_client:connect('127.0.0.1', port, function(err)
        if err then return end
        sse_client:read_start(function(_, data)
          if data then table.insert(sse_chunks, data) end
        end)
        sse_client:write(
          'GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
            .. 'Accept: text/event-stream\r\nOrigin: null\r\n'
            .. 'Connection: keep-alive\r\n\r\n'
        )
      end)

      vim.wait(500, function()
        for _ in pairs(srv.streams) do
          return true
        end
        return false
      end)

      srv.on_request = function(_, _params, ctx)
        vim.defer_fn(function() ctx:progress(50, 100, 'halfway') end, 10)
      end

      -- Issue the tools/call in a separate client. We only care about the
      -- broadcast hitting the SSE stream, so we don't read the response.
      local post_client = uv.new_tcp()
      post_client:connect('127.0.0.1', port, function(err)
        if err then return end
        post_client:write(
          'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n'
            .. 'Content-Length: 96\r\nContent-Type: application/json\r\n'
            .. 'Accept: application/json\r\nOrigin: null\r\n\r\n'
            .. '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x","_meta":{"progressToken":1}}}'
        )
      end)

      local done = vim.wait(
        2000,
        function() return table.concat(sse_chunks):find('notifications/progress', 1, true) ~= nil end
      )

      local sse_body = table.concat(sse_chunks)
      local _, hdr_end = sse_body:find('\r\n\r\n', 1, true)
      local sse_payload = hdr_end and sse_body:sub(hdr_end + 1) or sse_body

      local function first_data_event(body)
        local cur = body
        while #cur > 0 do
          local data, consumed = framing.sse_decode({ cur }, #cur)
          if not data then break end
          cur = cur:sub((consumed or 0) + 1)
          if data ~= '' then return data end
        end
        return nil
      end

      local decoded = first_data_event(sse_payload)

      sse_client:close()
      post_client:close()
      srv:terminate()

      return {
        wait_done = done,
        saw_progress = sse_body:find('notifications/progress', 1, true) ~= nil,
        decoded = decoded,
      }
    end)

    eq(true, out.wait_done, 'progress notification did not land on SSE within 2s')
    eq(true, out.saw_progress)
    eq('string', type(out.decoded))
    eq(
      true,
      out.decoded:find('"progressToken":1', 1, true) ~= nil,
      'progressToken should echo the request id'
    )
    eq(true, out.decoded:find('"progress":50', 1, true) ~= nil)
    eq(true, out.decoded:find('"total":100', 1, true) ~= nil)
    eq(true, out.decoded:find('halfway', 1, true) ~= nil)
  end)
end)
