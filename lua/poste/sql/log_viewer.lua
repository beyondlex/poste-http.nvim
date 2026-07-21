--- SQL Execution Log Viewer
--- Reads sql_log.jsonl, renders entries in a buffer with expand/collapse.
local M = {}

local syntax = require("poste.sql.syntax")
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
  -- Cap at 1000 entries
  if #result > 1000 then
    local capped = {}
    for i = 1, 1000 do capped[i] = result[i] end
    result = capped
  end
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
  if not ts then return "??-?? ??:??:??" end
  local _, month, day, hms = ts:match("(%d+)-(%d+)-(%d+)T(%d+:%d+:%d+)")
  if month and day and hms then
    return string.format("%s-%s %s", month, day, hms)
  end
  local t = ts:match("T(%d+:%d+:%d+)")
  if t then return t end
  t = ts:match("T(%d+:%d+)")
  return t or ts
end
M._format_time = format_time

local function preview_sql(sql, max_len)
  if not sql or sql == "" then return "" end
  -- Show only the first line for multi-line SQL
  local first_line = sql:match("^(.-)\n")
  if first_line then
    first_line = first_line:gsub("%s+$", "")
    if #first_line <= max_len - 1 then
      return first_line .. "…"
    end
  end
  if #sql <= max_len then return sql end
  return sql:sub(1, max_len - 1) .. "…"
end
M._preview_sql = preview_sql

local function clean_sql(sql)
  if not sql then return "" end
  local lines = {}
  for line in (sql .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed and not trimmed:match("^%-%-%s*@") and trimmed ~= "###" then
      table.insert(lines, trimmed)
    end
  end
  local result = table.concat(lines, "\n")
  return result:match("^%s*(.-)%s*$") or ""
end
M._clean_sql = clean_sql

local function guess_table(sql)
  if not sql then return nil end
  local patterns = {
    "[Jj][Oo][Ii][Nn]%s+([%w_]+)",
    "[Ff][Rr][Oo][Mm]%s+([%w_]+%.?([%w_]+))",
    "[Uu][Pp][Dd][Aa][Tt][Ee]%s+([%w_]+)",
    "[Ii][Nn][Tt][Oo]%s+([%w_]+)",
    "[Dd][Ee][Ll][Ee][Tt][Ee]%s+[Ff][Rr][Oo][Mm]%s+([%w_]+)",
    "[Ii][Nn][Ss][Ee][Rr][Tt]%s+[Ii][Nn][Tt][Oo]%s+([%w_]+)",
  }
  for _, pat in ipairs(patterns) do
    local t = sql:match(pat)
    if t then
      local _, after_dot = t:match("([%w_]+)%.([%w_]+)")
      return after_dot or t
    end
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
  local n = 0
  if entry.connection or entry.database or entry.source then
    n = n + 1
  end
  if entry.edit_summary then
    n = n + 1
  end
  local display_sql = clean_sql(entry.sql)
  if display_sql and display_sql ~= "" then
    for _ in (display_sql .. "\n"):gmatch("(.-)\n") do
      n = n + 1
    end
  end
  if entry.error and entry.error ~= "" then
    for _ in (entry.error .. "\n"):gmatch("(.-)\n") do
      n = n + 1
    end
  end
  n = n + 1 -- trailing blank line
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

local TBL_W = 0

local function entry_database(entry)
  if entry.database and entry.database ~= "" then return entry.database end
  if entry.connection and entry.connection ~= "" then
    local ok, config = pcall(require, "poste.sql.connections")
    if ok then
      local cfg = config.get_connection_config(entry.connection)
      if cfg and cfg.database and cfg.database ~= "" then return cfg.database end
    end
  end
  return nil
end

local function compute_table_width()
  local max_w = 0
  for _, entry in ipairs(entries) do
    local db = entry_database(entry) or entry_table(entry) or "?"
    max_w = math.max(max_w, #db)
  end
  TBL_W = math.min(math.max(max_w, 4), 25)
end

local function pad_table(s)
  if #s > TBL_W then return s:sub(1, TBL_W - 1) .. "…" end
  return s .. string.rep(" ", TBL_W - #s)
end

local function apply_highlights(line_idx, entry, _)
  -- Get actual line length for bounds checking
  local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
  local line_len = #line

  -- Error row: red for entire line (low priority so element colors show through)
  if entry.status == "error" and line_len > 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 0, {
      end_col = line_len, hl_group = "PosteLogError", priority = 100, hl_mode = "combine",
    })
  end

  -- Timestamp cols 2-17 (gray)
  vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 2, {
    end_col = 17, hl_group = "PosteSqlMetaDim", priority = 150,
  })
  -- Table name cols 19 to 19+TBL_W
  vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 18, {
    end_col = 18 + TBL_W, hl_group = "PosteSqlMeta", priority = 150,
  })
  -- Duration cols 21+TBL_W to 26+TBL_W (yellow)
  vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 20 + TBL_W, {
    end_col = 25 + TBL_W, hl_group = "PosteWinbarModified", priority = 150,
  })
  -- Source tag cols 28+TBL_W to 34+TBL_W (gray)
  vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 27 + TBL_W, {
    end_col = 33 + TBL_W, hl_group = "PosteSqlMetaDim", priority = 150,
  })
