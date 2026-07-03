if vim.g.loaded_mcp_nvim == 1 then return end
vim.g.loaded_mcp_nvim = 1

vim.api.nvim_create_user_command('McpStart', function()
  local mcp = require('mcp')
  if not mcp._state.setup_done then
    mcp.log.error('setup() has not been called')
    return
  end
  local port = mcp._start_http()
  mcp.log.info('HTTP server listening on port', port)
end, { desc = 'Start the mcp.nvim HTTP server' })

vim.api.nvim_create_user_command('McpStop', function()
  local mcp = require('mcp')
  mcp.stop()
  mcp.log.info('HTTP server stopped')
end, { desc = 'Stop the mcp.nvim HTTP server' })

vim.api.nvim_create_user_command('McpRestart', function()
  local mcp = require('mcp')
  mcp.restart()
  mcp.log.info('HTTP server restarted')
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
  local mcp = require('mcp')
  local name = args.args and args.args:match('^%S+')
  mcp.attach_opencode({ name = name })
end, {
  nargs = '?',
  desc = 'Subscribe mcp.nvim to a running opencode.nvim instance',
})
