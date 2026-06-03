-- Minimal Neovim configuration for running tests
-- This file is loaded by plenary before running tests

-- Add the plugin to runtime path
vim.opt.runtimepath:append(".")

-- Set up a dummy buffer for tests that need it
vim.api.nvim_buf_set_option(0, "filetype", "poste_http")
