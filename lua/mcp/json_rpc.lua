local MessageStream = require('mcp.json_rpc.message_stream')
local validate = vim.validate

---@enum mcp.json_rpc.error.Code
local error_code = {
  parse_error = -32700,
  invalid_request = -32600,
  method_not_found = -32601,
  invalid_params = -32602,
  internal_error = -32603,
  -- MCP-spec application-level codes (negative integers below -32000):
  resource_not_found = -32002,
  tool_not_found = -32602, -- alias of invalid_params per spec
}

---@enum mcp.json_rpc.ClientErrors
local client_errors = {
  recv_error = 1,
  send_error = 2,
  on_error = 3,
  missing_result = 4,
  rpc_error = 5,
  user_handler = 6,
  parse_error = 7,
  on_read_error = 8,
  notify_yielded = 9,
  handler_yielded = 10,
}

local M = {}

---@nodoc
---@type table<string,integer> | table<integer,string>
M.client_errors = vim.deepcopy(client_errors)
for k, v in pairs(client_errors) do
  M.client_errors[v] = k
end

---@nodoc
---@type table<string,integer> | table<integer,string>
M.error_code = vim.deepcopy(error_code)
for k, v in pairs(error_code) do
  M.error_code[v] = k
end

---@class mcp.json_rpc.Error
---@field code integer
---@field message string
---@field data? any

---@alias mcp.json_rpc.Request.Id integer | string

---@class mcp.json_rpc.Message
---@field jsonrpc string
---@field id? mcp.json_rpc.Request.Id
---@field method? string
---@field params? table
---@field result? any
---@field error? mcp.json_rpc.Error

---@class mcp.json_rpc.Transport
---@field on_error? fun(kind: string, err: any)
---@field listen fun(self: mcp.json_rpc.Transport, on_read: fun(err: string?, data: string?), on_exit: fun(code: integer, signal: integer))
---@field write fun(self: mcp.json_rpc.Transport, payload: string): boolean
---@field is_closing fun(self: mcp.json_rpc.Transport): boolean
---@field terminate fun(self: mcp.json_rpc.Transport)

---@class mcp.json_rpc.Dispatchers
--- Invoked on notifications received from the other endpoint.
---@field on_notify fun(method: string, params?: table)
--- Invoked on requests received from the other endpoint. Exactly one
--- of result/error MUST be returned.
---@field on_request fun(method: string, params?: table): any?, mcp.json_rpc.Error?
---@field on_exit fun(code: integer, signal: integer)
---@field on_error fun(code: integer, err: any)
local Dispatchers = {}

---@type mcp.json_rpc.Dispatchers
local default_dispatchers = {
  on_request = function(method, _) return nil, M.errors.method_not_found(method) end,
  on_notify = function() end,
  on_exit = function() end,
  on_error = function() end,
}

local function merge_dispatchers(dispatchers)
  if not dispatchers then return default_dispatchers end
  return {
    on_request = dispatchers.on_request or default_dispatchers.on_request,
    on_notify = dispatchers.on_notify or default_dispatchers.on_notify,
    on_exit = dispatchers.on_exit or default_dispatchers.on_exit,
    on_error = dispatchers.on_error or default_dispatchers.on_error,
  }
end

---@class mcp.json_rpc.Connection
---@field private request_count integer
---@field private request_callbacks table<integer, fun(err?: mcp.json_rpc.Error, result: any, request_id: integer)?>
---@field private transport mcp.json_rpc.Transport
---@field private message_stream mcp.json_rpc.message_stream
---@field private dispatchers mcp.json_rpc.Dispatchers
---@field private log vim.Log
---@field public on_request fun(method: string, params?: table): any?, mcp.json_rpc.Error?
---@field public on_notify fun(method: string, params?: table)
---@field public on_exit fun(code: integer, signal: integer)
---@field public on_error fun(code: integer, err: any)
---@field public on_sse_closed? fun()
local Connection = {}
Connection.__index = Connection

---@param transport mcp.json_rpc.Transport
---@param dispatchers mcp.json_rpc.Dispatchers
---@param log vim.Log
---@param decode fun(strbuf: string[], byte_len: integer): string?, integer?
---@param encode fun(msg: string): string
---@return mcp.json_rpc.Connection
function Connection.new(transport, dispatchers, log, decode, encode)
  local self = setmetatable({
    request_count = 0,
    request_callbacks = {},
    transport = transport,
    message_stream = MessageStream.new(
      decode,
      encode,
      function(err, data) self:on_read(err, data) end,
      function(err) self:on_read(err, nil) end
    ),
    dispatchers = dispatchers,
    log = log,
  }, Connection)
  transport:listen(
    function(err, data) self:on_read(err, data) end,
    function(code, signal) self:on_exit(code, signal) end
  )
  return self
end

---@return boolean
function Connection:is_closing() return self.transport:is_closing() end

