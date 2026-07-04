local M = {}

---@class mcp.util.http_client.Result
---@field status integer
---@field body string

---@param url string
---@param body string
---@param opts? { timeout_ms?: integer, headers?: table<string, string> }
---@param on_done fun(result: mcp.util.http_client.Result?, err: string?)
function M.post_json(url, body, opts, on_done)
  assert(type(on_done) == 'function', 'post_json: on_done callback is required')

  opts = opts or {}
  local timeout_ms = opts.timeout_ms or 3000
  local extra_headers = opts.headers or {}

  local args = {
    'curl',
    '-sS',
    '-X',
    'POST',
    '-H',
    'Content-Type: application/json',
  }
  for k, v in pairs(extra_headers) do
    table.insert(args, '-H')
    table.insert(args, k .. ': ' .. v)
  end
  table.insert(args, '--data-raw')
  table.insert(args, body)
  -- Trailing sentinel recovers the status without parsing curl -v.
  table.insert(args, '-w')
  table.insert(args, '\n%{http_code}')
  table.insert(args, url)

  local done = false

  local function finish(result, err)
    if done then return end
    done = true
    vim.schedule(function() on_done(result, err) end)
  end

  local function on_exit(completed)
    if done then return end
    if completed.code == 124 then
      finish(nil, 'request timed out after ' .. tostring(timeout_ms) .. 'ms')
      return
    end
    local stdout = completed.stdout or ''
    local status = stdout:match('(%d+)%s*$')
    if not status then
      local stderr = completed.stderr
      finish(
        nil,
        ('curl exited with code %d: %s'):format(
          completed.code or -1,
          (stderr ~= nil and stderr ~= '') and stderr or stdout
        )
      )
      return
    end
    local resp_body = stdout:sub(1, -(2 + #status))
    finish({ status = tonumber(status), body = resp_body }, nil)
  end

  local ok, sysobj_or_err = pcall(vim.system, args, {
    text = true,
    timeout = timeout_ms,
  }, vim.schedule_wrap(on_exit))
  if not ok then finish(nil, 'failed to spawn curl: ' .. tostring(sysobj_or_err)) end
end

return M
