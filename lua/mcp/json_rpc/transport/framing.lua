local M = {}

---@param strbuf string[]
---@return integer? 1-based index of first LF, or nil if absent
local function find_newline(strbuf)
  local offset = 0
  for _, chunk in ipairs(strbuf) do
    local nl = chunk:find('\n', 1, true)
    if nl then return offset + nl end
    offset = offset + #chunk
  end
  return nil
end

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
  -- Tolerate CRLF endings alongside LF.
  if s:sub(-1) == '\n' then s = s:sub(1, -2) end
  if s:sub(-1) == '\r' then s = s:sub(1, -2) end
  return s
end

---@param strbuf string[]
---@param byte_len integer
---@return string? body
---@return integer? consumed
function M.newline_decode(strbuf, byte_len)
  local nl = find_newline(strbuf)
  if not nl then return nil end
  return join_until(strbuf, nl), nl
end

---@param msg string
---@return string
function M.newline_encode(msg) return msg .. '\n' end

---@param strbuf string[]
---@return integer? 1-based byte offset immediately after `\r\n\r\n`
local function find_content_length_header_end(strbuf)
  local scan = table.concat(strbuf):sub(1, 4096)
  local hdr_end = scan:find('\r\n\r\n', 1, true)
  return hdr_end and (hdr_end + 3) or nil
end

---@param strbuf string[]
---@return integer?
local function parse_content_length(strbuf)
  local header = table.concat(strbuf):sub(1, 4096)
  local cl = header:match('[Cc]ontent%-[Ll]ength:%s*(%d+)')
  return tonumber(cl)
end

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

---@param msg string
---@return string
function M.content_length_encode(msg)
  return string.format('Content-Length: %d\r\n\r\n%s', #msg, msg)
end

---@param event_id integer|string|nil
---@param data string
---@return string
function M.sse_encode(event_id, data)
  local parts = {}
  if event_id ~= nil then parts[#parts + 1] = 'id: ' .. tostring(event_id) end
  -- SSE requires each line of a multi-line payload to be its own
  -- `data:` field; insert the prefix after every newline and once at
  -- the start so single-line payloads get it exactly once.
  local prefixed = tostring(data):gsub('\r?\n', '\ndata: ')
  parts[#parts + 1] = 'data: ' .. prefixed
  return table.concat(parts, '\n') .. '\n\n'
end

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
    if line:sub(1, 1) ~= ':' then
      local prefix, value = line:match('^([%a]-):%s?(.*)$')
      if prefix == 'data' then data_lines[#data_lines + 1] = value or '' end
    end
  end

  local payload = table.concat(data_lines, '\n')
  return payload, term_end
end

return M
