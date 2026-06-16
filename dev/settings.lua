-- dev/settings.lua — General Neovim options
--
-- vim.opt / vim.g / keymaps etc.  Edit freely, loaded live on every start.
--
-- Examples:
--   vim.opt.number = true
--   vim.opt.tabstop = 2
--   vim.opt.shiftwidth = 2
--   vim.opt.expandtab = true
--   vim.opt.mouse = "a"
vim.g.mapleader = " "
vim.opt.laststatus = 3

-- vim.keymap.set("n", "<leader>e", function() Snacks.explorer() end)
vim.keymap.set("n", "<C-l>", "<C-W>l")
vim.keymap.set("n", "<C-h>", "<C-W>h")
vim.keymap.set("n", "<C-j>", "<C-W>j")
vim.keymap.set("n", "<C-k>", "<C-W>k")

