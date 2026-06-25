local state = require("poste.state")
local format = require("poste.http.format")
local assertions = require("poste.http.assertions")
local scripts = require("poste.http.scripts")

local M = {}

local list_buf = nil
local list_win = nil
local list_width = 36
local detail_buf = nil
local detail_win = nil
local current_index = nil
local detail_view = "body"
local detail_jq_query = nil
local hiding = false
local list_ns = vim.api.nvim_create_namespace("poste_history_list")

local MAX_BODY_SAVE = 100 * 1024

function M.get_history_path()
  return vim.fn.stdpath("data") .. "/poste/http_history.json"
end

function M.load_from_disk()
  if state.http_history_loaded then return end
  state.http_history_loaded = true
  local path = M.get_history_path()
  local ok, f = pcall(io.open, path, "r")
  if not ok or not f then return end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then return end
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return end
  if data.version ~= 1 then return end
  state.http_history_id_counter = data.id_counter or 0
  state.http_history_max = data.max_entries or 100
  state.http_history = data.entries or {}
end

function M.save_to_disk()
  local data = {
    version = 1,
    id_counter = state.http_history_id_counter,
    max_entries = state.http_history_max,
    entries = state.http_history,
  }
  local path = M.get_history_path()
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then return end
  local f, err = io.open(path, "w")
  if not f then
    state.log("ERROR", "Failed to write history: " .. (err or "unknown"))
    return
  end
  f:write(encoded)
  f:close()
end

local function truncate_response(response)
  if not response or type(response) ~= "table" then return response end
  local r = vim.deepcopy(response)
  if r.body and type(r.body) == "string" and #r.body > MAX_BODY_SAVE then
    r.body = r.body:sub(1, MAX_BODY_SAVE) .. "\n... [truncated " .. #r.body .. " bytes]"
  end
  return r
end

function M.add_entry(name, response, assertion_results, script_logs, source_file)
  M.load_from_disk()

  state.http_history_id_counter = state.http_history_id_counter + 1
  local entry = {
    id = state.http_history_id_counter,
    name = name,
    time = os.time(),
    source_file = source_file or "",
    response = truncate_response(response),
    assertion_results = assertion_results and vim.deepcopy(assertion_results) or nil,
    script_logs = script_logs and vim.deepcopy(script_logs) or nil,
  }

  table.insert(state.http_history, 1, entry)

  if #state.http_history > state.http_history_max then
    table.remove(state.http_history)
  end

  M.save_to_disk()
end

function M.delete_entry(id)
  M.load_from_disk()
  for i, entry in ipairs(state.http_history) do
    if entry.id == id then
      table.remove(state.http_history, i)
      break
    end
  end
  M.save_to_disk()
end

local function format_timestamp(time)
  if not time then return "" end
  return os.date("%H:%M", time)
end

local function get_active_tabs()
  local entry = state.http_history[current_index]
  if not entry then return {} end
  local tabs = {
    { id = "body", label = "Body [H]" },
    { id = "request", label = "Rqst [R]" },
    { id = "verbose", label = "Verb [L]" },
  }
  if entry.assertion_results then
    table.insert(tabs, { id = "assertions", label = "Asserts [A]" })
  end
  if entry.script_logs and #entry.script_logs > 0 then
    table.insert(tabs, { id = "script_logs", label = "Script [S]" })
  end
  return tabs
end

local function update_winbar()
  if not detail_win or not vim.api.nvim_win_is_valid(detail_win) then return end
  local tabs = get_active_tabs()
  local parts = {}
  for _, tab in ipairs(tabs) do
    if tab.id == detail_view then
      table.insert(parts, "%#TabLineSel# " .. tab.label .. " %*")
    else
      table.insert(parts, "%#TabLine# " .. tab.label .. " %*")
    end
  end
  vim.wo[detail_win].winbar = table.concat(parts)
end

