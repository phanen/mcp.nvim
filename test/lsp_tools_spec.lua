-- mcp.tests.lsp_tools_spec
--
-- Tests for the built-in LSP tool handlers. We mock
-- `vim.lsp.buf_request_sync` rather than starting a real LSP server,
-- because nvim-test runs in a headless environment without any
-- language server infrastructure.
--
-- Each test calls the handler directly (inside the same `exec_lua`
-- sandbox where `vim.lsp` mocks are installed) and asserts on the
-- shape that the tool handler itself returns. The wrapping into the
-- MCP `tools/call` envelope (with `isError`) is exercised by the
-- server_spec tests, not here.

local n = require('nvim-test.helpers')

local eq = n.eq
local clear = n.clear
local exec_lua = n.exec_lua

--- Run `body` (a Lua source string) inside the exec_lua sandbox
--- after installing a `buf_request_sync` mock that returns `payload`.
--- To assert on the captured `params` passed to the LSP request,
--- the body should write them to `_G.__captured` and return them.
local function with_mock_lsp(payload, body)
  return exec_lua([[
    _G.__original_buf_request_sync = vim.lsp.buf_request_sync
    vim.lsp.buf_request_sync = function(_, _, params, _)
      _G.__captured = params
      return { { result = ]] .. (vim.inspect(payload)) .. [[ } }
    end
  ]] .. body)
end

--- Same as above, but the mock returns `nil` to simulate timeout /
--- no-clients. Used for the negative test.
local function with_mock_lsp_nil(body)
  return exec_lua([[
    _G.__original_buf_request_sync = vim.lsp.buf_request_sync
    vim.lsp.buf_request_sync = function(_, _, params, _)
      _G.__captured = params
      return nil
    end
  ]] .. body)
end