function Connection:terminate() return self.transport:terminate() end

---@param message mcp.json_rpc.Message
---@return boolean
function Connection:send(message)
  self.log.debug('rpc.send', message)
  local body = vim.json.encode(message)
  local payload = self.message_stream.encode(body)
  return self.transport:write(payload)
end

---@param method string
---@param params? table
---@return boolean
function Connection:notify(method, params)
  return self:send({ jsonrpc = '2.0', method = method, params = params })
end

---@param request_id mcp.json_rpc.Request.Id
---@param err? mcp.json_rpc.Error
---@param result? any
function Connection:respond(request_id, err, result)
  return self:send({ jsonrpc = '2.0', id = request_id, error = err, result = result })
end

---@param method string
---@param params? table
---@param callback fun(err?: mcp.json_rpc.Error, result: any, request_id: integer)
---@return boolean success
---@return integer? request_id
function Connection:request(method, params, callback)
  validate('callback', callback, 'function')
  self.request_count = self.request_count + 1
  local request_id = self.request_count
  self.request_callbacks[request_id] = callback
  local ok = self:send({ jsonrpc = '2.0', id = request_id, method = method, params = params })
  if not ok then
    self.request_callbacks[request_id] = nil
    return false, nil
  end
  return true, request_id
end

---@param errkind mcp.json_rpc.ClientErrors
---@param err any
function Connection:on_error(errkind, err)
  assert(M.client_errors[errkind])
  -- Best-effort: if the dispatcher's on_error itself throws we can't do
  -- much more.
  pcall(self.dispatchers.on_error, errkind, err)
end

---@param message mcp.json_rpc.Message
function Connection:on_receive(message)
  self.log.debug('rpc.receive', message)
  local id = message.id
  local method, params, err, result = message.method, message.params, message.error, message.result
  if type(method) == 'string' and id then
    if type(id) ~= 'number' and type(id) ~= 'string' and id ~= vim.NIL then
      self.log.error(
        'Server request id must be a number or string, got ' .. type(id),
        { id = id, method = method }
      )
      return
    end

    -- Schedule so user code can't synchronously terminate the
    -- transport from inside a request handler.
    vim.schedule(function()
      local r, e = self.dispatchers.on_request(method, params)
      self:respond(id, e, r)
    end)
  elseif id and (err or result) then
    local callback = self.request_callbacks[id]
    if not callback then return end
    self.request_callbacks[id] = nil
    callback(err, result, id)
  elseif method then
    self.dispatchers.on_notify(method, params)
  else
    self:on_error(M.client_errors.missing_result, 'Missing request id and method')
  end
end

function Connection:on_read(err, data)
  if err then
    self:on_error(M.client_errors.recv_error, err)
    return
  end
  if not data then return end
  self.message_stream:feed(nil, data)
end

function Connection:on_exit(code, signal)
  for request_id, callback in pairs(self.request_callbacks) do
    if callback then callback({ code = -1, message = 'Connection terminated' }, nil, request_id) end
  end
  self.request_callbacks = {}
  self.dispatchers.on_exit(code, signal)
end

---@class mcp.json_rpc.Opts
---@field dispatchers mcp.json_rpc.Dispatchers
---@field decode fun(strbuf: string[], byte_len: integer): string?, integer?
---@field encode fun(msg: string): string
---@field log? vim.Log

---@param transport mcp.json_rpc.Transport
---@param opts mcp.json_rpc.Opts
---@return mcp.json_rpc.Connection
function M.wrap(transport, opts)
  validate('opts', opts, 'table')
  validate('opts.dispatchers', opts.dispatchers, 'table')
  validate('opts.decode', opts.decode, 'function')
  validate('opts.encode', opts.encode, 'function')

  local log = opts.log or require('mcp.util.log').log
  local dispatchers = merge_dispatchers(opts.dispatchers)
  return Connection.new(transport, dispatchers, log, opts.decode, opts.encode)
end

---@param code integer
---@param message string
---@param data? any
---@return mcp.json_rpc.Error
function M.make_error(code, message, data)
  validate('code', code, 'number')
  validate('message', message, 'string')
  local err = { code = code, message = message } --- @type mcp.json_rpc.Error
  if data ~= nil then err.data = data end
  return err
end

M.errors = {
  parse_error = function(data) return M.make_error(M.error_code.parse_error, 'Parse error', data) end,
  invalid_request = function(data)
    return M.make_error(M.error_code.invalid_request, 'Invalid request', data)
  end,
  method_not_found = function(method)
    return M.make_error(M.error_code.method_not_found, 'Method not found: ' .. tostring(method))
  end,
  invalid_params = function(data)
    return M.make_error(M.error_code.invalid_params, 'Invalid params', data)
  end,
  internal_error = function(data)
    return M.make_error(M.error_code.internal_error, 'Internal error', data)
  end,
}
M.Dispatchers = Dispatchers
M.Connection = Connection

return M
