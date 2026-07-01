-- mcp.json_rpc.transport.tcp
--
-- TCP transport built on `vim.uv.new_tcp()`. Supports both client
-- (`connect`) and server (`listen` + per-connection accept) modes.
-- Each accepted peer is wrapped in a Connection-ready Transport.
--
-- Stream framing is delegated to the caller via the `decode`/`encode`
-- functions on the Connection. The transport itself is byte-oriented.

local M = {}

---@class mcp.json_rpc.transport.tcp.Server
---@field handle uv_tcp_t
---@field host string
---@field port integer
local Server = {}
Server.__index = Server

---@param host string
---@param port integer
---@return mcp.json_rpc.transport.tcp.Server
function M.bind(host, port)
  local handle = vim.uv.new_tcp()
  handle:bind(host, port)
  return setmetatable({ handle = handle, host = host, port = port }, Server)
end

---@return integer actual_port
function Server:listen()
  local handle = self.handle
  local connections = {}
  handle:listen(
    128,
    vim.schedule_wrap(function(err)
      if err then return end
      local client = vim.uv.new_tcp()
      local ok, accept_err = pcall(function() handle:accept(client) end)
      if not ok then return end
      -- Each accepted client is its own Transport. We hand back a
      -- table with the same shape Connection expects.
      table.insert(connections, client)
      local outbound = {}
      local transport = {
        handle = client,
        listen = function(self, on_read, on_exit)
          client:read_start(vim.schedule_wrap(function(read_err, data) on_read(read_err, data) end))
          self._on_exit = on_exit
        end,
        write = function(_, msg)
          if client:is_closing() then return false end
          local ok = pcall(function() client:write(msg) end)
          return ok
        end,
        is_closing = function() return client:is_closing() end,
        terminate = function()
          if not client:is_closing() then client:close() end
        end,
      }
      if Server.on_connection then Server.on_connection(transport) end
    end)
  )
  return handle:getsockname().port
end

M.Server = Server

---@class mcp.json_rpc.transport.tcp.Client
---@field handle uv_tcp_t
local Client = {}
Client.__index = Client

---@param host string
---@param port integer
---@return mcp.json_rpc.transport.tcp.Client
function M.connect(host, port, on_connect)
  local handle = vim.uv.new_tcp()
  local client = setmetatable({ handle = handle }, Client)
  handle:connect(
    host,
    port,
    vim.schedule_wrap(function(err)
      if err then
        if on_connect then on_connect(err, nil) end
        return
      end
      if on_connect then on_connect(nil, client) end
    end)
  )
  return client
end

---@param on_read fun(err: string?, data: string?)
---@param on_exit fun(code: integer, signal: integer)
function Client:listen(on_read, on_exit)
  self.handle:read_start(vim.schedule_wrap(function(err, data) on_read(err, data) end))
  self._on_exit = on_exit
end

---@param msg string
---@return boolean
function Client:write(msg)
  if self.handle:is_closing() then return false end
  local ok = pcall(function() self.handle:write(msg) end)
  return ok
end

---@return boolean
function Client:is_closing() return self.handle:is_closing() end

function Client:terminate()
  if not self.handle:is_closing() then self.handle:close() end
end

return M
