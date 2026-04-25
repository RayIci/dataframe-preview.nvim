-- Minimal Neovim config for running plenary tests headlessly.
local plenary_path = vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")
vim.opt.rtp:prepend(plenary_path)
vim.opt.rtp:prepend(vim.fn.getcwd()) -- add plugin root so require("dataframe-preview.*") works
