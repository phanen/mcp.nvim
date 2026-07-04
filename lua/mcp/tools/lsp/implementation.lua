local shared = require('mcp.tools.lsp._shared')

return {
  name = 'lsp_implementation',
  description = 'Find implementations of an interface or abstract method at a position.',
  inputSchema = {
    type = 'object',
    properties = {
      path = { type = 'string' },
      line = { type = 'integer', minimum = 0 },
      character = { type = 'integer', minimum = 0 },
    },
    required = { 'path', 'line', 'character' },
  },
  handler = function(args, ctx)
    local buf, uri = shared.ensure_buffer(args.path)
    local results, errors = shared.buf_request_sync(buf, 'textDocument/implementation', {
      textDocument = { uri = uri },
      position = { line = args.line, character = args.character },
    }, 2000)
    if #errors > 0 and #results == 0 then
      local __r = table.concat(errors, '; ')
      if ctx then ctx:err(__r) end
      return nil, __r
    end
    local lines = {}
    for _, r in ipairs(results) do
      for _, loc in ipairs(r) do
        table.insert(lines, shared.format_location(loc))
      end
    end
    if #lines == 0 then
      local __r = shared.text('No implementations found.')
      if ctx then ctx:ok(__r) end
      return __r
    end
    local __r = shared.text(table.concat(lines, '\n'))
    if ctx then ctx:ok(__r) end
    return __r
  end,
}
