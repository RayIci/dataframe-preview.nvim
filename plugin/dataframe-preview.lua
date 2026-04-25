-- Thin entrypoint — only guards against double-loading.
if vim.g.loaded_dataframe_preview then return end
vim.g.loaded_dataframe_preview = true
