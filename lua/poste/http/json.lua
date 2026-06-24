local state = require("poste.state")
local format = require("poste.http.format")

local M = {}

local hint_win = nil
local hint_buf = nil

local function close_hint()
  if hint_win and vim.api.nvim_win_is_valid(hint_win) then
    vim.api.nvim_win_close(hint_win, true)
    hint_win = nil
    hint_buf = nil
  end
end

local function show_hint_float(paths)
  close_hint()
  if #paths == 0 then return end

  hint_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(hint_buf, 0, -1, false, paths)
  vim.bo[hint_buf].modifiable = false

  local max_w = 0
  for _, p in ipairs(paths) do
    if #p > max_w then max_w = #p end
  end
  local width = math.min(max_w + 2, 64)
  local height = math.min(#paths, 12)

  local ui = vim.api.nvim_list_uis()[1]
  local row = math.floor(ui.height * 0.1)
  local col = ui.width - width - 1

  hint_win = vim.api.nvim_open_win(hint_buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Keys ",
    title_pos = "center",
  })
end

function M.get_key_paths()
  local r = state.last_response
  if not r or not r.body then return {} end
  local ok, data = pcall(vim.json.decode, r.body)
  if not ok or type(data) ~= "table" then return {} end

  local paths = {}
  local function walk(obj, prefix)
    if type(obj) ~= "table" then return end
    local is_array = #obj > 0
    if is_array then
      for i, v in ipairs(obj) do
        local p = prefix .. "[" .. tostring(i - 1) .. "]"
        table.insert(paths, p)
        walk(v, p)
      end
    else
      for k, v in pairs(obj) do
        local p = (#prefix > 0 and prefix .. "." or "") .. k
        table.insert(paths, p)
        walk(v, p)
      end
    end
  end
  walk(data, "")
  table.sort(paths)
  return paths
end

--- Open a float window with key paths as reference for jq input.
--- Float auto-closes when the returned close function is called.
--- @return function close_hint_fn
function M.open_key_hint()
  local paths = M.get_key_paths()
  if #paths > 0 then
    show_hint_float(paths)
  end
  return close_hint
end

function M.setup_buffer(buf)
  local win = vim.fn.bufwinid(buf)
  if win < 0 then return end
  vim.wo[win].foldmethod = "indent"
  vim.wo[win].foldlevel = 99
  vim.wo[win].foldcolumn = "1"
end

function M.apply_filter(query)
  local r = state.last_response
  if not r or not r.body then return end

  if not state._json.original_lines then
    local buf = require("poste.http.buffer").get_buf()
    state._json.original_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  local result
  if vim.fn.executable("jq") == 1 then
    local ok, output = pcall(vim.fn.system, { "jq", query, "-r" }, r.body)
    if ok then
      local parsed, _ = pcall(vim.json.decode, output)
      if parsed then
        result = format.pretty_body(output, "application/json")
      else
        result = output
      end
    else
      vim.notify("jq error: " .. (output or "unknown"), vim.log.levels.ERROR)
      return
    end
  else
    result = M._jsonpath_query(r.body, query)
  end

  if not result then return end

  local buf = require("poste.http.buffer").get_buf()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result, "\n"))
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  state._json.query = query
  state._json.is_filtered = true

  require("poste.http.buffer").update_winbar(state.current_view)
end

function M.restore_original()
  if not state._json.original_lines then return end

  local buf = require("poste.http.buffer").get_buf()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, state._json.original_lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  state._json.original_lines = nil
  state._json.query = nil
  state._json.is_filtered = false

  require("poste.http.buffer").update_winbar(state.current_view)
end

function M._jsonpath_query(body, query)
  local ok, data = pcall(vim.json.decode, body)
  if not ok then
    vim.notify("Invalid JSON body", vim.log.levels.ERROR)
    return nil
  end

  local steps = {}
  for step in query:gmatch("[^.]+") do
    table.insert(steps, step)
  end

  local current = data
  for _, step in ipairs(steps) do
    if type(current) ~= "table" then
      vim.notify("Cannot traverse: value is " .. type(current), vim.log.levels.WARN)
      return nil
    end

    local idx = step:match("^%[(%d+)%]$")
    if idx then
      current = current[tonumber(idx) + 1]
    elseif step:match("^%[%]$") then
      local results = {}
      for _, item in ipairs(current) do
        table.insert(results, item)
      end
      current = results
    else
      local key = step:match("^%.(.+)") or step
      if current[key] ~= nil then
        current = current[key]
      else
        vim.notify("Key '" .. key .. "' not found", vim.log.levels.WARN)
        return nil
      end
    end
  end

  return format.pretty_body(vim.json.encode(current), "application/json")
end

return M
