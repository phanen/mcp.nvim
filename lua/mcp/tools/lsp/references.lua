local shared = require('mcp.tools.lsp._shared')

return {
  name = 'lsp_references',
  description = 'List all references to the symbol at a position. Defaults to including the declaration; pass include_declaration=false to exclude it.',
  inputSchema = {
    type = 'object',
    properties = {
      path = { type = 'string', description = 'Absolute file path.' },
      line = { type = 'integer', minimum = 0 },
      character = { type = 'integer', minimum = 0 },
      include_declaration = {
        type = 'boolean',
        description = 'Include the declaration site in results.',
        default = true,
      },
    },
    required = { 'path', 'line', 'character' },
  },
  handler = function(args, ctx)
    local buf, uri = shared.ensure_buffer(args.path)
    local results, errors = shared.buf_request_sync(buf, 'textDocument/references', {
      textDocument = { uri = uri },
      position = { line = args.line, character = args.character },
      context = { includeDeclaration = args.include_declaration ~= false },
    }, 2000)
    if #errors > 0 and #results == 0 then
      local __r = table.concat(errors, '; ')
      if ctx then ctx:err(__r) end
      return nil, __r
    end
    local count = 0
    for _, r in ipairs(results) do
      for _, _ in ipairs(r) do
        count = count + 1
      end
    end
    local lines = { string.format('%d reference(s):', count) }
    for _, r in ipairs(results) do
      for _, loc in ipairs(r) do
        table.insert(lines, shared.format_location(loc))
      end
    end
    local __r = shared.text(table.concat(lines, '\n'))
    if ctx then ctx:ok(__r) end
    return __r
  end,
}
