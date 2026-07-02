-- mcp.tools.lsp
--
-- Built-in MCP tools that forward to Neovim's LSP clients. Each tool
-- accepts a file path + (line, character) position and asks the LSP
-- client attached to that buffer for the corresponding LSP method.
-- The tools are designed to be registered into a `mcp.ToolRegistry`
-- via `M.register_all(registry)`; the resulting tool names follow
-- Linw1995/nvim-mcp's naming so existing user conventions carry over.
--
-- The handler returns content shaped as MCP text content. LSP
-- `Location[]`, `SymbolInformation[]`, etc. are serialised to a
-- compact, human-readable form rather than raw JSON: the model that
-- gets to call these tools usually just needs file:line numbers, and
-- a flatter text representation is friendlier to read than opaque
-- nested objects.

local M = {}

--- Convert a file path to a `file://` URI, the canonical form LSP
--- uses for `textDocument/...` parameters.
---@param path string
---@return string
local function path_to_uri(path)
  if path:sub(1, 7) == 'file://' then return path end
  -- vim.uri_from_fname encodes the path; round-trip through
  -- vim.uri_to_fname via URI is fine in practice.
  return 'file://' .. (vim.uri_encode and vim.uri_encode(path) or path:gsub(' ', '%%20'))
end

--- Convert a `file://` URI back to a path. Falls back to the input
--- unchanged when it does not look like a URI.
---@param uri string
---@return string
local function uri_to_path(uri)
  if uri:sub(1, 7) ~= 'file://' then return uri end
  local ok, path = pcall(vim.uri_to_fname, uri)
  if ok and path and path ~= '' then return path end
  return uri:sub(8)
end

--- Format a single LSP `Location` (or `LocationLink`) as a one-line
--- `file:///path:line:col` reference. Defensive against both the old
--- `Location` and the `LocationLink` shapes that some servers return.
---@param loc table
---@return string
local function format_location(loc)
  -- LocationLink: { targetUri, targetRange, ... }
  if loc.targetUri then
    return string.format(
      '%s:%d:%d',
      uri_to_path(loc.targetUri),
      (loc.targetRange.start.line or 0) + 1,
      (loc.targetRange.start.character or 0) + 1
    )
  end
  -- Location: { uri, range }
  local uri = loc.uri or loc.documentUri
  if not uri then return tostring(loc) end
  local r = loc.range
    or { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 0 } }
  return string.format(
    '%s:%d:%d',
    uri_to_path(uri),
    (r.start.line or 0) + 1,
    (r.start.character or 0) + 1
  )
end

--- Format a single LSP `DocumentSymbol` or `SymbolInformation` as a
--- one-line `Kind name @ path:line:col` reference. The `kind` is
--- looked up against `vim.lsp.protocol.SymbolKind`.
---@param sym table
---@return string
local function format_symbol(sym)
  local kind = sym.kind
  local kind_name = 'Symbol'
  if vim.lsp and vim.lsp.protocol and vim.lsp.protocol.SymbolKind then
    kind_name = vim.lsp.protocol.SymbolKind[kind] or kind_name
  end
  local loc = sym.location or sym.range
  if sym.range and not sym.location then loc = { range = sym.range, uri = sym.uri } end
  local pos = loc.range and loc.range.start or { line = 0, character = 0 }
  local path = loc.uri and uri_to_path(loc.uri) or '<unknown>'
  return string.format(
    '%s %s @ %s:%d:%d',
    kind_name,
    sym.name or '?',
    path,
    (pos.line or 0) + 1,
    (pos.character or 0) + 1
  )
end

--- Make sure the file at `path` is loaded into a buffer, so that an
--- LSP client has something to attach to. Returns the buffer handle.
---@param path string
---@return integer bufnr
---@return string? uri
local function ensure_buffer(path)
  -- Absolutize so bufadd is not confused by relative paths.
  local abs = vim.fn.fnamemodify(path, ':p')
  if not vim.uv.fs_stat(abs) then error('File not found: ' .. abs) end
  local buf = vim.fn.bufadd(abs)
  vim.fn.bufload(buf)
  local uri = vim.uri_from_bufnr(buf) or path_to_uri(abs)
  return buf, uri
end

