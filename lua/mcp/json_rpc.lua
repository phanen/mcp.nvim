-- mcp.json_rpc
--
-- Generic JSON-RPC 2.0 peer (client + server role in one Connection).
-- Heavily adapted from runtime/lua/vim/json/rpc.lua
-- which is released under Apache-2.0 by the Neovim project.
--
-- What we changed vs upstream:
--   1. Removed `vim.lsp.log` dependency. We bring our own `M.log` with
--      the same `info` / `debug` / `warn` / `error` surface.
--   2. Decoupled `MessageStream` from `vim._core.stringbuffer`; see
--      `./message_stream.lua`.
--   3. Dropped the `vim.lsp.protocol.Method.*` type narrowing on
--      dispatchers. MCP uses arbitrary strings, not an enum.
--   4. Added server-side dispatch in `Connection:on_receive` (the upstream
--      module already had this; we kept it and rely on it).
--   5. Exposed `error.code` for callers who want to build protocol-level
--      errors without hand-rolling tables.

local MessageStream = require('mcp.json_rpc.message_stream')
local validate = vim.validate

--- The standard JSON-RPC 2.0 reserved error codes, plus a couple of MCP
--- server-specific extensions for tool-not-found and resource-not-found.
---@enum mcp.json_rpc.error.Code
local error_code = {
  lower_bound = -32768,
  upper_bound = -32000,
  parse_error = -32700,
  invalid_request = -32600,
  method_not_found = -32601,
  invalid_params = -32602,
  internal_error = -32603,
  -- MCP-spec application-level codes (negative integers below -32000):
  resource_not_found = -32002,
  tool_not_found = -32602, -- alias of invalid_params per spec
}

--- Diagnostic codes used by the Connection to report protocol-level
--- problems to the dispatcher's `on_error`. They are not JSON-RPC errors;
--- they are book-keeping for the connection itself.
---@enum mcp.json_rpc.ClientErrors
local client_errors = {
  INVALID_SERVER_MESSAGE = 1,
  INVALID_SERVER_JSON = 2,
  NO_RESULT_CALLBACK_FOUND = 3,
  READ_ERROR = 4,
  NOTIFICATION_HANDLER_ERROR = 5,
  SERVER_REQUEST_HANDLER_ERROR = 6,
  SERVER_RESULT_CALLBACK_ERROR = 7,
}

local M = {}

---@nodoc
---@type table<string,integer> | table<integer,string>
M.client_errors = vim.deepcopy(client_errors)
for k, v in pairs(client_errors) do
  M.client_errors[v] = k
end

---@nodoc
---@type table<string,integer>
M.error_code = vim.deepcopy(error_code)
for k, v in pairs(error_code) do
  M.error_code[v] = k
end

--- Minimal logger. Real callers can pass a richer logger via opts.log.
--- Default is silent unless MCP_DEBUG is set in the environment.
---@class mcp.json_rpc.log
---@field info fun(self, msg: string, ctx?: table)
---@field debug fun(self, msg: string, ctx?: table)
---@field warn fun(self, msg: string, ctx?: table)
---@field error fun(self, msg: string, ctx?: table)
local default_log = {}
default_log.__index = default_log
function default_log:info() end
function default_log:debug() end
function default_log:warn() end
function default_log:error() end

local function make_log()
  local enabled = vim.env.MCP_DEBUG and vim.env.MCP_DEBUG ~= ''
  if not enabled then return setmetatable({}, default_log) end
  return {
    info = function(_, msg, ctx)
      vim.notify('[mcp] ' .. msg .. (ctx and vim.inspect(ctx) or ''), vim.log.levels.INFO)
    end,
    debug = function(_, msg, ctx)
      vim.notify('[mcp] ' .. msg .. (ctx and vim.inspect(ctx) or ''), vim.log.levels.DEBUG)
    end,
    warn = function(_, msg, ctx)
      vim.notify('[mcp] ' .. msg .. (ctx and vim.inspect(ctx) or ''), vim.log.levels.WARN)
    end,
    error = function(_, msg, ctx)
      vim.notify('[mcp] ' .. msg .. (ctx and vim.inspect(ctx) or ''), vim.log.levels.ERROR)
    end,
  }
