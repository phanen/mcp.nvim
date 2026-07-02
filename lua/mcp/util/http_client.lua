-- mcp.util.http_client
--
-- Minimal blocking HTTP POST helper used by the opencode registration
-- path. We deliberately do not pull in plenary.curl, the MCP SDK, or
-- any other HTTP library: a single POST with a JSON body is all we
-- need, and shelling out to `curl` keeps the implementation tiny,
-- reliable, and free of event-loop reentrancy pitfalls.
--
-- Why curl-as-a-subprocess instead of raw libuv TCP?
-- ----------------------------------------------
-- The earlier version spoke HTTP directly via `vim.uv.new_tcp()`. It
-- worked in isolation, but when called from inside a `vim.schedule`
-- callback (which is exactly where `mcp.attach_opencode` ends up
-- running: opencode.nvim fires `custom.server_ready` from inside its
-- own `vim.schedule_wrap` deferred-callback path), the request
-- would time out at 3000ms even though the same call from the top
-- level completes in milliseconds. We never fully isolated the
-- trigger, but the symptom is consistent with `vim.wait` inside a
-- `vim.schedule` callback not seeing libuv completion events from a
-- freshly-spawned TCP handle.
--
-- Using `vim.fn.jobstart` + the on-disk `curl` binary sidesteps the
-- question entirely: the child process runs in its own kernel
-- context, never shares the lua VM's libuv loop, and the job's exit
-- event is delivered through the normal job-control channel that
-- nvim already pumps regardless of where we called it from. Same
-- approach plenary.nvim's `plenary.curl` uses, which is why
-- opencode.nvim's own HTTP calls keep working in the same env.
--
-- Scope: this client only does POST with a JSON body, a fixed
-- timeout, and no TLS / redirects / retries. The opencode server we
-- target is on localhost over a plain HTTP connection.

local M = {}

---@class mcp.util.http_client.Result
---@field status integer
---@field body string

--- Send a POST request with a JSON body to the given URL, blocking
--- until the response is received or the timeout fires. Returns
--- `result, err`. `result.status` is the HTTP status code; `result.body`
--- is the raw response body.
---
--- The URL must be of the form `http://host:port/path`. HTTPS is not
--- implemented (the opencode server we target is plaintext localhost).
---
---@param url string
---@param body string  serialised JSON
---@param opts? { timeout_ms?: integer, headers?: table<string, string> }
---@return mcp.util.http_client.Result
---@return string? err
function M.post_json(url, body, opts)
  opts = opts or {}
  local timeout_ms = opts.timeout_ms or 3000
  local extra_headers = opts.headers or {}

  -- We use `--max-time` in seconds (curl's coarse-grained deadline)
  -- plus `vim.wait` for the fine-grained ms-level cap. `--max-time`
  -- is the hard kill switch; vim.wait is what surfaces the timeout
  -- to our caller promptly without waiting the full second.
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
  -- Append a sentinel line with just the HTTP status code so we
  -- can recover it from stdout without parsing curl's -v noise.
  table.insert(args, '-w')
  table.insert(args, '\n%{http_code}')
  table.insert(args, url)

  local done = false
  local stdout_parts = {}
  local stderr_text = ''
  local job_exit_code
  local timed_out = false

  local job_id = vim.fn.jobstart(args, {
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
      job_exit_code = code
      done = true
    end,
  })

  if job_id <= 0 then
    return nil, 'failed to spawn curl (jobstart returned ' .. tostring(job_id) .. ')'
  end

  -- vim.wait pumps the libuv loop including job-control events. The
  -- callback's `done` flag is set by `on_exit`, which fires from
  -- nvim's normal job-pump path regardless of whether we entered
  -- vim.wait from the top level or from a vim.schedule callback.
  vim.wait(timeout_ms, function() return done end)

  if not done then
    timed_out = true
    pcall(vim.fn.jobstop, job_id)
  end

  if timed_out then return nil, 'request timed out after ' .. tostring(timeout_ms) .. 'ms' end

  local stdout = table.concat(stdout_parts, '\n')
  local code = stdout:match('(%d+)%s*$')
  if not code then
    -- curl didn't even produce a status (e.g. couldn't resolve host).
    -- Surface stderr to help the user debug.
    return nil,
      ('curl exited with code %d: %s'):format(
        job_exit_code or -1,
        stderr_text ~= '' and stderr_text or stdout
      )
  end

  -- Strip the trailing "\n<code>" sentinel and any leading newline.
  local body = stdout:sub(1, -(2 + #code))
  return { status = tonumber(code), body = body }, nil
end

return M
