-- mcp
--
-- Public entry point. `setup(opts)` configures the plugin and
-- (optionally) starts the HTTP server. The plugin then exposes a
-- `ToolRegistry` that callers can register MCP tools into via
-- `require('mcp').registry:register({ ... })`.
--
-- The plugin is the integration layer between the lower-level
-- modules (json_rpc, server, tool_registry, transport/http). User
-- code typically does not need to touch the lower-level modules
-- directly.

local M = {}

---@class mcp.Opts
---@field tools? table[]   list of mcp.ToolDef to register at setup time
---@field http? { enabled?: boolean, host?: string, port?: integer, allowed_origins?: string[], endpoint?: string }
---@field server_info? table  override the SERVER_INFO used in `initialize` responses
---@field instructions? string  server instructions shown to clients

---@class mcp.State
---@field setup_done boolean
---@field opts mcp.Opts
---@field registry? mcp.ToolRegistry
---@field http_server? mcp.json_rpc.transport.http.Server
---@field http_port? integer

---@type mcp.State
M._state = {
  setup_done = false,
  opts = {},
  registry = nil,
  http_server = nil,
  http_port = nil,
}

--- Configure the plugin. Idempotent: calling setup() more than once
--- replaces the configuration but does not leak the previous server.
---@param opts? mcp.Opts
function M.setup(opts)
  opts = opts or {}
  opts.http = opts.http or {}

  -- Tear down any previous HTTP server so repeated setup() calls
  -- do not leak listening sockets.
  if M._state.http_server then
    M._state.http_server:terminate()
    M._state.http_server = nil
    M._state.http_port = nil
  end

  -- Default the HTTP layer to enabled, on localhost, port 0
  -- (OS-assigned ephemeral). The chosen port is reported back to
  -- the caller via `state.http_port` after setup.
  if opts.http.enabled == nil then opts.http.enabled = true end
  opts.http.host = opts.http.host or '127.0.0.1'
  if opts.http.port == nil then opts.http.port = 0 end

  -- Apply SERVER_INFO overrides if provided.
  if opts.server_info then
    local server = require('mcp.server')
    server.SERVER_INFO = vim.tbl_extend('force', server.SERVER_INFO, opts.server_info)
  end

  -- Construct the registry and seed it with the user-supplied tools.
  local registry = require('mcp.tool_registry').new()
  for _, def in ipairs(opts.tools or {}) do
    registry:register(def)
  end

  -- Construct a stub JSON-RPC Connection whose only job is to hold
  -- the on_request handler closed over a Server instance. The
  -- HTTP transport does not use the streaming Connection; it
  -- dispatches directly to the on_request callback it was given
  -- at bind time. We keep this stub because the registry's
  -- list_changed notifications assume there is a Connection
  -- present, even though we never call Connection.send from here.
  local stub_conn = {
    on_request = function() end,
    on_notify = function() end,
    on_exit = function() end,
    on_error = function() end,
    is_closing = function() return false end,
    notify = function() end,
  }

  -- Construct the MCP Server. The dispatcher is the bridge to the
  -- HTTP transport.
  local mcp_server = require('mcp.server').new(stub_conn, registry)

  -- Apply instructions override.
  if opts.instructions then mcp_server.instructions = opts.instructions end

  -- Save state.
  M._state.setup_done = true
  M._state.opts = opts
  M._state.registry = registry
  M._state.server = mcp_server

  -- Start the HTTP server if enabled.
  if opts.http.enabled then M._start_http() end
end

--- Start the streamable-HTTP server. Idempotent: re-calling while
--- already running is a no-op.
function M._start_http()
  local opts = M._state.opts
  if M._state.http_server then return M._state.http_port end
  local http = require('mcp.json_rpc.transport.http')
  local mcp_server = M._state.server
  local server, port = http.bind(opts.http.host, opts.http.port, {
    endpoint = opts.http.endpoint,
    allowed_origins = opts.http.allowed_origins or { 'null' },
    -- The HTTP transport is request-response, so it dispatches each
    -- message directly. Requests go to the server dispatcher;
    -- notifications (including the lifecycle
    -- notifications/initialized) drive the server's lifecycle
    -- state machine through _on_notify.
    on_request = function(method, params) return mcp_server:_dispatch(method, params) end,
    on_notify = function(method, params) mcp_server:_on_notify(method, params) end,
  })
  M._state.http_server = server
  M._state.http_port = port
  return port
end

--- Stop the HTTP server.
function M.stop()
  if M._state.http_server then
    M._state.http_server:terminate()
    M._state.http_server = nil
    M._state.http_port = nil
  end
end

--- Restart the HTTP server (useful when you change opts).
function M.restart()
  M.stop()
  if M._state.setup_done and M._state.opts.http and M._state.opts.http.enabled ~= false then
    M._start_http()
  end
end

--- Convenience accessor for the tool registry so user code can do
--- `require('mcp').registry:register({ ... })`.
---@return mcp.ToolRegistry?
function M.registry() return M._state.registry end

--- Currently bound HTTP port, or nil if not running.
---@return integer?
function M.http_port() return M._state.http_port end

return M
