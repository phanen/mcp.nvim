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

-- The HTTP server the stub connection forwards notifications to.
-- Set by `_start_http()` and cleared whenever the server is torn
-- down (see `stop()` and the re-`setup()` path). When nil, the
-- registry's `:notify` is a silent no-op — which is fine because
-- nothing is connected yet to receive a stream event.
---@type mcp.json_rpc.transport.http.Server?
local http_broadcaster = nil

--- Configure the plugin. Idempotent: calling setup() more than once
--- replaces the configuration but does not leak the previous server.
---@param opts? mcp.Opts
function M.setup(opts)
  opts = opts or {}
  opts.http = opts.http or {}

  -- Tear down any previous HTTP server so repeated setup() calls
  -- do not leak listening sockets. Clearing `http_broadcaster` here
  -- also drops any in-flight stub_conn notifications on the floor
  -- rather than letting them touch a dead server.
  if M._state.http_server then
    M._state.http_server:terminate()
    M._state.http_server = nil
    M._state.http_port = nil
    http_broadcaster = nil
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

  -- Construct a stub JSON-RPC Connection. The HTTP transport does
  -- not use this Connection for message delivery; it dispatches
  -- directly to the on_request callback it was given at bind time.
  --
  -- The stub exists so that the registry has a Connection to call
  -- `:notify(method, params)` on. That call forwards into the
  -- streamable-HTTP server's SSE broadcaster, which serializes it
  -- as a `text/event-stream` event to every connected client. Until
  -- `_start_http()` runs the broadcaster is nil, so early-call
  -- list_changed notifications are no-ops (and harmless — nothing
  -- is connected yet to receive them).
  --
  -- The dispatcher methods (`on_request`, `on_notify`, `on_exit`,
  -- `on_error`) are properties, not methods — the server stores
  -- them directly. `is_closing` and `notify` are called via `:`
  -- syntax by the registry, so they receive `self` as the first
  -- argument and must accept it (even though the table shape is
  -- fixed, the Lua method-call sugar is what wires it up).
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

  -- Construct the MCP Server. The dispatcher is the bridge to the
  -- HTTP transport.
  local mcp_server = require('mcp.server').new(stub_conn, registry)

  -- Apply instructions override.
  if opts.instructions then mcp_server.instructions = opts.instructions end

  -- Reset attach state so re-running setup() does not silently
  -- leave a stale opencode subscription attached to the old server.
  M._state.opencode_attached = false

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
  -- Make the registry's stub_conn.notify forward into the new
  -- server's SSE broadcaster. After this point, list_changed and
  -- any future server-initiated notifications ride every open SSE
  -- stream.
  http_broadcaster = server
  return port
end

--- Stop the HTTP server.
function M.stop()
  if M._state.http_server then
    M._state.http_server:terminate()
    M._state.http_server = nil
    M._state.http_port = nil
    http_broadcaster = nil
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

---@class mcp.OpencodeRegisterOpts
---@field name? string  mcp server name to register as (default `nvim`)
---@field timeout_ms? integer  HTTP request timeout (default 3000)
---@field headers? table<string, string>  extra headers (e.g. opencode auth tokens)
---@field directory? string  workspace directory the registration is associated with (default `vim.fn.getcwd()`)

