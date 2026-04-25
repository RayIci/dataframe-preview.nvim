local classes = require("dataframe-preview.utils.classes")

---@class Metadata
---@field row_count integer
---@field col_count integer
---@field columns  string[]
---@field dtypes   string[]

---@class LanguageProvider
local LanguageProvider = {}

---Returns a read-only DAP evaluate expression that produces JSON metadata.
---@param var_name string
---@return string
function LanguageProvider:metadata_expr(var_name)
  classes.not_implemented_error("LanguageProvider:metadata_expr")
end

---Returns a read-only DAP evaluate expression that produces a JSON array of rows.
---@param var_name string
---@param offset   integer
---@param limit    integer
---@return string
function LanguageProvider:rows_expr(var_name, offset, limit)
  classes.not_implemented_error("LanguageProvider:rows_expr")
end

---Parses the raw DAP evaluate result into structured metadata.
---@param raw string
---@return Metadata
function LanguageProvider:parse_metadata(raw)
  classes.not_implemented_error("LanguageProvider:parse_metadata")
end

---Parses the raw DAP evaluate result into a list of row arrays.
---@param raw string
---@return any[][]
function LanguageProvider:parse_rows(raw)
  classes.not_implemented_error("LanguageProvider:parse_rows")
end

---@return LanguageProvider
function LanguageProvider.new()
  return classes.new(LanguageProvider)
end

return LanguageProvider
