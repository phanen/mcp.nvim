local shared = require('mcp.tools.nvim._shared')

return {
  name = 'nvim_diagnostics',
  description = 'Get Neovim diagnostics (errors, warnings, hints) reported by LSP servers and other diagnostic producers. Without this tool the model cannot see compilation errors or lint warnings in its edit targets. Pass `path` to scope to a single buffer; pass `min_severity` to include less-severe levels. Default `min_severity` is ERROR (only show errors).',
  inputSchema = {
    type = 'object',
    properties = {
      path = {
        type = 'string',
        description = 'Optional absolute file path. If provided, only diagnostics for that buffer are returned.',
      },
      min_severity = {
        type = 'string',
        enum = { 'ERROR', 'WARN', 'INFO', 'HINT' },
        description = 'Minimum severity to include. Default ERROR (only errors).',
        default = 'ERROR',
      },
    },
  },
  handler = function(args, ctx)
    args = args or {}
    if not (vim.diagnostic and vim.diagnostic.severity) then
      local __r = shared.text('vim.diagnostic is not available in this Neovim build.')
      if ctx then ctx:ok(__r) end
      return __r
    end
    local sev = vim.diagnostic.severity
    local name_to_sev = {
      ERROR = sev.ERROR,
      WARN = sev.WARN,
      INFO = sev.INFO,
      HINT = sev.HINT,
    }
    local min_sev_name = args.min_severity or 'ERROR'
    local min_sev_int = name_to_sev[min_sev_name] or sev.ERROR

    local bufnr
    if args.path and args.path ~= '' then
      local ok, b = pcall(shared.ensure_buffer, args.path)
      if not ok then
        if ctx then ctx:err(b) end
        return nil, b
      end
      bufnr = b
    end

    -- vim.diagnostic names the range from the server's perspective:
    -- `min` is the upper bound, `max` is the lower bound. So to include
    -- "ERROR through the user's `min_severity`" we pass
    -- min = user's value, max = ERROR.
    local items
    if bufnr then
      items = vim.diagnostic.get(bufnr, { severity = { min = min_sev_int, max = sev.ERROR } })
    else
      items = vim.diagnostic.get(nil, { severity = { min = min_sev_int, max = sev.ERROR } })
    end

    if not items or #items == 0 then
      local __r = shared.text(string.format('No diagnostics at severity <= %s.', min_sev_name))
      if ctx then ctx:ok(__r) end
      return __r
    end

    table.sort(items, function(a, b)
      if a.bufnr ~= b.bufnr then return a.bufnr < b.bufnr end
      if a.lnum ~= b.lnum then return a.lnum < b.lnum end
      return (a.col or 0) < (b.col or 0)
    end)

    local lines = {
      string.format('%d diagnostic(s) at severity <= %s:', #items, min_sev_name),
    }
    for _, d in ipairs(items) do
      table.insert(lines, shared.format_diagnostic(d))
    end
    local __r = shared.text(table.concat(lines, '\n'))
    if ctx then ctx:ok(__r) end
    return __r
  end,
}
