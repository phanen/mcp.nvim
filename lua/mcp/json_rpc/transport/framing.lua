-- mcp.json_rpc.transport.framing
--
-- Message-framing helpers that the JSON-RPC MessageStream consumes.
-- A decoder returns `body, consumed_bytes` when it has a complete
-- message ready in the accumulated buffer, or `nil` when it needs more
-- bytes. `encode` is the inverse: takes a complete JSON-RPC message
-- string and produces the wire bytes.
--
-- The three framing rules we support today:
--
--   * newline-delimited JSON: messages are separated by a single LF
--     byte. Used by the MCP `stdio` transport (see
--     specs/02-transports.md).
--   * Content-Length: messages are framed with the LSP-style
--     `Content-Length: N\r\n\r\n<json>` header. Used internally for
--     tests and for compatibility with anyone who asks for it.
--   * Server-Sent Events: messages are framed as
--     `id: <id>\ndata: <json>\n\n` events, separated by blank lines.
--     Used by the MCP Streamable HTTP transport when the server opens
--     a `text/event-stream` response to GET (server-to-client push)
--     and optionally to POST with JSON-RPC requests.
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

--- SSE encoder. Formats a single SSE event with the given `event_id`
--- (optional) and `data` payload. The payload may span multiple lines;
--- each line is prefixed with `data: ` per the SSE specification. The
--- event is terminated with a blank line (`\n\n`).
---
--- Used by the HTTP transport when it writes JSON-RPC notifications
--- to a `text/event-stream` response.
---@param event_id integer|string|nil
---@param data string
---@return string
function M.sse_encode(event_id, data)
  local parts = {}
  if event_id ~= nil then parts[#parts + 1] = 'id: ' .. tostring(event_id) end
  -- Prefix every line of `data` with "data: ". SSE requires that each
  -- line of multi-line data be its own "data:" field; we insert the
  -- prefix after every newline and once at the start so single-line
  -- payloads get the prefix exactly once.
  local prefixed = tostring(data):gsub('\r?\n', '\ndata: ')
  parts[#parts + 1] = 'data: ' .. prefixed
  return table.concat(parts, '\n') .. '\n\n'
end

--- SSE decoder. Scans `strbuf` for the first complete SSE event
--- (terminated by `\n\n` or `\r\n\r\n`). Returns the concatenated
--- `data:` payload, or `''` for events without a data field
--- (heartbeats / comments), plus the number of bytes consumed from
--- the front of the buffer. Returns `nil` if no event terminator is
--- yet present.
---
--- Comment lines (`:`-prefixed) and non-data fields (`event:`, `id:`,
--- `retry:`) are tolerated but not surfaced: we only care about the
--- JSON-RPC body, which by convention rides on `data:`. This matches
--- how the MCP reference clients emit JSON-RPC over SSE.
---@param strbuf string[]
---@param byte_len integer
---@return string? body
---@return integer? consumed
function M.sse_decode(strbuf, byte_len)
  local s = table.concat(strbuf)
  local term_start, term_end = s:find('\r\n\r\n', 1, true)
  if not term_start then
    term_start, term_end = s:find('\n\n', 1, true)
  end
  if not term_start then return nil end

  local data_lines = {}
  local body = s:sub(1, term_start - 1)
  for line in body:gmatch('[^\r\n]+') do
    -- Comment lines start with a colon; skip them.
    if line:sub(1, 1) ~= ':' then
      local prefix, value = line:match('^([%a]-):%s?(.*)$')
      if prefix == 'data' then data_lines[#data_lines + 1] = value or '' end
    end
  end

  local payload = table.concat(data_lines, '\n')
  return payload, term_end
end

return M
