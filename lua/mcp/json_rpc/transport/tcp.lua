local M = {}

---@class mcp.json_rpc.transport.tcp.Server
---@field handle uv.uv_tcp_t
---@field host string
---@field port integer
local Server = {}
Server.__index = Server

---@param host string
---@param port integer
---@return mcp.json_rpc.transport.tcp.Server
function M.bind(host, port)
  local handle = assert(vim.uv.new_tcp())
  handle:bind(host, port)
  return setmetatable({ handle = handle, host = host, port = port }, Server)
end

---@return integer actual_port
function Server:listen()
  local handle = self.handle
  local connections = {}
  handle:listen(128, function(err)
    if err then return end
    local client = assert(vim.uv.new_tcp())
    local ok = pcall(function() handle:accept(client) end)
    if not ok then return end
    -- Keep `client` reachable so the accepted handle stays alive until
    -- the peer closes it; libuv has no other reference once this
    -- callback returns.
    table.insert(connections, client)
  end)
  local sockname = assert(handle:getsockname(), 'uv tcp socket has no bound address')
  return sockname.port
end

M.Server = Server

---@class mcp.json_rpc.transport.tcp.Client
---@field handle uv.uv_tcp_t
---@field private _on_exit fun(code: integer, signal: integer)?
local Client = {}
Client.__index = Client

---@param host string
---@param port integer
---@return mcp.json_rpc.transport.tcp.Client
function M.connect(host, port, on_connect)
  local handle = assert(vim.uv.new_tcp())
  local client = setmetatable({ handle = handle }, Client)
  handle:connect(
    host,
    port,
    vim.schedule_wrap(function(err)
      if err then return end
      if on_connect then on_connect(client) end
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
function Client:is_closing() return self.handle:is_closing() == true end

function Client:terminate()
  if not self.handle:is_closing() then self.handle:close() end
end

return M
