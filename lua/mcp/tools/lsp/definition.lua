local shared = require('mcp.tools.lsp._shared')

return {
  name = 'lsp_definition',
  description = 'Resolve the symbol definition at a position. Uses the LSP client attached to the file. Returns a list of file:line:col references (the new location-link shape is auto-normalised).',
  inputSchema = {
    type = 'object',
    properties = {
      path = {
        type = 'string',
        description = 'Absolute file path. Must be loaded into a buffer.',
      },
      line = { type = 'integer', minimum = 0, description = '0-indexed line.' },
      character = { type = 'integer', minimum = 0, description = '0-indexed character.' },
    },
    required = { 'path', 'line', 'character' },
  },
  handler = function(args)
    local buf, uri = shared.ensure_buffer(args.path)
    local results, errors = shared.buf_request_sync(buf, 'textDocument/definition', {
      textDocument = { uri = uri },
      position = { line = args.line, character = args.character },
    }, 2000)
    if #errors > 0 and #results == 0 then return nil, table.concat(errors, '; ') end
    local lines = {}
    for _, r in ipairs(results) do
      if type(r) == 'table' then
        for _, loc in ipairs(r) do
          table.insert(lines, shared.format_location(loc))
        end
      end
    end
    if #lines == 0 then return shared.text('No definition found.') end
    return shared.text(table.concat(lines, '\n'))
  end,
}
