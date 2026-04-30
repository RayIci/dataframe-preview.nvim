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
  if type(s) ~= "string" then return "''" end
  return "'" .. s:gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

-- vim.json.decode maps JSON null to vim.NIL (userdata), not Lua nil.
-- This helper converts a potentially-NIL timezone field to a plain string or nil.
local function node_tz(v)
  return (type(v) == "string" and v ~= "") and v or nil
end

-- Returns the column Series adjusted for timezone so it can be compared
-- against a pd.Timestamp built with flt_tz.
local function dt_col_expr(var_name, col, col_tz, flt_tz)
  if col_tz and flt_tz then
    if col_tz ~= flt_tz then
      -- both tz-aware but different zones: convert column to the filter tz
      return string.format("%s[%s].dt.tz_convert(%s)", var_name, col, py_str(flt_tz))
    else
      -- same tz: use directly
      return string.format("%s[%s]", var_name, col)
    end
  elseif col_tz and not flt_tz then
    -- column is tz-aware, user wants naive comparison: strip tz
    return string.format("%s[%s].dt.tz_convert(None)", var_name, col)
  elseif not col_tz and flt_tz then
    -- column is tz-naive, user picked a tz: localize so comparison is valid
    return string.format("%s[%s].dt.tz_localize(%s)", var_name, col, py_str(flt_tz))
  else
    -- both naive
    return string.format("%s[%s]", var_name, col)
  end
end

-- Returns a pd.Timestamp expression for the filter value, with optional tz.
local function dt_ts_expr(val, flt_tz)
  if flt_tz then
    return string.format("__import__('pandas').Timestamp(%s, tz=%s)", val, py_str(flt_tz))
  else
    return string.format("__import__('pandas').Timestamp(%s)", val)
  end
end

