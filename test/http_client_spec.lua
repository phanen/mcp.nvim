-- mcp.tests.http_client_spec
--
-- Unit tests for `mcp.util.http_client.post_json`. The implementation
-- shells out to `curl` via `vim.fn.jobstart`, so we mock the jobstart
-- call and verify the curl argv layout. The real-curl integration is
-- covered by manual `--listen`-and-`curl` round-trips (not in the
-- test suite, because `vim.fn.jobstart`'s `on_exit` does not fire
-- reliably under `--headless` in this environment, which makes the
-- full exit-code / stderr code path hard to assert reliably here).

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

  it('builds the expected curl argv', function()
    local r = exec_lua(function()
      local commands = {}
      vim.fn.jobstart = function(cmd, _opts)
        for _, a in ipairs(cmd) do
          table.insert(commands, a)
        end
        return 1
      end
      local http = require('mcp.util.http_client')
      http.post_json(
        'http://127.0.0.1:4096/mcp?directory=x',
        '{"name":"nvim"}',
        { timeout_ms = 2000 }
      )
      return { commands = commands }
    end)

    -- argv[1] is the binary name; argv[2] is its first flag.
    eq('curl', r.commands[1])
    eq('-sS', r.commands[2])
    -- URL is the last positional argument.
    eq('http://127.0.0.1:4096/mcp?directory=x', r.commands[#r.commands])
    -- The "write out the status code after the body" sentinel
    -- (`-w '\n%{http_code}'`) sits right before the URL.
    eq('\n%{http_code}', r.commands[#r.commands - 1])
    -- The body sits two slots before the URL (we insert `-w` and its
    -- sentinel argument between them).
    eq('{"name":"nvim"}', r.commands[#r.commands - 3])
    -- `-X POST` is somewhere in the middle; just check it's there.
    local found_post = false
    for i, a in ipairs(r.commands) do
      if a == '-X' and r.commands[i + 1] == 'POST' then
        found_post = true
        break
      end
    end
    eq(true, found_post, 'expected -X POST in argv')
  end)

  it('passes custom headers through as additional -H flags', function()
    local r = exec_lua(function()
      local commands = {}
      vim.fn.jobstart = function(cmd, _opts)
        for _, a in ipairs(cmd) do
          table.insert(commands, a)
        end
        return 1
      end
      local http = require('mcp.util.http_client')
      http.post_json(
        'http://127.0.0.1:4096/mcp',
        '{}',
        { timeout_ms = 1000, headers = { ['X-Trace-Id'] = 'abc123' } }
      )
      return { commands = commands }
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
    local r = exec_lua(function()
      local commands = {}
      vim.fn.jobstart = function(cmd, _opts)
        for _, a in ipairs(cmd) do
          table.insert(commands, a)
        end
        return 1
      end
      local http = require('mcp.util.http_client')
      http.post_json('http://127.0.0.1:4096/mcp', '{}', { timeout_ms = 1000 })
      return { commands = commands }
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
