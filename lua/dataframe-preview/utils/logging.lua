---@alias LogLevel "debug" | "info" | "warn" | "error"

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local VIM_LEVELS = {
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

local M = {
  _level = "info",
  _name = "dataframe-preview",
}

---@param level LogLevel
function M.setup(level)
  M._level = level or "info"
end

---@param level LogLevel
---@param msg string
local function log(level, msg)
  if LEVELS[level] >= LEVELS[M._level] then
    vim.notify(string.format("[%s] %s", M._name, msg), VIM_LEVELS[level])
  end
end

function M.debug(msg)
  log("debug", msg)
end
function M.info(msg)
  log("info", msg)
end
function M.warn(msg)
  log("warn", msg)
end
function M.error(msg)
  log("error", msg)
end

return M