end

--- Dispatchers for incoming JSON-RPC messages.
---
---@class mcp.json_rpc.Dispatchers
---
--- Invoked on notifications received from the other endpoint.
--- - Parameters:
---   - {method}: (`string`) The invoked JSON-RPC method
---   - {params}: (`table?`) Parameters for the invoked method
---@field on_notify fun(method: string, params?: table)
---
--- Invoked on requests received from the other endpoint.
--- - Parameters:
---   - {method}: (`string`) The invoked JSON-RPC method
---   - {params}: (`table?`) Parameters for the invoked method
--- - Return (multiple):
---   - {result}: (`any?`) On success, the value to send back.
---   - {err}: (`mcp.json_rpc.Error?`) On error, the protocol-level error.
---
--- Exactly one of result/error MUST be returned. Returning both or
--- neither is treated as an internal error and reported via on_error.
---@field on_request fun(method: string, params?: table): any?, mcp.json_rpc.Error?
---
--- Invoked when the connection exits.
---@field on_exit fun(code: integer, signal: integer)
---
--- Invoked when the connection errors.
---@field on_error fun(code: integer, err: any)
local Dispatchers = {}

--- Default dispatchers used when the caller omits one. They are no-ops:
--- incoming requests receive a `method_not_found` error, incoming
--- notifications are dropped silently. Callers are expected to provide
--- their own.
---@type mcp.json_rpc.Dispatchers
local default_dispatchers = {
  on_notify = function() end,
  on_request = function(method) return nil, M.errors.method_not_found(method) end,
  on_exit = function() end,
  on_error = function(code, err)
    if vim.env.MCP_DEBUG then
      vim.notify(
        string.format('[mcp] connection error %d: %s', code, vim.inspect(err)),
        vim.log.levels.ERROR
      )
    end
  end,
}

--- Build a dispatchers table by overlaying user-provided dispatchers on
--- the defaults. Required because Lua does not let us deep-merge tables
--- in a single expression.
---@param dispatchers mcp.json_rpc.Dispatchers?
---@return mcp.json_rpc.Dispatchers
local function merge_dispatchers(dispatchers)
  if not dispatchers then return default_dispatchers end
  for name, fn in pairs(dispatchers) do
    if type(fn) ~= 'function' then
      error(string.format('dispatchers.%s must be a function', name))
    end
  end
  return {
    on_notify = dispatchers.on_notify or default_dispatchers.on_notify,
    on_request = dispatchers.on_request or default_dispatchers.on_request,
    on_exit = dispatchers.on_exit or default_dispatchers.on_exit,
    on_error = dispatchers.on_error or default_dispatchers.on_error,
  }
end

--- Represents one side of a JSON-RPC connection. The peer can both
--- initiate requests (via `:request`) and respond to requests from the
--- other endpoint (via dispatchers.on_request). This makes a single
--- Connection suitable for both client and server roles.
---
--- The connection does not own the transport; it drives it through the
--- `Transport` interface (see `./transport.lua`).
---
---@class mcp.json_rpc.Connection
---@field private request_count integer
---@field private request_callbacks table<integer, fun(err?: mcp.json_rpc.Error, result: any, request_id: integer)?>
---@field private transport mcp.json_rpc.Transport
---@field private message_stream mcp.json_rpc.message_stream
---@field private dispatchers mcp.json_rpc.Dispatchers
---@field private log mcp.json_rpc.log
local Connection = {}
Connection.__index = Connection

