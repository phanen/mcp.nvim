local json_rpc = require('mcp.json_rpc')

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
---@field on_request fun(method: string, params?: table): any?, mcp.json_rpc.Error?
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
local Server = {}
Server.__index = Server

---@param connection mcp.Dispatcher
---@param registry mcp.ToolRegistry
---@param opts? { server_info?: table, instructions?: string, capabilities?: table }
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
  }, Server)
  registry:set_connection(connection)
  self:_bind_dispatchers()
  return self
end

function Server:_bind_dispatchers()
  self.connection.on_request = function(method, params) return self:_dispatch(method, params) end
  self.connection.on_notify = function(method, params) self:_on_notify(method, params) end
  self.connection.on_sse_closed = function() self:_reset_for_new_session() end
end

---@param method string
---@param params table?
---@return any result
---@return table? error
function Server:_dispatch(method, params)
  if method == 'initialize' then return self:_handle_initialize(params) end
  if method == 'ping' then return {}, nil end

  if self.state ~= State.Ready then
    return nil,
      json_rpc.make_error(-32603, 'Server not initialized: state=' .. tostring(self.state))
  end

  if method == 'tools/list' then return self:_handle_tools_list(params) end
  if method == 'tools/call' then return self:_handle_tools_call(params) end

  return nil, json_rpc.errors.method_not_found(method)
end

function Server:_reset_for_new_session()
  if self.state == State.Closed then return end
  self.state = State.Created
  self.client_info = nil
  self.client_capabilities = nil
end

---@param method string
---@param _params table?
function Server:_on_notify(method, _params)
  if method == 'notifications/initialized' then
    if self.state == State.Negotiating then
      self.state = State.Ready
    elseif self.state == State.Ready then
      -- Idempotent re-init notification.
    else
      self.state = State.Closed
    end
  elseif method == 'notifications/cancelled' then
    -- No long-running requests, so cancellation is a no-op.
  end
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
function Server:_handle_tools_call(params)
  if type(params) ~= 'table' or type(params.name) ~= 'string' then
    return nil, json_rpc.errors.invalid_params('tools/call requires { name, arguments }')
  end
  local def = self.registry:get(params.name)
  if not def then return nil, json_rpc.errors.invalid_params('Unknown tool: ' .. params.name) end

  local args = params.arguments or {}
  local ok, content_or_err = pcall(def.handler, args)
  if not ok then
    -- Per the MCP spec, tool-level errors surface as `isError: true`,
    -- not as protocol exceptions.
    return {
      content = { { type = 'text', text = tostring(content_or_err) } },
      isError = true,
    },
      nil
  end

  if content_or_err == nil then
    return {
      content = { { type = 'text', text = tostring(def and 'unknown error' or '') } },
      isError = true,
    },
      nil
  end

  -- Accept single content item, list of content, or full result envelope.
  -- Always emit `isError` on success so the shape matches the spec.
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
