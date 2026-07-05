local shared = require('mcp.tools.lsp._shared')

return {
  name = 'lsp_hover',
  description = 'Get hover information (type signature, documentation) at a position. Returns the hover contents as a Markdown string.',
  inputSchema = {
    type = 'object',
    properties = {
      path = { type = 'string', description = 'Absolute file path.' },
      line = { type = 'integer', minimum = 0 },
      character = { type = 'integer', minimum = 0 },
    },
    required = { 'path', 'line', 'character' },
  },
  timeout_ms = 5000,
  cancel = function(_reason, ctx)
    -- buf_request_all returns a cancel function; stash it on ctx so
    -- this hook can abort the pending LSP request.
    if ctx and ctx._lsp_cancel then ctx._lsp_cancel() end
  end,
  handler = function(args, ctx)
    local buf, uri = shared.ensure_buffer(args.path)
    if ctx then
      local cancel = vim.lsp.buf_request_all(buf, 'textDocument/hover', {
        textDocument = { uri = uri },
        position = { line = args.line, character = args.character },
      }, function(results)
        if ctx._done then return end
        local parts = {}
        for _, r in ipairs(results) do
          local contents = r and r.result and r.result.contents
          if contents then
            if type(contents) == 'string' then
              table.insert(parts, contents)
            elseif type(contents) == 'table' then
              if contents.value then
                table.insert(parts, contents.value)
              elseif contents[1] then
                for _, c in ipairs(contents) do
                  if type(c) == 'string' then
                    table.insert(parts, c)
                  elseif type(c) == 'table' and c.value then
                    table.insert(parts, c.value)
                  end
                end
              end
            end
          end
        end
        if #parts == 0 then
          ctx:err('No hover information available.')
        else
          ctx:ok(shared.text(table.concat(parts, '\n\n')))
        end
      end)
      ctx._lsp_cancel = cancel
      return
    end

    -- Synchronous fallback (no ctx): mimic the old sync contract.
    local results, errors = shared.buf_request_sync(buf, 'textDocument/hover', {
      textDocument = { uri = uri },
      position = { line = args.line, character = args.character },
    }, 2000)
    if #errors > 0 and #results == 0 then return nil, table.concat(errors, '; ') end
    local parts = {}
    for _, r in ipairs(results) do
      local contents = r.contents
      if contents then
        if type(contents) == 'string' then
          table.insert(parts, contents)
        elseif type(contents) == 'table' then
          if contents.value then
            table.insert(parts, contents.value)
          elseif contents[1] then
            for _, c in ipairs(contents) do
              if type(c) == 'string' then
                table.insert(parts, c)
              elseif type(c) == 'table' and c.value then
                table.insert(parts, c.value)
              end
            end
          end
        end
      end
    end
    if #parts == 0 then return shared.text('No hover information available.') end
    return shared.text(table.concat(parts, '\n\n'))
  end,
}
