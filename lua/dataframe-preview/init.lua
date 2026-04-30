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

  -- Read lang_providers from raw opts to avoid vim.tbl_deep_extend stripping
  -- metatables from provider instances and breaking method dispatch.
  local lang_providers = (opts and opts.lang_providers) or {
    python = { PythonPandas.new() },
  }

  Commands.register(function()
    local ft = vim.bo.filetype
    local providers = lang_providers[ft]
    if not providers or #providers == 0 then
      -- Filetype not registered (e.g. dap-repl, scratch buffer).
      -- Collect all providers from all filetypes and let the orchestrator's
      -- can_handle_expr resolution pick the right one.
      local all = {}
      for _, ps in pairs(lang_providers) do
        for _, p in ipairs(ps) do
          all[#all + 1] = p
        end
      end
      if #all == 0 then
        Logging.error("dataframe-preview: no providers configured")
        return
      end
      providers = all
    end
    Orchestrator.preview(dap_provider, providers)
  end)

  M._initialized = true
end

return M
