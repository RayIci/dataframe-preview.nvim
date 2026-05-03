local classes = require("dataframe-preview.utils.classes")

---@class Metadata
---@field row_count     integer
---@field col_count     integer
---@field columns       string[]
---@field dtypes        string[]
---@field index_columns string[]  -- named index level names; empty for default RangeIndex

---@class SortEntry
---@field column    string   -- column name to sort by
---@field ascending boolean  -- true = ascending, false = descending

---@class FilterNode     -- recursive; either a condition leaf or a group with children
---@field type     string              -- "condition" | "group"
---@field logic    string|nil          -- group only: "AND" | "OR"
---@field children FilterNode[]|nil    -- group only: nested nodes
---@field column   string|nil          -- condition only
---@field operator string|nil          -- condition only: "contains"|"not_contains"|"equals"|
---                                                       "not_equals"|"starts_with"|"ends_with"|
---                                                       "gt"|"gte"|"lt"|"lte"
---@field value    string|nil          -- condition only

---@class LanguageProvider
local LanguageProvider = {}

---Returns a read-only DAP evaluate expression that produces JSON metadata.
---@param var_name    string
---@param filter_tree FilterNode|nil  -- optional recursive filter tree; row_count reflects filtered result
---@return string
function LanguageProvider:metadata_expr(var_name, filter_tree)
  classes.not_implemented_error("LanguageProvider:metadata_expr")
end

---Returns a read-only DAP evaluate expression that produces a JSON array of rows.
---@param var_name      string
---@param offset        integer
---@param limit         integer
---@param sort          SortEntry[]|nil   -- optional multi-column sort
---@param filter_tree   FilterNode|nil    -- optional recursive filter tree
---@param index_columns string[]|nil      -- named index levels; non-empty triggers reset_index() base
---@return string
function LanguageProvider:rows_expr(var_name, offset, limit, sort, filter_tree, index_columns)
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
