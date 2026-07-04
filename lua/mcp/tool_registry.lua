local M = {}

---@class mcp.ToolDef
---@field name string
---@field description string
---@field inputSchema? table
---@field handler fun(args: table, ctx?: mcp.json_rpc.DispatchCtx): table?, string?  # returns content[], or nil, err
---@field cancel? fun(reason: string?, ctx: mcp.json_rpc.DispatchCtx)
---@field timeout_ms? integer
---@field annotations? table

---@class mcp.ToolRegistry
---@field private tools table<string, mcp.ToolDef>
---@field private connection mcp.Dispatcher?
---@field private version integer
local ToolRegistry = {}
ToolRegistry.__index = ToolRegistry

---@param connection? mcp.Dispatcher
---@return mcp.ToolRegistry
function M.new(connection)
  return setmetatable({
    tools = {},
    connection = connection,
    version = 0,
  }, ToolRegistry)
end

---@param connection? mcp.Dispatcher
function ToolRegistry:set_connection(connection) self.connection = connection end

function ToolRegistry:register(def)
  assert(type(def.name) == 'string' and #def.name > 0, 'tool name must be a non-empty string')
  assert(type(def.description) == 'string', 'tool description must be a string')
  assert(type(def.handler) == 'function', 'tool handler must be a function')

  self.tools[def.name] = def
  self.version = self.version + 1
  if self.connection and not self.connection:is_closing() then
    self.connection:notify('notifications/tools/list_changed')
  end
end

---@param name string
---@return boolean removed
function ToolRegistry:unregister(name)
  if self.tools[name] then
    self.tools[name] = nil
    self.version = self.version + 1
    if self.connection and not self.connection:is_closing() then
      self.connection:notify('notifications/tools/list_changed')
    end
    return true
  end
  return false
end

---@return mcp.ToolDef[]
function ToolRegistry:list()
  local out = {}
  for _, def in pairs(self.tools) do
    table.insert(out, def)
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

---@param name string
---@return mcp.ToolDef?
function ToolRegistry:get(name) return self.tools[name] end

return M