-- Recursively converts a FilterNode tree into a Python boolean expression string.
-- Returns nil for nodes that contribute no condition (e.g. empty groups).
local function build_filter_node(var_name, node)
  if node.type == "condition" then
    local col    = py_str(node.column)
    local val    = py_str(node.value)
    local cat    = node.dtype_category or "string"
    local flt_tz = node_tz(node.filter_timezone)
    local col_tz = node_tz(node.col_timezone)

    -- Operators that need no value — check before the empty-value guard below.
    if node.operator == "is_null" then
      return string.format("(%s[%s].isna())", var_name, col)
    elseif node.operator == "is_not_null" then
      return string.format("(%s[%s].notna())", var_name, col)
    end

    -- All remaining operators require a non-empty value.  Skip the condition
    -- silently rather than generating an expression that matches everything or
    -- crashes the Python evaluator.
    if type(node.value) ~= "string" or node.value == "" then
      return nil
    end

    if node.operator == "contains" then
      return string.format("(%s[%s].astype(str).str.contains(%s, case=False, na=False))", var_name, col, val)
    elseif node.operator == "not_contains" then
      return string.format("(~%s[%s].astype(str).str.contains(%s, case=False, na=False))", var_name, col, val)
    elseif node.operator == "starts_with" then
      return string.format("(%s[%s].astype(str).str.startswith(%s, na=False))", var_name, col, val)
    elseif node.operator == "ends_with" then
      return string.format("(%s[%s].astype(str).str.endswith(%s, na=False))", var_name, col, val)
    elseif node.operator == "equals" then
      if cat == "datetime" then
        local dcol = dt_col_expr(var_name, col, col_tz, flt_tz)
        local ts   = dt_ts_expr(val, flt_tz)
        if #node.value <= 10 then
          -- Date-only: floor to day so "2023-01-01" matches any time on that day.
          return string.format("(%s.dt.floor('D') == %s)", dcol, ts)
        else
          return string.format("(%s == %s)", dcol, ts)
        end
      elseif cat == "numeric" then
        return string.format("(%s[%s] == float(%s))", var_name, col, val)
      else
        return string.format("(%s[%s].astype(str) == %s)", var_name, col, val)
      end
    elseif node.operator == "not_equals" then
      if cat == "datetime" then
        local dcol = dt_col_expr(var_name, col, col_tz, flt_tz)
        local ts   = dt_ts_expr(val, flt_tz)
        if #node.value <= 10 then
          return string.format("(%s.dt.floor('D') != %s)", dcol, ts)
        else
          return string.format("(%s != %s)", dcol, ts)
        end
      elseif cat == "numeric" then
        return string.format("(%s[%s] != float(%s))", var_name, col, val)
      else
        return string.format("(%s[%s].astype(str) != %s)", var_name, col, val)
      end
    elseif node.operator == "gt" then
      if cat == "datetime" then
        return string.format(
          "(%s > %s)", dt_col_expr(var_name, col, col_tz, flt_tz), dt_ts_expr(val, flt_tz)
        )
      else
        return string.format("(%s[%s] > float(%s))", var_name, col, val)
      end
    elseif node.operator == "gte" then
      if cat == "datetime" then
        return string.format(
          "(%s >= %s)", dt_col_expr(var_name, col, col_tz, flt_tz), dt_ts_expr(val, flt_tz)
        )
      else
        return string.format("(%s[%s] >= float(%s))", var_name, col, val)
      end
    elseif node.operator == "lt" then
      if cat == "datetime" then
        return string.format(
          "(%s < %s)", dt_col_expr(var_name, col, col_tz, flt_tz), dt_ts_expr(val, flt_tz)
        )
      else
        return string.format("(%s[%s] < float(%s))", var_name, col, val)
      end
    elseif node.operator == "lte" then
      if cat == "datetime" then
        return string.format(
          "(%s <= %s)", dt_col_expr(var_name, col, col_tz, flt_tz), dt_ts_expr(val, flt_tz)
        )
      else
        return string.format("(%s[%s] <= float(%s))", var_name, col, val)
      end
    end
  elseif node.type == "group" then
    if not node.children or #node.children == 0 then
      return nil
    end
    local parts = {}
    for _, child in ipairs(node.children) do
      local expr = build_filter_node(var_name, child)
      if expr then
        parts[#parts + 1] = expr
      end
    end
    if #parts == 0 then
      return nil
    end
    if #parts == 1 then
      return parts[1]
    end
    local joiner = (node.logic == "OR") and " | " or " & "
    return "(" .. table.concat(parts, joiner) .. ")"
  end
  return nil
end

-- Applies a FilterNode tree to var_name, returning a .loc[...] expression or
-- var_name unchanged when the tree is nil or produces no conditions.
local function apply_filter_tree(var_name, filter_tree)
  if not filter_tree then
    return var_name
  end
  local cond = build_filter_node(var_name, filter_tree)
  if not cond then
    return var_name
  end
  return string.format("%s.loc[%s]", var_name, cond)
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
-- When filter_tree is provided the shape reflects the filtered row count, while
-- columns and dtypes always come from the original (unfiltered) DataFrame.
---@param var_name    string
---@param filter_tree FilterNode|nil
---@return string
function PythonPandas:metadata_expr(var_name, filter_tree)
  local base = apply_filter_tree(var_name, filter_tree)
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
---@param var_name    string
---@param offset      integer
---@param limit       integer
---@param sort        SortEntry[]|nil
---@param filter_tree FilterNode|nil
---@return string
function PythonPandas:rows_expr(var_name, offset, limit, sort, filter_tree)
  local slice =
    string.format("%s.iloc[%d:%d]", apply_sort(apply_filter_tree(var_name, filter_tree), sort), offset, offset + limit)
  return string.format(
    "__import__('json').dumps("
      .. "%s"
      .. ".pipe(lambda _s: _s.astype(object).where(_s.notna(), None))"
      .. ".values.tolist(), default=str)",
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
    columns   = decoded.columns,
    dtypes    = decoded.dtypes,
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
