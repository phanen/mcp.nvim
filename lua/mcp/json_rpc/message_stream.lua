-- mcp.json_rpc.message_stream
--
-- Generic framing layer: feed it raw bytes from a transport, get back
-- complete decoded message bodies. The framing rule itself is injected,
-- so the same MessageStream can serve LSP-style Content-Length framing,
-- newline-delimited JSON (MCP stdio), and SSE (MCP Streamable HTTP).
--
-- Ported and adapted from `vim.net.MessageStream` in
-- runtime/lua/vim/net/_transport.lua which is
-- released under Apache-2.0 by the Neovim project. We re-implement it
-- here so mcp.nvim is self-contained and does not depend on Neovim
-- internal modules (`vim._core.stringbuffer`).

---@class mcp.json_rpc.message_stream
---@field private strbuf string[]
---@field private byte_len integer
---@field private decode fun(strbuf: string[]): string?, integer?  # returns body, consume_n
---@field private on_read fun(err: string?, data: string?)
---@field private on_error fun(err: any)
---@field encode fun(msg: string): string
local MessageStream = {}
MessageStream.__index = MessageStream

---@param decode fun(strbuf: string[]): string?, integer?
---@param encode fun(msg: string): string
---@param on_read fun(err: string?, data: string?)
---@param on_error fun(err: any)
---@return mcp.json_rpc.message_stream
function MessageStream.new(decode, encode, on_read, on_error)
  return setmetatable({
    strbuf = {},
    byte_len = 0,
    decode = decode,
    on_read = on_read,
    on_error = on_error,
    encode = encode,
  }, MessageStream)
end

---@param err string?
---@param data string?
function MessageStream:feed(err, data)
  if err then
    self.on_read(err, nil)
    return
  elseif data == nil then
    self.on_read(nil, nil)
    return
  end

  self.strbuf[#self.strbuf + 1] = data
  self.byte_len = self.byte_len + #data

  while true do
    local ok, body, consumed = pcall(self.decode, self.strbuf, self.byte_len)
    if not ok then
      self.on_error(body)
      return
    elseif body == nil then
      break
    end

    -- `consumed` is the number of bytes to drop from the front of the
    -- accumulated buffer. We don't actually splice; we just track the
    -- cumulative skip so future decoders can ignore already-consumed
    -- bytes. This keeps allocation cost low for large streams.
    self:_advance(consumed or #body)
    self.on_read(nil, body)
  end
end

---@private
---@param n integer
function MessageStream:_advance(n)
  if n <= 0 then return end
  local remaining = n
  while remaining > 0 and #self.strbuf > 0 do
    local head = self.strbuf[1]
    if #head <= remaining then
      table.remove(self.strbuf, 1)
      remaining = remaining - #head
    else
      self.strbuf[1] = head:sub(remaining + 1)
      remaining = 0
    end
  end
  self.byte_len = self.byte_len - n
end

---@return string
function MessageStream:drain()
  local s = table.concat(self.strbuf)
  self.strbuf = {}
  self.byte_len = 0
  return s
end

return MessageStream
