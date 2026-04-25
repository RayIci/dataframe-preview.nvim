local M = {}

-- WSL (Windows Subsystem for Linux) is detected via the WSL_DISTRO_NAME
-- environment variable, which is always set by the WSL runtime.
-- We check this separately from get_os() because WSL reports as "unix"
-- but needs different handling (e.g. opening a browser via cmd.exe).
function M.is_wsl()
  return vim.env.WSL_DISTRO_NAME ~= nil
end

---@return "windows" | "mac" | "unix" | "unknown"
function M.get_os()
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    return "windows"
  elseif vim.fn.has("mac") == 1 then
    return "mac"
  elseif vim.fn.has("unix") == 1 then
    return "unix"
  end
  return "unknown"
end

function M.is_windows()
  return M.get_os() == "windows"
end
function M.is_mac()
  return M.get_os() == "mac"
end
function M.is_unix()
  return M.get_os() == "unix"
end

return M
