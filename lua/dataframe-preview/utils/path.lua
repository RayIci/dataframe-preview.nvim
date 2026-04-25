local os_utils = require("dataframe-preview.utils.os")
local M = {}

---@return string
function M.sep()
  return os_utils.is_windows() and "\\" or "/"
end

---@param parts string[]
---@return string
function M.join(parts)
  return table.concat(parts, M.sep())
end

return M
