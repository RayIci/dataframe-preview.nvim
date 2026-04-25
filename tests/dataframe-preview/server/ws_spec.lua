local ws = require("dataframe-preview.server.ws")
local bit = require("bit")

describe("ws.encode", function()
  it("produces a valid FIN+text frame header byte", function()
    local frame = ws.encode("hello")
    assert.equal(0x81, frame:byte(1)) -- FIN=1, opcode=0x1 (text)
  end)

  it("encodes payload length correctly for short payload", function()
    local payload = "hello"
    local frame = ws.encode(payload)
    assert.equal(#payload, frame:byte(2))
  end)

  it("uses extended 16-bit length for payloads >= 126 bytes", function()
    local payload = string.rep("x", 200)
    local frame = ws.encode(payload)
    assert.equal(126, frame:byte(2))
    assert.equal(0, frame:byte(3))
    assert.equal(200, frame:byte(4))
  end)
end)

describe("ws.decode", function()
  local function make_masked_frame(payload)
    local mask = { 0xDE, 0xAD, 0xBE, 0xEF }
    local masked = {}
    for i = 1, #payload do
      masked[i] = string.char(bit.bxor(payload:byte(i), mask[(i - 1) % 4 + 1]))
    end
    return string.char(0x81)
      .. string.char(bit.bor(0x80, #payload))
      .. string.char(unpack(mask))
      .. table.concat(masked)
  end

  it("decodes a masked client frame", function()
    local payload = '{"type":"init"}'
    local frame = make_masked_frame(payload)
    local result = ws.decode(frame)
    assert.not_nil(result)
    assert.equal(ws.OP_TEXT, result.opcode)
    assert.equal(payload, result.payload)
  end)

  it("returns nil when buffer is incomplete", function()
    assert.is_nil(ws.decode("\x81"))
  end)
end)

describe("ws.encode_json", function()
  it("produces a frame whose payload is valid JSON", function()
    local frame = ws.encode_json({ type = "meta", row_count = 42 })
    -- short payload: payload starts at byte 3
    local payload = frame:sub(3)
    local ok, decoded = pcall(vim.json.decode, payload)
    assert.is_true(ok)
    assert.equal(42, decoded.row_count)
  end)
end)
