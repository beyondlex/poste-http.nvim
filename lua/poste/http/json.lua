local state = require("poste.state")
local format = require("poste.http.format")

local M = {}

--- Select a jq query from key paths or type a custom one.
--- Uses vim.ui.select for path picking, vim.ui.input for custom queries.
function M.start_interactive_input()
  -- Already filtered: go straight to input with current query pre-filled
  if state._json.query then
    vim.ui.input({ prompt = "jq> ", default = state._json.query }, function(query)
      if query and query ~= "" then M.apply_filter(query) end
    end)
    return
  end

  local paths = M.get_key_paths()
  if #paths > 0 then
    local items = vim.list_extend({}, paths)
    vim.ui.select(items, {
      prompt = "jq filter",
      format_item = function(item) return item end,
    }, function(choice)
      if choice then
        M.apply_filter(choice)
      end
    end)
  else
    vim.ui.input({ prompt = "jq> ", default = state._json.query or "" }, function(query)
      if query and query ~= "" then M.apply_filter(query) end
    end)
  end
end

function M.get_key_paths()
  local r = state.last_response
  if not r or not r.body then return {} end
  local ok, data = pcall(vim.json.decode, r.body)
  if not ok or type(data) ~= "table" then return {} end

  local paths = {}
  local function walk(obj, prefix)
    if type(obj) ~= "table" then return end
    local is_arr = #obj > 0
    if is_arr then
      local wild = prefix .. "[]"
      table.insert(paths, wild)
      if #obj > 0 then
        walk(obj[1], wild)
      end
      for i, v in ipairs(obj) do
        local p = prefix .. "[" .. tostring(i - 1) .. "]"
        table.insert(paths, p)
        walk(v, p)
      end
    else
      for k, v in pairs(obj) do
        local p = prefix .. "." .. k
        table.insert(paths, p)
        walk(v, p)
      end
    end
  end
  if #data > 0 then
    walk(data, ".")
  else
    for k, v in pairs(data) do
      local p = "." .. k
      table.insert(paths, p)
      walk(v, p)
    end
  end
  table.sort(paths)
  return paths
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
