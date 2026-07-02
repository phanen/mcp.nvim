-- Minimal async HTTP POST helper. We shell out to `curl` rather than
-- speak HTTP ourselves, so the opencode server can stay on plaintext
-- localhost and we sidestep TLS / DNS / platform quirks.

local M = {}

---@class mcp.util.http_client.Result
---@field status integer
---@field body string

--- Send a POST request with a JSON body. `on_done(result, err)` fires
--- exactly once when the response arrives or the request fails /
--- times out. The callback runs in the main loop (deferred via
--- vim.schedule), so vim.notify and other UI APIs are safe inside it.
---
--- URL must be of the form `http://host:port/path`. HTTPS is not
--- implemented.
---
---@param url string
---@param body string  serialised JSON
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
    '--max-time',
    tostring(math.max(1, math.ceil(timeout_ms / 1000))),
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
  -- Sentinel `\n%{http_code}` appended after the body lets us recover
  -- the status without parsing curl's `-v` noise.
  table.insert(args, '-w')
  table.insert(args, '\n%{http_code}')
  table.insert(args, url)

  local stdout_parts = {}
  local stderr_text = ''
  local done = false
  local job_id

  local timer = vim.uv.new_timer()

  local function finish(result, err)
    if done then return end
    done = true
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    vim.schedule(function() on_done(result, err) end)
  end

  timer:start(
    timeout_ms,
    0,
    function() finish(nil, 'request timed out after ' .. tostring(timeout_ms) .. 'ms') end
  )

  job_id = vim.fn.jobstart(args, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          stdout_parts[#stdout_parts + 1] = line
        end
      end
    end,
    on_stderr = function(_, data)
      if data then stderr_text = stderr_text .. table.concat(data, '\n') end
    end,
    on_exit = function(_, code)
      if done then return end
      local stdout = table.concat(stdout_parts, '\n')
      local status = stdout:match('(%d+)%s*$')
      if not status then
        finish(
          nil,
          ('curl exited with code %d: %s'):format(
            code or -1,
            stderr_text ~= '' and stderr_text or stdout
          )
        )
        return
      end
      local resp_body = stdout:sub(1, -(2 + #status))
      finish({ status = tonumber(status), body = resp_body }, nil)
    end,
  })

  if job_id <= 0 then
    finish(nil, 'failed to spawn curl (jobstart returned ' .. tostring(job_id) .. ')')
  end
end

return M
