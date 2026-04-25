local M = {}

---Raises a standard "not implemented" error for interface methods.
---@param fn_name string
function M.not_implemented_error(fn_name)
  error(string.format("Function '%s' is not implemented.", fn_name), 2)
end

---Creates a new instance of a class table via prototype chain.
---@param cls table
---@return table
function M.new(cls)
  local instance = setmetatable({}, { __index = cls })
  return instance
end

return M
