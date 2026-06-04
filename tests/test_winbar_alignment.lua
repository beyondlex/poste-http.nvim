--- Winbar alignment verification tests.
--- Uses production format.lua to build rows, ensuring test fidelity.
---
--- Run: nvim --headless -u NONE -c "set rtp+=." -c "luafile tests/test_winbar_alignment.lua" -c "qa!"

-- Make lua/poste require-able
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local sql_format = require("poste.sql.format")

local passed, failed, errors = 0, 0, {}

local function ok(msg)
  passed = passed + 1
  print("  ✓ " .. msg)
end

local function fail(msg)
  failed = failed + 1
  errors[#errors + 1] = msg
  print("  ✗ " .. msg)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- UTF-8: how many bytes a character starting with byte `b` occupies
local function utf8_charlen(b)
  if b < 0x80 then return 1
  elseif b < 0xC0 then return 1
  elseif b < 0xE0 then return 2
  elseif b < 0xF0 then return 3
  else return 4
  end
end

-- Find │ positions by DISPLAY width
local function find_sep_disp_positions(line)
  local result = {}
  local byte_idx = 1
  local disp_pos = 0
  while byte_idx <= #line do
    local cl = utf8_charlen(line:byte(byte_idx))
    local ch = line:sub(byte_idx, byte_idx + cl - 1)
    if ch == "│" then
      result[#result + 1] = disp_pos
    end
    disp_pos = disp_pos + vim.fn.strdisplaywidth(ch)
    byte_idx = byte_idx + cl
  end
  return result
end

-- Build a simple table and extract header + data lines from format_resultset.
-- This uses the PRODUCTION formatter so we test the real code path.
local function make_table(columns, rows, opts)
  opts = opts or {}
  local data = {
    type = "resultset",
    results = {{
      columns = columns,
      rows = rows,
      row_count = #rows,
      affected_rows = nil,
      execution_time_ms = 0,
    }},
    total_results = 1,
    total_rows = #rows,
    total_affected = 0,
    total_execution_time_ms = 0,
    connection = opts.connection or "test",
    database = opts.database or "test",
    dialect = "postgres",
  }
  local lines, meta = sql_format.format_resultset(data)
  return lines, meta
end

-- Extract header line and data lines from format_resultset output.
-- The header is at lines[meta.header_line], data starts at meta.data_start_line.
local function extract_header_and_data(lines, meta)
  local header = lines[meta.header_line]
  local data_lines = {}
  for i = meta.data_start_line, meta.data_end_line do
    data_lines[#data_lines + 1] = lines[i]
  end
  return header, data_lines
end

---------------------------------------------------------------------------
-- build_winbar_text: copy of production code (with UTF-8 char advancement)
---------------------------------------------------------------------------
local function build_winbar_text(header, leftcol, win_width)
  local sep = "│"
  local sep_len = #sep  -- 3 bytes
  local sep_first_byte = sep:byte(1)

  local result_bytes = {}
  local disp_pos = 0
  local byte_idx = 1

  while byte_idx <= #header do
    local b = header:byte(byte_idx)
    local char_bytes, char_width

    if b == sep_first_byte and header:sub(byte_idx, byte_idx + sep_len - 1) == sep then
      char_bytes = sep_len
      char_width = 1
    else
      char_bytes = utf8_charlen(b)
      if byte_idx + char_bytes - 1 > #header then
        char_bytes = #header - byte_idx + 1
      end
      char_width = vim.fn.strdisplaywidth(header:sub(byte_idx, byte_idx + char_bytes - 1))
      if char_width == 0 then char_width = 1 end
    end

    local char_start = disp_pos
    local char_end = disp_pos + char_width

    if char_end > leftcol and char_start < leftcol + win_width then
      if char_start < leftcol then
        local visible_width = math.min(char_end, leftcol + win_width) - leftcol
        result_bytes[#result_bytes + 1] = string.rep(" ", visible_width)
      elseif char_end > leftcol + win_width then
        local visible_width = leftcol + win_width - char_start
        result_bytes[#result_bytes + 1] = string.rep(" ", visible_width)
      else
        result_bytes[#result_bytes + 1] = header:sub(byte_idx, byte_idx + char_bytes - 1)
      end
    end

    disp_pos = char_end
    byte_idx = byte_idx + char_bytes
  end

  if #result_bytes == 0 then return "" end
  return table.concat(result_bytes)
end

---------------------------------------------------------------------------
-- Core alignment check
---------------------------------------------------------------------------

--- Verify that every │ in the winbar has a corresponding │ in the data line
--- at the same ABSOLUTE display position on screen.
--- Winbar separators are at relative positions (within the sliced string),
--- so absolute = relative + leftcol. Data separators are already absolute
--- (computed on the full data line).
local function check_alignment(header, data_line, leftcol, win_width, label)
  local winbar = build_winbar_text(header, leftcol, win_width)

  local winbar_rel_seps = find_sep_disp_positions(winbar)
  local data_abs_seps = find_sep_disp_positions(data_line)

  -- Convert winbar relative positions to absolute screen positions
  local winbar_abs_seps = {}
  for _, p in ipairs(winbar_rel_seps) do
    winbar_abs_seps[#winbar_abs_seps + 1] = p + leftcol
  end

  local data_sep_set = {}
  for _, p in ipairs(data_abs_seps) do
    data_sep_set[p] = true
  end

  for _, ws in ipairs(winbar_abs_seps) do
    if not data_sep_set[ws] then
      return false, string.format(
        "%s: winbar │ at screen display=%d has no data │ (leftcol=%d, win_width=%d)\n"
        .. "    winbar: [%s]  (abs seps: %s)\n    data:   [%s]  (abs seps: %s)",
        label, ws, leftcol, win_width,
        winbar, table.concat(winbar_abs_seps, ","),
        data_line, table.concat(data_abs_seps, ","))
    end
  end

  -- Winbar should not exceed window width
  local wb_width = vim.fn.strdisplaywidth(winbar)
  if wb_width > win_width then
    return false, string.format(
      "%s: winbar display width %d > win_width %d (leftcol=%d)\n"
      .. "    winbar: [%s]",
      label, wb_width, win_width, leftcol, winbar)
  end

  return true
end

--- Verify strdisplaywidth(line:sub(1, cell_start_byte)) gives correct
--- display position for each cell boundary.
local function check_disp_position(line, label)
  local sep = "│"
  local sep_len = #sep

  local byte_seps = {}
  local pos = 1
  while true do
    pos = line:find(sep, pos, true)
    if not pos then break end
    byte_seps[#byte_seps + 1] = pos
    pos = pos + sep_len
  end

  local disp_seps = find_sep_disp_positions(line)

  for i = 1, #byte_seps do
    local bp = byte_seps[i]
    -- cell_start_byte = 0-based byte of leading space after this │
    local cell_start_byte = bp + sep_len - 1
    local computed_disp = vim.fn.strdisplaywidth(line:sub(1, cell_start_byte))
    local expected_disp = disp_seps[i] + 1  -- display pos of │ + 1 for the space

    if computed_disp ~= expected_disp then
      return false, string.format(
        "%s: sep #%d at byte=%d, display=%d: strdisplaywidth(sub(1,%d))=%d, expected=%d",
        label, i, bp, disp_seps[i], cell_start_byte, computed_disp, expected_disp)
    end
  end

  return true
end

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------

print("\n═══════════════════════════════════════════════════")
print(" Winbar Alignment Tests")
print("═══════════════════════════════════════════════════")

-- ─── Test 1: ASCII columns, no truncation ────────────────────────────
print("\nTest 1: Winbar alignment — ASCII columns, no truncation")
do
  local columns = {
    { name = "id", type = "INT4" },
    { name = "name", type = "TEXT" },
    { name = "email", type = "TEXT" },
  }
  local rows = {
    { 1, "Alice", "alice@example.com" },
    { 2, "Bob", "bob@test.org" },
  }
  local lines, meta = make_table(columns, rows)
  local header, data_lines = extract_header_and_data(lines, meta)

  print(string.format("  header: [%s] (disp=%d, bytes=%d)",
    header, vim.fn.strdisplaywidth(header), #header))
  print(string.format("  data 1: [%s] (disp=%d, bytes=%d)",
    data_lines[1], vim.fn.strdisplaywidth(data_lines[1]), #data_lines[1]))

  local all_ok = true
  local win_width = 30
  for leftcol = 0, vim.fn.strdisplaywidth(header) - 5, 2 do
    for dl_idx, dl in ipairs(data_lines) do
      local ok_flag, msg = check_alignment(header, dl, leftcol, win_width,
        string.format("leftcol=%d, row=%d", leftcol, dl_idx))
      if not ok_flag then
        all_ok = false
        fail(msg)
      end
    end
  end
  if all_ok then
    ok("all scroll positions aligned")
  end
end

-- ─── Test 2: Truncated cells (… in data rows) ───────────────────────
print("\nTest 2: Winbar alignment — truncated cells with … character")
do
  local columns = {
    { name = "status", type = "TEXT" },
    { name = "published_at", type = "TEXT" },
    { name = "created_at", type = "TEXT" },
  }
  local rows = {
    { "published", "2026-05-15 12:45:30", "2026-06-04 12:45:30" },
    { "draft", "(NULL)", "2026-06-04 12:45:30" },
    { "archived", "2026-04-05 12:45:30", "2026-06-04 12:45:30" },
  }
  local lines, meta = make_table(columns, rows)
  local header, data_lines = extract_header_and_data(lines, meta)

  print(string.format("  header: [%s] (disp=%d, bytes=%d)",
    header, vim.fn.strdisplaywidth(header), #header))
  print(string.format("  data 1: [%s] (disp=%d, bytes=%d)",
    data_lines[1], vim.fn.strdisplaywidth(data_lines[1]), #data_lines[1]))

  local all_ok = true
  local win_width = 40
  for leftcol = 0, vim.fn.strdisplaywidth(header) - 5, 2 do
    for dl_idx, dl in ipairs(data_lines) do
      local ok_flag, msg = check_alignment(header, dl, leftcol, win_width,
        string.format("leftcol=%d, row=%d", leftcol, dl_idx))
      if not ok_flag then
        all_ok = false
        fail(msg)
      end
    end
  end
  if all_ok then
    ok("truncated data: all positions aligned")
  end
end

-- ─── Test 3: Many columns (byte vs display divergence stress test) ───
print("\nTest 3: Many columns — byte/display divergence stress test")
do
  local columns = {}
  local rows_data = {}
  for i = 1, 12 do
    columns[i] = { name = string.format("col_%d", i), type = "TEXT" }
    rows_data[i] = string.format("value_%d", i)
  end
  local rows = { rows_data, rows_data }
  local lines, meta = make_table(columns, rows)
  local header, data_lines = extract_header_and_data(lines, meta)

  local header_disp = vim.fn.strdisplaywidth(header)
  print(string.format("  %d columns, header: disp=%d, bytes=%d (divergence=%d)",
    #columns, header_disp, #header, #header - header_disp))

  local all_ok = true
  local win_width = 50
  for leftcol = 0, header_disp - 10, 3 do
    for dl_idx, dl in ipairs(data_lines) do
      local ok_flag, msg = check_alignment(header, dl, leftcol, win_width,
        string.format("leftcol=%d", leftcol))
      if not ok_flag then
        all_ok = false
        fail(msg)
        break  -- one failure per leftcol is enough
      end
    end
    if not all_ok then break end
  end
  if all_ok then
    ok("12 columns: all positions aligned")
  end
end

-- ─── Test 4: CJK column names ────────────────────────────────────────
print("\nTest 4: Winbar alignment — CJK column names")
do
  local columns = {
    { name = "状态", type = "TEXT" },
    { name = "发布时间", type = "TEXT" },
    { name = "作者", type = "TEXT" },
  }
  local rows = {
    { "published", "2026-05-15", "John" },
    { "draft", "2026-06-01", "Jane" },
  }
  local lines, meta = make_table(columns, rows)
  local header, data_lines = extract_header_and_data(lines, meta)

  print(string.format("  header: [%s] (disp=%d, bytes=%d)",
    header, vim.fn.strdisplaywidth(header), #header))

  local all_ok = true
  local win_width = 25
  for leftcol = 0, vim.fn.strdisplaywidth(header) - 5, 2 do
    for dl_idx, dl in ipairs(data_lines) do
      local ok_flag, msg = check_alignment(header, dl, leftcol, win_width,
        string.format("leftcol=%d, row=%d", leftcol, dl_idx))
      if not ok_flag then
        all_ok = false
        fail(msg)
      end
    end
  end
  if all_ok then
    ok("CJK columns: all positions aligned")
  end
end

-- ─── Test 5: leftcol at exact separator boundaries ───────────────────
print("\nTest 5: leftcol at exact separator boundaries")
do
  local columns = {
    { name = "name", type = "TEXT" },
    { name = "city", type = "TEXT" },
    { name = "country", type = "TEXT" },
  }
  local rows = { { "Alice", "San Francisco", "USA" } }
  local lines, meta = make_table(columns, rows)
  local header, data_lines = extract_header_and_data(lines, meta)

  local sep_positions = find_sep_disp_positions(header)
  print(string.format("  separator display positions: %s", table.concat(sep_positions, ", ")))

  local all_ok = true
  local win_width = 30
  for _, sp in ipairs(sep_positions) do
    local ok_flag, msg = check_alignment(header, data_lines[1], sp, win_width,
      string.format("leftcol=%d (at │)", sp))
    if not ok_flag then
      all_ok = false
      fail(msg)
    end
  end
  if all_ok then
    ok("leftcol at every │ boundary: aligned")
  end
end

-- ─── Test 6: leftcol mid-cell (partial cell at left edge) ────────────
print("\nTest 6: leftcol mid-cell (sidescrolloff partial cell)")
do
  local columns = {
    { name = "name", type = "TEXT" },
    { name = "description", type = "TEXT" },
    { name = "category", type = "TEXT" },
  }
  local rows = { { "Test", "A fairly long description here", "tech" } }
  local lines, meta = make_table(columns, rows)
  local header, data_lines = extract_header_and_data(lines, meta)

  local seps = find_sep_disp_positions(header)

  local all_ok = true
  local win_width = 25
  for i = 1, #seps - 1 do
    local mid = math.floor((seps[i] + seps[i + 1]) / 2)
    local ok_flag, msg = check_alignment(header, data_lines[1], mid, win_width,
      string.format("leftcol=%d (mid-cell)", mid))
    if not ok_flag then
      all_ok = false
      fail(msg)
    end
  end
  if all_ok then
    ok("mid-cell leftcol: aligned")
  end
end

-- ─── Test 7: position_cursor display position computation ─────────────
print("\nTest 7: strdisplaywidth at cell boundaries (position_cursor)")
do
  local columns = {
    { name = "id", type = "INT4" },
    { name = "name", type = "TEXT" },
    { name = "value", type = "TEXT" },
  }
  local rows = {
    { 1, "Alice", "some_value" },
    { 99, "Bob", "another_value_here" },
  }
  local lines, meta = make_table(columns, rows)
  local _, data_lines = extract_header_and_data(lines, meta)

  local all_ok = true
  for dl_idx, dl in ipairs(data_lines) do
    local ok_flag, msg = check_disp_position(dl, string.format("row %d", dl_idx))
    if not ok_flag then
      all_ok = false
      fail(msg)
    end
  end
  if all_ok then
    ok("strdisplaywidth at all cell boundaries correct")
  end
end

-- ─── Test 8: position_cursor with truncated data ─────────────────────
print("\nTest 8: strdisplaywidth at cell boundaries — truncated data with …")
do
  local columns = {
    { name = "status", type = "TEXT" },
    { name = "published_at", type = "TEXT" },
    { name = "created_at", type = "TEXT" },
  }
  local rows = {
    { "published", "2026-05-15 12:45:30.123456", "2026-06-04 12:45:30.123456" },
  }
  local lines, meta = make_table(columns, rows)
  local _, data_lines = extract_header_and_data(lines, meta)

  print(string.format("  data: [%s]", data_lines[1]))
  print(string.format("  bytes=%d, display=%d", #data_lines[1], vim.fn.strdisplaywidth(data_lines[1])))

  local ok_flag, msg = check_disp_position(data_lines[1], "truncated row")
  if ok_flag then
    ok("strdisplaywidth at cell boundaries correct with … truncation")
  else
    fail(msg)
  end
end

-- ─── Test 9: Simulate user's posts table scenario ────────────────────
print("\nTest 9: User scenario — blog posts table scroll")
do
  local columns = {
    { name = "id", type = "INT4" },
    { name = "title", type = "TEXT" },
    { name = "slug", type = "TEXT" },
    { name = "status", type = "TEXT" },
    { name = "published_at", type = "TEXT" },
    { name = "created_at", type = "TEXT" },
  }
  local rows = {
    { 1, "Getting Started with Rust", "getting-started-rust", "published", "2026-05-15 12:45:30", "2026-06-04 12:45:30" },
    { 2, "Advanced SQL Patterns", "advanced-sql-patterns", "published", "2026-05-20 12:45:30", "2026-06-04 12:45:30" },
    { 3, "Draft Post", "draft-post", "draft", nil, "2026-06-04 12:45:30" },
    { 4, "Archived Article", "archived-article", "archived", "2026-04-05 12:45:30", "2026-06-04 12:45:30" },
  }
  local lines, meta = make_table(columns, rows)
  local header, data_lines = extract_header_and_data(lines, meta)

  print(string.format("  header: [%s]", header))
  print(string.format("  header disp=%d, bytes=%d", vim.fn.strdisplaywidth(header), #header))
  print(string.format("  data 1: [%s]", data_lines[1]))

  local all_ok = true
  local win_width = 50
  for leftcol = 0, vim.fn.strdisplaywidth(header) - 5, 1 do
    for dl_idx, dl in ipairs(data_lines) do
      local ok_flag, msg = check_alignment(header, dl, leftcol, win_width,
        string.format("leftcol=%d, row=%d", leftcol, dl_idx))
      if not ok_flag then
        all_ok = false
        fail(msg)
        break
      end
    end
    if not all_ok then break end
  end
  if all_ok then
    ok("posts table: all rows aligned at every scroll position")
  end
end

-- ─── Test 10: Winbar width never exceeds window ──────────────────────
print("\nTest 10: Winbar width ≤ win_width for all leftcol values")
do
  local columns = {
    { name = "id", type = "INT4" },
    { name = "name", type = "TEXT" },
    { name = "email", type = "TEXT" },
    { name = "status", type = "TEXT" },
  }
  local rows = { { 1, "Alice", "alice@example.com", "active" } }
  local lines, meta = make_table(columns, rows)
  local header, _ = extract_header_and_data(lines, meta)

  local header_disp = vim.fn.strdisplaywidth(header)
  local all_ok = true
  for win_width = 10, header_disp, 5 do
    for leftcol = 0, header_disp - 3 do
      local winbar = build_winbar_text(header, leftcol, win_width)
      local wb_width = vim.fn.strdisplaywidth(winbar)
      if wb_width > win_width then
        fail(string.format("winbar width %d > win_width %d (leftcol=%d): [%s]",
          wb_width, win_width, leftcol, winbar))
        all_ok = false
        break
      end
    end
    if not all_ok then break end
  end
  if all_ok then
    ok("winbar width always ≤ win_width")
  end
end

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------

print("\n═══════════════════════════════════════════════════")
print(string.format(" Results: %d passed, %d failed", passed, failed))
print("═══════════════════════════════════════════════════")

if failed > 0 then
  print("\nFailed tests:")
  for _, err in ipairs(errors) do
    print("\n  ✗ " .. err)
  end
end
