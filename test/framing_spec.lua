-- mcp.tests.framing_spec
--
-- Unit tests for the MessageStream framing decoders/encoders. These
-- are pure functions over byte buffers and do not need a live
-- transport, so they run as ordinary busted cases.

local h = require('test.helpers')

local eq = h.eq
local exec_lua = h.exec_lua

describe('framing.newline', function()
  before_each(function() h.setup() end)

  it('returns nil until a complete line is in the buffer', function()
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      local body, consumed = framing.newline_decode({ 'partial' }, 7)
      return { body = body, consumed = consumed }
    end)
    eq(nil, got.body)
    eq(nil, got.consumed)
  end)

  it('returns the body and the bytes consumed when a LF is found', function()
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      local body, consumed = framing.newline_decode({ 'hello\nworld' }, 11)
      return { body = body, consumed = consumed }
    end)
    eq('hello', got.body)
    eq(6, got.consumed)
  end)

  it('strips trailing CR before LF (tolerates CRLF line endings)', function()
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      local body, consumed = framing.newline_decode({ 'ok\r\nnext' }, 8)
      return { body = body, consumed = consumed }
    end)
    eq('ok', got.body)
    eq(4, got.consumed)
  end)

  it('emits a single LF on encode', function()
    local encoded = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      return framing.newline_encode('hello')
    end)
    eq('hello\n', encoded)
  end)
end)

describe('framing.content_length', function()
  before_each(function() h.setup() end)

  it('returns nil until the header terminator arrives', function()
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      local body, _ = framing.content_length_decode({ 'Content-Length: 5\r\n' }, 19)
      return body
    end)
    eq(nil, got)
  end)

  it('returns nil until the full body arrives', function()
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      local body, _ = framing.content_length_decode({ 'Content-Length: 11\r\n\r\nhello' }, 30)
      return body
    end)
    eq(nil, got)
  end)

  it('returns the body and total consumed once everything is present', function()
    -- 17 (Content-Length: 5) + 2 (\r\n) + 2 (\r\n) + 5 (hello) = 26
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      local body, consumed = framing.content_length_decode({ 'Content-Length: 5\r\n\r\nhello' }, 30)
      return { body = body, consumed = consumed }
    end)
    eq('hello', got.body)
    eq(26, got.consumed)
  end)

  it('emits the LSP-style frame on encode', function()
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      return framing.content_length_encode('hi')
    end)
    eq('Content-Length: 2\r\n\r\nhi', got)
  end)
end)

describe('framing.sse', function()
  before_each(function() h.setup() end)

  it('encodes a single-line payload with id and data', function()
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      return framing.sse_encode(7, '{"jsonrpc":"2.0"}')
    end)
    eq('id: 7\ndata: {"jsonrpc":"2.0"}\n\n', got)
  end)

  it('encodes a payload without an id when nil is passed', function()
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      return framing.sse_encode(nil, 'hello')
    end)
    eq('data: hello\n\n', got)
  end)

  it('prefixes every line of a multi-line payload with data:', function()
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      return framing.sse_encode(2, 'line one\nline two')
    end)
    eq('id: 2\ndata: line one\ndata: line two\n\n', got)
  end)

  it('returns nil until the event terminator arrives', function()
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      return framing.sse_decode({ 'id: 1\ndata: x' }, #'id: 1\ndata: x')
    end)
    eq(nil, got)
  end)

  it('returns the data payload and the bytes consumed on \\n\\n terminator', function()
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      local buf = 'id: 1\ndata: hello\n\n'
      local body, consumed = framing.sse_decode({ buf }, #buf)
      return { body = body, consumed = consumed, buf_len = #buf }
    end)
    eq('hello', got.body)
    eq(got.buf_len, got.consumed)
  end)

  it('also accepts the \\r\\n\\r\\n terminator (some clients use CRLF)', function()
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      local buf = 'id: 1\r\ndata: hi\r\n\r\n'
      local body, consumed = framing.sse_decode({ buf }, #buf)
      return { body = body, consumed = consumed, buf_len = #buf }
    end)
    eq('hi', got.body)
    eq(got.buf_len, got.consumed)
  end)

  it('skips comment lines and only surfaces data: fields', function()
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      local buf = ': heartbeat\nid: 1\nevent: message\ndata: payload\n\n'
      local body = framing.sse_decode({ buf }, #buf)
      return body
    end)
    eq('payload', got)
  end)

  it('encode and decode round-trip for a JSON-RPC notification', function()
    local got = exec_lua(function()
      local framing = require('mcp.json_rpc.transport.framing')
      local payload = '{"jsonrpc":"2.0","method":"notifications/x"}'
      local frame = framing.sse_encode(99, payload)
      local body = framing.sse_decode({ frame }, #frame)
      return body
    end)
    eq('{"jsonrpc":"2.0","method":"notifications/x"}', got)
  end)
end)
