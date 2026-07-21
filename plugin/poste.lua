-- Poste plugin loader — HTTP request executor.
-- Requires poste-core.nvim for shared infrastructure.

-- Check poste-core is installed
local core_ok, _ = pcall(require, "poste.core")
if not core_ok then
  vim.notify("poste.nvim requires poste-core.nvim. Install it first.", vim.log.levels.ERROR)
  return
end

-- Ensure the plugin's lua directory is in package.path
local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local lua_path = plugin_dir .. "/lua/?.lua;" .. plugin_dir .. "/lua/?/init.lua"
if not package.path:find(lua_path, 1, true) then
  package.path = lua_path .. ";" .. package.path
end

-- Generate helptags so :h poste works
local doc_dir = plugin_dir .. "/doc"
if vim.fn.isdirectory(doc_dir) == 1 then
  pcall(vim.cmd.helptags, doc_dir)
end

-- Ensure the Rust CLI binary is installed (downloads if missing)
local install_ok, install = pcall(require, "poste.install")
if install_ok then
  install.ensure()
end

require("poste").setup()

-- PosteInfo: show binary, version, and completion engine status.
-- Defined here rather than in setup() so the latest plugin/poste.lua
-- on rtp always wins, even when lazy.nvim cached an older init.lua.
pcall(vim.api.nvim_del_user_command, "PosteInfo")
vim.api.nvim_create_user_command("PosteInfo", function()
  local state = require("poste.state")
  local binary = state.find_poste_binary()
  local binary_path = binary or "(not found)"
  local version = "(unknown)"
  if binary then
    local ok, output = pcall(vim.fn.system, { binary, "--version" })
    if ok then
      version = vim.trim(output)
    end
  end

  local sep = "─"
  local parts = { sep }

  table.insert(parts, "binary:  " .. binary_path)
  table.insert(parts, "version: " .. version)
  table.insert(parts, sep)

  local blink_ok = pcall(require, "blink.cmp")
  if blink_ok then
    local providers = {}
    local config_ok, config = pcall(require, "blink.cmp.config")
    if config_ok and config.sources and config.sources.providers then
      for id, _ in pairs(config.sources.providers) do
        table.insert(providers, id)
      end
    end
    local has_poste = vim.tbl_contains(providers, "poste") and "yes" or "no"
    table.insert(parts, "blink.cmp: loaded")
    table.insert(parts, "  providers:  " .. (#providers > 0 and table.concat(providers, ", ") or "(none)"))
    table.insert(parts, "  poste src:  " .. has_poste)
  else
    table.insert(parts, "blink.cmp: not loaded")
  end

  local cmp_ok = pcall(require, "cmp")
  if cmp_ok then
    table.insert(parts, "nvim-cmp:   loaded")
  end

  local completion_ok, completion = pcall(require, "poste.http.completion")
  if completion_ok then
    table.insert(parts, "poste cmp:  " .. completion.status())
  end

  local ft = vim.bo.filetype or "(none)"
  table.insert(parts, "filetype:   " .. ft)
  table.insert(parts, sep)

  vim.notify(table.concat(parts, "\n"), vim.log.levels.INFO)
end, { desc = "Show Poste environment info" })
