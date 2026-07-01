-- mcp.tool_registry
--
-- Registry of MCP tools exposed by this server. Tools are described by
-- a JSON Schema `inputSchema` (Lua table) and a `handler` function that
-- takes the validated arguments and returns either a list of content
-- items or `nil, err_message` to surface an execution error with
-- `isError: true` in the tool result.
--
-- The registry also tracks `list_changed` capability and emits the
-- `notifications/tools/list_changed` notification through the
-- supplied Connection whenever the tool set changes.

local M = {}

---@class mcp.ToolDef
---@field name string
---@field description string
---@field inputSchema? table JSON Schema describing arguments
---@field handler fun(args: table): table?, string?  # returns content[], or nil, err
---@field annotations? table

---@class mcp.ToolRegistry
---@field private tools table<string, mcp.ToolDef>
---@field private connection mcp.json_rpc.Connection?
---@field private version integer
local ToolRegistry = {}
ToolRegistry.__index = ToolRegistry

--- Construct an empty registry. Optionally accepts a Connection so
--- that `list_changed` notifications can be dispatched automatically.
---@param connection? mcp.json_rpc.Connection
---@return mcp.ToolRegistry
function M.new(connection)
  return setmetatable({
    tools = {},
    connection = connection,
    version = 0,
  }, ToolRegistry)
end

--- Bind (or rebind) the Connection used to emit list_changed
--- notifications. Pass `nil` to detach.
---@param registry mcp.ToolRegistry
---@param connection? mcp.json_rpc.Connection
function ToolRegistry:set_connection(connection) self.connection = connection end

---@param registry mcp.ToolRegistry
---@param def mcp.ToolDef
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

---@param registry mcp.ToolRegistry
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

---@param registry mcp.ToolRegistry
---@return mcp.ToolDef[]
function ToolRegistry:list()
  local out = {}
  for _, def in pairs(self.tools) do
    table.insert(out, def)
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

---@param registry mcp.ToolRegistry
---@param name string
---@return mcp.ToolDef?
function ToolRegistry:get(name) return self.tools[name] end

---@param registry mcp.ToolRegistry
---@return integer
function ToolRegistry:version() return self.version end

return M
