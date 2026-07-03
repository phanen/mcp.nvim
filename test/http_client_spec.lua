-- mcp.tests.http_client_spec
--
-- Unit tests for `mcp.util.http_client.post_json`. The implementation
-- shells out to `curl` via `vim.system`, so we mock it and verify the
-- curl argv layout. The real-curl integration is covered by manual
-- `--listen`-and-`curl` round-trips (not in the test suite, because the
-- on_exit path is sensitive to event-loop timing under `--headless`).

local n = require('nvim-test.helpers')

local eq = n.eq
local clear = n.clear
local exec_lua = n.exec_lua

describe('http_client.post_json', function()
  before_each(function()
    clear()
    exec_lua(function()
      package.path = vim.fn.fnamemodify('./lua/?.lua;', ':p')
        .. ';'
        .. vim.fn.fnamemodify('./lua/?/init.lua;', ':p')
        .. ';'
        .. package.path
      package.loaded['mcp.util.http_client'] = nil
    end)
  end)

  local function install_system_mock(commands)
    exec_lua(function()
      vim.system = function(cmd, _opts, on_exit)
        for _, a in ipairs(cmd) do
          -- `commands` table lives in the test runner; we capture the
          -- argv by reaching out via a global, set below.
          _G.__mcp_test_commands[#_G.__mcp_test_commands + 1] = a
        end
        vim.schedule(function() on_exit({ code = 0, signal = 0, stdout = '', stderr = '' }) end)
        return { is_closing = function() return false end }
      end
    end)
    commands = commands or {}
    -- Bridge the host-side table into the child nvim via a global.
    exec_lua(function(t) _G.__mcp_test_commands = t end, commands)
  end

  it('builds the expected curl argv', function()
    install_system_mock()
    local r = exec_lua(function()
      local http = require('mcp.util.http_client')
      http.post_json(
        'http://127.0.0.1:4096/mcp?directory=x',
        '{"name":"nvim"}',
        { timeout_ms = 2000 },
        function() end
      )
      vim.wait(50, function() return true end)
      return { commands = _G.__mcp_test_commands }
    end)

    local commands = r.commands
    eq('curl', commands[1])
    eq('-sS', commands[2])
    eq('http://127.0.0.1:4096/mcp?directory=x', commands[#commands])
    eq('\n%{http_code}', commands[#commands - 1])
    eq('{"name":"nvim"}', commands[#commands - 3])
    local found_post = false
    for i, a in ipairs(commands) do
      if a == '-X' and commands[i + 1] == 'POST' then
        found_post = true
        break
      end
    end
    eq(true, found_post, 'expected -X POST in argv')
  end)

  it('passes custom headers through as additional -H flags', function()
    install_system_mock()
    local r = exec_lua(function()
      local http = require('mcp.util.http_client')
      http.post_json(
        'http://127.0.0.1:4096/mcp',
        '{}',
        { timeout_ms = 1000, headers = { ['X-Trace-Id'] = 'abc123' } },
        function() end
      )
      vim.wait(50, function() return true end)
      return { commands = _G.__mcp_test_commands }
    end)

    local found = false
    for i, a in ipairs(r.commands) do
      if a == '-H' and r.commands[i + 1] == 'X-Trace-Id: abc123' then
        found = true
        break
      end
    end
    eq(true, found, 'expected -H X-Trace-Id: abc123 in argv')
  end)

  it('threads Content-Type: application/json as a default header', function()
    install_system_mock()
    local r = exec_lua(function()
      local http = require('mcp.util.http_client')
      http.post_json('http://127.0.0.1:4096/mcp', '{}', { timeout_ms = 1000 }, function() end)
      vim.wait(50, function() return true end)
      return { commands = _G.__mcp_test_commands }
    end)

    local found = false
    for i, a in ipairs(r.commands) do
      if a == '-H' and r.commands[i + 1] == 'Content-Type: application/json' then
        found = true
        break
      end
    end
    eq(true, found, 'expected -H Content-Type: application/json')
  end)
end)
