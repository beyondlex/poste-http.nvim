--- SQL Execution Log Viewer
--- Reads sql_log.jsonl, renders entries in a buffer with expand/collapse.
local M = {}

local ns = vim.api.nvim_create_namespace("poste_sql_log")
local buf = nil
local win = nil
local entries = {}
local expanded = {}
local filter_text = ""

local function get_log_path()
  return vim.fn.stdpath("data") .. "/poste/sql_log.jsonl"
end

local function load_entries()
  local path = get_log_path()
  local file = io.open(path, "r")
  if not file then return {} end
  local result = {}
  for line in file:lines() do
    if line ~= "" then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and entry then
        table.insert(result, entry)
      end
    end
  end
  file:close()
  table.sort(result, function(a, b) return (a.ts or "") > (b.ts or "") end)
  return result
end

local function filter_matches(entry)
  if filter_text == "" then return true end
  local lower = filter_text:lower()
  if (entry.table or ""):lower():find(lower, 1, true) then return true end
  if (entry.connection or ""):lower():find(lower, 1, true) then return true end
  if (entry.status or ""):lower():find(lower, 1, true) then return true end
  if (entry.database or ""):lower():find(lower, 1, true) then return true end
  if (entry.sql or ""):lower():find(lower, 1, true) then return true end
  return false
end
M._filter_matches = filter_matches

local function format_time(ts)
  if not ts then return "??:??:??" end
  local t = ts:match("T(%d+:%d+:%d+)")
  if t then return t end
  t = ts:match("T(%d+:%d+)")
  return t or ts
end
M._format_time = format_time

local function preview_sql(sql, max_len)
  if not sql or sql == "" then return "" end
  local s = sql:gsub("\n", "\\n")
  if #s <= max_len then return s end
  return s:sub(1, max_len - 1) .. "…"
end
M._preview_sql = preview_sql

local function clean_sql(sql)
  if not sql then return "" end
  local lines = {}
  for line in (sql .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed and not trimmed:match("^%-%-%s*@") and trimmed ~= "###" then
      table.insert(lines, line)
    end
  end
  return table.concat(lines, "\n")
end
M._clean_sql = clean_sql

local function guess_table(sql)
  if not sql then return nil end
  local patterns = {
    "FROM%s+([%w_]+)",
    "JOIN%s+([%w_]+)",
    "UPDATE%s+([%w_]+)",
    "INTO%s+([%w_]+)",
    "DELETE%s+FROM%s+([%w_]+)",
    "INSERT%s+INTO%s+([%w_]+)",
  }
  for _, pat in ipairs(patterns) do
    local t = sql:match(pat)
    if t then return t end
  end
  return nil
end
M._guess_table = guess_table

local function entry_table(entry)
  if entry.table and entry.table ~= "" then return entry.table end
  if entry.table_name and entry.table_name ~= "" then return entry.table_name end
  return guess_table(entry.sql)
end
M._entry_table = entry_table

local function count_detail_lines(entry)
  local n = 1
  if entry.connection or entry.database or entry.source then
    n = n + 1
  end
  if entry.edit_summary then
    n = n + 1
  end
  local sql_lines = 1
  local display_sql = clean_sql(entry.sql)
  if display_sql and display_sql ~= "" then
    local lines = {}
    for _ in (display_sql .. "\n"):gmatch("(.-)\n") do
      table.insert(lines, _)
    end
    sql_lines = #lines
  end
  n = n + sql_lines + 1
  if entry.error and entry.error ~= "" then
    local err_lines = 0
    for _ in (entry.error .. "\n"):gmatch("(.-)\n") do
      err_lines = err_lines + 1
    end
    n = n + err_lines + 1
  end
  return n
end
M._count_detail_lines = count_detail_lines

--- Set entries directly (for testing).
function M._set_entries(data)
  entries = data
  expanded = {}
  filter_text = ""
end

--- Set filter text directly (for testing).
function M._set_filter_text(text)
  filter_text = text
end

--- Set expanded state directly (for testing).
function M._set_expanded(idx, val)
  expanded[idx] = val
end

local function apply_highlights(line_idx, entry, is_detail)
  vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 2, {
    end_col = 3, hl_group = entry.status == "error" and "PosteLogError" or "PosteLogSuccess", priority = 150,
  })
  local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
  local _, te = line:find("%[.-%]", 19)
  if te then
    local ts = line:find("%[", 19)
    if ts then
      vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, ts - 1, {
        end_col = te, hl_group = "PosteSqlMeta", priority = 150,
      })
    end
  end
end

local function apply_detail_highlights(line_idx, entry)
  local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
  if line:match("Error:") then
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 2, {
      end_col = #line, hl_group = "PosteLogError", priority = 150,
    })
  elseif line:match("SQL:") then
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 2, {
      end_col = #line, hl_group = "PosteLogSQL", priority = 150,
    })
  elseif line:match("Edit:") then
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 2, {
      end_col = #line, hl_group = "PosteSqlMetaDim", priority = 150,
    })
  end
end

