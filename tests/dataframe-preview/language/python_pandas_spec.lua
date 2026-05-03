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

  it("uses reset_index() base when index_columns is non-empty", function()
    local expr = provider:rows_expr("df", 0, 100, nil, nil, { "date" })
    assert.truthy(expr:find("reset_index", 1, true))
  end)

  it("does not use reset_index() when index_columns is empty", function()
    local expr = provider:rows_expr("df", 0, 100, nil, nil, {})
    assert.falsy(expr:find("reset_index", 1, true))
  end)
end)

describe("PythonPandas.parse_metadata", function()
  local provider = PythonPandas.new()

  it("parses a valid response with no named index", function()
    local raw = vim.json.encode({
      shape = { 1000, 5 },
      columns = { "a", "b", "c", "d", "e" },
      dtypes = { "int64", "object", "float64", "bool", "datetime64[ns]" },
      index_columns = {},
    })
    local meta = provider:parse_metadata(raw)
    assert.equal(1000, meta.row_count)
    assert.equal(5, meta.col_count)
    assert.equal(5, #meta.columns)
    assert.equal("int64", meta.dtypes[1])
    assert.equal(0, #meta.index_columns)
  end)

  it("parses a response with a named index column prepended", function()
    local raw = vim.json.encode({
      shape = { 500, 3 },
      columns = { "date", "open", "close", "volume" },
      dtypes = { "datetime64[ns]", "float64", "float64", "int64" },
      index_columns = { "date" },
    })
    local meta = provider:parse_metadata(raw)
    assert.equal(500, meta.row_count)
    assert.equal(4, meta.col_count)
    assert.equal(4, #meta.columns)
    assert.equal("date", meta.columns[1])
    assert.equal(1, #meta.index_columns)
    assert.equal("date", meta.index_columns[1])
  end)

  it("parses a response where pandas named an unnamed index 'index'", function()
    -- Simulates df.index = pd.date_range(...) with no .name set.
    -- pandas reset_index() names such a column "index" automatically.
    local raw = vim.json.encode({
      shape = { 100, 2 },
      columns = { "index", "value" },
      dtypes = { "datetime64[ns]", "float64" },
      index_columns = { "index" },
    })
    local meta = provider:parse_metadata(raw)
    assert.equal(100, meta.row_count)
    assert.equal(2, meta.col_count)
    assert.equal("index", meta.columns[1])
    assert.equal(1, #meta.index_columns)
    assert.equal("index", meta.index_columns[1])
  end)

  it("tolerates missing index_columns field (legacy server response)", function()
    local raw = vim.json.encode({
      shape = { 10, 2 },
      columns = { "x", "y" },
      dtypes = { "int64", "float64" },
    })
    local meta = provider:parse_metadata(raw)
    assert.equal(0, #meta.index_columns)
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

describe("PythonPandas.can_handle_expr", function()
  local provider = PythonPandas.new()

  it("includes the variable name", function()
    assert.truthy(provider:can_handle_expr("my_df"):find("my_df", 1, true))
  end)

  it("uses isinstance and pandas.DataFrame", function()
    local expr = provider:can_handle_expr("df")
    assert.truthy(expr:find("isinstance", 1, true))
    assert.truthy(expr:find("pandas", 1, true))
    assert.truthy(expr:find("DataFrame", 1, true))
  end)
end)

describe("PythonPandas.parse_can_handle", function()
  local provider = PythonPandas.new()

  it("returns true for unquoted True", function()
    assert.is_true(provider:parse_can_handle("True"))
  end)

  it("returns true for single-quoted True (DAP string repr)", function()
    assert.is_true(provider:parse_can_handle("'True'"))
  end)

  it("returns false for False", function()
    assert.is_false(provider:parse_can_handle("False"))
  end)

  it("returns false for unexpected values", function()
    assert.is_false(provider:parse_can_handle("None"))
    assert.is_false(provider:parse_can_handle("true"))
    assert.is_false(provider:parse_can_handle(""))
  end)
end)
