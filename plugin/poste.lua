-- Poste plugin loader — HTTP request executor.

-- Preload our core modules into package.loaded so they are cached before
-- any other plugin can load their own versions.
require("poste-http.state")
require("poste-http.constants")
require("poste-http.util")
require("poste-http.event")
require("poste-http.buffer_setup")
require("poste-http.help")
require("poste-http.select")
require("poste-http.indicators")

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

require("poste-http").setup()

-- Ensure all Poste* highlight groups are defined (for tree-sitter).
pcall(require, "poste-http.http.highlights")

-- Register filetype autocmd and treesitter for .http/.rest files.
local buffer_setup = require("poste-http.buffer_setup")
vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
  pattern = { "*.http", "*.rest" },
  callback = function()
    vim.bo.filetype = "poste_http"
    buffer_setup.setup_buffer_keymaps(0)
    buffer_setup.attach_boundary(vim.api.nvim_get_current_buf())
    pcall(function()
      require("poste-http.http.treesitter").enable(0)
    end)
  end,
})

vim.api.nvim_create_autocmd("BufEnter", {
  pattern = { "*.http", "*.rest" },
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo.filetype == "poste_http" then
      require("poste-http.http.boundary_indicator").refresh(buf, vim.fn.line("."))
      -- proactively warm the gRPC completion index when the cursor sits in
      -- a GRPC block (cheap no-op otherwise)
      pcall(function()
        require("poste-http.http.grpc_proto").prewarm_for_cursor(buf, vim.fn.line("."))
      end)
    end
  end,
})

-- Set the env winbar for http buffers and restore it when a window goes
-- back to a non-http buffer (env.sync_winbar clears only bars it set).
vim.api.nvim_create_autocmd("BufEnter", {
  pattern = "*",
  callback = function()
    require("poste-http.http.env").sync_winbar()
  end,
})

for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  local name = vim.api.nvim_buf_get_name(buf)
  if name:match("%.http$") or name:match("%.rest$") then
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_http")
    buffer_setup.setup_buffer_keymaps(buf)
    buffer_setup.attach_boundary(buf)
  end
end

-- PosteHttpInfo: show binary, version, and completion engine status.
-- (PosteTree was a duplicate of PosteHttpTSInspect and was removed.)
pcall(vim.api.nvim_del_user_command, "PosteHttpInfo")

vim.api.nvim_create_user_command("PosteHttpInfo", function()
  local sep = "─"
  local parts = { sep }

  local curl_ok = vim.fn.executable("curl") == 1
  table.insert(parts, "curl:      " .. (curl_ok and "found" or "not found"))

  local parser_dir = vim.fn.stdpath("data") .. "/site/parser"
  local ts_ok, _ = pcall(vim.treesitter.get_parser, 0, "poste_http")
  local ts_file = (vim.fn.filereadable(parser_dir .. "/poste_http.so") == 1) and "installed" or "missing"
  table.insert(parts, "treesitter: " .. (ts_ok and "active" or "unavailable") .. " (" .. ts_file .. ")")

  local ts_json_ok, _ = pcall(vim.treesitter.get_parser, 0, "poste_json")
  local ts_json_file = (vim.fn.filereadable(parser_dir .. "/poste_json.so") == 1) and "installed" or "missing"
  table.insert(parts, "poste_json:" .. (ts_json_ok and "active" or "unavailable") .. " (" .. ts_json_file .. ")")

  local ts_graphql_ok, _ = pcall(vim.treesitter.get_parser, 0, "poste_graphql")
  local ts_graphql_file = (vim.fn.filereadable(parser_dir .. "/poste_graphql.so") == 1) and "installed" or "missing"
  table.insert(parts, "poste_graphql:" .. (ts_graphql_ok and "active" or "unavailable") .. " (" .. ts_graphql_file .. ")")

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

  local completion_ok, completion = pcall(require, "poste-http.http.completion")
  if completion_ok then
    table.insert(parts, "poste cmp:  " .. completion.status())
  end

  local ft = vim.bo.filetype or "(none)"
  table.insert(parts, "filetype:   " .. ft)
  table.insert(parts, sep)

  vim.notify(table.concat(parts, "\n"), vim.log.levels.INFO)
end, { desc = "Show Poste HTTP environment info" })

vim.api.nvim_create_user_command("PosteHttpBuildParsers", function()
  require("poste-http.install").force_build()
end, { desc = "Compile tree-sitter parsers for poste-http" })

vim.api.nvim_create_user_command("PosteHttpTSStatus", function()
  local state = require("poste-http.state")
  local ts = state.config.use_treesitter or {}
  local buf = vim.api.nvim_get_current_buf()
  local parser_ok = require("poste-http.http.ts_query").is_available(buf)
  local ft = vim.bo[buf].filetype

  local lines = {
    "─ tree-sitter status ─",
    string.format("filetype:      %s", ft),
    string.format("parser active: %s", parser_ok and "yes" or "no"),
    string.format("nav:           %s", ts.nav and "tree-sitter" or "regex"),
    string.format("context_det:   %s", ts.context_detector and "tree-sitter" or "regex"),
    string.format("outline:       %s", ts.outline and "tree-sitter" or "regex"),
    string.format("folding:       %s", ts.folding and "tree-sitter" or "regex"),
    string.format("diagnostics:   %s", ts.diagnostics and "tree-sitter" or "regex"),
    "─",
  }
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, { desc = "Show tree-sitter feature status" })