---@param transport mcp.json_rpc.Transport
---@param dispatchers mcp.json_rpc.Dispatchers
---@param log mcp.json_rpc.log
---@param decode fun(strbuf: string[], byte_len: integer): string?, integer?
---@param encode fun(msg: string): string
---@return mcp.json_rpc.Connection
function Connection.new(transport, dispatchers, log, decode, encode)
  local self = setmetatable({
    request_count = 0,
    request_callbacks = {},
    transport = transport,
    dispatchers = dispatchers,
    log = log,
  }, Connection)

  local message_stream = MessageStream.new(decode, encode, function(err, data)
    if err then
      self:on_error(client_errors.READ_ERROR, err)
    elseif data then
      local ok, message = pcall(vim.json.decode, data)
      if not ok then
        self:on_error(client_errors.INVALID_SERVER_JSON, message)
        return
      elseif type(message) ~= 'table' then
        self:on_error(client_errors.INVALID_SERVER_MESSAGE, message)
        return
      end
      self:on_receive(message)
    else
      self:terminate()
    end
  end, function(err)
    self:on_error(client_errors.INVALID_SERVER_MESSAGE, err)
    self:terminate()
  end)
  self.message_stream = message_stream

  transport:listen(function(err, data) message_stream:feed(err, data) end, dispatchers.on_exit)

  return self
end

---@return boolean
function Connection:is_closing() return self.transport:is_closing() end

function Connection:terminate() return self.transport:terminate() end

--- Encode a Lua object to JSON and send it across the transport.
---@param message mcp.json_rpc.Message
---@return boolean
function Connection:send(message)
  self.log.debug('rpc.send', message)
  if self.transport:is_closing() then return false end

  local json = vim.json.encode(message)
  self.transport:write(self.message_stream.encode(json))
  return true
end

--- Sends a notification to the other endpoint.
---@param method string
---@param params? table
---@return boolean
function Connection:notify(method, params)
  return self:send({
    jsonrpc = '2.0',
    method = method,
    params = params,
  })
end

--- Sends a response to an incoming request.
---@param request_id mcp.json_rpc.Request.Id
---@param err? mcp.json_rpc.Error
---@param result? any
function Connection:respond(request_id, err, result)
  return self:send({
    id = request_id,
    jsonrpc = '2.0',
    error = err,
    result = result,
  })
end

--- Sends a request to the other endpoint and runs `callback` upon response.
---@param method string
---@param params? table
---@param callback fun(err?: mcp.json_rpc.Error, result: any, request_id: integer)
---@return boolean success
---@return integer? request_id
function Connection:request(method, params, callback)
  validate('callback', callback, 'function')
  self.request_count = self.request_count + 1
  local request_id = self.request_count
  local result = self:send({
    id = request_id,
    jsonrpc = '2.0',
    method = method,
    params = params,
  })

  if not result then return false end

  self.request_callbacks[request_id] = vim.schedule_wrap(callback)
  return result, request_id
end

---@param errkind mcp.json_rpc.ClientErrors
---@param err any
function Connection:on_error(errkind, err)
  assert(M.client_errors[errkind])
  -- TODO what to do if pcall fails? The dispatcher's on_error is
  -- best-effort; if it throws we cannot do much more.
  pcall(self.dispatchers.on_error, errkind, err)
end

