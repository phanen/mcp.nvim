local json_rpc = require('mcp.json_rpc')
local DispatchCtx = require('mcp.json_rpc.dispatch_ctx')

local PROTOCOL_VERSION = '2025-03-26'
local SERVER_INFO = {
  name = 'mcp.nvim',
  version = '0.0.1',
}

---@alias mcp.Server.State
---| 'Created'
---| 'Negotiating'
---| 'Ready'
---| 'Closed'

local State = {
  Created = 'Created',
  Negotiating = 'Negotiating',
  Ready = 'Ready',
  Closed = 'Closed',
}

local M = {}

---@class mcp.Dispatcher
---@field on_request fun(method: string, params?: table, ctx?: mcp.json_rpc.DispatchCtx): any?, mcp.json_rpc.Error?
---@field on_notify fun(method: string, params?: table)
---@field on_sse_closed? fun()
---@field notify fun(self: mcp.Dispatcher, method: string, params?: table)
---@field is_closing fun(self: mcp.Dispatcher): boolean

---@class mcp.Server
---@field connection mcp.Dispatcher
---@field registry mcp.ToolRegistry
---@field state mcp.Server.State
---@field client_info table?
---@field client_capabilities table?
---@field instructions string?
---@field default_tool_timeout_ms integer
---@field private _inflight table<integer|string, mcp.Server.Inflight>
local Server = {}
Server.__index = Server

---@param connection mcp.Dispatcher
---@param registry mcp.ToolRegistry
---@param opts? { server_info?: table, instructions?: string, capabilities?: table, default_tool_timeout_ms?: integer }
---@return mcp.Server
function M.new(connection, registry, opts)
  opts = opts or {}
  local self = setmetatable({
    connection = connection,
    registry = registry,
    state = State.Created,
    client_info = nil,
    client_capabilities = nil,
    instructions = opts.instructions,
    default_tool_timeout_ms = opts.default_tool_timeout_ms or DispatchCtx.DEFAULT_TOOL_TIMEOUT_MS,
    _inflight = {},
  }, Server)
  registry:set_connection(connection)
  self:_bind_dispatchers()
  return self
end

function Server:_bind_dispatchers()
  self.connection.on_request = function(method, params, ctx)
    return self:_dispatch(method, params, ctx)
  end
  self.connection.on_notify = function(method, params) self:_on_notify(method, params) end
  self.connection.on_sse_closed = function() self:_reset_for_new_session() end
end

---@param method string
---@param params table?
---@param ctx? mcp.json_rpc.DispatchCtx
---@return any result
---@return table? error
function Server:_dispatch(method, params, ctx)
  if method == 'initialize' then return self:_handle_initialize(params) end
  if method == 'ping' then return {}, nil end

  if self.state ~= State.Ready then
    return nil,
      json_rpc.make_error(-32603, 'Server not initialized: state=' .. tostring(self.state))
  end

  if method == 'tools/list' then return self:_handle_tools_list(params) end
  if method == 'tools/call' then return self:_handle_tools_call(params, ctx) end

  return nil, json_rpc.errors.method_not_found(method)
end

function Server:_reset_for_new_session()
  if self.state == State.Closed then return end
  self.state = State.Created
  self.client_info = nil
  self.client_capabilities = nil
end

---@param method string
---@param params table?
function Server:_on_notify(method, params)
  if method == 'notifications/initialized' then
    if self.state == State.Negotiating then
      self.state = State.Ready
    elseif self.state == State.Ready then
      -- Idempotent re-init notification.
    else
      self.state = State.Closed
    end
  elseif method == 'notifications/cancelled' then
    self:_handle_cancelled(params)
  end
end

---@class mcp.Server.Inflight
---@field def mcp.ToolDef
---@field ctx mcp.json_rpc.DispatchCtx

---@param params table?
function Server:_handle_cancelled(params)
  local id = params and params.requestId
  if id == nil then return end
  local inflight = self._inflight and self._inflight[id]
  if not inflight then return end
  if inflight.def and inflight.def.cancel then
    pcall(inflight.def.cancel, params and params.reason, inflight.ctx)
  end
  self._inflight[id] = nil
end

