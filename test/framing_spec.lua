-- mcp.tests.framing_spec
--
-- Unit tests for the MessageStream framing decoders/encoders. These
-- are pure functions over byte buffers and do not need a live
-- transport, so they run as ordinary busted cases.

local n = require('nvim-test.helpers')

local eq = n.eq
local clear = n.clear
local exec_lua = n.exec_lua

describe('framing.newline', function()
  before_each(function()
    clear()
    exec_lua(
      function() package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p') .. ';' .. package.path end
    )
  end)

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
  before_each(function()
    clear()
    exec_lua(
      function() package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p') .. ';' .. package.path end
    )
  end)

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
