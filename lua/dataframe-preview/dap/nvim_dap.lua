local DapProvider = require("dataframe-preview.dap.provider")
local classes = require("dataframe-preview.utils.classes")

---@class NvimDap : DapProvider
local NvimDap = setmetatable({}, { __index = DapProvider })

function NvimDap:is_available()
  local ok = pcall(require, "dap")
  return ok
end

---@param callback fun(frame_id: integer|nil, err: string|nil)
function NvimDap:get_frame_id(callback)
  local ok, dap = pcall(require, "dap")
  if not ok then
    callback(nil, "nvim-dap not available")
    return
  end

  local session = dap.session()
  if not session then
    callback(nil, "No active DAP session")
    return
  end

  local thread_id = session.stopped_thread_id
  if not thread_id then
    callback(nil, "Debugger is not paused at a breakpoint")
    return
  end

  session:request("stackTrace", { threadId = thread_id }, function(err, resp)
    vim.schedule(function()
      if err then
        callback(nil, "stackTrace error: " .. tostring(err.message))
        return
      end
      local frames = resp and resp.stackFrames
      if not frames or #frames == 0 then
        callback(nil, "No stack frames available")
        return
      end
      callback(frames[1].id, nil)
    end)
  end)
end

---@param expr     string
---@param frame_id integer
---@param callback fun(err: string|nil, result: string|nil)
function NvimDap:evaluate(expr, frame_id, callback)
  local ok, dap = pcall(require, "dap")
  if not ok then
    callback("nvim-dap not available", nil)
    return
  end

  local session = dap.session()
  if not session then
    callback("No active DAP session", nil)
    return
  end

  session:request("evaluate", {
    expression = expr,
    context = "repl",
    frameId = frame_id,
  }, function(err, resp)
    vim.schedule(function()
      if err then
        callback("evaluate error: " .. tostring(err.message), nil)
        return
      end
      callback(nil, resp and resp.result)
    end)
  end)
end

---@return NvimDap
function NvimDap.new()
  return classes.new(NvimDap)
end

return NvimDap
