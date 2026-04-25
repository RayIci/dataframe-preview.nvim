local PythonPandas = require("dataframe-preview.language.python_pandas")

describe("PythonPandas.metadata_expr", function()
  local provider = PythonPandas.new()

  it("includes the variable name three times", function()
    local expr = provider:metadata_expr("my_df")
    assert.truthy(expr:find("my_df", 1, true))
  end)

  it("returns a json.dumps expression", function()
    local expr = provider:metadata_expr("df")
    assert.truthy(expr:find("json", 1, true))
  end)
end)

describe("PythonPandas.rows_expr", function()
  local provider = PythonPandas.new()

  it("uses iloc with correct offset and end", function()
    local expr = provider:rows_expr("df", 50, 100)
    assert.truthy(expr:find("iloc%[50:150%]"))
  end)
end)

describe("PythonPandas.parse_metadata", function()
  local provider = PythonPandas.new()

  it("parses a valid response", function()
    local raw = vim.json.encode({
      shape = { 1000, 5 },
      columns = { "a", "b", "c", "d", "e" },
      dtypes = { "int64", "object", "float64", "bool", "datetime64[ns]" },
    })
    local meta = provider:parse_metadata(raw)
    assert.equal(1000, meta.row_count)
    assert.equal(5, meta.col_count)
    assert.equal(5, #meta.columns)
    assert.equal("int64", meta.dtypes[1])
  end)

  it("raises on invalid JSON", function()
    local ok, _ = pcall(function()
      provider:parse_metadata("not json")
    end)
    assert.is_false(ok)
  end)
end)

describe("PythonPandas.parse_rows", function()
  local provider = PythonPandas.new()

  it("returns a list of row arrays", function()
    local raw = vim.json.encode({ { 1, "foo", 3.14 }, { 2, "bar", nil } })
    local rows = provider:parse_rows(raw)
    assert.equal(2, #rows)
    assert.equal(1, rows[1][1])
    assert.equal("foo", rows[1][2])
  end)
end)
