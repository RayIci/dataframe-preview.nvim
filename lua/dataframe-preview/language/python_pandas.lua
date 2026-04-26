-- python_pandas.lua
--
-- LanguageProvider implementation for Python + Pandas DataFrames.
--
-- A LanguageProvider has two responsibilities:
--   1. Build DAP evaluate expressions that extract data from the debugged
--      process as JSON strings.
--   2. Parse those JSON strings back into Lua tables.
--
-- ZERO CODE INJECTION PRINCIPLE
--   The expressions below look like Python code, and they are — but they are
--   evaluated by the debug adapter as read-only REPL expressions, exactly
--   like typing them into the debug console.  Nothing is written to disk,
--   no files are opened, no modules are imported permanently.  The expressions
--   only READ data from the dataframe and serialise it as a string.
--
-- WHY __import__('json') INSTEAD OF import json?
--   DAP evaluate requests are single expressions, not statements.  `import`
--   is a statement in Python and cannot be used inside an expression.
--   __import__('json') is the function call equivalent and works inside
--   f-strings, comprehensions, and single-expression eval contexts.
--
-- WHY .astype(object).where(...notna(), None)?
--   Pandas represents missing values as `NaN` (a float), which is not valid
--   JSON.  json.dumps would produce the string "NaN" rather than `null`,
--   breaking the decoder.  Calling .astype(object) and then .where(...notna(), None)
--   replaces every NaN with Python None, which json.dumps correctly encodes
--   as JSON null.

local LanguageProvider = require("dataframe-preview.language.provider")
local classes = require("dataframe-preview.utils.classes")

-- The DAP adapter returns the Python repr() of the evaluated expression.
-- For a string value this means the JSON is wrapped in single or double quotes:
--   '{"shape": [366, 2], ...}'   ← what we receive
--   {"shape": [366, 2], ...}     ← what vim.json.decode needs
-- This helper strips exactly one layer of surrounding quotes.
local function unwrap_python_string(s)
  local first, last = s:sub(1, 1), s:sub(-1)
  if (first == "'" and last == "'") or (first == '"' and last == '"') then
    return s:sub(2, -2)
  end
  return s
end

-- Wraps s as a Python single-quoted string literal, escaping backslashes and
-- single quotes so the result is safe to embed in a generated Python expression.
local function py_str(s)
  return "'" .. s:gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

