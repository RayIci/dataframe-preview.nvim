local os_utils = require("dataframe-preview.utils.os")
local log = require("dataframe-preview.utils.logging")

local M = {}

---Opens a URL in the system default browser without blocking Neovim.
---@param url string
function M.open(url)
  local os = os_utils.get_os()
  local cmd

  if os == "mac" then
    cmd = { "open", url }
  elseif os == "windows" then
    cmd = { "cmd", "/c", "start", "", url }
  else
    cmd = { "xdg-open", url }
  end

  local handle
  handle = vim.uv.spawn(cmd[1], {
    args = vim.list_slice(cmd, 2),
    detached = true,
  }, function()
    if handle then
      handle:close()
    end
  end)

  if not handle then
    log.error("browser: failed to open URL: " .. url)
  end
end

return M