--- POST the mcp.nvim URL to an opencode server's `mcp.add` endpoint
--- so opencode connects to us and pulls tools. Module-local: not
--- part of the public API. The only caller is `attach_opencode`; the
--- manual command path was removed because it duplicated the
--- auto-wire flow and left no good answer for the "no opencode.nvim"
--- user (they should edit `opencode.json` instead).
---
--- Must be defined before `M.attach_opencode` so the closures inside
--- capture the local upvalue rather than the global of the same name.
---@param opencode_url string  base URL of the running opencode server (e.g. http://127.0.0.1:4096)
---@param opts? mcp.OpencodeRegisterOpts
---@return table  { ok, status?, body?, error? }
local function opencode_register(opencode_url, opts)
  opts = opts or {}
  local name = opts.name or 'nvim'
  local our_url = M.url()
  if not our_url then
    return { ok = false, error = 'mcp HTTP server is not running; call setup() first' }
  end

  -- opencode servers key MCP registrations by workspace directory. The
  -- picker in opencode.nvim always queries `GET /mcp?directory=<cwd>`,
  -- so we have to POST with the same directory for the server to
  -- show up in the user's current project. Without this param the
  -- server gets associated with the opencode process's own CWD and
  -- is invisible from any project buffer.
  local directory = opts.directory or vim.fn.getcwd()

  local http = require('mcp.util.http_client')
  local body = vim.json.encode({
    name = name,
    config = {
      type = 'remote',
      url = our_url,
    },
  })

  -- Tiny URL encoder: use Neovim's built-in. The opencode server
  -- only does an exact-match on this value, so over-encoding is
  -- fine as long as the bytes match the path on disk.
  local endpoint = (opencode_url:gsub('/$', ''))
    .. '/mcp?directory='
    .. vim.uri_encode(directory, 'rfc3986')
  local result, err = http.post_json(endpoint, body, {
    timeout_ms = opts.timeout_ms or 3000,
    headers = opts.headers or {},
  })

  if err then return { ok = false, error = err } end

  if result.status < 200 or result.status >= 300 then
    return {
      ok = false,
      status = result.status,
      error = ('opencode rejected the registration (HTTP %d): %s'):format(
        result.status,
        result.body
      ),
    }
  end

  local ok2, decoded = pcall(vim.json.decode, result.body)
  if not ok2 then
    return {
      ok = true,
      status = result.status,
      body = result.body,
      warning = 'response was not valid JSON',
    }
  end
  return { ok = true, status = result.status, body = decoded }
end

--- Subscribe to a running opencode.nvim instance and auto-register
--- this mcp.nvim server with it whenever opencode is ready, and re-
--- register whenever opencode.nvim's `current_cwd` or
--- `active_session` changes so that the entry stays visible in
--- `:Opencode mcp`. This is the recommended way to pair mcp.nvim
--- with opencode.nvim; the user does not have to write any
--- autocmd themselves.
---
--- opencode.nvim keys MCP state by workspace directory. The
--- `:Opencode mcp` picker queries `GET /mcp?directory=<current_cwd>`,
--- so we POST against the same directory. Rather than mirroring
--- opencode.nvim's DirChanged autocmd, we subscribe directly to
--- the opencode state store; that way we also catch new sessions
--- opened in a different directory without an `:cd`.
---
--- The function is idempotent: calling it more than once will not
--- register the callback twice.
---
---@param opts? { name?: string }
function M.attach_opencode(opts)
  opts = opts or {}
  if M._state.opencode_attached then return end
  local ok, oc_state = pcall(require, 'opencode.state')
  if not ok then
    vim.notify('[mcp] opencode.nvim is not installed; skipping attach', vim.log.levels.INFO)
    return
  end

  -- All the actual wiring lives here so we can call it once now and
  -- again later if the EventManager wasn't ready yet. opencode.nvim
  -- builds its EventManager as the last step of `require('opencode')
  -- .setup(...)` (see opencode2/lua/opencode/event_manager.lua:632),
  -- and mcp.nvim's `config = function()` is often called before that
  -- because users typically don't declare a `dependencies` edge. So
  -- the EventManager is usually nil on the first call. The fix is to
  -- subscribe to the store's `event_manager` slot and re-run the
  -- wiring once opencode.nvim publishes the real manager.
  local function wire(event_manager)
    local last_server_url

    ---@param directory string
    local function re_register_for(directory)
      if not last_server_url then return end
      local result = opencode_register(last_server_url, { name = opts.name, directory = directory })
      if not result.ok then
        vim.notify(
          string.format(
            '[mcp] Failed to (re)register against %s: %s',
            directory,
            result.error or 'unknown'
          ),
          vim.log.levels.WARN
        )
      end
    end

    event_manager:subscribe('custom.server_ready', function(data)
      last_server_url = data.url
      local directory = oc_state.current_cwd or vim.fn.getcwd()
      local result = opencode_register(data.url, { name = opts.name, directory = directory })
      if result.ok then
        vim.notify(
          string.format('[mcp] Registered with opencode at %s (workspace: %s)', data.url, directory),
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

    -- Re-register when opencode.nvim's tracked cwd changes (e.g. the
    -- user runs `:cd`, opens a new tab in a different folder, or
    -- opencode.nvim updates its state from elsewhere).
    oc_state.store.subscribe('current_cwd', function(_, new_val)
      if type(new_val) == 'string' and new_val ~= '' then re_register_for(new_val) end
    end)

    -- Re-register when the active session swaps to one anchored in
    -- a different directory.
    oc_state.store.subscribe('active_session', function(_, new_val)
      local dir = new_val and new_val.directory
      if type(dir) == 'string' and dir ~= '' then re_register_for(dir) end
    end)

    M._state.opencode_attached = true
  end

  -- Fast path: EventManager is already wired. Wire immediately.
  if oc_state.event_manager then
    wire(oc_state.event_manager)
    return
  end

  -- Slow path: watch the store for `event_manager` becoming set.
  -- opencode.nvim publishes it as the final step of its setup, so
  -- this callback fires once and then we never run again. Falls
  -- through to the user-visible warning if opencode.nvim's state
  -- module is loaded but the store isn't (which would be unusual
  -- — e.g. a manual stub for unit tests).
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
  end)
end

--- Public URL of the bound HTTP server, suitable for passing to an
--- MCP client config. Returns `nil` when the server is not running.
---@return string?
function M.url()
  local port = M._state.http_port
  local host = M._state.opts.http and M._state.opts.http.host or '127.0.0.1'
  local endpoint = M._state.opts.http and M._state.opts.http.endpoint or '/mcp'
  if not port then return nil end
  return string.format('http://%s:%d%s', host, port, endpoint)
end

return M