-- Returns a pandas boolean-index expression that applies all FilterCondition
-- items joined with the given logic operator ("AND" → & , "OR" → |).
-- Returns var_name unchanged when the filter list is nil or empty.
local function build_filter_cond(var_name, filter, filter_logic)
  if not filter or #filter == 0 then
    return var_name
  end
  local conds = {}
  for _, f in ipairs(filter) do
    local col = py_str(f.column)
    local val = py_str(f.value)
    local c
    if f.operator == "contains" then
      c = string.format("%s[%s].astype(str).str.contains(%s, case=False, na=False)", var_name, col, val)
    elseif f.operator == "not_contains" then
      c = string.format("~%s[%s].astype(str).str.contains(%s, case=False, na=False)", var_name, col, val)
    elseif f.operator == "equals" then
      c = string.format("(%s[%s].astype(str) == %s)", var_name, col, val)
    elseif f.operator == "not_equals" then
      c = string.format("(%s[%s].astype(str) != %s)", var_name, col, val)
    elseif f.operator == "starts_with" then
      c = string.format("%s[%s].astype(str).str.startswith(%s, na=False)", var_name, col, val)
    elseif f.operator == "ends_with" then
      c = string.format("%s[%s].astype(str).str.endswith(%s, na=False)", var_name, col, val)
    elseif f.operator == "gt" then
      c = string.format("(%s[%s] > float(%s))", var_name, col, val)
    elseif f.operator == "gte" then
      c = string.format("(%s[%s] >= float(%s))", var_name, col, val)
    elseif f.operator == "lt" then
      c = string.format("(%s[%s] < float(%s))", var_name, col, val)
    elseif f.operator == "lte" then
      c = string.format("(%s[%s] <= float(%s))", var_name, col, val)
    end
    if c then
      conds[#conds + 1] = c
    end
  end
  if #conds == 0 then
    return var_name
  end
  local joiner = (filter_logic == "OR") and " | " or " & "
  return string.format("%s.loc[%s]", var_name, table.concat(conds, joiner))
end

-- Wraps base_expr in a .sort_values() call when the sort list is non-empty.
local function apply_sort(base_expr, sort)
  if not sort or #sort == 0 then
    return base_expr
  end
  local cols, ascs = {}, {}
  for _, s in ipairs(sort) do
    cols[#cols + 1] = py_str(s.column)
    ascs[#ascs + 1] = s.ascending and "True" or "False"
  end
  return string.format(
    "%s.sort_values([%s], ascending=[%s])",
    base_expr,
    table.concat(cols, ", "),
    table.concat(ascs, ", ")
  )
end

---@class PythonPandas : LanguageProvider
local PythonPandas = setmetatable({}, { __index = LanguageProvider })

-- Returns a Python expression that evaluates to a JSON string containing:
--   { "shape": [rows, cols], "columns": [...], "dtypes": [...] }
--
-- When `filter` is provided the shape reflects the filtered row count, while
-- columns and dtypes always come from the original (unfiltered) DataFrame.
---@param var_name     string
---@param filter       FilterCondition[]|nil
---@param filter_logic string|nil
---@return string
function PythonPandas:metadata_expr(var_name, filter, filter_logic)
  local base = build_filter_cond(var_name, filter, filter_logic)
  return string.format(
    "__import__('json').dumps({"
      .. "'shape': list(%s.shape),"
      .. "'columns': %s.columns.tolist(),"
      .. "'dtypes': %s.dtypes.astype(str).tolist()"
      .. "})",
    base,
    var_name,
    var_name
  )
end

-- Returns a Python expression that evaluates to a JSON string containing
-- a list of rows, each row being a list of cell values.
--
-- When sort/filter are provided the data is filtered, sorted, then sliced.
-- .pipe(lambda _s: _s.astype(object).where(_s.notna(), None)) avoids
-- evaluating the (potentially complex) slice expression twice.
--
-- default=str — fallback serialiser for non-JSON-native types: Timestamp,
--               numpy.int64, Decimal, etc.
---@param var_name     string
---@param offset       integer
---@param limit        integer
---@param sort         SortEntry[]|nil
---@param filter       FilterCondition[]|nil
---@param filter_logic string|nil
---@return string
function PythonPandas:rows_expr(var_name, offset, limit, sort, filter, filter_logic)
  local slice = string.format(
    "%s.iloc[%d:%d]",
    apply_sort(build_filter_cond(var_name, filter, filter_logic), sort),
    offset,
    offset + limit
  )
  return string.format(
    "__import__('json').dumps(%s.pipe(lambda _s: _s.astype(object).where(_s.notna(), None)).values.tolist(), default=str)",
    slice
  )
end

-- Parses the JSON string returned by metadata_expr into a Metadata table.
-- Raises an error (caught by pcall in the orchestrator) if the string is not
-- valid JSON or does not have the expected shape.
---@param raw string
---@return Metadata
function PythonPandas:parse_metadata(raw)
  local ok, decoded = pcall(vim.json.decode, unwrap_python_string(raw))
  if not ok or not decoded then
    error("PythonPandas: failed to parse metadata: " .. tostring(raw))
  end
  -- decoded.shape is [rows, cols] — Lua tables are 1-indexed.
  return {
    row_count = decoded.shape[1],
    col_count = decoded.shape[2],
    columns = decoded.columns,
    dtypes = decoded.dtypes,
  }
end

-- Returns a Python expression that evaluates to True if var_name is a pandas
-- DataFrame, False otherwise.  Used by the multi-provider resolution logic to
-- pick the right provider when several are registered for the same filetype.
---@param var_name string
---@return string
function PythonPandas:can_handle_expr(var_name)
  return string.format("isinstance(%s, __import__('pandas').DataFrame)", var_name)
end

-- Parses the raw DAP result from can_handle_expr into a boolean.
-- Python bools have repr "True"/"False"; DAP may also wrap them in quotes.
---@param raw string
---@return boolean
function PythonPandas:parse_can_handle(raw)
  return unwrap_python_string(raw) == "True"
end

-- Parses the JSON string returned by rows_expr into a list of row arrays.
-- Returns: { {val, val, ...}, {val, val, ...}, ... }
---@param raw string
---@return any[][]
function PythonPandas:parse_rows(raw)
  local ok, decoded = pcall(vim.json.decode, unwrap_python_string(raw))
  if not ok or not decoded then
    error("PythonPandas: failed to parse rows: " .. tostring(raw))
  end
  return decoded
end

---@return PythonPandas
function PythonPandas.new()
  return classes.new(PythonPandas)
end

return PythonPandas
