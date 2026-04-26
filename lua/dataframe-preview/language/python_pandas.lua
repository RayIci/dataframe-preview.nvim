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

---@class PythonPandas : LanguageProvider
local PythonPandas = setmetatable({}, { __index = LanguageProvider })

-- Returns a Python expression that evaluates to a JSON string containing:
--   { "shape": [rows, cols], "columns": [...], "dtypes": [...] }
--
-- Example for var_name = "df":
--   __import__('json').dumps({
--     'shape':   list(df.shape),          -- e.g. [50000, 5]
--     'columns': df.columns.tolist(),     -- e.g. ["id", "name", ...]
--     'dtypes':  df.dtypes.astype(str).tolist() -- e.g. ["int64", "object", ...]
--   })
---@param var_name string
---@return string
function PythonPandas:metadata_expr(var_name)
  return string.format(
    "__import__('json').dumps({"
      .. "'shape': list(%s.shape),"
      .. "'columns': %s.columns.tolist(),"
      .. "'dtypes': %s.dtypes.astype(str).tolist()"
      .. "})",
    var_name,
    var_name,
    var_name
  )
end

-- Returns a Python expression that evaluates to a JSON string containing
-- a list of rows, each row being a list of cell values.
--
-- Example for var_name="df", offset=0, limit=100:
--   __import__('json').dumps(
--     df.iloc[0:100]
--       .astype(object)
--       .where(df.iloc[0:100].notna(), None)
--       .values.tolist()
--   )
--
-- .iloc[offset:offset+limit] — slice the requested rows (0-based, exclusive end)
-- .astype(object)            — convert all columns to Python object dtype so
--                              NaN becomes float('nan') rather than numpy.nan
-- .where(...notna(), None)   — replace NaN with None (→ JSON null)
-- .values.tolist()           — convert to a plain Python list of lists
-- default=str                — fallback serializer for any type json.dumps does
--                              not know natively: Timestamp → "2024-01-01 00:00:00",
--                              numpy.int64 → "42", Decimal → "3.14", etc.
---@param var_name string
---@param offset   integer
---@param limit    integer
---@return string
function PythonPandas:rows_expr(var_name, offset, limit)
  local slice = string.format("%s.iloc[%d:%d]", var_name, offset, offset + limit)
  return string.format(
    "__import__('json').dumps(%s.astype(object).where(%s.notna(), None).values.tolist(), default=str)",
    slice,
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
