local server = require("dataframe-preview.server.server")
local session_store = require("dataframe-preview.server.session_store")
local browser = require("dataframe-preview.browser")
local log = require("dataframe-preview.utils.logging")

local M = {}

---Generates a simple UUID v4-like string using process ID and high-resolution time.
---@return string
local function generate_uuid()
  local pid = vim.uv.os_getpid()
  local time = vim.uv.hrtime()
  -- Supplement with math.random for additional entropy
  math.randomseed(time)
  return string.format(
    "%08x-%04x-4%03x-%04x-%012x",
    pid,
    math.random(0, 0xFFFF),
    math.random(0, 0xFFF),
    math.random(0x8000, 0xBFFF),
    math.random(0, 0xFFFFFFFFFFFF)
  )
end

---Main entry point: evaluates the variable under the cursor and opens a preview tab.
---@param dap_provider  DapProvider
---@param lang_provider LanguageProvider
function M.preview(dap_provider, lang_provider)
  if not dap_provider:is_available() then
    log.error("dataframe-preview: DAP provider is not available")
    return
  end

  local var_name = vim.fn.expand("<cword>")
  if var_name == "" then
    log.warn("dataframe-preview: cursor is not on a variable name")
    return
  end

  dap_provider:get_frame_id(function(frame_id, err)
    if err then
      log.error("dataframe-preview: " .. err)
      return
    end

    local meta_expr = lang_provider:metadata_expr(var_name)

    dap_provider:evaluate(meta_expr, frame_id, function(eval_err, result)
      if eval_err then
        log.error("dataframe-preview: failed to evaluate '" .. var_name .. "': " .. eval_err)
        return
      end

      local ok, metadata = pcall(lang_provider.parse_metadata, lang_provider, result)
      if not ok then
        log.error("dataframe-preview: '" .. var_name .. "' does not appear to be a DataFrame")
        return
      end

      local uuid = generate_uuid()
      session_store.create(uuid, {
        var_name = var_name,
        frame_id = frame_id,
        metadata = metadata,
      })

      server.ensure_started(dap_provider, lang_provider, function(port)
        local url = string.format("http://127.0.0.1:%d/?session=%s", port, uuid)
        log.info("dataframe-preview: opening " .. var_name .. " (" .. metadata.row_count .. " rows)")
        browser.open(url)
      end)
    end)
  end)
end

return M
