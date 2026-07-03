local shared = require('mcp.tools.lsp._shared')

return {
  name = 'lsp_rename',
  description = 'Rename the symbol at path/line/column to new_name. Sends `textDocument/rename` to the LSP client attached to the file and applies the returned WorkspaceEdit to the affected buffers (unsaved). Returns one `file:line:col` line per applied edit, sorted by file then position.',
  inputSchema = {
    type = 'object',
    properties = {
      path = {
        type = 'string',
        description = 'Absolute file path. Must be loaded into a buffer.',
      },
      line = { type = 'integer', minimum = 0, description = '0-indexed line of the symbol.' },
      character = {
        type = 'integer',
        minimum = 0,
        description = '0-indexed character of the symbol.',
      },
      new_name = { type = 'string', description = 'The new name to rename the symbol to.' },
    },
    required = { 'path', 'line', 'character', 'new_name' },
  },
  handler = function(args)
    local buf, uri = shared.ensure_buffer(args.path)
    local results, errors = shared.buf_request_sync(buf, 'textDocument/rename', {
      textDocument = { uri = uri },
      position = { line = args.line, character = args.character },
      newName = args.new_name,
    }, 2000)
    if #errors > 0 and #results == 0 then return nil, table.concat(errors, '; ') end

    local edit = nil
    for _, r in ipairs(results) do
      if r ~= nil then
        edit = r
        break
      end
    end

    if not edit or (not edit.changes and not edit.documentChanges) then
      return shared.text(
        'No rename edits returned (symbol may not be renameable at this position).'
      )
    end

    local paths, edits_by_path = shared.apply_workspace_edit(edit)

    local total = 0
    for _, edits in pairs(edits_by_path) do
      total = total + #edits
    end

    local lines = {
      string.format('Renamed to %q (%d edit(s) across %d file(s)):', args.new_name, total, #paths),
    }
    for _, path in ipairs(paths) do
      local edits = edits_by_path[path]
      local ordered = {}
      for _, e in ipairs(edits) do
        table.insert(ordered, e)
      end
      table.sort(ordered, function(a, b)
        if a.range.start.line ~= b.range.start.line then
          return a.range.start.line < b.range.start.line
        end
        return a.range.start.character < b.range.start.character
      end)
      for _, e in ipairs(ordered) do
        local s = e.range.start
        table.insert(
          lines,
          string.format('%s:%d:%d', path, (s.line or 0) + 1, (s.character or 0) + 1)
        )
      end
    end
    return shared.text(table.concat(lines, '\n'))
  end,
}
