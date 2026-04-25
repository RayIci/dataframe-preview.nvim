-- nvim_dap.lua
--
-- Concrete implementation of the DapProvider interface for
-- mfussenegger/nvim-dap (the most popular DAP client for Neovim).
--
-- WHAT IS DAP?
--   DAP stands for Debug Adapter Protocol — a JSON-RPC protocol (like LSP)
--   that allows editors to communicate with language-specific debug adapters
--   (e.g. debugpy for Python, codelldb for Rust/C++).  The adapter runs as a
--   separate process; nvim-dap is the Neovim client that speaks to it.
--
-- WHAT DOES THIS MODULE DO?
--   It wraps two nvim-dap operations in the DapProvider interface:
--
--   1. get_frame_id — asks the adapter for the current call stack and returns
--      the ID of the topmost frame.  We need this ID so that `evaluate`
--      requests resolve variable names in the right scope.
--
--   2. evaluate — sends an `evaluate` request to the adapter with an
--      expression string.  The adapter runs it in the paused process and
--      returns the result as a string.
--
-- ALL CALLBACKS ARE ASYNC
--   nvim-dap operations talk to the adapter over a socket.  The response
--   arrives asynchronously and is delivered via vim.schedule (Neovim main
--   thread).  We mirror that pattern — our callbacks also fire on the main
--   thread.

local DapProvider = require("dataframe-preview.dap.provider")
local classes = require("dataframe-preview.utils.classes")

---@class NvimDap : DapProvider
local NvimDap = setmetatable({}, { __index = DapProvider })

-- Returns true if the "dap" module (nvim-dap) can be required.
-- If the user hasn't installed nvim-dap this returns false and the
-- orchestrator shows a friendly error instead of crashing.
function NvimDap:is_available()
  local ok = pcall(require, "dap")
  return ok
end

-- Resolves the current stack frame ID asynchronously.
--
-- HOW IT WORKS:
--   1. Get the active DAP session object.
--   2. Read session.stopped_thread_id — this is set when the debugger pauses
--      at a breakpoint.  If it's nil the debugger is still running.
--   3. Send a "stackTrace" request to the adapter for that thread.
--   4. The adapter replies with an array of frames.  We take frames[1] (the
--      topmost / most recent frame) and return its ID.
--
---@param callback fun(frame_id: integer|nil, err: string|nil)
function NvimDap:get_frame_id(callback)
  local ok, dap = pcall(require, "dap")
  if not ok then
    callback(nil, "nvim-dap not available")
    return
  end

  -- dap.session() returns the currently focused session, or nil.
  local session = dap.session()
  if not session then
    callback(nil, "No active DAP session")
    return
  end

  -- stopped_thread_id is set by nvim-dap when the debugger hits a
  -- breakpoint or is manually paused.  It's nil while the program is running.
  local thread_id = session.stopped_thread_id
  if not thread_id then
    callback(nil, "Debugger is not paused at a breakpoint")
    return
  end

  -- Send the "stackTrace" request to the debug adapter.
  -- The response contains an array of stack frames for the given thread.
  session:request("stackTrace", { threadId = thread_id }, function(err, resp)
    -- Wrap with vim.schedule because this callback arrives from nvim-dap's
    -- internal socket handler and we want to be safely on the main thread.
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
      -- Return the ID of the topmost (most recent) frame.
      callback(frames[1].id, nil)
    end)
  end)
end

-- Evaluates a read-only expression in the given stack frame.
--
-- `expr` is a language-specific string produced by the LanguageProvider,
-- e.g. for Python:
--   __import__('json').dumps({'shape': list(df.shape), ...})
--
-- The debug adapter evaluates this in the paused process and returns the
-- result as the `result` field of the response.  For Python this will be a
-- JSON string that parse_metadata / parse_rows can decode.
--
-- We pass context="repl" which tells the adapter to evaluate the expression
-- in the REPL context (same as typing it in the debug console).
--
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
    context = "repl", -- evaluate in REPL/console context
    frameId = frame_id, -- scope: must match the paused frame
  }, function(err, resp)
    vim.schedule(function()
      if err then
        callback("evaluate error: " .. tostring(err.message), nil)
        return
      end
      -- resp.result is the string representation of the evaluated expression.
      callback(nil, resp and resp.result)
    end)
  end)
end

---@return NvimDap
function NvimDap.new()
  return classes.new(NvimDap)
end

return NvimDap
