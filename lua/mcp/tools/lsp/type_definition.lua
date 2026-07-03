local shared = require('mcp.tools.lsp._shared')

return {
  name = 'lsp_type_definition',
  description = 'Find the type definition of the symbol at a position.',
  inputSchema = {
    type = 'object',
    properties = {
      path = { type = 'string' },
      line = { type = 'integer', minimum = 0 },
      character = { type = 'integer', minimum = 0 },
    },
    required = { 'path', 'line', 'character' },
  },
  handler = function(args)
    local buf, uri = shared.ensure_buffer(args.path)
    local results, errors = shared.buf_request_sync(buf, 'textDocument/typeDefinition', {
      textDocument = { uri = uri },
      position = { line = args.line, character = args.character },
    }, 2000)
    if #errors > 0 and #results == 0 then return nil, table.concat(errors, '; ') end
    local lines = {}
    for _, r in ipairs(results) do
      for _, loc in ipairs(r) do
        table.insert(lines, shared.format_location(loc))
      end
    end
    if #lines == 0 then return shared.text('No type definition found.') end
    return shared.text(table.concat(lines, '\n'))
  end,
}
