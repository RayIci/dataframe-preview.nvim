-- sha1.lua
--
-- Pure-Lua SHA1 hash function, compatible with LuaJIT (Neovim's Lua runtime).
--
-- WHY IS SHA1 HERE?
--   The WebSocket upgrade handshake (RFC 6455 §4.2.2) requires the server to
--   prove it understood the client's request by computing:
--
--     Sec-WebSocket-Accept = base64( sha1( Sec-WebSocket-Key + MAGIC_GUID ) )
--
--   Neovim exposes no built-in SHA1 function, so we implement it ourselves.
--   This is the ONLY place SHA1 is used.  It is NOT used for any security
--   purpose beyond the handshake protocol requirement.
--
-- WHY NOT USE vim.fn.system("openssl sha1 ...")?
--   That would block Neovim's main thread during every WebSocket connection,
--   causing a visible freeze.  A pure-Lua solution runs synchronously inside
--   the already-running event loop without any subprocess overhead.
--
-- LuaJIT COMPATIBILITY NOTE:
--   Neovim uses LuaJIT, which implements Lua 5.1.  The bitwise operators
--   introduced in Lua 5.3 (|, &, ~, <<, >>) do NOT exist in LuaJIT.
--   We use the `bit` library that LuaJIT ships with instead.
--   Key mappings:
--     Lua 5.4   →  LuaJIT bit lib
--     a | b     →  bit.bor(a, b)
--     a & b     →  bit.band(a, b)
--     a ~ b     →  bit.bxor(a, b)   (XOR; tilde means NOT in Lua 5.4)
--     ~a        →  bit.bnot(a)
--     a << n    →  bit.lshift(a, n)
--     a >> n    →  bit.rshift(a, n)  (logical, zero-fills from left)
--
--   LuaJIT bit operations return SIGNED 32-bit integers (range -2^31..2^31-1).
--   SHA1 needs UNSIGNED 32-bit arithmetic.  We use bit.tobit() to truncate
--   additions back into the 32-bit signed range, which gives the same bit
--   pattern as unsigned wrap-around.

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol = bit.lshift, bit.rshift, bit.rol

local M = {}

-- add32(...): modular 32-bit addition.
--
-- Lua's doubles can represent integers exactly up to 2^53, so adding two
-- signed 32-bit integers as doubles is always exact.  bit.tobit() then
-- truncates the result back to 32 bits (matching unsigned overflow behaviour).
local function add32(...)
  local r = 0
  for i = 1, select("#", ...) do
    r = bit.tobit(r + select(i, ...))
  end
  return r
end

-- u32be(s, i): read 4 bytes starting at position `i` as a big-endian
-- unsigned 32-bit integer (stored as a LuaJIT signed 32-bit integer —
-- the bit pattern is identical, which is all SHA1 cares about).
local function u32be(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return bor(bor(bor(lshift(a, 24), lshift(b, 16)), lshift(c, 8)), d)
end

-- be4(v): convert a 32-bit value back to 4 big-endian bytes.
-- rshift is a logical (unsigned) right shift, so negative values (sign bit
-- set) become positive after the shift — which is what we want for
-- extracting the high bytes.
local function be4(v)
  return string.char(band(rshift(v, 24), 0xFF), band(rshift(v, 16), 0xFF), band(rshift(v, 8), 0xFF), band(v, 0xFF))
end

-- ---------------------------------------------------------------------------
-- M.digest(msg)  →  20-byte binary SHA1 hash string
--
-- SHA1 algorithm overview:
--
--   1. Pre-processing: pad the message so its length ≡ 56 (mod 64).
--      Append a 1-bit, then zeros, then the original bit-length as a
--      64-bit big-endian integer.  This makes the padded message a
--      multiple of 512 bits (64 bytes).
--
--   2. Process 64-byte chunks one at a time.  Each chunk is expanded from
--      16 × 32-bit words into 80 × 32-bit words using bit rotations and XOR.
--
--   3. Run 80 rounds of mixing on 5 accumulator registers (a,b,c,d,e),
--      divided into 4 groups of 20 with different mixing functions and
--      constants (K values).
--
--   4. Add each chunk's final (a,b,c,d,e) into the running hash state (h).
--
--   5. Concatenate h[1]..h[5] as big-endian 32-bit integers → 20-byte digest.
-- ---------------------------------------------------------------------------
function M.digest(msg)
  local len = #msg

  -- Step 1a: append the mandatory 0x80 byte (bit "1" followed by zeros).
  msg = msg .. "\x80"

  -- Step 1b: pad with zero bytes until length ≡ 56 (mod 64).
  -- We need 8 bytes at the end for the 64-bit length field, so we stop at 56.
  while #msg % 64 ~= 56 do
    msg = msg .. "\x00"
  end

  -- Step 1c: append the original message length in bits as 8 bytes big-endian.
  -- For messages shorter than 2^29 bytes the upper 4 bytes are always zero.
  local bit_len = len * 8
  msg = msg
    .. "\x00\x00\x00\x00" -- upper 32 bits of bit-length (always 0 here)
    .. string.char(
      band(rshift(bit_len, 24), 0xFF),
      band(rshift(bit_len, 16), 0xFF),
      band(rshift(bit_len, 8), 0xFF),
      band(bit_len, 0xFF)
    )

  -- Step 2: initialise the 5 hash accumulators with SHA1's fixed constants.
  -- These magic numbers are the fractional parts of the square roots of 2,3,5,10.
  local h = {
    0x67452301,
    0xEFCDAB89,
    0x98BADCFE,
    0x10325476,
    bit.tobit(0xC3D2E1F0), -- needs tobit because it exceeds signed 32-bit max
  }

  -- Step 3 & 4: process each 64-byte (512-bit) chunk.
  for chunk = 1, #msg, 64 do
    -- Expand the 16 input words into 80 working words.
    local w = {}
    for i = 0, 15 do
      w[i] = u32be(msg, chunk + i * 4)
    end
    for i = 16, 79 do
      -- Each extended word is a left-rotate-by-1 of the XOR of four earlier words.
      w[i] = rol(bxor(bxor(bxor(w[i - 3], w[i - 8]), w[i - 14]), w[i - 16]), 1)
    end

    -- Save the current hash state so we can add it back after the 80 rounds.
    local a, b, c, d, e = h[1], h[2], h[3], h[4], h[5]

    for i = 0, 79 do
      local f, k

      if i < 20 then
        -- Rounds 0-19: Ch (choose) function + K = sqrt(2)
        f = bor(band(b, c), band(bnot(b), d))
        k = 0x5A827999
      elseif i < 40 then
        -- Rounds 20-39: Parity function + K = sqrt(3)
        f = bxor(bxor(b, c), d)
        k = 0x6ED9EBA1
      elseif i < 60 then
        -- Rounds 40-59: Maj (majority) function + K = sqrt(5)
        f = bor(bor(band(b, c), band(b, d)), band(c, d))
        k = bit.tobit(0x8F1BBCDC)
      else
        -- Rounds 60-79: Parity function again + K = sqrt(10)
        f = bxor(bxor(b, c), d)
        k = bit.tobit(0xCA62C1D6)
      end

      -- One round: rotate `a` left by 5, mix in everything, rotate `b` left by 30.
      local tmp = add32(rol(a, 5), f, e, k, w[i])
      e = d
      d = c
      c = rol(b, 30)
      b = a
      a = tmp
    end

    -- Add this chunk's contribution into the running hash state.
    h[1] = add32(h[1], a)
    h[2] = add32(h[2], b)
    h[3] = add32(h[3], c)
    h[4] = add32(h[4], d)
    h[5] = add32(h[5], e)
  end

  -- Step 5: serialise the five 32-bit hash words as a 20-byte big-endian string.
  return be4(h[1]) .. be4(h[2]) .. be4(h[3]) .. be4(h[4]) .. be4(h[5])
end

-- Base64 alphabet (RFC 4648 standard encoding, with padding).
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- ---------------------------------------------------------------------------
-- M.b64encode(s)  →  base64-encoded string
--
-- Encodes a binary string to base64.  Processes 3 input bytes at a time,
-- producing 4 output characters.  Pads with "=" if the input length is not
-- a multiple of 3.
-- ---------------------------------------------------------------------------
function M.b64encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    b = b or 0 -- pad missing bytes with 0 for the bit arithmetic
    c = c or 0
    -- Combine 3 bytes into a 24-bit number, then extract four 6-bit groups.
    local n = a * 0x10000 + b * 0x100 + c
    out[#out + 1] = B64:sub(math.floor(n / 0x40000) + 1, math.floor(n / 0x40000) + 1)
    out[#out + 1] = B64:sub(math.floor(n / 0x1000) % 64 + 1, math.floor(n / 0x1000) % 64 + 1)
    -- If the original string had fewer than 3 bytes in this group, pad with "=".
    out[#out + 1] = i + 1 <= #s and B64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "="
    out[#out + 1] = i + 2 <= #s and B64:sub(n % 64 + 1, n % 64 + 1) or "="
  end
  return table.concat(out)
end

return M