local function render_detail()
  if not detail_buf or not vim.api.nvim_buf_is_valid(detail_buf) then return end
  local entry = state.http_history[current_index]
  if not entry then
    vim.api.nvim_buf_set_option(detail_buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(detail_buf, 0, -1, false, { "(no history)" })
    vim.api.nvim_buf_set_option(detail_buf, "modifiable", false)
    vim.bo[detail_buf].filetype = "text"
    update_winbar()
    return
  end

  local lines, filetype
  local r = entry.response

  if detail_view == "body" then
    if not r or not r.body or r.body == "" then
      lines = { "(no response body)" }
      filetype = "text"
    else
      lines = format.format_body(r)
      filetype = format.detect_filetype(r.content_type)
    end
  elseif detail_view == "verbose" then
    lines = format.format_verbose(r)
    filetype = "markdown"
  elseif detail_view == "assertions" then
    lines = assertions.format_assertions(entry.assertion_results)
    filetype = "markdown"
  elseif detail_view == "script_logs" then
    lines = scripts.format_script_logs(entry.script_logs)
    filetype = "markdown"
  elseif detail_view == "request" then
    lines = format.format_request_payload(r)
    local ct = ""
    local req_headers = r.metadata and r.metadata.request_headers
    if req_headers then
      for l in req_headers:gmatch("[^\r\n]+") do
        local k, v = l:match("^([^:]+):%s*(.+)$")
        if k and k:lower() == "content-type" then ct = v end
      end
    end
    filetype = (ct:lower():find("multipart/form%-data")) and "markdown" or format.detect_filetype(ct)
  else
    lines = { "Unknown view: " .. detail_view }
    filetype = "text"
  end

  vim.api.nvim_buf_set_option(detail_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(detail_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(detail_buf, "modifiable", false)
  vim.bo[detail_buf].filetype = filetype or "text"
  pcall(vim.api.nvim_win_set_cursor, detail_win, { 1, 0 })
  update_winbar()

  if filetype == "json" then
    local json = require("poste.http.json")
    json.setup_buffer(detail_buf)
  end

  if detail_view == "body" and (not r or not r.body or r.body == "") then
    local ns = vim.api.nvim_create_namespace("poste_history_hint")
    vim.api.nvim_buf_clear_namespace(detail_buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(detail_buf, ns, 0, 0, {
      end_col = #lines[1],
      hl_group = "Comment",
    })
  end

  if detail_view == "verbose" and r and r.status then
    local ns = vim.api.nvim_create_namespace("poste_history_status")
    vim.api.nvim_buf_clear_namespace(detail_buf, ns, 0, -1)
    local hl_group
    local sc = r.status
    if sc < 300 then hl_group = "PosteStatus2xx"
    elseif sc < 400 then hl_group = "PosteStatus3xx"
    elseif sc < 500 then hl_group = "PosteStatus4xx"
    else hl_group = "PosteStatus5xx"
    end
    for i, line in ipairs(lines) do
      local status_start, status_end = line:find("%*%*.-%*%*")
      if status_start then
        vim.api.nvim_buf_set_extmark(detail_buf, ns, i - 1, status_start - 1, {
          end_col = status_end,
          hl_group = hl_group,
          priority = 200,
        })
        break
      end
    end
  end

  detail_jq_query = nil
end

local function render_list()
  if not list_buf or not vim.api.nvim_buf_is_valid(list_buf) then return end
  local lines = {}
  local name_width = list_width - 6

  vim.api.nvim_buf_clear_namespace(list_buf, list_ns, 0, -1)

  if #state.http_history == 0 then
    lines = { "(no history)" }
  else
    for _, entry in ipairs(state.http_history) do
      local name = entry.name
      if #name > name_width then
        name = name:sub(1, name_width - 3) .. "..."
      end
      local ts = format_timestamp(entry.time)
      local line = string.format("%-" .. name_width .. "s %s", name, ts)
      table.insert(lines, line)
    end
  end

  vim.api.nvim_buf_set_option(list_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(list_buf, "modifiable", false)
  vim.bo[list_buf].filetype = "poste_history_list"

  -- Gray timestamp via extmarks
  for i, line in ipairs(lines) do
    local ts_start = line:match("^.*() %d%d:%d%d$")
    if ts_start then
      vim.api.nvim_buf_set_extmark(list_buf, list_ns, i - 1, ts_start + 1, {
        end_col = #line,
        hl_group = "Comment",
        priority = 100,
      })
    end
  end

  if current_index == nil and #state.http_history > 0 then
    current_index = 1
  end

  if current_index and current_index <= #state.http_history then
    pcall(vim.api.nvim_win_set_cursor, list_win, { current_index, 0 })
  end
end

local function hide()
  if hiding then return end
  hiding = true
  if list_win and vim.api.nvim_win_is_valid(list_win) then
    vim.api.nvim_win_close(list_win, true)
  end
  if detail_win and vim.api.nvim_win_is_valid(detail_win) then
    vim.api.nvim_win_close(detail_win, true)
  end
  list_buf = nil
  list_win = nil
  detail_buf = nil
  detail_win = nil
  current_index = nil
  detail_view = "body"
  detail_jq_query = nil
  hiding = false
end

local function navigate_list(direction)
  if #state.http_history == 0 then return end
  if current_index == nil then
    current_index = direction > 0 and 1 or #state.http_history
  else
    current_index = current_index + direction
    if current_index < 1 then current_index = #state.http_history
    elseif current_index > #state.http_history then current_index = 1 end
  end
  pcall(vim.api.nvim_win_set_cursor, list_win, { current_index, 0 })
  render_detail()
end

local function delete_at_cursor()
  if #state.http_history == 0 or not current_index then return end
  local entry = state.http_history[current_index]
  M.delete_entry(entry.id)
  if current_index > #state.http_history then
    current_index = #state.http_history
  end
  render_list()
  render_detail()
end

local function switch_tab(tab_id)
  detail_view = tab_id
  render_detail()
end

local function cycle_tab(direction)
  local tabs = get_active_tabs()
  if #tabs == 0 then return end
  local idx = 1
  for i, tab in ipairs(tabs) do
    if tab.id == detail_view then idx = i end
  end
  local next = ((idx - 1 + direction) % #tabs) + 1
  detail_view = tabs[next].id
  render_detail()
end

local function focus_detail()
  if detail_win and vim.api.nvim_win_is_valid(detail_win) then
    vim.api.nvim_set_current_win(detail_win)
  end
end

local function wincmd_list()
  if list_win and vim.api.nvim_win_is_valid(list_win) then
    vim.api.nvim_set_current_win(list_win)
  end
end

local function wincmd_detail()
  if detail_win and vim.api.nvim_win_is_valid(detail_win) then
    vim.api.nvim_set_current_win(detail_win)
  end
end

local function setup_detail_keymaps()
  local opts = { buffer = detail_buf, noremap = true, silent = true }

  local k = state.get_keymap("http_response", "close", "q")
  if k then vim.keymap.set("n", k, hide, opts) end

  k = state.get_keymap("http_response", "view_body", "H")
  if k then vim.keymap.set("n", k, function() switch_tab("body") end, opts) end

  k = state.get_keymap("http_response", "view_request", "R")
  if k then vim.keymap.set("n", k, function() switch_tab("request") end, opts) end

  k = state.get_keymap("http_response", "view_verbose", "I")
  if k then vim.keymap.set("n", k, function() switch_tab("verbose") end, opts) end

  k = state.get_keymap("http_response", "view_assertions", "A")
  if k then vim.keymap.set("n", k, function() switch_tab("assertions") end, opts) end

  k = state.get_keymap("http_response", "view_script_logs", "S")
  if k then vim.keymap.set("n", k, function() switch_tab("script_logs") end, opts) end

  k = state.get_keymap("http_response", "next_tab", "<Tab>")
  if k then vim.keymap.set("n", k, function() cycle_tab(1) end, opts) end

  k = state.get_keymap("http_response", "prev_tab", "<S-Tab>")
  if k then vim.keymap.set("n", k, function() cycle_tab(-1) end, opts) end

  local nopts = { buffer = detail_buf, noremap = true, silent = true, nowait = true }
  vim.keymap.set("n", "<C-W>h", wincmd_list, nopts)

  k = state.get_keymap("http_response", "json_filter", "<leader>j")
  if k then
    vim.keymap.set("n", k, function()
      if vim.bo[detail_buf].filetype ~= "json" then return end
      local entry = state.http_history[current_index]
      if not entry then return end
      local saved = state.last_response
      state.last_response = entry.response
      require("poste.http.json").start_interactive_input()
      entry.response = state.last_response
      state.last_response = saved
      render_detail()
    end, opts)
  end

  k = state.get_keymap("http_response", "json_restore", "<leader>jc")
  if k then
    vim.keymap.set("n", k, function()
      local entry = state.http_history[current_index]
      if not entry then return end
      local json = require("poste.http.json")
      json.restore_original()
      render_detail()
    end, opts)
  end
end

local function setup_list_keymaps()
  local opts = { buffer = list_buf, noremap = true, silent = true }

  local k = state.get_keymap("http_history", "close", "q")
  if k then vim.keymap.set("n", k, hide, opts) end

  k = state.get_keymap("http_history", "delete_entry", "dd")
  if k then vim.keymap.set("n", k, delete_at_cursor, opts) end

  k = state.get_keymap("http_history", "focus_detail", "<CR>")
  if k then vim.keymap.set("n", k, focus_detail, opts) end

  vim.keymap.set("n", "j", function() navigate_list(1) end, opts)
  vim.keymap.set("n", "k", function() navigate_list(-1) end, opts)

  local nopts = { buffer = list_buf, noremap = true, silent = true, nowait = true }
  vim.keymap.set("n", "<C-W>l", wincmd_detail, nopts)

  vim.api.nvim_buf_attach(list_buf, false, {
    on_detach = function()
      hide()
    end,
  })
end

function M.show()
  M.load_from_disk()

  if list_win and vim.api.nvim_win_is_valid(list_win) then
    pcall(vim.api.nvim_set_current_win, list_win)
    return
  end

  local editor_width = vim.o.columns
  local editor_height = vim.o.lines
  local total_width = math.floor(editor_width * 0.92)
  local total_height = math.floor(editor_height * 0.88)
  local top = math.floor((editor_height - total_height) / 2)
  local left = math.floor((editor_width - total_width) / 2)
  list_width = 36
  local gap = 1

  list_buf = vim.api.nvim_create_buf(false, true)
  list_win = vim.api.nvim_open_win(list_buf, true, {
    relative = "editor",
    width = list_width,
    height = total_height,
    row = top,
    col = left,
    style = "minimal",
    border = "single",
    title = " Poste HTTP History ",
    title_pos = "center",
  })
  vim.wo[list_win].cursorline = true

  local detail_width = total_width - list_width - gap - 1
  detail_buf = vim.api.nvim_create_buf(false, true)
  detail_win = vim.api.nvim_open_win(detail_buf, false, {
    relative = "editor",
    width = detail_width,
    height = total_height,
    row = top,
    col = left + list_width + gap,
    style = "minimal",
    border = "single",
  })

  current_index = nil
  detail_view = "body"

  setup_list_keymaps()
  setup_detail_keymaps()

  render_list()
  render_detail()

  pcall(vim.api.nvim_set_current_win, list_win)
end

return M