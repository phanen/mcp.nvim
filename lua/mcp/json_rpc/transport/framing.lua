-- mcp.json_rpc.transport.framing
--
-- Message-framing helpers that the JSON-RPC MessageStream consumes.
-- A decoder returns `body, consumed_bytes` when it has a complete
-- message ready in the accumulated buffer, or `nil` when it needs more
-- bytes. `encode` is the inverse: takes a complete JSON-RPC message
-- string and produces the wire bytes.
--
-- The two framing rules we support today:
--
--   * newline-delimited JSON: messages are separated by a single LF
--     byte. Used by the MCP `stdio` transport (see
--     specs/02-transports.md).
--   * Content-Length: messages are framed with the LSP-style
--     `Content-Length: N\r\n\r\n<json>` header. Used internally for
--     tests and for compatibility with anyone who asks for it.
--
-- Decoders never throw. They return `nil` whenever the buffer is
-- shorter than a complete message; they return the body and the number
-- of bytes to consume otherwise.

local M = {}

--- Find the position of the first LF byte in `strbuf` (across chunk
--- boundaries). Returns the 1-based index of the LF, or nil if absent.
---@param strbuf string[]
---@return integer?
local function find_newline(strbuf)
  local offset = 0
  for _, chunk in ipairs(strbuf) do
    local nl = chunk:find('\n', 1, true)
    if nl then return offset + nl end
    offset = offset + #chunk
  end
  return nil
end

--- Reassemble `strbuf[1..limit_index]` into a single string, dropping
--- trailing `\n` if present.
---@param strbuf string[]
---@param limit_index integer 1-based index of the last byte to keep
---@return string body
local function join_until(strbuf, limit_index)
  local offset = 0
  local pieces = {}
  for _, chunk in ipairs(strbuf) do
    local end_index = math.min(limit_index - offset, #chunk)
    if end_index <= 0 then break end
    table.insert(pieces, chunk:sub(1, end_index))
    offset = offset + end_index
    if offset >= limit_index then break end
  end
  local s = table.concat(pieces)
  -- strip trailing \n; trailing \r\n is also tolerated
  if s:sub(-1) == '\n' then s = s:sub(1, -2) end
  if s:sub(-1) == '\r' then s = s:sub(1, -2) end
  return s
end

--- Newline-delimited JSON framing. Each chunk may contain zero or more
--- complete messages; we always consume one message at a time.
---@param strbuf string[]
---@param byte_len integer
---@return string? body
---@return integer? consumed
function M.newline_decode(strbuf, byte_len)
  local nl = find_newline(strbuf)
  if not nl then return nil end
  return join_until(strbuf, nl), nl
end

--- Newline-delimited JSON encoder. Appends a single LF byte.
---@param msg string
---@return string
function M.newline_encode(msg) return msg .. '\n' end

--- Locate the byte offset where the `Content-Length` header ends
--- (i.e. immediately after `\r\n\r\n`). Returns nil if the header is
--- not yet complete.
---@param strbuf string[]
---@return integer? 1-based byte offset
local function find_content_length_header_end(strbuf)
  -- Stitch the buffer up to the maximum header size we are willing to
  -- scan, then look for the `\r\n\r\n` terminator.
  local scan = table.concat(strbuf):sub(1, 4096)
  local hdr_end = scan:find('\r\n\r\n', 1, true)
  return hdr_end and (hdr_end + 3) or nil
end

--- Parse the `Content-Length: N` value out of the LSP-style header.
---@param strbuf string[]
---@return integer?
local function parse_content_length(strbuf)
  local header = table.concat(strbuf):sub(1, 4096)
  local cl = header:match('[Cc]ontent%-[Ll]ength:%s*(%d+)')
  if not cl then return nil end
  return tonumber(cl)
end

--- Content-Length framing decoder. Compatible with LSP wire format.
---@param strbuf string[]
---@param byte_len integer
---@return string? body
---@return integer? consumed
function M.content_length_decode(strbuf, byte_len)
  local hdr_end = find_content_length_header_end(strbuf)
  if not hdr_end then return nil end
  local cl = parse_content_length(strbuf)
  if not cl then return nil end
  if byte_len < hdr_end + cl then return nil end
  local body = table.concat(strbuf):sub(hdr_end + 1, hdr_end + cl)
  return body, hdr_end + cl
end

--- Content-Length framing encoder.
---@param msg string
---@return string
function M.content_length_encode(msg)
  return string.format('Content-Length: %d\r\n\r\n%s', #msg, msg)
end

return M
