local shared = require('mcp.tools.nvim._shared')

return {
  name = 'nvim_quickfix',
  description = 'Get the current quickfix list as a list of `path:line:col: text` lines (grep-like). Includes the list title for context. Returns a clean message if the list is empty.',
  inputSchema = { type = 'object' },
  handler = function(_)
    local qf = vim.fn.getqflist({ items = 0, title = 0 })
    local title = qf.title
    local items = qf.items or {}

    local title_str = ''
    if title and title ~= '' then title_str = string.format(' (title: %s)', title) end

    if #items == 0 then return shared.text('Quickfix list is empty' .. title_str .. '.') end

    local lines = {
      string.format('Quickfix list: %d entries%s', #items, title_str),
    }
    for i, item in ipairs(items) do
      local fname = item.filename
      if (not fname or fname == '') and item.bufnr and item.bufnr ~= 0 then
        fname = vim.api.nvim_buf_get_name(item.bufnr)
      end
      if not fname or fname == '' then fname = '[No Name]' end
      local lnum = item.lnum or 0
      local col = item.col or 0
      local text_ = item.text or ''
      local type_ = (item.type and item.type ~= '') and (item.type .. ': ') or ''
      table.insert(lines, string.format('%4d %s:%d:%d: %s%s', i, fname, lnum, col, type_, text_))
    end
    return shared.text(table.concat(lines, '\n'))
  end,
}
