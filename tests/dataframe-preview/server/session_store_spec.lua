local store = require("dataframe-preview.server.session_store")

describe("session_store", function()
  before_each(function()
    store.clear()
  end)

  it("creates and retrieves a session", function()
    store.create("uuid-1", { var_name = "df", frame_id = 10, metadata = nil })
    local s = store.get("uuid-1")
    assert.not_nil(s)
    assert.equal("df", s.var_name)
  end)

  it("returns nil for unknown uuid", function()
    assert.is_nil(store.get("no-such-uuid"))
  end)

  it("removes a session", function()
    store.create("uuid-2", { var_name = "x", frame_id = 1, metadata = nil })
    store.remove("uuid-2")
    assert.is_nil(store.get("uuid-2"))
  end)

  it("attaches a ws_client to an existing session", function()
    store.create("uuid-3", { var_name = "y", frame_id = 2, metadata = nil })
    local fake_client = {}
    store.attach_client("uuid-3", fake_client)
    assert.equal(fake_client, store.get("uuid-3").ws_client)
  end)
end)