--- Run an LSP request synchronously against the client(s) attached
--- to `bufnr`. Wraps `vim.lsp.buf_request_sync` with a sensible
--- default timeout and returns the merged results, dropping
--- `err`/`error` entries.
---@param bufnr integer
---@param method string
---@param params table
---@param timeout_ms? integer default 2000
---@return table[] results
---@return string[] errors
local function buf_request_sync(bufnr, method, params, timeout_ms)
  timeout_ms = timeout_ms or 2000
  local responses = vim.lsp.buf_request_sync(bufnr, method, params, timeout_ms)
  if not responses then
    return {}, { 'LSP request timed out after ' .. tostring(timeout_ms) .. 'ms' }
  end
  local results = {}
  local errors = {}
  for _, resp in pairs(responses) do
    if resp.err then
      table.insert(errors, tostring(resp.err.message or resp.err))
    elseif resp.result ~= nil then
      table.insert(results, resp.result)
    end
  end
  return results, errors
end

--- Apply TextEdits in reverse start-position order so earlier ranges
--- do not shift under later insertions.
---@param bufnr integer
---@param edits table[]
local function apply_text_edits(bufnr, edits)
  if not edits or #edits == 0 then return end
  local sorted = {}
  for _, e in ipairs(edits) do
    table.insert(sorted, e)
  end
  table.sort(sorted, function(a, b)
    local la, lb = a.range.start.line, b.range.start.line
    if la ~= lb then return la > lb end
    return a.range.start.character > b.range.start.character
  end)
  for _, edit in ipairs(sorted) do
    local s = edit.range.start
    local e = edit.range['end']
    local replacement = edit.newText or ''
    local lines = vim.split(replacement, '\n', { plain = true })
    vim.api.nvim_buf_set_text(bufnr, s.line, s.character, e.line, e.character, lines)
  end
end

