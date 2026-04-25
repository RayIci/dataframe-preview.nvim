local LanguageProvider = require("dataframe-preview.language.provider")
local classes = require("dataframe-preview.utils.classes")

---@class PythonPandas : LanguageProvider
local PythonPandas = setmetatable({}, { __index = LanguageProvider })

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

function PythonPandas:rows_expr(var_name, offset, limit)
  local slice = string.format("%s.iloc[%d:%d]", var_name, offset, offset + limit)
  return string.format(
    "__import__('json').dumps(%s.astype(object).where(%s.notna(), None).values.tolist())",
    slice,
    slice
  )
end

---@param raw string
---@return Metadata
function PythonPandas:parse_metadata(raw)
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or not decoded then
    error("PythonPandas: failed to parse metadata: " .. tostring(raw))
  end
  return {
    row_count = decoded.shape[1],
    col_count = decoded.shape[2],
    columns = decoded.columns,
    dtypes = decoded.dtypes,
  }
end

---@param raw string
---@return any[][]
function PythonPandas:parse_rows(raw)
  local ok, decoded = pcall(vim.json.decode, raw)
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
