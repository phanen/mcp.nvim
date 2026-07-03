local M = {}

---@param path string
---@return integer bufnr
function M.ensure_buffer(path)
  local abs = vim.fn.fnamemodify(path, ':p')
  if not vim.uv.fs_stat(abs) then error('File not found: ' .. abs) end
  local buf = vim.fn.bufadd(abs)
  vim.fn.bufload(buf)
  return buf
end

---@param content string
---@return table
function M.text(content) return { { type = 'text', text = content } } end

---@param severity integer?
---@return string
function M.severity_name(severity)
  if not severity then return '?' end
  local s = vim.diagnostic and vim.diagnostic.severity
  if not s then return tostring(severity) end
  if severity == s.ERROR then return 'ERROR' end
  if severity == s.WARN then return 'WARN' end
  if severity == s.INFO then return 'INFO' end
  if severity == s.HINT then return 'HINT' end
  return tostring(severity)
end

---@param d table
---@return string
function M.format_diagnostic(d)
  local path = vim.api.nvim_buf_get_name(d.bufnr)
  if path == '' then path = '[No Name]' end
  local header = string.format(
    '%s %s:%d:%d',
    M.severity_name(d.severity),
    path,
    (d.lnum or 0) + 1,
    (d.col or 0) + 1
  )
  local msg = (d.message or ''):gsub('\n', ' ')
  local has_source = d.source and d.source ~= ''
  local has_code = d.code and d.code ~= ''
  if has_source and has_code then
    return string.format('%s [%s:%s] - %s', header, d.source, tostring(d.code), msg)
  elseif has_source then
    return string.format('%s [%s] - %s', header, d.source, msg)
  elseif has_code then
    return string.format('%s [%s] - %s', header, tostring(d.code), msg)
  end
  return string.format('%s - %s', header, msg)
end

return M
