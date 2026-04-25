local M = {}

---Registers the :PreviewDataFrame user command.
---@param preview_fn fun()
function M.register(preview_fn)
  vim.api.nvim_create_user_command("PreviewDataFrame", function()
    preview_fn()
  end, {
    desc = "Preview the DataFrame variable under the cursor in a browser",
    nargs = 0,
  })
end

return M
