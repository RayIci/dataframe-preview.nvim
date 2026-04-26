local classes = require("dataframe-preview.utils.classes")

---@class Metadata
---@field row_count integer
---@field col_count integer
---@field columns  string[]
---@field dtypes   string[]

---@class SortEntry
---@field column    string   -- column name to sort by
---@field ascending boolean  -- true = ascending, false = descending

---@class FilterCondition
---@field column   string  -- column name to filter on
---@field operator string  -- "contains"|"not_contains"|"equals"|"not_equals"|"starts_with"|"ends_with"|"gt"|"gte"|"lt"|"lte"
---@field value    string  -- filter value (always a string; numeric conversions happen in the expression)

---@class LanguageProvider
local LanguageProvider = {}

---Returns a read-only DAP evaluate expression that produces JSON metadata.
---@param var_name     string
---@param filter       FilterCondition[]|nil  -- optional; when present, row_count reflects filtered result
---@param filter_logic string|nil             -- "AND" | "OR"; defaults to "AND"
---@return string
function LanguageProvider:metadata_expr(var_name, filter, filter_logic)
  classes.not_implemented_error("LanguageProvider:metadata_expr")
end

---Returns a read-only DAP evaluate expression that produces a JSON array of rows.
---@param var_name     string
---@param offset       integer
---@param limit        integer
---@param sort         SortEntry[]|nil         -- optional multi-column sort
---@param filter       FilterCondition[]|nil   -- optional column filters
---@param filter_logic string|nil              -- "AND" | "OR"; defaults to "AND"
---@return string
function LanguageProvider:rows_expr(var_name, offset, limit, sort, filter, filter_logic)
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

---Returns a read-only DAP evaluate expression that resolves to a boolean
---indicating whether var_name is a type this provider can handle.
---@param var_name string
---@return string
function LanguageProvider:can_handle_expr(var_name)
  classes.not_implemented_error("LanguageProvider:can_handle_expr")
end

---Parses the raw DAP evaluate result from can_handle_expr into a boolean.
---@param raw string
---@return boolean
function LanguageProvider:parse_can_handle(raw)
  classes.not_implemented_error("LanguageProvider:parse_can_handle")
end

---@return LanguageProvider
function LanguageProvider.new()
  return classes.new(LanguageProvider)
end

return LanguageProvider
