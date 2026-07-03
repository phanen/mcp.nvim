-- mcp.tests.nvim_tools_spec
--
-- Tests for the built-in nvim_* tool handlers (diagnostics, quickfix).
-- Unlike the lsp_* tools, these talk directly to vim.* APIs, so we use
-- the real `vim.diagnostic.set` / `vim.fn.setqflist` rather than mocks.
--
-- All scratch files live under `test/.tmp/` (gitignored) and are removed
-- in `after_each` so they don't leak into git status.

local h = require('test.helpers')

local eq = h.eq
local exec_lua = h.exec_lua

local TMPDIR = 'test/.tmp'
local pending_files = {}

--- Plain (non-pattern) substring search. Lua patterns treat `-`, `[`,
--- `]`, `+`, `?`, `^`, `$`, `.` etc. as special, which is a footgun in
--- test assertions like `text:find('a-only')`.
---@param text string
---@param needle string
---@return boolean
local function contains(text, needle) return string.find(text, needle, 1, true) ~= nil end
--- Pre-create scratch files inside `test/.tmp/` (gitignored), then run
--- `body` in the same exec_lua sandbox. Each created path is recorded
--- in `pending_files` for `after_each` cleanup.
local function with_files(files, body)
  local writes = { "os.execute('mkdir -p " .. TMPDIR .. "')" }
  for _, name in ipairs(files) do
    local full = TMPDIR .. '/' .. name
    pending_files[#pending_files + 1] = full
    table.insert(
      writes,
      string.format("local f = io.open(%q, 'w'); f:write('-- scratch\\n'); f:close()", full)
    )
  end
  return h.in_sandbox(table.concat(writes, '\n') .. '\n' .. body)
end

--- Cleanup helper: remove every file we created in this test. Safe to
--- call even when the list is empty. Uses `os.remove` rather than
--- `os.execute` to avoid shell-escaping helpers that only exist inside
--- Neovim (this test runs under busted, not inside a Neovim runtime).
local function cleanup_pending_files()
  if #pending_files == 0 then return end
  for _, path in ipairs(pending_files) do
    pcall(os.remove, path)
  end
  pending_files = {}
end

describe('nvim tools', function()
  before_each(function()
    pending_files = {}
    h.setup()
  end)

  it('registers all expected tool names', function()
    local out = h.in_sandbox([[
      local registry = require('mcp.tool_registry').new()
      registry:register(require('mcp.tools.nvim.diagnostics'))
      registry:register(require('mcp.tools.nvim.quickfix'))
      local names = {}
      for _, t in ipairs(registry:list()) do table.insert(names, t.name) end
      table.sort(names)
      return names
    ]])
    eq('nvim_diagnostics', out[1])
    eq('nvim_quickfix', out[2])
  end)

  it('register_nvim_diagnostics alone registers only that tool', function()
    local out = h.in_sandbox([[
      local registry = require('mcp.tool_registry').new()
      registry:register(require('mcp.tools.nvim.diagnostics'))
      local names = {}
      for _, t in ipairs(registry:list()) do table.insert(names, t.name) end
      return names
    ]])
    eq(1, #out)
    eq('nvim_diagnostics', out[1])
  end)

  it('register_nvim_quickfix alone registers only that tool', function()
    local out = h.in_sandbox([[
      local registry = require('mcp.tool_registry').new()
      registry:register(require('mcp.tools.nvim.quickfix'))
      local names = {}
      for _, t in ipairs(registry:list()) do table.insert(names, t.name) end
      return names
    ]])
    eq(1, #out)
    eq('nvim_quickfix', out[1])
  end)

  describe('nvim_diagnostics', function()
    it('only ERROR severity is returned by default (min_severity = ERROR)', function()
      with_files({ 'nvim_diag_a.txt' }, [[
        local sev = vim.diagnostic.severity
        local buf = vim.fn.bufadd(']] .. TMPDIR .. [[/nvim_diag_a.txt')
        vim.fn.bufload(buf)
        local ns = vim.api.nvim_create_namespace('nvim_tools_spec')
        vim.diagnostic.set(ns, buf, {
          { bufnr = buf, lnum = 1, end_lnum = 1, col = 0, end_col = 0,
            severity = sev.ERROR, message = 'first error' },
          { bufnr = buf, lnum = 2, end_lnum = 2, col = 0, end_col = 0,
            severity = sev.WARN,  message = 'a warning' },
          { bufnr = buf, lnum = 3, end_lnum = 3, col = 0, end_col = 0,
            severity = sev.INFO,  message = 'an info' },
          { bufnr = buf, lnum = 4, end_lnum = 4, col = 0, end_col = 0,
            severity = sev.HINT,  message = 'a hint' },
        })
      ]])
      local out = exec_lua([[
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.diagnostics'))
        return registry:get('nvim_diagnostics').handler({})
      ]])
      local text = out[1].text
      eq(true, contains(text, 'first error'), text)
      eq(true, not contains(text, 'a warning'), text)
      eq(true, not contains(text, 'an info'), text)
      eq(true, not contains(text, 'a hint'), text)
      eq(true, contains(text, '1 diagnostic'), text)
    end)

    it('min_severity = INFO includes ERROR through INFO but excludes HINT', function()
      with_files({ 'nvim_diag_a.txt' }, [[
        local sev = vim.diagnostic.severity
        local buf = vim.fn.bufadd(']] .. TMPDIR .. [[/nvim_diag_a.txt')
        vim.fn.bufload(buf)
        local ns = vim.api.nvim_create_namespace('nvim_tools_spec')
        vim.diagnostic.set(ns, buf, {
          { bufnr = buf, lnum = 1, end_lnum = 1, col = 0, end_col = 0,
            severity = sev.ERROR, message = 'an error' },
          { bufnr = buf, lnum = 2, end_lnum = 2, col = 0, end_col = 0,
            severity = sev.WARN,  message = 'a warning' },
          { bufnr = buf, lnum = 3, end_lnum = 3, col = 0, end_col = 0,
            severity = sev.INFO,  message = 'an info' },
          { bufnr = buf, lnum = 4, end_lnum = 4, col = 0, end_col = 0,
            severity = sev.HINT,  message = 'a hint' },
        })
      ]])
      local out = exec_lua([[
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.diagnostics'))
        return registry:get('nvim_diagnostics').handler({ min_severity = 'INFO' })
      ]])
      local text = out[1].text
      eq(true, contains(text, 'an error'), text)
      eq(true, contains(text, 'a warning'), text)
      eq(true, contains(text, 'an info'), text)
      eq(true, not contains(text, 'a hint'), text)
      eq(true, contains(text, '<= INFO'), text)
      eq(true, contains(text, '3 diagnostic'), text)
    end)

    it('min_severity = HINT includes all severities', function()
      with_files({ 'nvim_diag_a.txt' }, [[
        local sev = vim.diagnostic.severity
        local buf = vim.fn.bufadd(']] .. TMPDIR .. [[/nvim_diag_a.txt')
        vim.fn.bufload(buf)
        local ns = vim.api.nvim_create_namespace('nvim_tools_spec')
        vim.diagnostic.set(ns, buf, {
          { bufnr = buf, lnum = 0, severity = sev.ERROR, message = 'e' },
          { bufnr = buf, lnum = 1, severity = sev.WARN,  message = 'w' },
          { bufnr = buf, lnum = 2, severity = sev.INFO,  message = 'i' },
          { bufnr = buf, lnum = 3, severity = sev.HINT,  message = 'h' },
        })
      ]])
      local out = exec_lua([[
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.diagnostics'))
        return registry:get('nvim_diagnostics').handler({ min_severity = 'HINT' })
      ]])
      local text = out[1].text
      eq(true, contains(text, '4 diagnostic'), text)
      eq(true, contains(text, '<= HINT'), text)
    end)

    it('filters to a single buffer when path is provided', function()
      with_files({ 'nvim_diag_a.txt', 'nvim_diag_b.txt' }, [[
        local sev = vim.diagnostic.severity
        local ns = vim.api.nvim_create_namespace('nvim_tools_spec')
        local ba = vim.fn.bufadd(']] .. TMPDIR .. [[/nvim_diag_a.txt'); vim.fn.bufload(ba)
        local bb = vim.fn.bufadd(']] .. TMPDIR .. [[/nvim_diag_b.txt'); vim.fn.bufload(bb)
        vim.diagnostic.set(ns, ba, {
          { bufnr = ba, lnum = 0, severity = sev.ERROR, message = 'a-only' },
        })
        vim.diagnostic.set(ns, bb, {
          { bufnr = bb, lnum = 0, severity = sev.ERROR, message = 'b-only' },
        })
      ]])
      local out = exec_lua([[
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.diagnostics'))
        return registry:get('nvim_diagnostics').handler({
          path = ']] .. TMPDIR .. [[/nvim_diag_a.txt',
        })
      ]])
      local text = out[1].text
      eq(true, contains(text, 'a-only'), text)
      eq(true, not contains(text, 'b-only'), text)
    end)

    it('returns nil + error when path does not exist on disk', function()
      local out = exec_lua([[
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.diagnostics'))
        local r, err = registry:get('nvim_diagnostics').handler({
          path = ']] .. TMPDIR .. [[/does_not_exist_nvim_diag.txt',
        })
        return { r = r, err = err }
      ]])
      eq(nil, out.r)
      eq(true, type(out.err) == 'string' and contains(out.err, 'File not found'), tostring(out.err))
    end)

    it('returns a clean message when there are no diagnostics', function()
      local out = exec_lua([[
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.diagnostics'))
        return registry:get('nvim_diagnostics').handler({})
      ]])
      eq(true, contains(out[1].text, 'No diagnostics at severity <= ERROR'), out[1].text)
    end)

    it('callers can override default severity via the min_severity argument', function()
      with_files({ 'nvim_diag_a.txt' }, [[
        local sev = vim.diagnostic.severity
        local buf = vim.fn.bufadd(']] .. TMPDIR .. [[/nvim_diag_a.txt')
        vim.fn.bufload(buf)
        local ns = vim.api.nvim_create_namespace('nvim_tools_spec')
        vim.diagnostic.set(ns, buf, {
          { bufnr = buf, lnum = 0, severity = sev.ERROR, message = 'the-error' },
          { bufnr = buf, lnum = 1, severity = sev.WARN,  message = 'the-warn' },
          { bufnr = buf, lnum = 2, severity = sev.INFO,  message = 'the-info' },
          { bufnr = buf, lnum = 3, severity = sev.HINT,  message = 'the-hint' },
        })
      ]])
      local out = exec_lua([[
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.diagnostics'))
        return registry:get('nvim_diagnostics').handler({ min_severity = 'INFO' })
      ]])
      local text = out[1].text
      eq(true, contains(text, 'the-info'), text)
      eq(true, not contains(text, 'the-hint'), text)
      eq(true, contains(text, '<= INFO'), text)
    end)

    it('falls back to ERROR when min_severity is bogus', function()
      with_files({ 'nvim_diag_a.txt' }, [[
        local sev = vim.diagnostic.severity
        local buf = vim.fn.bufadd(']] .. TMPDIR .. [[/nvim_diag_a.txt')
        vim.fn.bufload(buf)
        local ns = vim.api.nvim_create_namespace('nvim_tools_spec')
        vim.diagnostic.set(ns, buf, {
          { bufnr = buf, lnum = 0, severity = sev.ERROR, message = 'e' },
          { bufnr = buf, lnum = 1, severity = sev.WARN,  message = 'w' },
        })
      ]])
      local out = exec_lua([[
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.diagnostics'))
        return registry:get('nvim_diagnostics').handler({
          min_severity = 'NOPE',
        })
      ]])
      local text = out[1].text
      eq(true, contains(text, 'e'), text)
      eq(true, not contains(text, 'w'), text)
    end)

    it('strips newlines from diagnostic messages', function()
      with_files({ 'nvim_diag_a.txt' }, [[
        local sev = vim.diagnostic.severity
        local buf = vim.fn.bufadd(']] .. TMPDIR .. [[/nvim_diag_a.txt')
        vim.fn.bufload(buf)
        local ns = vim.api.nvim_create_namespace('nvim_tools_spec')
        vim.diagnostic.set(ns, buf, {
          { bufnr = buf, lnum = 0, severity = sev.ERROR,
            message = 'line one\nline two\nline three' },
        })
      ]])
      local out = exec_lua([[
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.diagnostics'))
        return registry:get('nvim_diagnostics').handler({})
      ]])
      local text = out[1].text
      eq(true, contains(text, 'line one line two line three'), text)
      eq(true, not contains(text, '\nline'), text)
    end)

    it('formats header as SEVERITY path:line:col', function()
      with_files({ 'nvim_diag_fmt.txt' }, [[
        local sev = vim.diagnostic.severity
        local buf = vim.fn.bufadd(']] .. TMPDIR .. [[/nvim_diag_fmt.txt')
        vim.fn.bufload(buf)
        local ns = vim.api.nvim_create_namespace('nvim_tools_spec')
        vim.diagnostic.set(ns, buf, {
          { bufnr = buf, lnum = 9, end_lnum = 9, col = 4, end_col = 4,
            severity = sev.ERROR, message = 'oops' },
        })
      ]])
      local out = exec_lua([[
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.diagnostics'))
        return registry:get('nvim_diagnostics').handler({
          path = ']] .. TMPDIR .. [[/nvim_diag_fmt.txt',
        })
      ]])
      local text = out[1].text
      eq(
        true,
        contains(text, 'ERROR ') and contains(text, TMPDIR .. '/nvim_diag_fmt.txt:10:5'),
        text
      )
      eq(true, contains(text, ' - oops'), text)
    end)

    it('includes source and code tags when present', function()
      with_files({ 'nvim_diag_a.txt', 'nvim_diag_b.txt', 'nvim_diag_c.txt', 'nvim_diag_d.txt' }, [[
        local sev = vim.diagnostic.severity
        local ns = vim.api.nvim_create_namespace('nvim_tools_spec')
        local function seed(name, msg, src, code)
          local b = vim.fn.bufadd(']] .. TMPDIR .. [[/' .. name); vim.fn.bufload(b)
          local row = { bufnr = b, lnum = 0, severity = sev.ERROR, message = msg }
          if src ~= nil then row.source = src end
          if code ~= nil then row.code = code end
          vim.diagnostic.set(ns, b, { row })
        end
        seed('nvim_diag_a.txt', 'with both',        'lua_ls', 'unused')
        seed('nvim_diag_b.txt', 'with source only', 'lua_ls')
        seed('nvim_diag_c.txt', 'with code only',   nil, 42)
        seed('nvim_diag_d.txt', 'no source no code')
      ]])
      local out = exec_lua([[
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.diagnostics'))
        return registry:get('nvim_diagnostics').handler({
          min_severity = 'HINT',
        })
      ]])
      local text = out[1].text
      eq(true, contains(text, '[lua_ls:unused] - with both'), text)
      eq(true, contains(text, '[lua_ls] - with source only'), text)
      eq(true, contains(text, '[42] - with code only'), text)
      eq(true, contains(text, ' - no source no code'), text)
    end)
  end)

  describe('nvim_quickfix', function()
    it('reports an empty quickfix list cleanly', function()
      local out = exec_lua([[
        vim.fn.setqflist({}, ' ', { title = '', items = {} })
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.quickfix'))
        return registry:get('nvim_quickfix').handler({})
      ]])
      eq(true, contains(out[1].text, 'Quickfix list is empty'), out[1].text)
    end)

    it('includes the title when one is set', function()
      local out = exec_lua([[
        vim.fn.setqflist({}, ' ', { title = 'Grep results', items = {} })
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.quickfix'))
        return registry:get('nvim_quickfix').handler({})
      ]])
      eq(true, contains(out[1].text, '(title: Grep results)'), out[1].text)
    end)

    it('formats entries as numbered path:line:col lines', function()
      local out = exec_lua([[
        vim.fn.setqflist({}, ' ', {
          title = '',
          items = {
            { filename = ']] .. TMPDIR .. [[/foo.txt', lnum = 12, col = 5, text = 'first hit',  type = 'E' },
            { filename = ']] .. TMPDIR .. [[/bar.txt', lnum = 7,  col = 1, text = 'second hit', type = 'W' },
          },
        })
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.quickfix'))
        return registry:get('nvim_quickfix').handler({})
      ]])
      local text = out[1].text
      eq(true, contains(text, '2 entries'), text)
      eq(true, contains(text, 'foo.txt:12:5: E: first hit'), text)
      eq(true, contains(text, 'bar.txt:7:1: W: second hit'), text)
    end)

    it('resolves filename from bufnr when filename is missing', function()
      with_files({ 'nvim_qf_buf.txt' }, [[
        local buf = vim.fn.bufadd(vim.fn.fnamemodify(']] .. TMPDIR .. [[/nvim_qf_buf.txt', ':p'))
        vim.fn.bufload(buf)
        vim.fn.setqflist({}, ' ', {
          title = '',
          items = { { bufnr = buf, lnum = 1, col = 1, text = 'buf hit' } },
        })
      ]])
      local out = exec_lua([[
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.quickfix'))
        return registry:get('nvim_quickfix').handler({})
      ]])
      local text = out[1].text
      eq(true, contains(text, 'nvim_qf_buf.txt:1:1: buf hit'), text)
    end)

    it('falls back to [No Name] when entry has no filename and no bufnr', function()
      local out = exec_lua([[
        vim.fn.setqflist({}, ' ', {
          title = '',
          items = { { lnum = 0, col = 0, text = 'no name' } },
        })
        local registry = require('mcp.tool_registry').new()
        registry:register(require('mcp.tools.nvim.quickfix'))
        return registry:get('nvim_quickfix').handler({})
      ]])
      local text = out[1].text
      eq(true, contains(text, '[No Name]:0:0: no name'), text)
    end)
  end)
end)
