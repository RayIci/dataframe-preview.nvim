-- WebSocket implementation per RFC 6455. LuaJIT-compatible (uses `bit` library).
local bit = require("bit")
local band = bit.band
local bxor = bit.bxor
local bor = bit.bor

local sha1 = require("dataframe-preview.server.sha1")
local http = require("dataframe-preview.server.http")

local M = {}

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

M.OP_TEXT = 0x1
M.OP_CLOSE = 0x8
M.OP_PING = 0x9
M.OP_PONG = 0xA

---Performs the WebSocket upgrade handshake.
---@param req HttpRequest
---@return string  HTTP 101 response
function M.handshake(req)
  local key = req.headers["sec-websocket-key"]
  local accept = sha1.b64encode(sha1.digest(key .. WS_GUID))
  return http.build_response(101, "Switching Protocols", {
    ["Upgrade"] = "websocket",
    ["Connection"] = "Upgrade",
    ["Sec-WebSocket-Accept"] = accept,
  }, "")
end

---Encodes a string payload into an unmasked WebSocket text frame (server→client).
---@param payload string
---@return string  binary frame
function M.encode(payload)
  local len = #payload
  local parts = { string.char(bor(0x80, M.OP_TEXT)) } -- FIN + text opcode

  if len < 126 then
    parts[#parts + 1] = string.char(len)
  elseif len < 0x10000 then
    parts[#parts + 1] = string.char(126)
    parts[#parts + 1] = string.char(band(math.floor(len / 0x100), 0xFF), band(len, 0xFF))
  else
    parts[#parts + 1] = string.char(127)
    -- 8-byte big-endian (upper 4 bytes are 0 for practical sizes)
    parts[#parts + 1] = "\x00\x00\x00\x00"
    parts[#parts + 1] = string.char(
      band(math.floor(len / 0x1000000), 0xFF),
      band(math.floor(len / 0x10000), 0xFF),
      band(math.floor(len / 0x100), 0xFF),
      band(len, 0xFF)
    )
  end

  parts[#parts + 1] = payload
  return table.concat(parts)
end

---Decodes one masked client→server frame from a buffer.
---Returns nil when the buffer does not yet contain a complete frame.
---@param buf string
---@return { opcode: integer, payload: string, consumed: integer } | nil
function M.decode(buf)
  if #buf < 2 then
    return nil
  end

  local b1 = buf:byte(1)
  local b2 = buf:byte(2)
  local opcode = band(b1, 0x0F)
  local masked = band(b2, 0x80) ~= 0
  local len = band(b2, 0x7F)
  local pos = 3

  if len == 126 then
    if #buf < 4 then
      return nil
    end
    local hi, lo = buf:byte(3, 4)
    len = hi * 0x100 + lo
    pos = 5
  elseif len == 127 then
    if #buf < 10 then
      return nil
    end
    len = 0
    for i = 3, 10 do
      len = len * 256 + buf:byte(i)
    end
    pos = 11
  end

  local mask_key = ""
  if masked then
    if #buf < pos + 3 then
      return nil
    end
    mask_key = buf:sub(pos, pos + 3)
    pos = pos + 4
  end

  if #buf < pos + len - 1 then
    return nil
  end

  local raw = buf:sub(pos, pos + len - 1)
  local payload

  if masked then
    local chars = {}
    for i = 1, len do
      local data_byte = raw:byte(i)
      local mask_byte = mask_key:byte((i - 1) % 4 + 1)
      chars[i] = string.char(bxor(data_byte, mask_byte))
    end
    payload = table.concat(chars)
  else
    payload = raw
  end

  return { opcode = opcode, payload = payload, consumed = pos + len - 1 }
end

---Encodes a Lua table as a WebSocket text frame containing JSON.
---@param tbl table
---@return string
function M.encode_json(tbl)
  return M.encode(vim.json.encode(tbl))
end

return M
