local M = {}

M.check = function()
  vim.health.start('mcp')
  local mcp = require('mcp')
  if not mcp._state.setup_done then
    vim.health.warn('setup() has not been called')
    return
  end
  vim.health.ok('setup() called')
  local http_opts = mcp._state.opts.http
  assert(http_opts, 'setup() did not initialise http opts')
  if mcp._state.http_server then
    vim.health.ok(
      string.format('HTTP server listening on %s:%d', http_opts.host, mcp._state.http_port)
    )
  else
    vim.health.info('HTTP server not started')
  end
  local registry = mcp._state.registry
  if registry then
    vim.health.ok(string.format('%d tool(s) registered', #registry:list()))
  else
    vim.health.warn('no tool registry initialised')
  end
end

return M
