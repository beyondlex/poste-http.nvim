local state = require("poste.state")
local format = require("poste.http.format")

local M = {}
local hl_ns = vim.api.nvim_create_namespace("poste_jq_input")

local function filter_paths(paths, input)
  if not input or input == "" then return paths end
  local lower = input:lower()
  local results = {}
  for _, p in ipairs(paths) do
    if p:lower():find(lower, 1, true) then
      table.insert(results, p)
    end
  end
  return results
end

--- Interactive jq input with a completion dropdown.
--- Float shows input line + filtered key paths; Tab/arrows to navigate, Enter to confirm.
function M.start_interactive_input()
  local paths = M.get_key_paths()
  if #paths == 0 then
    vim.ui.input({ prompt = "jq> " }, function(query)
      if query and query ~= "" then M.apply_filter(query) end
    end)
    return
  end

  local input = ""
  local matches = paths
  local selected = 0
  local float_buf = vim.api.nvim_create_buf(false, true)
  local float_win

  local function redraw()
    matches = filter_paths(paths, input)
    local lines = { "jq> " .. input .. "█" }
    for i, p in ipairs(matches) do
      if #lines >= 15 then break end
      lines[#lines + 1] = "  " .. p
    end
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)

    vim.api.nvim_buf_clear_namespace(float_buf, hl_ns, 0, -1)
    if selected > 0 then
      vim.api.nvim_buf_add_highlight(float_buf, hl_ns, "Visual", selected, 0, -1)
    end
  end

  local max_w = 0
  for _, p in ipairs(paths) do
    if #p + 3 > max_w then max_w = #p + 3 end
  end
  local width = math.min(math.max(max_w, 14), 64)
  local height = math.min(#paths + 1, 15)

  float_win = vim.api.nvim_open_win(float_buf, false, {
    relative = "cursor",
    width = width,
    height = height,
    row = 1,
    col = 0,
    style = "minimal",
    border = "rounded",
    title = " jq ",
    title_pos = "center",
    focusable = false,
  })

  redraw()
  vim.cmd("redraw")

  while true do
    local char = vim.fn.getchar()
    local t = type(char)
    local c = t == "number" and vim.fn.nr2char(char) or tostring(char)

    if c == "\r" or c == "\n" then
      local query = selected > 0 and selected <= #matches and matches[selected] or input
      pcall(vim.api.nvim_win_close, float_win, true)
      if query and query ~= "" then M.apply_filter(query) end
      return

    elseif c == "\x1b" then
      pcall(vim.api.nvim_win_close, float_win, true)
      return

    elseif c == "\t" or c == "\x0e" or c == "<Down>" then
      if #matches > 0 then selected = (selected % #matches) + 1 end
      redraw()

    elseif c == "\x10" or c == "<Up>" then
      if #matches > 0 then selected = (selected - 2) % #matches + 1 end
      redraw()

    elseif c == "\x7f" or c == "\x08" or c == "<BS>" then
      if #input > 0 then
        input = input:sub(1, -2)
        selected = 0
        redraw()
      end

    elseif t == "number" and char >= 32 then
      input = input .. c
      selected = 0
      redraw()
    end
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
