--- SQL statement extraction utilities.
---
--- Pure functions for finding and extracting SQL statements from a buffer.
--- Extracted from sql/init.lua to reduce module size and improve testability.

local cli = require("poste.cli")
local state = require("poste.state")

local M = {}

---------------------------------------------------------------------------
-- Block boundary detection
---------------------------------------------------------------------------

--- Find the ###-delimited block containing a given line.
--- Returns (block_start, block_end) as 1-based line numbers.
function M.find_block_for_line(buf_lines, line)
  -- Search backward for the opening ###
  local start = line
  while start >= 1 do
    if buf_lines[start]:match("^%s*###") then
      start = start + 1  -- skip past the ### line
      break
    end
    if start == 1 then break end
    start = start - 1
  end
  -- Search forward for the closing ### (or end of buffer)
  local finish = line
  while finish < #buf_lines do
    if buf_lines[finish + 1]:match("^%s*###") then
      break
    end
    finish = finish + 1
  end
  return start, finish
end

--- Try to find statement boundaries using the Rust binary.
--- Returns {start_line, end_line} as 1-based buffer line numbers, or nil.
function M.try_rust_stmt_span(buf_lines, cursor_line)
  -- Find the current ### block to limit the scope
  local block_start, block_end = M.find_block_for_line(buf_lines, cursor_line)

  -- Extract block lines and compute relative cursor
  local block_lines = {}
  for i = block_start, block_end do
    block_lines[#block_lines + 1] = buf_lines[i] or ""
  end
  local rel_cursor = cursor_line - block_start  -- 0-based within block

  -- Call Rust binary
  local input = table.concat(block_lines, "\n")
  local parsed, err = cli.run_json({ "context", "stmt", tostring(rel_cursor) }, { stdin = input })
  if not parsed then return nil end

  -- Convert Rust 0-based lines to absolute Lua 1-based lines
  local rust_start = parsed.start_line
  local rust_end = parsed.end_line
  if type(rust_start) ~= "number" or type(rust_end) ~= "number" then return nil end

  local abs_start = block_start + rust_start
  local abs_end = block_start + rust_end
  if vim.g.poste_sql_debug then
    vim.notify(string.format("[poste] Rust stmt span: relative=(%d,%d) absolute=(%d,%d)",
      rust_start, rust_end, abs_start, abs_end), vim.log.levels.INFO)
  end

  return { abs_start, abs_end }
end

--- Try to find ALL statement boundaries using the Rust binary.
--- Calls `poste context stmt-ranges` which returns semantic boundaries
--- without relying on ';'.
--- Returns number[] of 1-based buffer statement start lines, or nil.
function M.try_rust_stmt_ranges(buf_lines, start_line, end_line)
  -- Extract the range of lines
  local range_lines = {}
  for i = start_line, end_line do
    range_lines[#range_lines + 1] = buf_lines[i] or ""
  end

  local input = table.concat(range_lines, "\n")
  local parsed, err = cli.run_json({ "context", "stmt-ranges" }, { stdin = input })
  if not parsed then return nil end

  local ok, parsed = pcall(vim.json.decode, output)
  if not ok or type(parsed) ~= "table" or #parsed == 0 then return nil end

  -- parsed is [[start0, end0], [start1, end1], ...] (0-based, relative to range)
  local stmt_lines = {}
  for _, pair in ipairs(parsed) do
    local rs, re
    if type(pair[1]) == "number" then
      rs, re = pair[1], pair[2]
    elseif type(pair.start_line) == "number" then
      rs, re = pair.start_line, pair.end_line
    else
      goto continue_range
    end
    local abs_start = start_line + rs
    local abs_end = start_line + (re or rs)
    -- Advance past blank/directive/comment lines within the range
    while abs_start <= abs_end and abs_start <= end_line do
      local t = (buf_lines[abs_start] or ""):match("^%s*(.*)$") or ""
      if t == "" or t:match("^%-%-") or t:match("^%s*###") or t:upper():match("^USE ") then
        abs_start = abs_start + 1
      else
        break
      end
    end
    if abs_start <= end_line then
      table.insert(stmt_lines, abs_start)
    end
    ::continue_range::
  end

  return #stmt_lines > 0 and stmt_lines or nil
end

---------------------------------------------------------------------------
-- Single-statement extraction
---------------------------------------------------------------------------

--- Extract a single SQL statement at the cursor position.
--- Delimited purely by semicolons, wrapped in a synthetic ### block.
function M.extract_stmt_at_cursor(buf_lines, cursor_line)
  local directives = {}
  for _, l in ipairs(buf_lines) do
    if l:match("^%s*%-%-") or l:match("^%s*$") then
      table.insert(directives, l)
    else
      break
    end
  end

  local stmt_start
  local stmt_end
  -- Try Rust for proper statement boundary detection (handles ; in strings/comments)
  -- poste_sql_legacy_completion: nil → Rust+Lua, true → Lua only, "rust" → Rust only
  local use_rust = not vim.g.poste_sql_legacy_completion or vim.g.poste_sql_legacy_completion == "rust"
  local rust_ok, rust_result
  if use_rust then
    rust_ok, rust_result = pcall(M.try_rust_stmt_span, buf_lines, cursor_line)
  end
  if use_rust and rust_ok and rust_result then
    stmt_start = rust_result[1]
    stmt_end = rust_result[2]
    -- If cursor is on a blank line, skip forward past empty lines
    -- to find the next statement start.
    if (buf_lines[cursor_line] or ""):match("^%s*$") then
      -- Cursor on blank line: skip forward past empty lines from the
      -- Rust result, and show the statement above the blank lines.
      while stmt_start <= #buf_lines and (buf_lines[stmt_start] or ""):match("^%s*$") do
        stmt_start = stmt_start + 1
      end
    end
    -- Skip past directive lines (-- @connection, -- @database), ### markers,
    -- and blank lines before the cursor.
    while stmt_start < cursor_line and stmt_start <= #buf_lines do
      local l = buf_lines[stmt_start] or ""
      if l:match("^%s*$") or l:match("^%s*%-%-") or l:match("^%s*###") then
        stmt_start = stmt_start + 1
      else
        break
      end
    end
  else
    -- Fall back to Lua logic
    if (buf_lines[cursor_line] or ""):match("^%s*$") then
      -- Cursor on empty line: search forward for next statement
      stmt_start = cursor_line
      while stmt_start <= #buf_lines and (buf_lines[stmt_start] or ""):match("^%s*$") do
        stmt_start = stmt_start + 1
      end
    else
      stmt_start = cursor_line
      for i = cursor_line - 1, 1, -1 do
        local txt = buf_lines[i] or ""
        if txt:match(";") then
          stmt_start = i + 1
          break
        end
        if txt:match("^%s*###") or txt:match("^%s*%-%-%s*@") then
          stmt_start = i + 1
          break
        end
      end
      while stmt_start <= cursor_line and (buf_lines[stmt_start] or ""):match("^%s*$") do
        stmt_start = stmt_start + 1
      end
    end

    stmt_end = #buf_lines
    for i = cursor_line, #buf_lines do
      if (buf_lines[i] or ""):match(";") then
        stmt_end = i
        break
      end
    end
  end

  -- Ensure stmt_start is not on a blank line
  while stmt_start and stmt_start <= #buf_lines and (buf_lines[stmt_start] or ""):match("^%s*$") do
    stmt_start = stmt_start + 1
  end

  local stmt_lines = {}
  for i = stmt_start, stmt_end do
    table.insert(stmt_lines, buf_lines[i] or "")
  end

  -- If the detected statement is all blank/empty lines, nothing to execute
  local all_blank = true
  for _, l in ipairs(stmt_lines) do
    if not l:match("^%s*$") then all_blank = false; break end
  end
  if all_blank then
    return nil, nil, stmt_start
  end

  -- If the detected statement contains only comment lines, nothing to execute
  local has_sql = false
  for _, l in ipairs(stmt_lines) do
    local trimmed = l:match("^%s*(.*)$")
    if trimmed ~= "" and not trimmed:match("^%-%-") then
      has_sql = true
      break
    end
  end
  if not has_sql then
    return nil, nil, stmt_start
  end

  local parts = {}
  for _, l in ipairs(directives) do table.insert(parts, l) end
  table.insert(parts, "###")
  for _, l in ipairs(stmt_lines) do table.insert(parts, l) end

  -- When cursor is below the statement (e.g. on blank lines below), clamp
  -- adjusted_line to stmt_end so it doesn't exceed the synthetic ### block.
  local cursor_ref = (cursor_line >= stmt_start) and math.min(cursor_line, stmt_end) or stmt_start
  local adjusted_line = #directives + 1 + (cursor_ref - stmt_start + 1)
  return table.concat(parts, "\n"), adjusted_line, stmt_start
end

---------------------------------------------------------------------------
-- Multi-statement extraction
---------------------------------------------------------------------------

--- Find buffer line numbers for each SQL statement within a line range.
--- Scans for non-blank, non-comment lines as statement starts. A line
--- containing `;` marks the end of the current statement. The start of
--- the next statement is the next non-blank, non-comment line.
--- @param buf_lines string[]
--- @param start_line number  1-indexed start of range
--- @param end_line   number  1-indexed end of range
--- @return number[]  buffer line numbers of each statement's first content line
function M.find_stmt_lines(buf_lines, start_line, end_line)
  -- Lua ;-scan first (deterministic for standard SQL)
  local stmt_lines = {}
  local current_stmt = nil

  for i = start_line, end_line do
    local line = buf_lines[i] or ""
    local trimmed = line:match("^%s*(.*)$")

    -- Skip blank lines and directive comments
    if trimmed == "" then goto continue end
    if trimmed:match("^%-%-%s*@") then goto continue end
    if trimmed:match("^%s*###") then goto continue end
    if trimmed:upper():match("^USE ") then goto continue end
    if trimmed:match("^%-%-") then goto continue end

    if current_stmt == nil then current_stmt = i end

    if line:match(";") then
      table.insert(stmt_lines, current_stmt)
      current_stmt = nil
    end

    ::continue::
  end

  if current_stmt then table.insert(stmt_lines, current_stmt) end

  if #stmt_lines > 0 then return stmt_lines end

  -- Fallback: try Rust semantic boundary detection
  return M.try_rust_stmt_ranges(buf_lines, start_line, end_line)
end

--- Extract a visual selection as a synthetic ### block for the CLI.
--- @param buf_lines string[]
--- @param start_line number
--- @param end_line   number
--- @return string block_content  full content with directives + ### + selected lines
--- @return number[] stmt_lines   buffer line numbers of each statement
--- @return number   directive_count  number of file-level directive lines
function M.extract_visual_block(buf_lines, start_line, end_line)
  local directives = {}
  for _, l in ipairs(buf_lines) do
    if l:match("^%s*%-%-") or l:match("^%s*$") then
      table.insert(directives, l)
    else
      break
    end
  end

  local parts = {}
  for _, l in ipairs(directives) do table.insert(parts, l) end
  table.insert(parts, "###")
  for i = start_line, end_line do
    table.insert(parts, buf_lines[i] or "")
  end

  local stmt_lines = M.find_stmt_lines(buf_lines, start_line, end_line)
  return table.concat(parts, "\n"), stmt_lines, #directives
end

---------------------------------------------------------------------------
-- Table name extraction from SQL
---------------------------------------------------------------------------

--- Extract primary table name from a SQL statement.
--- Returns nil for JOINs with 2+ tables (use "result n" instead).
function M.extract_table_name(sql)
  if not sql or sql == "" then return nil end
  -- Strip -- line comments and /* */ block comments
  local clean = sql:gsub("%-%-[^\n]*", ""):gsub("/%*.-%*/", "")
  local upper = clean:upper()
  local join_count = 0
  local idx = 1
  while true do
    local pos = upper:find("JOIN", idx, { plain = true })
    if not pos then break end
    local before = upper:sub(pos - 1, pos - 1)
    if before == "" or before == " " or before == "\n" or before == "\t" then
      join_count = join_count + 1
    end
    idx = pos + 4
  end
  if join_count >= 2 then return nil end
  local patterns = { "FROM%s+(%S+)", "UPDATE%s+(%S+)", "INTO%s+(%S+)", "JOIN%s+(%S+)" }
  for _, pat in ipairs(patterns) do
    local tname = upper:match(pat)
    if tname then
      tname = tname:gsub("^[`\"'\\[]+", ""):gsub("[`\"'\\]]+$", "")
      tname = tname:gsub("[%p%s]+$", "")
      local dot = tname:find("%.")
      if dot then tname = tname:sub(dot + 1) end
      if tname ~= "" then return tname:lower() end
    end
  end
  return nil
end

--- Get SQL text for the i-th statement (1-indexed) from buf_lines using stmt_lines.
--- @param buf_lines string[]
--- @param stmt_lines number[]
--- @param idx number 1-indexed statement index
--- @param max_end number|nil max line to read (e.g. visual selection end)
--- @return string
function M.get_stmt_sql(buf_lines, stmt_lines, idx, max_end)
  local start = stmt_lines[idx]
  if not start then return "" end
  local stop = stmt_lines[idx + 1] and (stmt_lines[idx + 1] - 1) or max_end or start
  local lines = {}
  for i = start, stop do
    local ln = buf_lines[i]
    if ln and ln ~= "" then
      lines[#lines + 1] = ln
    end
  end
  return table.concat(lines, " ")
end

M._test = {
  extract_stmt_at_cursor = M.extract_stmt_at_cursor,
  find_stmt_lines = M.find_stmt_lines,
  extract_visual_block = M.extract_visual_block,
  try_rust_stmt_span = M.try_rust_stmt_span,
  try_rust_stmt_ranges = M.try_rust_stmt_ranges,
  find_block_for_line = M.find_block_for_line,
}

return M