---@param params table?
---@return table? result
---@return mcp.json_rpc.Error?
function Server:_handle_initialize(params)
  if self.state ~= State.Created then
    return nil, json_rpc.make_error(-32603, 'initialize called in state ' .. tostring(self.state))
  end
  self.state = State.Negotiating
  self.client_info = params and params.clientInfo or nil
  self.client_capabilities = params and params.capabilities or {}

  local capabilities = {
    tools = { listChanged = true },
    logging = {},
  }

  return {
    protocolVersion = PROTOCOL_VERSION,
    capabilities = capabilities,
    serverInfo = SERVER_INFO,
    instructions = self.instructions,
  },
    nil
end

---@param _params table?
---@return table? result
---@return mcp.json_rpc.Error?
function Server:_handle_tools_list(_params)
  local tools = self.registry:list()
  local out = {}
  for _, t in ipairs(tools) do
    local entry = {
      name = t.name,
      description = t.description,
    }
    if t.inputSchema then entry.inputSchema = t.inputSchema end
    if t.annotations then entry.annotations = t.annotations end
    table.insert(out, entry)
  end
  return { tools = out }, nil
end

---@param params table?
---@param ctx? mcp.json_rpc.DispatchCtx
---@return table? result
---@return mcp.json_rpc.Error?
function Server:_handle_tools_call(params, ctx)
  if type(params) ~= 'table' or type(params.name) ~= 'string' then
    return nil, json_rpc.errors.invalid_params('tools/call requires { name, arguments }')
  end
  local def = self.registry:get(params.name)
  if not def then return nil, json_rpc.errors.invalid_params('Unknown tool: ' .. params.name) end

  local args = params.arguments or {}

  if ctx then
    self._inflight[ctx.request_id] = { def = def, ctx = ctx }
    local id = ctx.request_id
    ctx._on_done = function() self._inflight[id] = nil end
    if def.cancel then ctx:set_cancel(def.cancel) end
    if def.timeout_ms == nil then def.timeout_ms = self.default_tool_timeout_ms end
    ctx:start_timeout(def.timeout_ms)
  end

  local ok, content_or_err = pcall(def.handler, args, ctx)
  if not ok then
    -- Per the MCP spec, tool-level errors surface as `isError: true`.
    if ctx and not ctx._done then
      ctx:err(tostring(content_or_err))
      return nil
    end
    return {
      content = { { type = 'text', text = tostring(content_or_err) } },
      isError = true,
    },
      nil
  end

  -- No ctx: caller (older transport) takes the synchronous envelope
  -- and serialises it itself.
  if not ctx then return self:_build_envelope(content_or_err) end
  if ctx._done then return nil end

  -- ctx attached: handler may have finished via ctx:ok / ctx:err above
  -- (the early return handled that). If it synchronously returned a
  -- value, surface it through the ctx so transport sees a single
  -- write. `nil` is ambiguous in async code — handler might be using
  -- the ctx and just hasn't returned yet — so we leave ctx live for
  -- timeout / cancel rather than auto-erroring.
  if content_or_err == nil then return nil end
  if type(content_or_err) == 'table' then
    if content_or_err.content then
      local result = vim.deepcopy(content_or_err)
      if result.isError then
        ctx:err(result.content)
      else
        ctx:ok(result.content)
      end
      return nil
    end
    if content_or_err.type then
      ctx:ok({ content_or_err })
      return nil
    end
    if content_or_err[1] then
      ctx:ok(content_or_err)
      return nil
    end
  end
  ctx:err('Tool handler returned an unrecognised value')
  return nil
end

---@param content_or_err any
---@return table? envelope
---@return mcp.json_rpc.Error?
function Server:_build_envelope(content_or_err)
  local _ = self
  if content_or_err == nil then
    return {
      content = { { type = 'text', text = 'unknown error' } },
      isError = true,
    },
      nil
  end
  if type(content_or_err) == 'table' then
    if content_or_err.content then
      local result = vim.deepcopy(content_or_err)
      if result.isError == nil then result.isError = false end
      return result, nil
    end
    if content_or_err.type then return { content = { content_or_err }, isError = false }, nil end
    if content_or_err[1] then return { content = content_or_err, isError = false }, nil end
  end
  return nil, json_rpc.errors.internal_error('Tool handler returned an unrecognised value')
end

M.State = State
M.PROTOCOL_VERSION = PROTOCOL_VERSION
M.SERVER_INFO = SERVER_INFO

return M