---@param message mcp.json_rpc.Message
function Connection:on_receive(message)
  self.log.debug('rpc.receive', message)

  if type(message.method) == 'string' and message.id then
    -- Received a request.
    if type(message.id) ~= 'number' and type(message.id) ~= 'string' and message.id ~= vim.NIL then
      self.log.error(
        'Server request id must be a number or string, got ' .. type(message.id),
        message.method,
        message.id
      )
      self:on_error(client_errors.INVALID_SERVER_MESSAGE, message)
      return
    end

    -- Schedule here so user functions can't synchronously terminate the
    -- transport out from under us and still expect a response.
    vim.schedule(coroutine.wrap(function()
      xpcall(function()
        local result, err = self.dispatchers.on_request(message.method, message.params)
        self.log.debug('remote_request: callback result', { result = result, err = err })
        if result == nil and err == nil then
          error(
            string.format(
              'method %q: either a result or an error must be sent to the server in response',
              message.method
            )
          )
        end
        if err then
          validate('result', result, 'nil')
          validate('err', err, 'table')
          validate('err.code', err.code, 'number')
          validate('err.message', err.message, 'string')
          assert(
            error_code.lower_bound <= err.code and err.code <= error_code.upper_bound,
            string.format(
              'method %q: error code %d is reserved by the JSON-RPC specification for pre-defined errors',
              message.method,
              err.code
            )
          )
        end
        self:respond(message.id, err, result)
      end, function(err)
        self:on_error(client_errors.SERVER_REQUEST_HANDLER_ERROR, err)
        self:respond(message.id, { code = error_code.internal_error, message = err }, nil)
      end)
    end))
  elseif message.id then
    -- Received a response to a request we sent.
    if message.id == vim.NIL then
      self.log.warn('Server sent response with null id', message)
      self:on_error(client_errors.INVALID_SERVER_MESSAGE, message)
      return
    end
    if (message.error == nil or message.error == vim.NIL) and message.result == nil then
      self.log.error('Server respond empty result and error', message)
      self:on_error(client_errors.INVALID_SERVER_MESSAGE, message)
      return
    end

    local result_id = vim._assert_integer(message.id)
    local callback = assert(self.request_callbacks[result_id])
    self.request_callbacks[result_id] = nil

    xpcall(
      function()
        callback(message.error, message.result ~= vim.NIL and message.result or nil, result_id)
      end,
      function(err) self:on_error(client_errors.SERVER_RESULT_CALLBACK_ERROR, err) end
    )
  elseif type(message.method) == 'string' then
    -- Received a notification.
    xpcall(
      function()
        assert(
          self.dispatchers.on_notify(message.method, message.params) == nil,
          'notification handlers should not return a value'
        )
      end,
      function(err) self:on_error(client_errors.NOTIFICATION_HANDLER_ERROR, err) end
    )
  else
    -- Invalid server message
    self:on_error(client_errors.INVALID_SERVER_MESSAGE, message)
  end
end

---@class mcp.json_rpc.Opts
---@field dispatchers mcp.json_rpc.Dispatchers
---@field decode fun(strbuf: string[], byte_len: integer): string?, integer?
---@field encode fun(msg: string): string
---@field log? mcp.json_rpc.log

--- Wrap a transport so it is usable as a JSON-RPC client.
---
---@param transport mcp.json_rpc.Transport
---@param opts mcp.json_rpc.Opts
---@return mcp.json_rpc.Connection
function M.wrap(transport, opts)
  validate('opts', opts, 'table')
  validate('opts.dispatchers', opts.dispatchers, 'table')
  validate('opts.decode', opts.decode, 'function')
  validate('opts.encode', opts.encode, 'function')

  local log = opts.log or make_log()
  local dispatchers = merge_dispatchers(opts.dispatchers)
  return Connection.new(transport, dispatchers, log, opts.decode, opts.encode)
end
--- Build a JSON-RPC error object with the given code and message.
---@param code integer
---@param message string
---@param data? any
---@return mcp.json_rpc.Error
function M.make_error(code, message, data)
  validate('code', code, 'number')
  validate('message', message, 'string')
  local err = { code = code, message = message }
  if data ~= nil then err.data = data end
  return err
end

--- Pre-built error objects for common cases.
M.errors = {
  parse_error = function(message)
    return M.make_error(error_code.parse_error, message or 'Parse error')
  end,
  invalid_request = function(message)
    return M.make_error(error_code.invalid_request, message or 'Invalid Request')
  end,
  method_not_found = function(method)
    return M.make_error(error_code.method_not_found, 'Method not found: ' .. tostring(method))
  end,
  invalid_params = function(message, data)
    return M.make_error(error_code.invalid_params, message or 'Invalid params', data)
  end,
  internal_error = function(message, data)
    return M.make_error(error_code.internal_error, message or 'Internal error', data)
  end,
}
M.Dispatchers = Dispatchers
M.Connection = Connection

return M
