-- plugin/mcp
--
-- User-facing commands for the mcp.nvim plugin. Defined here rather
-- than in lua/ so they are auto-registered when the plugin is
-- loaded by Neovim's package loader.

if vim.g.loaded_mcp_nvim == 1 then return end
vim.g.loaded_mcp_nvim = 1

vim.api.nvim_create_user_command('McpStart', function()
  local mcp = require('mcp')
  if not mcp._state.setup_done then
    vim.notify('[mcp] setup() has not been called', vim.log.levels.ERROR)
    return
  end
  local port = mcp._start_http()
  vim.notify(string.format('[mcp] HTTP server listening on port %d', port), vim.log.levels.INFO)
end, { desc = 'Start the mcp.nvim HTTP server' })

vim.api.nvim_create_user_command('McpStop', function()
  require('mcp').stop()
  vim.notify('[mcp] HTTP server stopped', vim.log.levels.INFO)
end, { desc = 'Stop the mcp.nvim HTTP server' })

vim.api.nvim_create_user_command('McpRestart', function()
  require('mcp').restart()
  vim.notify('[mcp] HTTP server restarted', vim.log.levels.INFO)
end, { desc = 'Restart the mcp.nvim HTTP server' })

vim.api.nvim_create_user_command('McpPort', function()
  local port = require('mcp').http_port()
  if port then
    print(string.format('mcp.nvim is listening on http://127.0.0.1:%d/mcp', port))
  else
    print('mcp.nvim is not running; use :McpStart')
  end
end, { desc = 'Print the mcp.nvim HTTP server URL' })

vim.api.nvim_create_user_command('McpAttachOpencode', function(args)
  -- Convenience: same as `require('mcp').attach_opencode({ name = ... })`.
  -- Useful when the user wants to wire mcp.nvim + opencode.nvim
  -- after both are already loaded (e.g. via :packadd) and prefers
  -- the command over a function call.
  local mcp = require('mcp')
  local name = args.args and args.args:match('^%S+')
  mcp.attach_opencode({ name = name })
end, {
  nargs = '?',
  desc = 'Subscribe mcp.nvim to a running opencode.nvim instance',
})
