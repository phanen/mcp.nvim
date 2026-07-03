local M = {}

---@param path string
---@return string  idempotent for inputs already in URI form
function M.path_to_uri(path)
  if path:sub(1, 7) == 'file://' then return path end
  return 'file://' .. (vim.uri_encode and vim.uri_encode(path) or path:gsub(' ', '%%20'))
end

---@param uri string
---@return string  returns input unchanged when not a URI
function M.uri_to_path(uri)
  if uri:sub(1, 7) ~= 'file://' then return uri end
  local ok, path = pcall(vim.uri_to_fname, uri)
  if ok and path and path ~= '' then return path end
  return uri:sub(8)
end

--- Format an LSP `Location` or `LocationLink` as one-line `path:line:col`.
--- Accepts both the old `Location` and the `LocationLink` shape
--- (`targetUri` / `targetRange`) so the caller doesn't special-case.
---@param loc table
---@return string
function M.format_location(loc)
  if loc.targetUri then
    return string.format(
      '%s:%d:%d',
      M.uri_to_path(loc.targetUri),
      (loc.targetRange.start.line or 0) + 1,
      (loc.targetRange.start.character or 0) + 1
    )
  end
  local uri = loc.uri or loc.documentUri
  if not uri then return tostring(loc) end
  local r = loc.range
    or { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 0 } }
  return string.format(
    '%s:%d:%d',
    M.uri_to_path(uri),
    (r.start.line or 0) + 1,
    (r.start.character or 0) + 1
  )
end

---@param sym table
---@return string
function M.format_symbol(sym)
  local kind = sym.kind
  local kind_name = 'Symbol'
  if vim.lsp and vim.lsp.protocol and vim.lsp.protocol.SymbolKind then
    kind_name = vim.lsp.protocol.SymbolKind[kind] or kind_name
  end
  local loc = sym.location or sym.range
  if sym.range and not sym.location then loc = { range = sym.range, uri = sym.uri } end
  local pos = loc.range and loc.range.start or { line = 0, character = 0 }
  local path = loc.uri and M.uri_to_path(loc.uri) or '<unknown>'
  return string.format(
    '%s %s @ %s:%d:%d',
    kind_name,
    sym.name or '?',
    path,
    (pos.line or 0) + 1,
    (pos.character or 0) + 1
  )
end

---@param path string
---@return integer bufnr
---@return string? uri
function M.ensure_buffer(path)
  local abs = vim.fn.fnamemodify(path, ':p')
  if not vim.uv.fs_stat(abs) then error('File not found: ' .. abs) end
  local buf = vim.fn.bufadd(abs)
  vim.fn.bufload(buf)
  local uri = vim.uri_from_bufnr(buf) or M.path_to_uri(abs)
  return buf, uri
end

---@param bufnr integer
---@param method string
---@param params table
---@param timeout_ms? integer default 2000
---@return table[] results
---@return string[] errors
function M.buf_request_sync(bufnr, method, params, timeout_ms)
  timeout_ms = timeout_ms or 2000
  local responses = vim.lsp.buf_request_sync(bufnr, method, params, timeout_ms)
  if not responses then
    return {}, { 'LSP request timed out after ' .. tostring(timeout_ms) .. 'ms' }
  end
  local results = {}
  local errors = {}
  for _, resp in pairs(responses) do
    if resp.err then
      table.insert(errors, tostring(resp.err.message or resp.err))
    elseif resp.result ~= nil then
      table.insert(results, resp.result)
    end
  end
  return results, errors
end

--- Apply TextEdits in reverse start-position order so earlier ranges
--- do not shift under later insertions.
---@param bufnr integer
---@param edits table[]
function M.apply_text_edits(bufnr, edits)
  if not edits or #edits == 0 then return end
  local sorted = {}
  for _, e in ipairs(edits) do
    table.insert(sorted, e)
  end
  table.sort(sorted, function(a, b)
    local la, lb = a.range.start.line, b.range.start.line
    if la ~= lb then return la > lb end
    return a.range.start.character > b.range.start.character
  end)
  for _, edit in ipairs(sorted) do
    local s = edit.range.start
    local e = edit.range['end']
    local replacement = edit.newText or ''
    local lines = vim.split(replacement, '\n', { plain = true })
    vim.api.nvim_buf_set_text(bufnr, s.line, s.character, e.line, e.character, lines)
  end
end

---@param edit table
---@return string[] paths
---@return table<string, table[]> edits_by_path
function M.apply_workspace_edit(edit)
  local edits_by_path = {}
  if edit.changes then
    for uri, edits in pairs(edit.changes) do
      edits_by_path[M.uri_to_path(uri)] = edits
    end
  end
  if edit.documentChanges then
    for _, change in ipairs(edit.documentChanges) do
      if change.textDocument then
        edits_by_path[M.uri_to_path(change.textDocument.uri)] = change.edits
      end
    end
  end
  for path, edits in pairs(edits_by_path) do
    local abs = vim.fn.fnamemodify(path, ':p')
    local buf = vim.fn.bufadd(abs)
    vim.fn.bufload(buf)
    M.apply_text_edits(buf, edits)
  end
  local paths = {}
  for p in pairs(edits_by_path) do
    paths[#paths + 1] = p
  end
  table.sort(paths)
  return paths, edits_by_path
end

---@param content string
---@return table
function M.text(content) return { { type = 'text', text = content } } end

return M
