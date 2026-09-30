local state = require("poste-http.state")
local util = require("poste-http.util")
local winbar = require("poste-http.ui.winbar")
local notify = require("poste-http.ui.notify").notify

local M = {}

--- Is this buffer an HTTP request buffer? The filetype is the primary
--- signal; the .http/.rest NAME match covers a file open before its
--- filetype plugin ran (both callers must agree, or an env switch updates
--- windows that sync_winbar considers http, or vice versa).
local function is_http_buf(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return vim.bo[buf].filetype == "poste_http"
    or name:match("%.http$") ~= nil
    or name:match("%.rest$") ~= nil
end

local function build_http_winbar()
  return winbar.http_env(state.current_env)
end

--- Set the env winbar for windows showing http buffers, and clear it again
--- when such a window shows a non-http buffer (REVIEW-2026-09-06: the
--- plugin's BufEnter set vim.wo.winbar and never restored it). Called on
--- every BufEnter from plugin/poste.lua; set_env keeps live windows in
--- sync after an env switch.
function M.sync_winbar()
  local buf = vim.api.nvim_get_current_buf()
  local bar = winbar.http_env(state.current_env)
  if is_http_buf(buf) then
    vim.wo.winbar = bar
  elseif vim.wo.winbar == bar then
    -- Only clear a bar we set; never touch a user's own winbar. nil
    -- removes the window-local value, falling back to the global.
    vim.api.nvim_set_option_value("winbar", nil, { scope = "local" })
  end
end

--- Env names defined by the env.json discoverable from search_dir, or nil
--- when there is no readable env.json (walk-up miss, unreadable file, or a
--- payload that is not a JSON object). nil means "no known universe of
--- names" — validation is only meaningful when the file defines it.
local function discover_env_names(search_dir)
  local env_file = util.find_file_upwards("env.json", search_dir)
  if not env_file then return nil end
  local ok, data = pcall(vim.fn.readfile, env_file)
  if not ok or not data then return nil end
  local ok2, parsed = pcall(vim.json.decode, table.concat(data, "\n"))
  if not ok2 or type(parsed) ~= "table" then return nil end
  local names = {}
  for name in pairs(parsed) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

function M.set_env(env_name)
  -- A typo'd `:PosteHttpEnv prodX` used to switch silently; every {{var}}
  -- then resolved to nothing and the request went out with literal
  -- placeholders. When a readable env.json defines the universe of names,
  -- an unknown name is rejected with the valid ones. Without the file the
  -- switch stays permissive — vars may come from scripts or prompt vars.
  local buf_name = vim.api.nvim_buf_get_name(0)
  local search_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
  local names = discover_env_names(search_dir)
  if names and not vim.list_contains(names, env_name) then
    notify(string.format("Unknown environment '%s' — env.json defines: %s",
      env_name, table.concat(names, ", ")), vim.log.levels.WARN)
    return false
  end
  state.current_env = env_name
  notify("Environment switched to: " .. env_name, vim.log.levels.INFO)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if is_http_buf(buf) then
      vim.wo[win].winbar = build_http_winbar()
    end
  end
  return true
end

function M.get_env()
  return state.current_env
end

function M.pick_env()
  local buf_name = vim.api.nvim_buf_get_name(0)
  local search_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
  local env_file = util.find_file_upwards("env.json", search_dir)
  if not env_file then
    notify("No env.json found", vim.log.levels.WARN)
    return
  end
  -- discover_env_names reports nothing for an unreadable/unparsable file;
  -- say the file is broken rather than "no environments" (the file exists).
  local envs = discover_env_names(search_dir)
  if envs == nil then
    notify("Cannot parse env.json: " .. env_file, vim.log.levels.WARN)
    return
  end
  if #envs == 0 then
    notify("No environments found in env.json", vim.log.levels.WARN)
    return
  end
  local select_mod = require("poste-http.select")
  select_mod.select(envs, "Select Environment", function(choice)
    if choice then M.set_env(choice) end
  end)
end

M.build_http_winbar = build_http_winbar

return M
