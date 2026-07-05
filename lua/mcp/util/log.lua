-- Thin shim over `vim.log` (Neovim 0.12+ nightly). The shim exposes
-- the same `new` / `set_level` / `levels` surface so callers stay
-- portable. On older Neovim builds `vim.log.new` is missing, so the
-- shim returns a stub logger whose `info` / `warn` / `error` methods
-- forward to `vim.notify` so messages still surface via `:messages`.
local M = {}

M.levels = {
  TRACE = 0,
  DEBUG = 1,
  INFO = 2,
  WARN = 3,
  ERROR = 4,
  OFF = 5,
}

local function has_real_log() return type(vim.log) == 'table' and type(vim.log.new) == 'function' end

local function has_set_level()
  return type(vim.log) == 'table' and type(vim.log.set_level) == 'function'
end

local function make_legacy_logger(name)
  local label = {
    [M.levels.TRACE] = 'TRACE',
    [M.levels.DEBUG] = 'DEBUG',
    [M.levels.INFO] = 'INFO',
    [M.levels.WARN] = 'WARN',
    [M.levels.ERROR] = 'ERROR',
  }
  local function emit(level, ...)
    local msg = table.concat({ ... }, ' ')
    if msg == '' then return end
    vim.notify(string.format('[%s][%s] %s', name, label[level] or 'INFO', msg), level)
  end
  return {
    trace = function(...) emit(M.levels.TRACE, ...) end,
    debug = function(...) emit(M.levels.DEBUG, ...) end,
    info = function(...) emit(M.levels.INFO, ...) end,
    warn = function(...) emit(M.levels.WARN, ...) end,
    error = function(...) emit(M.levels.ERROR, ...) end,
  }
end

---@param opts? { name?: string, current_level?: integer }
---@return table
function M.new(opts)
  opts = opts or {}
  if has_real_log() then return vim.log.new(opts) end
  return make_legacy_logger(opts.name or 'mcp')
end

---@param log table
---@param level integer
function M.set_level(log, level)
  if has_set_level() then return vim.log.set_level(log, level) end
end

return M
