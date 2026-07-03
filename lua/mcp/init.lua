local M = {}

---@type vim.Log
local log = vim.log.new({ name = 'mcp' })
vim.log.set_level(log, vim.log.levels.INFO)
M.log = log

---@class mcp.Opts
---@field tools? table[]   DEPRECATED: list of mcp.ToolDef to register at setup time. Prefer `register()` after setup; kept for backward compatibility.
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

--- nil broadcasts are silently dropped, so the registry can call
--- `:notify` before the HTTP server is bound.
---@type mcp.json_rpc.transport.http.Server?
local http_broadcaster = nil

---@param opts? mcp.Opts
function M.setup(opts)
  opts = opts or {}
  opts.http = opts.http or {}

  if M._state.http_server then
    M._state.http_server:terminate()
    M._state.http_server = nil
    M._state.http_port = nil
    http_broadcaster = nil
  end

  if opts.http.enabled == nil then opts.http.enabled = true end
  opts.http.host = opts.http.host or '127.0.0.1'
  if opts.http.port == nil then opts.http.port = 0 end

  if opts.server_info then
    local server = require('mcp.server')
    server.SERVER_INFO = vim.tbl_extend('force', server.SERVER_INFO, opts.server_info)
  end

  local registry = require('mcp.tool_registry').new()
  for _, def in ipairs(opts.tools or {}) do
    registry:register(def)
  end

  ---@type mcp.Dispatcher
  local stub_conn = {
    on_request = function() end,
    on_notify = function() end,
    on_exit = function() end,
    on_error = function() end,
    is_closing = function(_self)
      return http_broadcaster ~= nil and http_broadcaster:is_closing() or false
    end,
    notify = function(_self, method, params)
      if http_broadcaster then http_broadcaster:notify(method, params) end
    end,
  }

  local mcp_server = require('mcp.server').new(stub_conn, registry)

  if opts.instructions then mcp_server.instructions = opts.instructions end

  M._state.setup_done = true
  M._state.opts = opts
  M._state.registry = registry
  M._state.server = mcp_server

  assert(opts.http, 'http opts missing') -- narrowed by line 37 default
  if opts.http.enabled then M._start_http() end
end

--- Idempotent.
function M._start_http()
  local opts = M._state.opts
  local http_opts = opts.http
  assert(http_opts, 'setup() did not initialise http opts')
  if M._state.http_server then return M._state.http_port end
  local http = require('mcp.json_rpc.transport.http')
  local mcp_server = M._state.server
  local host = assert(http_opts.host, 'setup() did not set http.host')
  local port = assert(http_opts.port, 'setup() did not set http.port')
  local server, actual_port = http.bind(host, port, {
    endpoint = http_opts.endpoint,
    allowed_origins = http_opts.allowed_origins or { 'null' },
    on_request = function(method, params) return mcp_server:_dispatch(method, params) end,
    on_notify = function(method, params) mcp_server:_on_notify(method, params) end,
    -- SSE liveness is the only session-end signal we have, lacking
    -- `Mcp-Session-Id`. A new client triggers a fresh `initialize`.
    on_sse_closed = function() mcp_server:_reset_for_new_session() end,
  })
  M._state.http_server = server
  M._state.http_port = actual_port
  http_broadcaster = server
  return actual_port
end

function M.stop()
  if M._state.http_server then
    M._state.http_server:terminate()
    M._state.http_server = nil
    M._state.http_port = nil
    http_broadcaster = nil
  end
end

function M.restart()
  M.stop()
  if M._state.setup_done and M._state.opts.http and M._state.opts.http.enabled ~= false then
    M._start_http()
  end
end

---@return mcp.ToolRegistry?
function M.registry() return M._state.registry end

---@class mcp.RegisterSpec
---@field mod? string  module path; must export either a `mcp.ToolDef` table or `(opts) -> mcp.ToolDef`
---@field opts? table  forwarded to the module's factory when it returns a function (ignored otherwise)
---@field name? string  (inline) tool name; required when `mod` is absent
---@field description? string  (inline) tool description; required when `mod` is absent
---@field inputSchema? table  (inline) JSON Schema describing arguments
---@field handler? fun(args: table): table?, string?  (inline) tool handler; required when `mod` is absent
---@field annotations? table  (inline) optional tool annotations

---@param spec mcp.RegisterSpec | mcp.RegisterSpec[]
function M.register(spec)
  if not M._state.setup_done or not M._state.registry then
    error('mcp.register requires setup() to be called first')
  end
  if type(spec) ~= 'table' then error('mcp.register: spec must be a table or a list of tables') end
  if spec[1] ~= nil then
    for _, s in ipairs(spec) do
      M.register(s)
    end
    return
  end

  if not spec.mod then
    M._state.registry:register(spec)
    return
  end

  local ok, mod = pcall(require, spec.mod)
  if not ok then
    error(string.format('mcp.register: failed to require module %q: %s', spec.mod, tostring(mod)))
  end
  local def
  if type(mod) == 'function' then
    def = mod(spec.opts or {})
  elseif type(mod) == 'table' then
    def = mod
  else
    error(
      string.format(
        'mcp.register: module %q must export a `mcp.ToolDef` table or (opts) -> mcp.ToolDef factory',
        spec.mod
      )
    )
  end
  if type(def) ~= 'table' then
    error(
      string.format('mcp.register: module %q returned %s, expected a table', spec.mod, type(def))
    )
  end
  M._state.registry:register(def)
end

---@return integer?
function M.http_port() return M._state.http_port end

---@return string?
function M.url()
  local port = M._state.http_port
  local host = M._state.opts.http and M._state.opts.http.host or '127.0.0.1'
  local endpoint = M._state.opts.http and M._state.opts.http.endpoint or '/mcp'
  if not port then return nil end
  return string.format('http://%s:%d%s', host, port, endpoint)
end

return M
