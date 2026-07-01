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

vim.api.nvim_create_user_command('McpRegister', function(args)
  -- :McpRegister [opencode_url] [name]
  -- If a URL is passed on the command line we use that; otherwise
  -- we read the URL the user is currently connected to via
  -- opencode.nvim. If neither is available we print a hint.
  local mcp = require('mcp')
  local ok_opencode, opencode = pcall(require, 'opencode')
  local url = args.args and args.args:match('^%S+')
  if not url and ok_opencode and opencode.state and opencode.state.opencode_server then
    url = opencode.state.opencode_server.url
  end
  if not url then
    vim.notify(
      '[mcp] Usage: :McpRegister <opencode_url> [name]\n'
        .. '       Or pair with opencode.nvim and call from the custom.server_ready event.',
      vim.log.levels.ERROR
    )
    return
  end
  local name = args.args and args.args:match('%s+(%S+)$')
  local result = mcp.opencode_register(url, { name = name })
  if not result.ok then
    vim.notify('[mcp] Registration failed: ' .. tostring(result.error), vim.log.levels.ERROR)
  elseif result.status and result.status >= 400 then
    vim.notify(string.format('[mcp] opencode returned %d: %s', result.status, vim.inspect(result.body or result.error)), vim.log.levels.WARN)
  else
    vim.notify(string.format('[mcp] Registered with opencode at %s (status %s)', url, tostring(result.status)), vim.log.levels.INFO)
  end
end, {
  nargs = '?',
  desc = 'Register this mcp.nvim instance with a running opencode server',
})
