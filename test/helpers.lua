-- mcp.tests.helpers
--
-- Shared setup helpers for the busted spec files. Centralises the
-- `package.path` dance the runner needs to make `require('mcp.*')`
-- resolve against the in-repo `lua/` tree, since nvim-test does not
-- propagate `--lpath` to the inner nvim `--exec` Lua chunks.
--
-- Usage:
--
--   local h = require('test.helpers')
--
--   describe('foo', function()
--     before_each(function() h.setup() end)
--     -- or, when you also need to wipe some module-level state:
--     before_each(function()
--       h.setup(function()
--         package.loaded['mcp.util.http_client'] = nil
--       end)
--     end)
--
--     it('does the thing', function()
--       local out = h.exec_lua(function() return require('mcp.foo').bar() end)
--       h.eq('bar', out)
--     end)
--   end)

local n = require('nvim-test.helpers')

local M = {}

local clear, exec_lua = n.clear, n.exec_lua

M.eq = n.eq
M.neq = n.neq
M.clear = clear
M.exec_lua = exec_lua

--- Restart the child nvim and prepend the repo's `lua/` tree to
--- `package.path` inside it. Mirrors what every spec used to write by
--- hand before its first `require('mcp.*')`.
---
--- @param extra? fun() optional sandbox-side setup that runs after the
---   path prepend in the same nvim instance (e.g. clearing
---   `package.loaded`, resetting module-level state).
function M.setup(extra)
  clear()
  exec_lua(
    function()
      package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p')
        .. ';'
        .. vim.fn.fnamemodify('./lua/?/init.lua;', ':p')
        .. ';'
        .. package.path
    end
  )
  if extra ~= nil then exec_lua(extra) end
end

return M
