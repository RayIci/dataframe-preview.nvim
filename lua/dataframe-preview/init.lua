local Config = require("dataframe-preview.config")
local Logging = require("dataframe-preview.utils.logging")
local Commands = require("dataframe-preview.commands")
local Orchestrator = require("dataframe-preview.orchestrator")
local NvimDap = require("dataframe-preview.dap.nvim_dap")
local PythonPandas = require("dataframe-preview.language.python_pandas")

---@class DataFramePreview
local M = {
  _initialized = false,
}

---@param opts table|nil
function M.setup(opts)
  if M._initialized then
    return
  end

  local config = Config.apply(opts)
  Logging.setup(config.debug and "debug" or "info")

  local dap_provider = NvimDap.new()
  local lang_provider = PythonPandas.new()

  Commands.register(function()
    Orchestrator.preview(dap_provider, lang_provider)
  end)

  M._initialized = true
end

return M
