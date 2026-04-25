-- Pure-Lua SHA1, LuaJIT-compatible (uses the `bit` library).
-- Used exclusively for the WebSocket handshake Accept key (RFC 6455 §4.2.2).
local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol = bit.lshift, bit.rshift, bit.rol

local M = {}

-- Modular 32-bit addition (LuaJIT bit ops return signed 32-bit integers).
local function add32(...)
  local r = 0
  for i = 1, select("#", ...) do
    r = bit.tobit(r + select(i, ...))
  end
  return r
end

-- Big-endian 4-byte slice → signed 32-bit integer.
local function u32be(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return bor(bor(bor(lshift(a, 24), lshift(b, 16)), lshift(c, 8)), d)
end

-- Signed 32-bit integer → 4 big-endian bytes.
local function be4(v)
  return string.char(band(rshift(v, 24), 0xFF), band(rshift(v, 16), 0xFF), band(rshift(v, 8), 0xFF), band(v, 0xFF))
end

---Computes the 20-byte binary SHA1 digest of `msg`.
---@param msg string
---@return string
function M.digest(msg)
  local len = #msg
  msg = msg .. "\x80"
  while #msg % 64 ~= 56 do
    msg = msg .. "\x00"
  end

  local bit_len = len * 8
  msg = msg
    .. "\x00\x00\x00\x00"
    .. string.char(
      band(rshift(bit_len, 24), 0xFF),
      band(rshift(bit_len, 16), 0xFF),
      band(rshift(bit_len, 8), 0xFF),
      band(bit_len, 0xFF)
    )

  local h = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, bit.tobit(0xC3D2E1F0) }

  for chunk = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do
      w[i] = u32be(msg, chunk + i * 4)
    end
    for i = 16, 79 do
      w[i] = rol(bxor(bxor(bxor(w[i - 3], w[i - 8]), w[i - 14]), w[i - 16]), 1)
    end

    local a, b, c, d, e = h[1], h[2], h[3], h[4], h[5]

    for i = 0, 79 do
      local f, k
      if i < 20 then
        f = bor(band(b, c), band(bnot(b), d))
        k = 0x5A827999
      elseif i < 40 then
        f = bxor(bxor(b, c), d)
        k = 0x6ED9EBA1
      elseif i < 60 then
        f = bor(bor(band(b, c), band(b, d)), band(c, d))
        k = bit.tobit(0x8F1BBCDC)
      else
        f = bxor(bxor(b, c), d)
        k = bit.tobit(0xCA62C1D6)
      end
      local tmp = add32(rol(a, 5), f, e, k, w[i])
      e = d
      d = c
      c = rol(b, 30)
      b = a
      a = tmp
    end

    h[1] = add32(h[1], a)
    h[2] = add32(h[2], b)
    h[3] = add32(h[3], c)
    h[4] = add32(h[4], d)
    h[5] = add32(h[5], e)
  end

  return be4(h[1]) .. be4(h[2]) .. be4(h[3]) .. be4(h[4]) .. be4(h[5])
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

---Base64-encodes a binary string.
---@param s string
---@return string
function M.b64encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    b = b or 0
    c = c or 0
    local n = a * 0x10000 + b * 0x100 + c
    out[#out + 1] = B64:sub(math.floor(n / 0x40000) + 1, math.floor(n / 0x40000) + 1)
    out[#out + 1] = B64:sub(math.floor(n / 0x1000) % 64 + 1, math.floor(n / 0x1000) % 64 + 1)
    out[#out + 1] = i + 1 <= #s and B64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "="
    out[#out + 1] = i + 2 <= #s and B64:sub(n % 64 + 1, n % 64 + 1) or "="
  end
  return table.concat(out)
end

return M
