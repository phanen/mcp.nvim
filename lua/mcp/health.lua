-- mcp.health
--
-- `:checkhealth mcp` integration. Reports:
--   * Whether setup() has been called
--   * Whether the HTTP server is bound and listening
--   * The number of registered tools
--   * The chosen protocol version and transport
--   * Open Origin allow-list (security note)

local M = {}

local function ok(msg) return { 'OK', msg } end

local function warn(msg) return { 'WARN', msg } end

local function info(msg) return { 'INFO', msg } end

local function err(msg) return { 'ERROR', msg } end

---@return table[]  # list of { status, message } rows for vim.health.report_*
function M.check()
  local rows = {}
  local mcp = require('mcp')

  if not mcp._state.setup_done then
    table.insert(rows, warn('setup() has not been called'))
    table.insert(rows, info('Add `require("mcp").setup({})` to your init.lua'))
    return rows
  end

  table.insert(rows, ok('setup() called'))

  if mcp._state.http_server then
    table.insert(
      rows,
      ok(
        string.format(
          'HTTP server listening on %s:%d',
          mcp._state.opts.http.host,
          mcp._state.http_port
        )
      )
    )
    if mcp._state.opts.http.host ~= '127.0.0.1' then
      table.insert(
        rows,
        warn(
          'binding to a non-loopback address exposes the MCP server to your network; consider using a reverse proxy with auth'
        )
      )
    end
  else
    table.insert(rows, info('HTTP server not started (use start() to begin listening)'))
  end

  local registry = mcp._state.registry
  if registry then
    local tools = registry:list()
    table.insert(rows, ok(string.format('%d tool(s) registered', #tools)))
    for _, t in ipairs(tools) do
      table.insert(rows, info(string.format('  - %s: %s', t.name, t.description)))
    end
  else
    table.insert(rows, warn('no tool registry initialised'))
  end

  local origins = mcp._state.opts.http.allowed_origins or { 'null' }
  table.insert(
    rows,
    ok(string.format('Origin allow-list (%d): %s', #origins, table.concat(origins, ', ')))
  )

  table.insert(rows, info('MCP protocol version: ' .. require('mcp.server').PROTOCOL_VERSION))
  table.insert(
    rows,
    info(
      'Server identity: '
        .. require('mcp.server').SERVER_INFO.name
        .. ' v'
        .. require('mcp.server').SERVER_INFO.version
    )
  )

  return rows
end

return M
