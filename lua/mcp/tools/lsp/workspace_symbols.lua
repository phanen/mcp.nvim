local shared = require('mcp.tools.lsp._shared')

return {
  name = 'lsp_workspace_symbols',
  description = 'Search for symbols across the workspace by query string. Returns a flat list of matches.',
  inputSchema = {
    type = 'object',
    properties = {
      query = { type = 'string', description = 'Substring or fuzzy query.' },
    },
    required = { 'query' },
  },
  handler = function(args)
    -- workspace/symbol is server-wide; any attached client works.
    local buf = vim.api.nvim_get_current_buf()
    local results, errors = shared.buf_request_sync(buf, 'workspace/symbol', {
      query = args.query,
    }, 2000)
    if #errors > 0 and #results == 0 then return nil, table.concat(errors, '; ') end
    local lines = {}
    for _, r in ipairs(results) do
      for _, sym in ipairs(r) do
        table.insert(lines, shared.format_symbol(sym))
      end
    end
    if #lines == 0 then return shared.text('No matches.') end
    return shared.text(table.concat(lines, '\n'))
  end,
}
