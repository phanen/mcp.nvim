---@class mcp.json_rpc.DispatchCtx
---@field request_id integer|string
---@field progress_token? any
---@field tool_name string
---@field _done boolean
---@field _timer userdata?
---@field _on_done? fun()
---@field _transport table
---@field _cancel_fn? fun(reason: string?, ctx: mcp.json_rpc.DispatchCtx)
---@field _timeout_ms? integer
---@field ok fun(self, content: table[])
---@field err fun(self, message: string|table[])
---@field progress fun(self, progress: integer, total?: integer, message?: string)
---@field set_cancel fun(self, cancel_fn?: fun(reason: string?, ctx: mcp.json_rpc.DispatchCtx))
---@field start_timeout fun(self, timeout_ms?: integer)

local DispatchCtx = {}
DispatchCtx.__index = DispatchCtx

local M = {}

M.DEFAULT_TOOL_TIMEOUT_MS = 30000

---@param envelope { content: table[], isError: boolean }
function DispatchCtx:_finish(envelope)
  if self._done then return end
  self._done = true
  if self._timer and not self._timer:is_closing() then
    self._timer:stop()
    self._timer:close()
  end
  if self._on_done then self._on_done() end
  self._transport:write_response(self.request_id, envelope)
end

---@param content table[]
function DispatchCtx:ok(content) self:_finish({ content = content, isError = false }) end

---@param message string|table[]
function DispatchCtx:err(message)
  local content
  if type(message) == 'string' then
    content = { { type = 'text', text = message } }
  else
    content = message
  end
  self:_finish({ content = content, isError = true })
end

---@param progress integer
---@param total? integer
---@param message? string
function DispatchCtx:progress(progress, total, message)
  if self._done or not self.progress_token then return end
  self._transport:send_notification('notifications/progress', {
    progressToken = self.progress_token,
    progress = progress,
    total = total,
    message = message,
  })
end

---@param cancel_fn? fun(reason: string?, ctx: mcp.json_rpc.DispatchCtx)
function DispatchCtx:set_cancel(cancel_fn) self._cancel_fn = cancel_fn end

---@param timeout_ms? integer
function DispatchCtx:start_timeout(timeout_ms)
  if self._timer and not self._timer:is_closing() then return end
  if not timeout_ms or timeout_ms <= 0 then return end
  self._timeout_ms = timeout_ms
  local timer = assert(vim.uv.new_timer())
  self._timer = timer
  ---@type mcp.json_rpc.DispatchCtx
  local ctx = self
  timer:start(
    timeout_ms,
    0,
    vim.schedule_wrap(function()
      if ctx._done then return end
      if ctx._cancel_fn then pcall(ctx._cancel_fn, 'tool timed out', ctx) end
      ctx:err(string.format('tool "%s" timed out after %dms', ctx.tool_name, timeout_ms))
    end)
  )
end

---@param opts {
---  request_id: integer|string,
---  progress_token?: any,
---  tool_name: string,
---  transport: table,
---  cancel_fn?: fun(reason: string?, ctx: mcp.json_rpc.DispatchCtx),
---  timeout_ms?: integer,
---  on_done?: fun(),
---}
---@return mcp.json_rpc.DispatchCtx
function M.make_ctx(opts)
  local ctx = setmetatable({
    request_id = opts.request_id,
    progress_token = opts.progress_token,
    tool_name = opts.tool_name,
    _done = false,
    _timer = nil,
    _on_done = opts.on_done,
    _transport = opts.transport,
    _cancel_fn = opts.cancel_fn,
  }, DispatchCtx)

  if opts.timeout_ms and opts.timeout_ms > 0 then ctx:start_timeout(opts.timeout_ms) end

  return ctx
end

return M
