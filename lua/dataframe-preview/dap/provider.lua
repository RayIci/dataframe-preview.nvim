local classes = require("dataframe-preview.utils.classes")

---@class DapProvider
local DapProvider = {}

---Returns true if the underlying DAP plugin is loaded.
---@return boolean
function DapProvider:is_available()
  classes.not_implemented_error("DapProvider:is_available")
end

---Resolves the current stack frame ID asynchronously.
---@param callback fun(frame_id: integer|nil, err: string|nil)
function DapProvider:get_frame_id(callback)
  classes.not_implemented_error("DapProvider:get_frame_id")
end

---Evaluates a read-only expression in the given stack frame.
---@param expr string
---@param frame_id integer
---@param callback fun(err: string|nil, result: string|nil)
function DapProvider:evaluate(expr, frame_id, callback)
  classes.not_implemented_error("DapProvider:evaluate")
end

---@return DapProvider
function DapProvider.new()
  return classes.new(DapProvider)
end

return DapProvider
