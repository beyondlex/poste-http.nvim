local state = require("poste.state")
local util = require("poste.util")

local M = {}

local function build_http_winbar()
  local left = string.format(" Env: %s ", state.current_env)
  local right = " <leader>vv switch "
  return "%#PosteSqlMeta#" .. left .. "%=" .. "%#PosteSqlMetaDim#" .. right
end

function M.set_env(env_name)
  state.current_env = env_name
  vim.notify("Environment switched to: " .. env_name, vim.log.levels.INFO)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ft = vim.bo[buf].filetype
    if ft == "poste_http" then
      vim.wo[win].winbar = build_http_winbar()
    end
  end
end

function M.get_env()
  return state.current_env
end

function M.pick_env()
  local search_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h")
  if search_dir == "" then search_dir = vim.fn.getcwd() end
  local env_file = util.find_file_upwards("env.json", search_dir)
  if not env_file then
    vim.notify("No env.json found", vim.log.levels.WARN, { title = "Poste" })
    return
  end
  local ok, data = pcall(vim.fn.readfile, env_file)
  if not ok or not data then
    vim.notify("Cannot read env.json", vim.log.levels.WARN, { title = "Poste" })
    return
  end
  local ok2, parsed = pcall(vim.json.decode, table.concat(data, "\n"))
  if not ok2 or type(parsed) ~= "table" then
    vim.notify("Cannot parse env.json", vim.log.levels.WARN, { title = "Poste" })
    return
  end
  local envs = {}
  for name, _ in pairs(parsed) do
    envs[#envs + 1] = name
  end
  table.sort(envs)
  if #envs == 0 then
    vim.notify("No environments found in env.json", vim.log.levels.WARN, { title = "Poste" })
    return
  end
  local select_mod = require("poste.select")
  select_mod.select(envs, "Select Environment", function(choice)
    if choice then M.set_env(choice) end
  end)
end

M.build_http_winbar = build_http_winbar

return M