end

--- Apply SQL syntax highlighting to a single line via shared syntax module.
--- @param buf number  Buffer handle
--- @param ns number   Namespace
--- @param line_idx number  Buffer line (1-indexed)
--- @param text string SQL text for this line (without buffer prefix)
--- @param offset number  Column offset in buffer
local function highlight_sql_line(buf2, ns2, line_idx, text, offset)  -- luacheck: ignore 431
  syntax.highlight_line(buf2, ns2, line_idx, text, offset)
end

local function apply_detail_highlights(line_idx, entry, detail_idx)
  -- Precompute line counts for this entry
  local n_sql = 0
  local display_sql = clean_sql(entry.sql)
  if display_sql and display_sql ~= "" then
    for _ in (display_sql .. "\n"):gmatch("(.-)\n") do
      n_sql = n_sql + 1
    end
  end
  local n_err = 0
  if entry.error and entry.error ~= "" then
    for _ in (entry.error .. "\n"):gmatch("(.-)\n") do
      n_err = n_err + 1
    end
  end

  local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
  local line_len = #line

  -- Green bg for all non-blank detail lines
  if line_len > 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 0, {
      end_col = line_len, hl_group = "PosteLogDetailBg", priority = 80, hl_mode = "combine",
    })
  end
  if line_len == 0 then return end

  -- Determine line type by position (order: SQL → error → meta → edit)
  local pos = detail_idx
  if pos <= n_sql then
    -- SQL line: vertical bar + > marker + keyword highlights
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 2, {
      virt_text = {{"│", "PosteSqlMetaDim"}}, virt_text_pos = "overlay",
      priority = 90,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 3, {
      virt_text = {{"> ", "PosteLogSQL"}}, virt_text_pos = "overlay",
      priority = 170,
    })
    -- Full SQL syntax highlighting
    if line_len > 5 then
      highlight_sql_line(buf, ns, line_idx, line:sub(6), 5)
    end
  elseif pos <= n_sql + n_err then
    -- Error line: vertical bar + red fg + < marker
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 0, {
      end_col = line_len, hl_group = "PosteLogError", priority = 160,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 2, {
      virt_text = {{"│", "PosteSqlMetaDim"}}, virt_text_pos = "overlay",
      priority = 90,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 3, {
      virt_text = {{"< ", "PosteLogError"}}, virt_text_pos = "overlay",
      priority = 170,
    })
  else
    -- Meta/edit line: gray, bar, no marker
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 2, {
      virt_text = {{"│", "PosteSqlMetaDim"}}, virt_text_pos = "overlay",
      priority = 90,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 0, {
      end_col = line_len, hl_group = "PosteSqlMetaDim", priority = 160,
    })
  end
end

local function update_winbar()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local total = #entries
  local count = 0
  for _ in ipairs(entries) do
    if filter_matches(entries[_]) then count = count + 1 end
  end
  local parts = { "%#PosteSqlMeta# SQL Log" }
  if filter_text ~= "" then
    table.insert(parts, string.format(" %%#PosteLogFilter#filter: %s%%#PosteSqlMeta#", filter_text))
  end
  table.insert(parts, string.format("  [%d/%d]", count, total))
  if count < total then
    table.insert(parts, "  %#PosteSqlMetaDim#filtered%#PosteSqlMeta#")
  end
  table.insert(parts, "  %#PosteSqlMetaDim#│  q=close  f=filter  F=clear  C=clear-all  ↵=expand%#PosteSqlMeta#")
  pcall(vim.api.nvim_set_option_value, "winbar", table.concat(parts), { win = win })
end

local function build_lines()
  local lines = {}
  local filtered = {}
  for i, entry in ipairs(entries) do
    if filter_matches(entry) then
      table.insert(filtered, i)
    end
  end
  compute_table_width()
  local line_idx = 1
  for _, idx in ipairs(filtered) do
    local entry = entries[idx]
    local time = format_time(entry.ts)
    local db = pad_table(entry_database(entry) or entry_table(entry) or "?")
    local ms = string.format("%5s", tostring(entry.elapsed_ms or 0) .. "ms")
    local src_tag = string.format("%-6s", entry.source == "dataset_commit" and "commit" or entry.source == "import" and "import" or "exec")
    local display_sql = clean_sql(entry.sql)
    local sql = preview_sql(display_sql, 70)
    local parts = { "  ", time, "  ", db, "  ", ms, "  ", src_tag, " ", sql }
    local summary = table.concat(parts)
    table.insert(lines, summary)
    line_idx = line_idx + 1
    if expanded[idx] then
      -- SQL lines first
      local display_sql2 = clean_sql(entry.sql)
      if display_sql2 and display_sql2 ~= "" then
        for sql_line in (display_sql2 .. "\n"):gmatch("(.-)\n") do
          table.insert(lines, "     " .. sql_line)
          line_idx = line_idx + 1
        end
      end
      -- Error lines
      if entry.error and entry.error ~= "" then
        for err_line in (entry.error .. "\n"):gmatch("(.-)\n") do
          table.insert(lines, "     " .. err_line)
          line_idx = line_idx + 1
        end
      end
      -- Connection info (gray)
      local entry_db = entry_database(entry) or ""
      if entry.connection or entry.database or entry.source then
        table.insert(lines, "     " .. table.concat({
          "Connection: " .. (entry.connection or "?"),
          "Database: " .. (entry_db ~= "" and entry_db or "?"),
          "Source: " .. (entry.source or "?"),
        }, " · "))
        line_idx = line_idx + 1
      end
      -- Edit summary (gray)
      if entry.edit_summary then
        local s = entry.edit_summary
        table.insert(lines, string.format("     Edit: +%d updates, %d inserts, %d deletes",
          s.updates or 0, s.inserts or 0, s.deletes or 0))
        line_idx = line_idx + 1
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
  if #lines == 0 then
    lines = { "  <empty>" }
  end
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if #filtered == 0 then
    local line_len = #(lines[1] or "")
    if line_len > 0 then
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
        end_col = line_len, hl_group = "PosteSqlMetaDim", priority = 150,
      })
    end
    return
  end
  local line_idx = 1
  for _, idx in ipairs(filtered) do
    local entry = entries[idx]
    apply_highlights(line_idx, entry, false)
    line_idx = line_idx + 1
    if expanded[idx] then
      local dl = count_detail_lines(entry)
      for d = 1, dl do
        apply_detail_highlights(line_idx, entry, d)
        line_idx = line_idx + 1
      end
    end
  end
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  update_winbar()
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
  local current = 1
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
  vim.fn.setreg("+", sql)
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
  vim.fn.setreg("+", entry.sql)
  vim.notify("SQL yanked", vim.log.levels.INFO)
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

function M.clear_logs()
  local path = get_log_path()
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local f = io.open(path, "w")
  if f then
    f:write("")
    f:close()
  end
  entries = {}
  expanded = {}
  filter_text = ""
  render()
  vim.notify("SQL log cleared", vim.log.levels.INFO)
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
  })
  vim.api.nvim_win_set_option(win, "cursorline", true)
  vim.api.nvim_win_set_option(win, "breakindent", true)
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
  vim.keymap.set("n", "C", M.clear_logs, opts)
end

return M