--- Apply a WorkspaceEdit, handling both `changes` and `documentChanges`
--- shapes. File-level ops inside `documentChanges` are skipped.
---@param edit table  WorkspaceEdit from the LSP server
---@return string[] paths
---@return table<string, table[]> edits_by_path
local function apply_workspace_edit(edit)
  local edits_by_path = {}
  if edit.changes then
    for uri, edits in pairs(edit.changes) do
      edits_by_path[uri_to_path(uri)] = edits
    end
  end
  if edit.documentChanges then
    for _, change in ipairs(edit.documentChanges) do
      if change.textDocument then
        edits_by_path[uri_to_path(change.textDocument.uri)] = change.edits
      end
    end
  end
  for path, edits in pairs(edits_by_path) do
    local abs = vim.fn.fnamemodify(path, ':p')
    local buf = vim.fn.bufadd(abs)
    vim.fn.bufload(buf)
    apply_text_edits(buf, edits)
  end
  local paths = {}
  for p in pairs(edits_by_path) do
    paths[#paths + 1] = p
  end
  table.sort(paths)
  return paths, edits_by_path
end

--- Text content wrapper. Always returns the shape mcp.server expects
--- from a tool handler.
local function text(content) return { { type = 'text', text = content } } end

---@class mcp.tools.lsp.RegOpts
---@field timeout_ms? integer  default 2000

--- Register the standard set of LSP tools into the given registry.
---@param registry mcp.ToolRegistry
---@param opts? mcp.tools.lsp.RegOpts
function M.register_all(registry, opts)
  opts = opts or {}
  local timeout = opts.timeout_ms or 2000

  -- lsp_definition: resolve the symbol at path/line/column.
  registry:register({
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
      local buf, uri = ensure_buffer(args.path)
      local results, errors = buf_request_sync(buf, 'textDocument/definition', {
        textDocument = { uri = uri },
        position = { line = args.line, character = args.character },
      }, timeout)
      if #errors > 0 and #results == 0 then return nil, table.concat(errors, '; ') end
      local lines = {}
      for _, r in ipairs(results) do
        if type(r) == 'table' then
          for _, loc in ipairs(r) do
            table.insert(lines, format_location(loc))
          end
        end
      end
      if #lines == 0 then return text('No definition found.') end
      return text(table.concat(lines, '\n'))
    end,
  })

  -- lsp_references: list all usages of the symbol at position.
  registry:register({
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
    handler = function(args)
      local buf, uri = ensure_buffer(args.path)
      local results, errors = buf_request_sync(buf, 'textDocument/references', {
        textDocument = { uri = uri },
        position = { line = args.line, character = args.character },
        context = { includeDeclaration = args.include_declaration ~= false },
      }, timeout)
      if #errors > 0 and #results == 0 then return nil, table.concat(errors, '; ') end
      local count = 0
      for _, r in ipairs(results) do
        for _, _ in ipairs(r) do
          count = count + 1
        end
      end
      local lines = { string.format('%d reference(s):', count) }
      for _, r in ipairs(results) do
        for _, loc in ipairs(r) do
          table.insert(lines, format_location(loc))
        end
      end
      return text(table.concat(lines, '\n'))
    end,
  })

  -- lsp_hover: get hover info at position.
  registry:register({
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
    handler = function(args)
      local buf, uri = ensure_buffer(args.path)
      local results, errors = buf_request_sync(buf, 'textDocument/hover', {
        textDocument = { uri = uri },
        position = { line = args.line, character = args.character },
      }, timeout)
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
      if #parts == 0 then return text('No hover information available.') end
      return text(table.concat(parts, '\n\n'))
    end,
  })

  -- lsp_document_symbols: list all symbols in a file.
  registry:register({
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
      local results, errors = buf_request_sync(buf, 'textDocument/documentSymbol', {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
      }, timeout)
      if #errors > 0 and #results == 0 then return nil, table.concat(errors, '; ') end
      local lines = {}
      for _, r in ipairs(results) do
        for _, sym in ipairs(r) do
          table.insert(lines, format_symbol(sym))
        end
      end
      if #lines == 0 then return text('No symbols found.') end
      return text(table.concat(lines, '\n'))
    end,
  })

  -- lsp_workspace_symbols: project-wide symbol search by query.
  registry:register({
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
      -- workspace/symbol is server-wide, so we just need any
      -- attached client; use the buffer of args.path if provided,
      -- else the current buffer.
      local buf = vim.api.nvim_get_current_buf()
      local results, errors = buf_request_sync(buf, 'workspace/symbol', {
        query = args.query,
      }, timeout)
      if #errors > 0 and #results == 0 then return nil, table.concat(errors, '; ') end
      local lines = {}
      for _, r in ipairs(results) do
        for _, sym in ipairs(r) do
          table.insert(lines, format_symbol(sym))
        end
      end
      if #lines == 0 then return text('No matches.') end
      return text(table.concat(lines, '\n'))
    end,
  })

  -- lsp_implementation: find implementations.
  registry:register({
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
    handler = function(args)
      local buf, uri = ensure_buffer(args.path)
      local results, errors = buf_request_sync(buf, 'textDocument/implementation', {
        textDocument = { uri = uri },
        position = { line = args.line, character = args.character },
      }, timeout)
      if #errors > 0 and #results == 0 then return nil, table.concat(errors, '; ') end
      local lines = {}
      for _, r in ipairs(results) do
        for _, loc in ipairs(r) do
          table.insert(lines, format_location(loc))
        end
      end
      if #lines == 0 then return text('No implementations found.') end
      return text(table.concat(lines, '\n'))
    end,
  })

  -- lsp_type_definition: jump to the type definition.
  registry:register({
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
      local buf, uri = ensure_buffer(args.path)
      local results, errors = buf_request_sync(buf, 'textDocument/typeDefinition', {
        textDocument = { uri = uri },
        position = { line = args.line, character = args.character },
      }, timeout)
      if #errors > 0 and #results == 0 then return nil, table.concat(errors, '; ') end
      local lines = {}
      for _, r in ipairs(results) do
        for _, loc in ipairs(r) do
          table.insert(lines, format_location(loc))
        end
      end
      if #lines == 0 then return text('No type definition found.') end
      return text(table.concat(lines, '\n'))
    end,
  })

  -- lsp_rename: rename a symbol across the workspace. Buffers are
  -- left modified but unsaved — matching `vim.lsp.buf.rename`.
  registry:register({
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
      local buf, uri = ensure_buffer(args.path)
      local results, errors = buf_request_sync(buf, 'textDocument/rename', {
        textDocument = { uri = uri },
        position = { line = args.line, character = args.character },
        newName = args.new_name,
      }, timeout)
      if #errors > 0 and #results == 0 then return nil, table.concat(errors, '; ') end

      local edit = nil
      for _, r in ipairs(results) do
        if r ~= nil then
          edit = r
          break
        end
      end

      if not edit or (not edit.changes and not edit.documentChanges) then
        return text('No rename edits returned (symbol may not be renameable at this position).')
      end

      local paths, edits_by_path = apply_workspace_edit(edit)

      local total = 0
      for _, edits in pairs(edits_by_path) do
        total = total + #edits
      end

      local lines = {
        string.format(
          'Renamed to %q (%d edit(s) across %d file(s)):',
          args.new_name,
          total,
          #paths
        ),
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
      return text(table.concat(lines, '\n'))
    end,
  })
end

M._format_location = format_location
M._format_symbol = format_symbol
M._text = text
M._apply_text_edits = apply_text_edits
M._apply_workspace_edit = apply_workspace_edit
return M
