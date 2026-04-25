---@class DataFramePreviewConfig
---@field debug boolean

local M = {}

---@type DataFramePreviewConfig
local defaults = {
  debug = false,
}

---Merges user-supplied opts with defaults and returns the final config.
---@param opts table|nil
---@return DataFramePreviewConfig
function M.apply(opts)
  return vim.tbl_deep_extend("force", defaults, opts or {})
end

return M
