local M = {}

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

  M._state.opencode_attached = false
  M._state.setup_done = true
  M._state.opts = opts
  M._state.registry = registry
  M._state.server = mcp_server

  if opts.http.enabled then M._start_http() end
end

--- Idempotent.
function M._start_http()
  local opts = M._state.opts
  if M._state.http_server then return M._state.http_port end
  local http = require('mcp.json_rpc.transport.http')
  local mcp_server = M._state.server
  local server, port = http.bind(opts.http.host, opts.http.port, {
    endpoint = opts.http.endpoint,
    allowed_origins = opts.http.allowed_origins or { 'null' },
    on_request = function(method, params) return mcp_server:_dispatch(method, params) end,
    on_notify = function(method, params) mcp_server:_on_notify(method, params) end,
    -- SSE liveness is the only session-end signal we have, lacking
    -- `Mcp-Session-Id`. A new client triggers a fresh `initialize`.
    on_sse_closed = function() mcp_server:_reset_for_new_session() end,
  })
  M._state.http_server = server
  M._state.http_port = port
  http_broadcaster = server
  return port
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

---@class mcp.OpencodeRegisterOpts
---@field name? string  mcp server name to register as (default `nvim`)
---@field timeout_ms? integer  HTTP request timeout (default 3000)
---@field headers? table<string, string>  extra headers (e.g. opencode auth tokens)
---@field directory? string  workspace directory the registration is associated with (default `vim.fn.getcwd()`)

---@param opencode_url string  base URL of the running opencode server (e.g. http://127.0.0.1:4096)
---@param opts? mcp.OpencodeRegisterOpts
---@param on_done fun(result: { ok: boolean, status?: integer, body?: any, error?: string })
local function opencode_register(opencode_url, opts, on_done)
  opts = opts or {}
  local name = opts.name or 'nvim'
  local our_url = M.url()
  if not our_url then
    on_done({ ok = false, error = 'mcp HTTP server is not running; call setup() first' })
    return
  end

  local directory = opts.directory or vim.fn.getcwd()

  local body = vim.json.encode({
    name = name,
    config = {
      type = 'remote',
      url = our_url,
    },
  })

  local endpoint = (opencode_url:gsub('/$', ''))
    .. '/mcp?directory='
    .. vim.uri_encode(directory, 'rfc3986')

  require('mcp.util.http_client').post_json(endpoint, body, {
    timeout_ms = opts.timeout_ms or 3000,
    headers = opts.headers or {},
  }, function(result, err)
    if err then
      on_done({ ok = false, error = err })
      return
    end

    if result.status < 200 or result.status >= 300 then
      on_done({
        ok = false,
        status = result.status,
        error = ('opencode rejected the registration (HTTP %d): %s'):format(
          result.status,
          result.body
        ),
      })
      return
    end

    local ok, decoded = pcall(vim.json.decode, result.body)
    if ok then
      on_done({ ok = true, status = result.status, body = decoded })
    else
      on_done({
        ok = true,
        status = result.status,
        body = result.body,
        warning = 'response was not valid JSON',
      })
    end
  end)
end

--- Idempotent. Subscribes to opencode.nvim's state store so the
--- registration is re-issued on `current_cwd` / `active_session`
--- changes without the user writing any autocmd.
---@param opts? { name?: string }
function M.attach_opencode(opts)
  opts = opts or {}
  if M._state.opencode_attached then return end
  local ok, oc_state = pcall(require, 'opencode.state')
  if not ok then
    vim.notify('[mcp] opencode.nvim is not installed; skipping attach', vim.log.levels.INFO)
    return
  end

  local last_registered_directory
  local last_server_url
  local debounce_timer

  local function do_register(url, directory)
    last_registered_directory = directory
    opencode_register(url, { name = opts.name, directory = directory }, function(result)
      if result.ok then
        vim.notify(
          string.format('[mcp] Registered with opencode at %s (workspace: %s)', url, directory),
          vim.log.levels.INFO
        )
      else
        vim.notify(
          string.format(
            '[mcp] Failed to register with opencode: %s',
            result.error or ('status ' .. tostring(result.status))
          ),
          vim.log.levels.WARN
        )
      end
    end)
  end

  local function schedule_re_register(directory)
    if not last_server_url or type(directory) ~= 'string' or directory == '' then return end
    if directory == last_registered_directory then return end
    if debounce_timer and not debounce_timer:is_closing() then
      debounce_timer:stop()
      debounce_timer:close()
    end
    debounce_timer = vim.uv.new_timer()
    debounce_timer:start(200, 0, function()
      if debounce_timer and not debounce_timer:is_closing() then
        debounce_timer:stop()
        debounce_timer:close()
      end
      debounce_timer = nil
      if directory == last_registered_directory then return end
      do_register(last_server_url, directory)
    end)
  end

  local function wire(event_manager)
    event_manager:subscribe('custom.server_ready', function(data)
      last_server_url = data.url
      do_register(data.url, oc_state.current_cwd or vim.fn.getcwd())
    end)

    oc_state.store.subscribe('current_cwd', function(_, new_val) schedule_re_register(new_val) end)

    oc_state.store.subscribe(
      'active_session',
      function(_, new_val) schedule_re_register(new_val and new_val.directory) end
    )
  end

  if oc_state.opencode_server and oc_state.opencode_server.url then
    local last_server_url = oc_state.opencode_server.url
    local directory = oc_state.current_cwd or vim.fn.getcwd()
    do_register(last_server_url, directory)

    local function attach_followups()
      oc_state.store.subscribe(
        'current_cwd',
        function(_, new_val) schedule_re_register(new_val) end
      )
      oc_state.store.subscribe(
        'active_session',
        function(_, new_val) schedule_re_register(new_val and new_val.directory) end
      )
    end
    if oc_state.event_manager then
      oc_state.event_manager:subscribe('custom.server_ready', function(data) end)
      attach_followups()
    elseif oc_state.store and oc_state.store.subscribe then
      oc_state.store.subscribe('event_manager', function(_, new_val)
        if M._state.opencode_attached then return end
        if not new_val then return end
        new_val:subscribe('custom.server_ready', function(data) end)
        attach_followups()
      end)
    end
    M._state.opencode_attached = true
    return
  end

  if oc_state.event_manager then
    wire(oc_state.event_manager)
    M._state.opencode_attached = true
    return
  end

  if not (oc_state.store and oc_state.store.subscribe) then
    vim.notify(
      '[mcp] opencode.nvim is loaded but its state store is missing; attach_opencode is a no-op',
      vim.log.levels.WARN
    )
    return
  end
  vim.notify(
    '[mcp] opencode.nvim EventManager not ready yet; deferring attach until it is',
    vim.log.levels.INFO
  )
  oc_state.store.subscribe('event_manager', function(_, new_val)
    if M._state.opencode_attached then return end
    if not new_val then return end
    wire(new_val)
    M._state.opencode_attached = true
  end)
end

---@return string?
function M.url()
  local port = M._state.http_port
  local host = M._state.opts.http and M._state.opts.http.host or '127.0.0.1'
  local endpoint = M._state.opts.http and M._state.opts.http.endpoint or '/mcp'
  if not port then return nil end
  return string.format('http://%s:%d%s', host, port, endpoint)
end

return M
