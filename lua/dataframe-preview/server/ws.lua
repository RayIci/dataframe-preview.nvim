-- ws.lua
--
-- WebSocket implementation (RFC 6455).
--
-- WebSocket is a protocol that starts as a regular HTTP request and then
-- "upgrades" into a persistent, full-duplex binary channel over the same
-- TCP connection.  Once upgraded, both sides can send messages at any time
-- without the request/response overhead of HTTP.
--
-- WHY WebSocket and not plain HTTP?
--   We need the Lua server to PUSH rows to the browser as soon as the DAP
--   evaluate call finishes — which can happen at any time.  Plain HTTP would
--   require the browser to poll repeatedly.  WebSocket lets the server send
--   data the moment it is ready.
--
-- This file covers three concerns:
--   1. The HTTP upgrade handshake   (ws.handshake)
--   2. Encoding server→browser frames  (ws.encode / ws.encode_json)
--   3. Decoding browser→server frames  (ws.decode)
--
-- NOTE: Neovim embeds LuaJIT (Lua 5.1).  The Lua 5.4 bitwise operators
-- (|, &, ~, <<, >>) are not available.  We use the `bit` library instead.

local bit = require("bit")
local band = bit.band -- bitwise AND:  a & b
local bxor = bit.bxor -- bitwise XOR:  a ^ b  (NOT ~, that's Lua 5.4)
local bor = bit.bor -- bitwise OR:   a | b

local sha1 = require("dataframe-preview.server.sha1")
local http = require("dataframe-preview.server.http")

local M = {}

-- The magic GUID defined by the WebSocket spec (RFC 6455 §4.2.2).
-- Every WebSocket implementation in the world uses this exact string.
-- It is concatenated with the client's key and SHA1-hashed to produce
-- the Sec-WebSocket-Accept response header, proving the server is a
-- genuine WebSocket server and not some other protocol accidentally
-- receiving the upgrade request.
local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

-- WebSocket opcodes (RFC 6455 §5.2).
-- The opcode is a 4-bit field in the first byte of every frame.
M.OP_TEXT = 0x1 -- UTF-8 text payload  (we use this for JSON messages)
M.OP_CLOSE = 0x8 -- orderly connection close
M.OP_PING = 0x9 -- keepalive ping from client
M.OP_PONG = 0xA -- keepalive pong reply from server

-- ---------------------------------------------------------------------------
-- M.handshake(req)
--
-- Builds the HTTP 101 "Switching Protocols" response that completes the
-- WebSocket upgrade.
--
-- The client sends:
--   GET /ws HTTP/1.1
--   Upgrade: websocket
--   Sec-WebSocket-Key: <random base64 string>
--   ...
--
-- We must respond with:
--   HTTP/1.1 101 Switching Protocols
--   Upgrade: websocket
--   Connection: Upgrade
--   Sec-WebSocket-Accept: <SHA1(key + GUID) in base64>
--
-- After this response the TCP connection speaks WebSocket frames, not HTTP.
-- ---------------------------------------------------------------------------
function M.handshake(req)
  local key = req.headers["sec-websocket-key"]

  -- Compute the accept token.  The spec mandates:
  --   accept = base64( sha1( client_key + WS_GUID ) )
  -- This lets the browser verify the server is WebSocket-aware.
  local accept = sha1.b64encode(sha1.digest(key .. WS_GUID))

  return http.build_response(101, "Switching Protocols", {
    ["Upgrade"] = "websocket",
    ["Connection"] = "Upgrade",
    ["Sec-WebSocket-Accept"] = accept,
  }, "")
end

-- ---------------------------------------------------------------------------
-- M.encode(payload)
--
-- Wraps a string payload in a WebSocket text frame ready to send to the
-- browser.
--
-- Frame structure (simplified, RFC 6455 §5.2):
--
--  Byte 0:  FIN(1) + RSV(3) + Opcode(4)
--           FIN=1 means this is the final (and only) fragment.
--           Opcode 0x1 = text frame.
--           Combined: 0x80 | 0x01 = 0x81
--
--  Byte 1:  MASK(1) + Payload-length(7)
--           Server→client frames must NOT be masked (MASK bit = 0).
--           Length encoding:
--             0–125        → store directly in bits 0-6
--             126–65535    → store 126, then 2-byte big-endian actual length
--             ≥65536       → store 127, then 8-byte big-endian actual length
--
--  Bytes 2+: Payload bytes (unmasked, server side)
-- ---------------------------------------------------------------------------
function M.encode(payload)
  local len = #payload
  -- 0x80 = FIN flag, bor with OP_TEXT (0x01) = 0x81
  local parts = { string.char(bor(0x80, M.OP_TEXT)) }

  if len < 126 then
    -- Short payload: length fits in 7 bits — store it directly.
    parts[#parts + 1] = string.char(len)
  elseif len < 0x10000 then
    -- Medium payload (126–65535 bytes): use 126 as a sentinel followed by
    -- the real length in 2 bytes, big-endian.
    parts[#parts + 1] = string.char(126)
    parts[#parts + 1] = string.char(
      band(math.floor(len / 0x100), 0xFF), -- high byte
      band(len, 0xFF) -- low byte
    )
  else
    -- Large payload (≥65536 bytes): use 127 as a sentinel followed by the
    -- real length in 8 bytes, big-endian.  The upper 4 bytes are always 0
    -- for any practically sized message.
    parts[#parts + 1] = string.char(127)
    parts[#parts + 1] = "\x00\x00\x00\x00" -- upper 32 bits (always 0 here)
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

-- ---------------------------------------------------------------------------
-- M.decode(buf)
--
-- Attempts to decode one WebSocket frame from the raw byte buffer `buf`.
-- Returns nil if the buffer does not yet contain a complete frame (caller
-- should wait for more TCP data and try again).
--
-- CLIENT→SERVER frames are always MASKED (RFC 6455 §5.3).
-- Masking is a security measure: the client XORs every payload byte with a
-- rotating 4-byte key before sending.  We must XOR them back to get the
-- original data.
--
-- Returns: { opcode, payload, consumed }
--   opcode   — the frame type (OP_TEXT, OP_CLOSE, etc.)
--   payload  — the decoded (unmasked) content as a string
--   consumed — how many bytes of `buf` this frame occupied
--              (caller should do buf = buf:sub(consumed+1) to advance)
-- ---------------------------------------------------------------------------
function M.decode(buf)
  -- Need at least 2 bytes for the basic header.
  if #buf < 2 then
    return nil
  end

  local b1 = buf:byte(1)
  local b2 = buf:byte(2)

  -- Extract the opcode from the lower 4 bits of byte 1.
  local opcode = band(b1, 0x0F)

  -- The MASK bit is the highest bit of byte 2.
  -- RFC 6455 requires browser→server frames to always be masked.
  local masked = band(b2, 0x80) ~= 0

  -- The lower 7 bits of byte 2 encode the payload length (or a sentinel).
  local len = band(b2, 0x7F)
  local pos = 3 -- byte index of the first byte after the basic header

  if len == 126 then
    -- 126 is a sentinel meaning "the next 2 bytes hold the actual length".
    if #buf < 4 then
      return nil
    end
    local hi, lo = buf:byte(3, 4)
    len = hi * 0x100 + lo
    pos = 5
  elseif len == 127 then
    -- 127 is a sentinel meaning "the next 8 bytes hold the actual length".
    if #buf < 10 then
      return nil
    end
    len = 0
    for i = 3, 10 do
      len = len * 256 + buf:byte(i)
    end
    pos = 11
  end

  -- Read the 4-byte masking key (present whenever MASK bit is set).
  local mask_key = ""
  if masked then
    if #buf < pos + 3 then
      return nil
    end -- need 4 more bytes for the key
    mask_key = buf:sub(pos, pos + 3)
    pos = pos + 4
  end

  -- Make sure the full payload has arrived.
  if #buf < pos + len - 1 then
    return nil
  end

  local raw = buf:sub(pos, pos + len - 1)
  local payload

  if masked then
    -- Unmask: XOR each byte with the corresponding byte of the 4-byte key.
    -- The key cycles every 4 bytes: key[(i-1) % 4 + 1].
    local chars = {}
    for i = 1, len do
      local data_byte = raw:byte(i)
      local mask_byte = mask_key:byte((i - 1) % 4 + 1)
      chars[i] = string.char(bxor(data_byte, mask_byte))
    end
    payload = table.concat(chars)
  else
    -- Server-to-server frames (unusual) are not masked.
    payload = raw
  end

  return {
    opcode = opcode,
    payload = payload,
    consumed = pos + len - 1, -- total bytes consumed from buf
  }
end

-- Convenience wrapper: encodes a Lua table as JSON and wraps it in a
-- WebSocket text frame.  This is what handlers.lua uses for every response.
---@param tbl table
---@return string
function M.encode_json(tbl)
  return M.encode(vim.json.encode(tbl))
end

return M