describe('lsp tools', function()
  before_each(function()
    clear()
    exec_lua(function()
      package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p')
        .. ';'
        .. vim.fn.fnamemodify('./lua/?/init.lua;', ':p')
        .. ';'
        .. package.path

      -- Scratch file in cwd (nvim-test sandboxing forbids /tmp).
      local f = io.open('lsp_test_fixture.txt', 'w')
      f:write('-- scratch\n')
      f:close()
    end)
  end)

  after_each(function()
    exec_lua(function() os.remove('lsp_test_fixture.txt') end)
  end)

  it('registers all expected tool names', function()
    local names = exec_lua(function()
      local registry = require('mcp.tool_registry').new()
      require('mcp.tools.lsp').register_all(registry, { timeout_ms = 1000 })
      local out = {}
      for _, t in ipairs(registry:list()) do
        table.insert(out, t.name)
      end
      table.sort(out)
      return out
    end)
    eq('lsp_definition', names[1])
    eq('lsp_document_symbols', names[2])
    eq('lsp_hover', names[3])
    eq('lsp_implementation', names[4])
    eq('lsp_references', names[5])
    eq('lsp_rename', names[6])
    eq('lsp_type_definition', names[7])
    eq('lsp_workspace_symbols', names[8])
  end)

  it('lsp_definition formats Location results as file:line:col lines', function()
    local out = with_mock_lsp(
      {
        { uri = 'file://lsp_test_fixture.txt', range = { start = { line = 11, character = 3 } } },
      },
      [[
      local registry = require('mcp.tool_registry').new()
      require('mcp.tools.lsp').register_all(registry)
      return registry:get('lsp_definition').handler({
        path = 'lsp_test_fixture.txt', line = 0, character = 0,
      })
    ]]
    )
    eq(1, #out)
    eq('text', out[1].type)
    eq(true, out[1].text:find('lsp_test_fixture.txt:12:4') ~= nil, out[1].text)
  end)

  it('lsp_definition formats LocationLink results via targetUri/targetRange', function()
    local out = with_mock_lsp(
      {
        {
          targetUri = 'file://lsp_test_fixture.txt',
          targetRange = { start = { line = 20, character = 5 } },
        },
      },
      [[
      local registry = require('mcp.tool_registry').new()
      require('mcp.tools.lsp').register_all(registry)
      return registry:get('lsp_definition').handler({
        path = 'lsp_test_fixture.txt', line = 0, character = 0,
      })
    ]]
    )
    eq(true, out[1].text:find('lsp_test_fixture.txt:21:6') ~= nil, out[1].text)
  end)

  it('lsp_references counts matches and includes the declaration by default', function()
    local out = with_mock_lsp(
      {
        { uri = 'file://lsp_test_fixture.txt', range = { start = { line = 0, character = 0 } } },
        { uri = 'file://lsp_test_fixture.txt', range = { start = { line = 9, character = 2 } } },
      },
      [[
      local registry = require('mcp.tool_registry').new()
      require('mcp.tools.lsp').register_all(registry)
      local res = registry:get('lsp_references').handler({
        path = 'lsp_test_fixture.txt', line = 5, character = 0,
      })
      return { text = res[1].text, captured = _G.__captured }
    ]]
    )
    eq(true, out.captured.context.includeDeclaration)
    eq(true, out.text:find('2 reference') ~= nil, out.text)
    eq(true, out.text:find('lsp_test_fixture.txt:1:1') ~= nil, out.text)
    eq(true, out.text:find('lsp_test_fixture.txt:10:3') ~= nil, out.text)
  end)

  it('lsp_references honours include_declaration=false', function()
    local out = with_mock_lsp(
      {},
      [[
      local registry = require('mcp.tool_registry').new()
      require('mcp.tools.lsp').register_all(registry)
      registry:get('lsp_references').handler({
        path = 'lsp_test_fixture.txt', line = 0, character = 0, include_declaration = false,
      })
      return _G.__captured
    ]]
    )
    eq(false, out.context.includeDeclaration)
  end)

  it('lsp_hover joins multiple content blocks with blank lines', function()
    local out = with_mock_lsp(
      {
        contents = { { value = 'function foo()' }, { language = 'lua', value = 'local foo' } },
      },
      [[
      local registry = require('mcp.tool_registry').new()
      require('mcp.tools.lsp').register_all(registry)
      return registry:get('lsp_hover').handler({
        path = 'lsp_test_fixture.txt', line = 0, character = 0,
      })
    ]]
    )
    eq(true, out[1].text:find('function foo()') ~= nil)
    eq(true, out[1].text:find('local foo') ~= nil)
    eq(true, out[1].text:find('\n\n') ~= nil)
  end)

  it('lsp_document_symbols flattens SymbolInformation entries', function()
    local out = with_mock_lsp(
      {
        {
          name = 'greet',
          kind = 12,
          location = {
            uri = 'file://lsp_test_fixture.txt',
            range = { start = { line = 2, character = 0 } },
          },
        },
      },
      [[
      local registry = require('mcp.tool_registry').new()
      require('mcp.tools.lsp').register_all(registry)
      return registry:get('lsp_document_symbols').handler({
        path = 'lsp_test_fixture.txt',
      })
    ]]
    )
    eq(true, out[1].text:find('Function greet @') ~= nil, out[1].text)
  end)

  it('returns a clean no-result message when the LSP returns an empty list', function()
    local out = with_mock_lsp(
      {},
      [[
      local registry = require('mcp.tool_registry').new()
      require('mcp.tools.lsp').register_all(registry)
      return registry:get('lsp_definition').handler({
        path = 'lsp_test_fixture.txt', line = 0, character = 0,
      })
    ]]
    )
    eq('No definition found.', out[1].text)
  end)

  it('returns isError=true when the LSP request times out', function()
    local out = with_mock_lsp_nil([[
      local registry = require('mcp.tool_registry').new()
      require('mcp.tools.lsp').register_all(registry, { timeout_ms = 10 })
      local r, err = registry:get('lsp_definition').handler({
        path = 'lsp_test_fixture.txt', line = 0, character = 0,
      })
      return { r = r, err = err }
    ]])
    -- nil result, second value is the error string
    eq(nil, out.r)
    eq(true, type(out.err) == 'string' and out.err:find('timed out') ~= nil, tostring(out.err))
  end)

  -- `local foo = 1\nreturn foo\n` so rename edits are observable.
  local function setup_rename_fixture()
    exec_lua(function()
      local f = io.open('lsp_test_fixture.txt', 'w')
      f:write('local foo = 1\n')
      f:write('return foo\n')
      f:close()
    end)
  end

  it('lsp_rename sends newName in the LSP params', function()
    setup_rename_fixture()
    local out = with_mock_lsp(
      { changes = {} },
      [[
        local registry = require('mcp.tool_registry').new()
        require('mcp.tools.lsp').register_all(registry)
        registry:get('lsp_rename').handler({
          path = 'lsp_test_fixture.txt', line = 0, character = 6,
          new_name = 'bar',
        })
        return _G.__captured
      ]]
    )
    eq('bar', out.newName)
    eq(0, out.position.line)
    eq(6, out.position.character)
    eq(true, out.textDocument.uri:find('lsp_test_fixture.txt') ~= nil, out.textDocument.uri)
  end)

  it('lsp_rename applies WorkspaceEdit.changes to the affected buffers', function()
    setup_rename_fixture()
    local out = exec_lua([[
      local f = io.open('lsp_test_fixture.txt', 'w')
      f:write('local foo = 1\n')
      f:write('return foo\n')
      f:close()

      _G.__original_buf_request_sync = vim.lsp.buf_request_sync
      local fixture_uri = 'file://' .. vim.fn.fnamemodify('lsp_test_fixture.txt', ':p')
      vim.lsp.buf_request_sync = function(_, _, params, _)
        _G.__captured = params
        return { { result = {
          changes = {
            [fixture_uri] = {
              { range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 9 } }, newText = 'bar' },
              { range = { start = { line = 1, character = 7 }, ['end'] = { line = 1, character = 10 } }, newText = 'bar' },
            },
          },
        } } }
      end

      local registry = require('mcp.tool_registry').new()
      require('mcp.tools.lsp').register_all(registry)
      local res = registry:get('lsp_rename').handler({
        path = 'lsp_test_fixture.txt', line = 0, character = 7,
        new_name = 'bar',
      })
      local buf = vim.fn.bufadd(vim.fn.fnamemodify('lsp_test_fixture.txt', ':p'))
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      return { res = res, captured = _G.__captured, lines = lines }
    ]])
    eq('local bar = 1', out.lines[1])
    eq('return bar', out.lines[2])
    eq(true, out.res[1].text:find('Renamed to "bar"') ~= nil, out.res[1].text)
    eq(true, out.res[1].text:find('2 edit') ~= nil, out.res[1].text)
    eq(true, out.res[1].text:find('1 file') ~= nil, out.res[1].text)
  end)

  it('lsp_rename applies edits via documentChanges when changes is absent', function()
    setup_rename_fixture()
    local out = exec_lua([[
      local f = io.open('lsp_test_fixture.txt', 'w')
      f:write('local foo = 1\n')
      f:close()

      _G.__original_buf_request_sync = vim.lsp.buf_request_sync
      local fixture_uri = 'file://' .. vim.fn.fnamemodify('lsp_test_fixture.txt', ':p')
      vim.lsp.buf_request_sync = function(_, _, params, _)
        return { { result = {
          documentChanges = {
            {
              textDocument = { uri = fixture_uri, version = 1 },
              edits = {
                { range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 9 } }, newText = 'baz' },
              },
            },
          },
        } } }
      end

      local registry = require('mcp.tool_registry').new()
      require('mcp.tools.lsp').register_all(registry)
      registry:get('lsp_rename').handler({
        path = 'lsp_test_fixture.txt', line = 0, character = 7,
        new_name = 'baz',
      })
      local buf = vim.fn.bufadd(vim.fn.fnamemodify('lsp_test_fixture.txt', ':p'))
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    ]])
    eq('local baz = 1', out[1])
  end)

  it('lsp_rename returns a clean message when the LSP returns no edits', function()
    setup_rename_fixture()
    local out = with_mock_lsp(
      nil,
      [[
        local registry = require('mcp.tool_registry').new()
        require('mcp.tools.lsp').register_all(registry)
        return registry:get('lsp_rename').handler({
          path = 'lsp_test_fixture.txt', line = 0, character = 0,
          new_name = 'bar',
        })
      ]]
    )
    eq(true, out[1].text:find('No rename edits returned') ~= nil, out[1].text)
  end)

  it('lsp_rename applies edits in reverse order so positions stay valid', function()
    setup_rename_fixture()
    -- Two adjacent edits on the same line: document-order application
    -- would shift the second range; reverse-order keeps byte offsets.
    local out = exec_lua([[
      local f = io.open('lsp_test_fixture.txt', 'w')
      f:write('aa bb cc dd\n')
      f:close()

      _G.__original_buf_request_sync = vim.lsp.buf_request_sync
      local fixture_uri = 'file://' .. vim.fn.fnamemodify('lsp_test_fixture.txt', ':p')
      vim.lsp.buf_request_sync = function(_, _, params, _)
        return { { result = {
          changes = {
            [fixture_uri] = {
              -- Replace "bb" with "BBB" at col 3..5
              { range = { start = { line = 0, character = 3 }, ['end'] = { line = 0, character = 5 } }, newText = 'BBB' },
              -- Replace "cc" with "CCC" at col 6..8
              { range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 8 } }, newText = 'CCC' },
            },
          },
        } } }
      end

      local registry = require('mcp.tool_registry').new()
      require('mcp.tools.lsp').register_all(registry)
      registry:get('lsp_rename').handler({
        path = 'lsp_test_fixture.txt', line = 0, character = 0,
        new_name = 'unused',
      })
      local buf = vim.fn.bufadd(vim.fn.fnamemodify('lsp_test_fixture.txt', ':p'))
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    ]])
    eq('aa BBB CCC dd', out[1])
  end)
end)
