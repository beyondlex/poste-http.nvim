-- Poste plugin loader
-- This file is automatically loaded by Neovim when the plugin is installed

-- Ensure the plugin's lua directory is in package.path
local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local lua_path = plugin_dir .. "/lua/?.lua;" .. plugin_dir .. "/lua/?/init.lua"
if not package.path:find(lua_path, 1, true) then
  package.path = lua_path .. ";" .. package.path
end

require("poste").setup()
