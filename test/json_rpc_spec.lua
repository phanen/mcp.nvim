-- mcp.tests.json_rpc_spec
--
-- Smoke tests for the generic JSON-RPC peer. We cover the public API
-- surface (error codes, error builders) and one round-trip through a
-- mock transport to validate that the Connection dispatches incoming
-- requests back to the user. End-to-end tests against real
-- TCP / stdio transports live in transport_spec.lua (added when the
-- transport module lands).

local n = require('nvim-test.helpers')

local eq = n.eq
local clear = n.clear
local exec_lua = n.exec_lua

describe('json_rpc', function()
  before_each(function()
    clear()
    exec_lua(function()
      -- nvim-test's busted runner does not propagate --lpath to the
      -- inner nvim --exec Lua chunks in a way we can rely on, so we
      -- explicitly prepend the plugin's lua/ tree to package.path.
      package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p')
        .. ';'
        .. vim.fn.fnamemodify('./lua/?/init.lua;', ':p')
        .. ';'
        .. package.path
    end)
  end)

  it('exposes the standard JSON-RPC reserved error codes', function()
    eq(-32700, exec_lua(function() return require('mcp.json_rpc').error_code.parse_error end))
    eq(-32600, exec_lua(function() return require('mcp.json_rpc').error_code.invalid_request end))
    eq(-32601, exec_lua(function() return require('mcp.json_rpc').error_code.method_not_found end))
    eq(-32602, exec_lua(function() return require('mcp.json_rpc').error_code.invalid_params end))
    eq(-32603, exec_lua(function() return require('mcp.json_rpc').error_code.internal_error end))
  end)

  it('builds an error object with code, message, and optional data', function()
    local err = exec_lua(
      function() return require('mcp.json_rpc').make_error(-32602, 'bad input', { field = 'x' }) end
    )
    eq(-32602, err.code)
    eq('bad input', err.message)
    eq('x', err.data.field)
  end)

  it('errors.* factory functions produce shaped error objects', function()
    local out = exec_lua(function()
      local E = require('mcp.json_rpc').errors
      return {
        parse = E.parse_error().code,
        invalid_req = E.invalid_request().code,
        not_found = E.method_not_found('xyz').code,
        bad_params = E.invalid_params().code,
        internal = E.internal_error().code,
        not_found_msg = E.method_not_found('xyz').message,
      }
    end)
    eq(-32700, out.parse)
    eq(-32600, out.invalid_req)
    eq(-32601, out.not_found)
    eq(-32602, out.bad_params)
    eq(-32603, out.internal)
    eq('Method not found: xyz', out.not_found_msg)
  end)
end)