local function build_lines()
  local lines = {}
  local count = 0
  local filtered = {}
  for i, entry in ipairs(entries) do
    if filter_matches(entry) then
      table.insert(filtered, i)
      count = count + 1
    end
  end
  local header = "  SQL Log"
  if filter_text ~= "" then
    header = header .. "  filter: " .. filter_text
  end
  header = header .. string.format("  [%d/%d]", count, #entries)
  table.insert(lines, header)
  table.insert(lines, string.rep("─", 80))
  local line_idx = 3
  for _, idx in ipairs(filtered) do
    local entry = entries[idx]
    local icon = entry.status == "error" and "✗" or "✓"
    local time = format_time(entry.ts)
    local tbl = entry_table(entry) or "?"
    local ms = tostring(entry.elapsed_ms or 0)
    local display_sql = clean_sql(entry.sql)
    local sql = preview_sql(display_sql, 70)
    local src_tag = entry.source == "dataset_commit" and "commit" or "exec"
    local summary = string.format("  %s  %s  [%s]  %sms  %-5s %s", icon, time, tbl, ms, src_tag, sql)
    table.insert(lines, summary)
    line_idx = line_idx + 1
    if expanded[idx] then
      table.insert(lines, "  │  " .. table.concat({
        "Connection: " .. (entry.connection or "?"),
        "Database: " .. (entry.database or "?"),
        "Source: " .. (entry.source or "?"),
      }, " · "))
      line_idx = line_idx + 1
      if entry.edit_summary then
        local s = entry.edit_summary
        table.insert(lines, string.format("  │  Edit: +%d updates, %d inserts, %d deletes",
          s.updates or 0, s.inserts or 0, s.deletes or 0))
        line_idx = line_idx + 1
      end
      table.insert(lines, "  │  SQL:")
      line_idx = line_idx + 1
      local display_sql = clean_sql(entry.sql)
      if display_sql and display_sql ~= "" then
        for sql_line in (display_sql .. "\n"):gmatch("(.-)\n") do
          table.insert(lines, "  │    " .. sql_line)
          line_idx = line_idx + 1
        end
      end
      if entry.error and entry.error ~= "" then
        table.insert(lines, "  │  Error:")
        line_idx = line_idx + 1
        for err_line in (entry.error .. "\n"):gmatch("(.-)\n") do
          table.insert(lines, "  │    " .. err_line)
          line_idx = line_idx + 1
        end
      end
      table.insert(lines, "")
      line_idx = line_idx + 1
    end
  end
  return lines, filtered
end

local function render()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local lines, filtered = build_lines()
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local line_idx = 3
  for _, idx in ipairs(filtered) do
    local entry = entries[idx]
    apply_highlights(line_idx, entry, false)
    line_idx = line_idx + 1
    if expanded[idx] then
      local dl = count_detail_lines(entry)
      for d = 1, dl do
        apply_detail_highlights(line_idx, entry)
        line_idx = line_idx + 1
      end
    end
  end
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

function M.get_entry_at_cursor()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return M._get_entry_at_line(0) end
  local cursor = vim.api.nvim_win_get_cursor(win or 0)
  return M._get_entry_at_line(cursor[1] or 0)
end

function M._get_entry_at_line(line_idx)
  if line_idx == 0 then return nil end
  local filtered = {}
  for i, _ in ipairs(entries) do
    if filter_matches(entries[i]) then
      table.insert(filtered, i)
    end
  end
  local current = 3
  for _, idx in ipairs(filtered) do
    if current == line_idx then return idx end
    current = current + 1
    if expanded[idx] then
      current = current + count_detail_lines(entries[idx])
    end
    if current > line_idx then return idx end
  end
  return nil
end

function M.toggle_expand()
  local idx = M.get_entry_at_cursor()
  if not idx then return end
  expanded[idx] = not expanded[idx]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    render()
  end
end

function M.set_filter()
  vim.ui.input({ prompt = "SQL log filter: ", default = filter_text }, function(input)
    if input == nil then return end
    filter_text = input
    render()
  end)
end

function M.clear_filter()
  filter_text = ""
  render()
end

function M.re_run()
  local idx = M.get_entry_at_cursor()
  if not idx then return end
  local entry = entries[idx]
  if not entry.sql or entry.sql == "" then
    vim.notify("No SQL to re-run", vim.log.levels.WARN)
    return
  end
  local sql = entry.sql
  vim.fn.setreg('"', sql)
  vim.notify("SQL yanked to default register — paste into a .sql buffer and run", vim.log.levels.INFO)
end

function M.yank_sql()
  local idx = M.get_entry_at_cursor()
  if not idx then return end
  local entry = entries[idx]
  if not entry.sql or entry.sql == "" then
    vim.notify("No SQL to yank", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg('"', entry.sql)
  vim.notify("SQL yanked to default register", vim.log.levels.INFO)
end

function M.refresh()
  entries = load_entries()
  render()
end

function M.close()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  buf = nil
  win = nil
end

function M.toggle()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    M.close()
    return
  end
  entries = load_entries()
  expanded = {}
  filter_text = ""
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql_log")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_name(buf, "poste://sql-log")
  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.floor(vim.o.columns * 0.85),
    height = math.floor(vim.o.lines * 0.75),
    row = math.floor(vim.o.lines * 0.12),
    col = math.floor(vim.o.columns * 0.07),
    style = "minimal",
    border = "rounded",
    title = " SQL Log ",
    title_pos = "center",
  })
  vim.api.nvim_win_set_option(win, "cursorline", true)
  render()
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", M.close, opts)
  vim.keymap.set("n", "<Esc>", M.close, opts)
  vim.keymap.set("n", "j", "<Cmd>normal! j<CR>", opts)
  vim.keymap.set("n", "k", "<Cmd>normal! k<CR>", opts)
  vim.keymap.set("n", "<CR>", M.toggle_expand, opts)
  vim.keymap.set("n", "f", M.set_filter, opts)
  vim.keymap.set("n", "F", M.clear_filter, opts)
  vim.keymap.set("n", "r", M.re_run, opts)
  vim.keymap.set("n", "y", M.yank_sql, opts)
  vim.keymap.set("n", "R", M.refresh, opts)
end

return M
