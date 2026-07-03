local M = {}

local log = vim.log.new({ name = 'mcp.opencode' })
vim.log.set_level(log, vim.log.levels.INFO)

local attached = false

function M.is_attached() return attached end

function M.reset() attached = false end

---@class mcp.integrations.opencode.RegisterOpts
---@field name? string
---@field timeout_ms? integer
---@field headers? table<string, string>
---@field directory? string

---@param opencode_url string
---@param opts? mcp.integrations.opencode.RegisterOpts
---@param on_done fun(result: { ok: boolean, status?: integer, body?: any, error?: string })
function M.register(opencode_url, opts, on_done)
  opts = opts or {}
  local name = opts.name or 'nvim'
  local our_url = require('mcp').url()
  if not our_url then
    on_done({ ok = false, error = 'mcp HTTP server is not running; call setup() first' })
    return
  end

  local directory = opts.directory or vim.fn.getcwd()

  local body = vim.json.encode({
    name = name,
    config = { type = 'remote', url = our_url },
  })

  local endpoint = (opencode_url:gsub('/$', ''))
    .. '/mcp?directory='
    .. vim.uri_encode(directory, 'rfc3986')

  require('mcp.util.http_client').post_json(endpoint, body, {
    timeout_ms = opts.timeout_ms or 3000,
    headers = opts.headers or {},
  }, function(result, err)
    if err or not result then
      on_done({ ok = false, error = err or 'http_client returned no result' })
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

function M.attach(opts)
  if attached then return end
  local ok, oc_state = pcall(require, 'opencode.state')
  if not ok then
    log.info('opencode.nvim is not installed; skipping attach')
    return
  end

  local function do_attach(url)
    local directory = oc_state.current_cwd or vim.fn.getcwd()
    M.register(url, { name = opts and opts.name, directory = directory }, function(result)
      if result.ok then
        log.info('Registered with opencode at', url, '(workspace:', directory, ')')
        attached = true
      else
        log.warn(
          'Failed to register with opencode:',
          result.error or ('status ' .. tostring(result.status))
        )
      end
    end)
  end

  local url = oc_state.opencode_server and oc_state.opencode_server.url
  if url then
    do_attach(url)
    return
  end

  local em = oc_state.event_manager
  if not em then
    log.info('opencode.nvim server is not running; skipping attach')
    return
  end
  log.info('opencode.nvim server not ready yet; deferring attach until it is')
  local on_ready = function(data)
    em:unsubscribe('custom.server_ready', on_ready)
    if attached then return end
    do_attach(data.url)
  end
  em:subscribe('custom.server_ready', on_ready)
end

return M
