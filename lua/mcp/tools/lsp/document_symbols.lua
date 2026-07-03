local shared = require('mcp.tools.lsp._shared')

return {
  name = 'lsp_document_symbols',
  description = 'List all symbols (functions, classes, variables) defined in a file. Returns a flat list of `Kind name @ path:line:col`.',
  inputSchema = {
    type = 'object',
    properties = {
      path = { type = 'string', description = 'Absolute file path.' },
      depth = {
        type = 'integer',
        description = 'Optional. If set, only include symbols with this name-path depth or less. DocumentSymbol hierarchy is flattened.',
      },
    },
    required = { 'path' },
  },
  handler = function(args)
    local buf = vim.fn.bufadd(vim.fn.fnamemodify(args.path, ':p'))
    vim.fn.bufload(buf)
    local results, errors = shared.buf_request_sync(buf, 'textDocument/documentSymbol', {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
    }, 2000)
    if #errors > 0 and #results == 0 then return nil, table.concat(errors, '; ') end
    local lines = {}
    for _, r in ipairs(results) do
      for _, sym in ipairs(r) do
        table.insert(lines, shared.format_symbol(sym))
      end
    end
    if #lines == 0 then return shared.text('No symbols found.') end
    return shared.text(table.concat(lines, '\n'))
  end,
}
