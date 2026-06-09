--- SQL execution entry point — supports single-statement (normal mode)
--- and multi-statement (visual selection) execution.
--- Each statement result goes into its own dataset tab.
local state = require("poste.state")
local indicators = require("poste.indicators")
local sql_format = require("poste.sql.format")
local sql_buffer = require("poste.sql.buffer")

local M = {}

-- Execution tracking for callback ordering
local exec_seq = 0
local _vis_active = false
local _vis_start = 0
local _vis_end = 0

--- Show or open a float window with text content.
local function show_float(lines, title, ft)
  if not lines or #lines == 0 then
    vim.notify("No content to display", vim.log.levels.WARN, { title = "Poste SQL" })
    return
  end

  local max_width = math.min(math.floor(vim.o.columns * 0.7), 100)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 4, max_width)

  local max_height = math.floor(vim.o.lines * 0.5)
  local height = math.max(3, math.min(#lines + 2, max_height))

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].filetype = ft or "sql"
  vim.bo[float_buf].modifiable = false

  local win_opts = {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height, style = "minimal",
    border = "rounded", title = title, title_pos = "left",
  }
  local ok, win = pcall(vim.api.nvim_open_win, float_buf, true, win_opts)
  if not ok then
    win_opts.title = nil; win_opts.title_pos = nil
    win = vim.api.nvim_open_win(float_buf, true, win_opts)
  end

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].scrolloff = 1
  vim.wo[win].cursorline = true

  local sopts = { buffer = float_buf, noremap = true, silent = true }
  vim.keymap.set("n", "j", "j", sopts)
  vim.keymap.set("n", "k", "k", sopts)
  vim.keymap.set("n", "d", "<C-d>", sopts)
  vim.keymap.set("n", "u", "<C-u>", sopts)
  vim.keymap.set("n", "g", "gg", sopts)
  vim.keymap.set("n", "G", "G", sopts)
  local close_fn = function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  vim.keymap.set("n", "q", close_fn, sopts)
  vim.keymap.set("n", "<Esc>", close_fn, sopts)
end

--------------------------------------------------------------------------------
-- Binary discovery
--------------------------------------------------------------------------------

local function find_poste_binary()
  if state.config.poste_binary ~= "" and vim.fn.filereadable(state.config.poste_binary) == 1 then
    return vim.fn.fnamemodify(state.config.poste_binary, ":p")
  end
  for _, path in ipairs({ "./target/debug/poste", "./target/release/poste" }) do
    if vim.fn.filereadable(path) == 1 then
      return vim.fn.fnamemodify(path, ":p")
    end
  end
  return vim.fn.exepath("poste")
end

--------------------------------------------------------------------------------
-- Statement extraction
--------------------------------------------------------------------------------

--- Find the ###-delimited block containing a given line.
--- Returns (block_start, block_end) as 1-based line numbers.
local function find_block_for_line(buf_lines, line)
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
local function try_rust_stmt_span(buf_lines, cursor_line)
  local binary = find_poste_binary()
  if not binary then return nil end

  -- Find the current ### block to limit the scope
  local block_start, block_end = find_block_for_line(buf_lines, cursor_line)

  -- Extract block lines and compute relative cursor
  local block_lines = {}
  for i = block_start, block_end do
    block_lines[#block_lines + 1] = buf_lines[i] or ""
  end
  local rel_cursor = cursor_line - block_start  -- 0-based within block

  -- Call Rust binary
  local cmd = string.format("%s context stmt %d", vim.fn.shellescape(binary), rel_cursor)
  local input = table.concat(block_lines, "\n")
  local output = vim.fn.system(cmd, input)
  if vim.v.shell_error ~= 0 then return nil end

  local ok, parsed = pcall(vim.json.decode, output)
  if not ok or not parsed or type(parsed) ~= "table" then return nil end

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

--- Extract a single SQL statement at the cursor position.
--- Delimited purely by semicolons, wrapped in a synthetic ### block.
local function extract_stmt_at_cursor(buf_lines, cursor_line)
  local directives = {}
  for _, l in ipairs(buf_lines) do
    if l:match("^%s*%-%-") or l:match("^%s*$") then
      table.insert(directives, l)
    else
      break
    end
  end

  local stmt_start
  -- Try Rust for proper statement boundary detection (handles ; in strings/comments)
  -- poste_sql_legacy_completion: nil → Rust+Lua, true → Lua only, "rust" → Rust only
  local use_rust = not vim.g.poste_sql_legacy_completion or vim.g.poste_sql_legacy_completion == "rust"
  local rust_ok, rust_result
  if use_rust then
    rust_ok, rust_result = pcall(try_rust_stmt_span, buf_lines, cursor_line)
  end
  if use_rust and rust_ok and rust_result then
    stmt_start = rust_result[1]
    stmt_end = rust_result[2]
    -- If cursor is on a blank line, skip forward past empty lines
    -- to find the next statement start.
    if (buf_lines[cursor_line] or ""):match("^%s*$") then
      while stmt_start <= #buf_lines and (buf_lines[stmt_start] or ""):match("^%s*$") do
        stmt_start = stmt_start + 1
      end
    end
    -- Skip past directive lines (-- @connection, -- @database), ### markers,
    -- and blank lines before the cursor — Rust's find_statement_span only
    -- uses ; boundaries, so it doesn't know about these SQL-file-specific constructs.
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

  local parts = {}
  for _, l in ipairs(directives) do table.insert(parts, l) end
  table.insert(parts, "###")
  for _, l in ipairs(stmt_lines) do table.insert(parts, l) end

  local adjusted_line = #directives + 1 + ((cursor_line >= stmt_start and cursor_line or stmt_start) - stmt_start + 1)
  return table.concat(parts, "\n"), adjusted_line, stmt_start
end

--- Find buffer line numbers for each SQL statement within a line range.
--- Scans for non-blank, non-comment lines as statement starts. A line
--- containing `;` marks the end of the current statement. The start of
--- the next statement is the next non-blank, non-comment line.
--- @param buf_lines string[]
--- @param start_line number  1-indexed start of range
--- @param end_line   number  1-indexed end of range
--- @return number[]  buffer line numbers of each statement's first content line
local function find_stmt_lines(buf_lines, start_line, end_line)
  local stmt_lines = {}
  local current_stmt = nil

  for i = start_line, end_line do
    local line = buf_lines[i] or ""
    local trimmed = line:match("^%s*(.*)$")

    -- Skip blank lines and directive comments
    if trimmed == "" then
      -- end of a statement can be here if the previous line ended with ;
      goto continue
    end
    if trimmed:match("^%-%-%s*@") then
      goto continue
    end

    -- Skip ### block separators
    if trimmed:match("^%s*###") then
      goto continue
    end

    -- Skip USE statements (handled silently by Rust executor via pool reconnect)
    if trimmed:upper():match("^USE ") then
      goto continue
    end

    -- Comment line: skip unless we're inside a statement
    if trimmed:match("^%-%-") then
      goto continue
    end

    -- Content line
    if current_stmt == nil then
      current_stmt = i
    end

    -- Statement ends at a line containing ;
    if line:match(";") then
      table.insert(stmt_lines, current_stmt)
      current_stmt = nil
    end

    ::continue::
  end

  -- Last statement without trailing semicolon
  if current_stmt then
    table.insert(stmt_lines, current_stmt)
  end

  return stmt_lines
end

--- Extract a visual selection as a synthetic ### block for the CLI.
--- @param buf_lines string[]
--- @param start_line number
--- @param end_line   number
--- @return string block_content  full content with directives + ### + selected lines
--- @return number[] stmt_lines   buffer line numbers of each statement
--- @return number   directive_count  number of file-level directive lines
local function extract_visual_block(buf_lines, start_line, end_line)
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

  local stmt_lines = find_stmt_lines(buf_lines, start_line, end_line)
  return table.concat(parts, "\n"), stmt_lines, #directives
end

--- Extract primary table name from a SQL statement.
--- Returns nil for JOINs with 2+ tables (use "result n" instead).
local function extract_table_name(sql)
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
local function get_stmt_sql(buf_lines, stmt_lines, idx, max_end)
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

--- Install keymaps for this SQL buffer (one-time setup).
local function ensure_sql_keymaps(buf)
  if vim.b[buf].poste_sql_keymaps_installed then return end
  vim.b[buf].poste_sql_keymaps_installed = true

  local keymap_opts = { buffer = buf, noremap = true, silent = true }

  -- Normal mode: execute statement at cursor
  vim.keymap.set("n", "<CR>", function()
    M.run_sql_request()
  end, keymap_opts)

  -- K: show DDL for table under cursor
  vim.keymap.set("n", "K", function()
    M.show_table_ddl()
  end, keymap_opts)

  -- Visual mode: execute selected statements
  vim.keymap.set("x", "<CR>", function()
    _vis_start = vim.fn.line("v")
    _vis_end = vim.fn.line(".")
    _vis_active = true
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
      "n", false
    )
    M.run_sql_request()
  end, keymap_opts)

  -- CursorMoved: update context indicator in statusline
  local augroup = "PosteSQLContext_" .. buf
  pcall(vim.api.nvim_del_augroup_by_name, augroup)
  local group = vim.api.nvim_create_augroup(augroup, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    callback = function()
      if vim.api.nvim_get_current_buf() ~= buf then return end
      local ctx_mod = require("poste.sql.context")
      local text = ctx_mod.get_cursor_status_text(buf)
      vim.b[buf].poste_sql_context = text
    end,
  })
end
M.ensure_sql_keymaps = ensure_sql_keymaps

-- INSERT INTO value-to-column hint
require("poste.sql.insert_hint").setup()

-- Global: clear filter/search from any buffer
vim.keymap.set("n", "<leader>cr", function()
  local sql_buffer = require("poste.sql.buffer")
  if sql_buffer.is_open() then
    sql_buffer.clear_filter_search()
  end
end, { noremap = true, silent = true, desc = "Poste: clear filter/search" })

--------------------------------------------------------------------------------
-- Main entry point
--------------------------------------------------------------------------------

function M.run_sql_request()
  local src_buf = vim.api.nvim_get_current_buf()
  indicators.clear_all(src_buf)

  exec_seq = exec_seq + 1
  local current_seq = exec_seq

  -- Clear old dataset content before new async execution
  sql_buffer.clear_panel(current_seq)

  local binary = find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found.", vim.log.levels.ERROR)
    return
  end

  ensure_sql_keymaps(src_buf)

  local buf_lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
  local file = vim.api.nvim_buf_get_name(src_buf)
  if file == "" then
    file = vim.fn.getcwd() .. "/untitled.sql"
  end

  local is_visual = _vis_active
  _vis_active = false

  local buf_content
  local adjusted_line
  local stmt_lines = {}  -- buffer line numbers for indicators
  local visual_sel_end

  if is_visual then
    local sel_start = math.min(_vis_start, _vis_end)
    local sel_end = math.max(_vis_start, _vis_end)
    sel_start = math.max(1, sel_start)
    sel_end = math.min(#buf_lines, sel_end)
    visual_sel_end = sel_end
    local directive_count
    buf_content, stmt_lines, directive_count = extract_visual_block(buf_lines, sel_start, sel_end)

    -- Find adjusted_line: first non-blank/non-comment line after ### in buf_content
    local content_lines = vim.split(buf_content, "\n")
    adjusted_line = 0
    for j, ln in ipairs(content_lines) do
      local trimmed = ln:match("^%s*(.*)$")
      if trimmed ~= "" and not trimmed:match("^%-%-") and not trimmed:match("^###") then
        adjusted_line = j
        break
      end
    end
    if adjusted_line == 0 then
      adjusted_line = directive_count + 2
    end
    adjusted_line = math.max(1, adjusted_line)
  else
    local line = vim.fn.line(".")
    buf_content, adjusted_line, stmt_start = extract_stmt_at_cursor(buf_lines, line)
    stmt_lines = { stmt_start or 1 }
  end

  -- Set running indicators
  local first_line = stmt_lines[1]
  if not first_line then
    first_line = (is_visual and math.max(_vis_start or 0, _vis_end or 0) > 0)
      and math.min(_vis_start, _vis_end) or 1
  end
  first_line = math.max(1, math.min(first_line, #buf_lines))

  if #stmt_lines > 0 then
    for _, ln in ipairs(stmt_lines) do
      indicators.set_indicator(src_buf, ln - 1, "running")
    end
  else
    indicators.set_indicator(src_buf, first_line - 1, "running")
  end

  local cmd = string.format("%s run %s --line %d --env %s --json --stdin",
    vim.fn.shellescape(binary),
    vim.fn.shellescape(file),
    adjusted_line,
    vim.fn.shellescape(state.current_env)
  )

  local sql_context = require("poste.sql.context")
  local ctx
  if is_visual then
    local sel_start = math.min(_vis_start, _vis_end)
    ctx = sql_context.resolve_full_context(src_buf, math.max(1, sel_start - 1))
  else
    ctx = sql_context.resolve_full_context(src_buf)
  end
  local db = ctx.database
  if db and db ~= vim.NIL and db ~= "" then
    cmd = cmd .. " --database " .. vim.fn.shellescape(db)
  end

  state.log("INFO", string.format("SQL cmd: %s", cmd))

  local stderr_buf = {}

  local job_id = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      while #data > 0 and data[#data] == "" do
        data[#data] = nil
      end
      if #data == 0 then return end

      local output = table.concat(data, "\n")
      state.log("INFO", "SQL stdout: " .. output:sub(1, 200))

local seq = current_seq
      vim.schedule(function()
        if seq < exec_seq then
          return
        end
        local ok, parsed = pcall(vim.json.decode, output)
        if ok and parsed and type(parsed) == "table" then
          state.last_response = parsed

          -- If raw mode was active, restore dataset buffer before rendering new results
          require("poste.sql.buffer_nav").restore_from_raw_mode()

          sql_context.handle_use_statement(parsed)

          -- Decode body to get actual SQL results
          local ok_body, data = pcall(vim.json.decode, parsed.body)
          if not ok_body or type(data) ~= "table" then
            data = nil
          end

            local results = data and data.results or {}
            local is_multi = #results > 1

          if is_multi then
            for i, result in ipairs(results) do
              if result.error then
                local err_line = stmt_lines[i] or first_line
                indicators.set_indicator(src_buf, err_line - 1, "error")
                local err_text = type(result.error) == "string" and result.error or vim.inspect(result.error)
                local lines = sql_format.format_error(err_text, data.connection or "")
                sql_buffer.render_dataset(lines, { type = "error" }, { tab_index = i, exec_seq = seq })
              else
                local sql_text = get_stmt_sql(buf_lines, stmt_lines, i, visual_sel_end)
                local table_name = extract_table_name(sql_text)
                local single_data = {
                  type = "resultset",
                  results = { result },
                  total_rows = tonumber(result.row_count) or 0,
                  total_affected = tonumber(result.affected_rows) or 0,
                  total_execution_time_ms = tonumber(result.execution_time_ms) or 0,
                  connection = result.connection or data.connection,
                  database = data.database,
                  dialect = data.dialect,
                  table_name = table_name,
                }
                local layout = sql_format.plan_resultset_layout(single_data)
                local lines, meta
                if layout then
                  lines, meta = sql_format.render_page(layout, 1, 50)
                  meta.table_name = table_name
                else
                  lines, meta = sql_format.format_resultset(single_data)
                end
                sql_buffer.render_dataset(lines, meta, { tab_index = i, exec_seq = seq, data = single_data, layout = layout })

                local line_nr = stmt_lines[i] or first_line
                indicators.set_indicator(src_buf, line_nr - 1, "success", result.execution_time_ms)
              end
            end
          else
            -- Single result
            local table_name
            if is_visual then
              local start_ln = math.min(_vis_start, _vis_end)
              local end_ln = math.max(_vis_start, _vis_end)
              local vis_lines = {}
              for i = start_ln, end_ln do
                local ln = buf_lines[i]
                if ln then vis_lines[#vis_lines + 1] = ln end
              end
              table_name = extract_table_name(table.concat(vis_lines, " "))
            else
              table_name = extract_table_name(buf_content)
            end
            local lines, meta, layout = sql_format.format_dataset(parsed)

            -- Auto-prompt for raw mode when many columns
            if layout and not state.sql._raw_mode and #layout.columns > 30 then
              vim.schedule(function()
                vim.ui.select({ "Yes", "No" }, {
                  prompt = string.format("%d columns detected. Switch to plain-table (no pagination/navigation)?", #layout.columns),
                  title = "Poste SQL",
                }, function(choice)
                  if choice == "Yes" then
                    vim.schedule(function()
                      require("poste.sql.buffer_nav").toggle_raw_mode()
                    end)
                  end
                end)
              end)
            end
            if table_name then meta.table_name = table_name end
            sql_buffer.render_dataset(lines, meta, { exec_seq = seq, layout = layout })

            local has_err = results[1] and results[1].error
            if has_err then
              indicators.set_indicator(src_buf, first_line - 1, "error")
            else
              indicators.set_indicator(src_buf, first_line - 1, "success", parsed.latency_ms)
            end
          end
        else
          state.log("WARN", "SQL JSON parse failed, showing raw output")
          indicators.set_indicator(src_buf, first_line - 1, "error")
          local lines = sql_format.format_error("JSON parse failed\n\n" .. output, "")
          sql_buffer.render_dataset(lines, { type = "error" }, { exec_seq = seq })
        end
      end)
    end,
    on_stderr = function(_, data)
      if not data then return end
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(stderr_buf, l) end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        state.log("ERROR", string.format("SQL exit code %d", code))
        vim.schedule(function()
          if current_seq < exec_seq then return end
          indicators.set_indicator(src_buf, first_line - 1, "error")
          local stderr_text = table.concat(stderr_buf, "\n")
          local lines = sql_format.format_error(
            stderr_text ~= "" and stderr_text or "Query failed with exit code " .. code,
            state.sql.context.connection or ""
          )
          sql_buffer.render_dataset(lines, { type = "error" })
        end)
      end
    end,
  })

  if job_id > 0 then
    vim.fn.chansend(job_id, buf_content)
    vim.fn.chanclose(job_id, "stdin")
  else
    indicators.set_indicator(src_buf, first_line - 1, "error")
    vim.notify("Failed to start poste job", vim.log.levels.ERROR, { title = "Poste SQL" })
  end
end

M._test = {
  extract_stmt_at_cursor = extract_stmt_at_cursor,
  find_stmt_lines = find_stmt_lines,
  extract_visual_block = extract_visual_block,
  try_rust_stmt_span = try_rust_stmt_span,
  find_block_for_line = find_block_for_line,
}

--- Show column info in a float window.
local function show_column_info(binary, conn, db, file, table_name, col_name)
  local cmd = string.format("%s introspect %s --type columns --table %s --env %s",
    vim.fn.shellescape(binary),
    vim.fn.shellescape(conn),
    vim.fn.shellescape(table_name),
    vim.fn.shellescape(state.current_env)
  )
  if file and file ~= "" then
    cmd = cmd .. " --path " .. vim.fn.shellescape(vim.fn.fnamemodify(file, ":h"))
  end
  if db and db ~= vim.NIL and db ~= "" then
    cmd = cmd .. " --database " .. vim.fn.shellescape(db)
  end

  state.log("INFO", "Column info cmd: " .. cmd)

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      while #data > 0 and data[#data] == "" do
        data[#data] = nil
      end
      if #data == 0 then return end

      local output = table.concat(data, "\n")
      vim.schedule(function()
        local ok, parsed = pcall(vim.json.decode, output)
        if not ok or type(parsed) ~= "table" then
          vim.notify("Failed to parse introspection response", vim.log.levels.ERROR, { title = "Poste SQL" })
          return
        end

        local items = parsed.items
        if not items or #items == 0 then
          vim.notify("No columns found for table '" .. table_name .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
          return
        end

        local col = nil
        for _, c in ipairs(items) do
          if c.name == col_name then col = c; break end
        end
        if not col then
          vim.notify("Column '" .. col_name .. "' not found in table '" .. table_name .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
          return
        end

        local lines = {
          "  Table:    " .. table_name,
          "  Type:     " .. tostring(col.type or ""),
          "  Nullable: " .. tostring(col.nullable == true and "YES" or (col.nullable == false and "NO" or "?")),
          "  Default:  " .. tostring(col.default or "(null)"),
        }
        if col.max_length then
          table.insert(lines, "  Max Len:  " .. tostring(col.max_length))
        end
        if col.comment and col.comment ~= vim.NIL then
          table.insert(lines, "  Comment:  '" .. tostring(col.comment) .. "'")
        end

        show_float(lines, "Column: " .. col_name, "sql")
      end)
    end,
    on_stderr = function(_, data)
      if not data then return end
      for _, l in ipairs(data) do
        if l ~= "" then state.log("ERROR", "Column info stderr: " .. l) end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          vim.notify("Column introspection exited with code " .. code, vim.log.levels.ERROR, { title = "Poste SQL" })
        end)
      end
    end,
  })
end

--- Show DDL for the table under the cursor in a floating window.
function M.show_table_ddl()
  local binary = find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found.", vim.log.levels.ERROR, { title = "Poste SQL" })
    return
  end

  -- Check if cursor is on a -- @database <name> line → list tables
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""
  local db_match = line_text:match("^%s*--%s*@database%s+(.+)")
  if db_match then
    local db_name = vim.trim(db_match)
    local ctx = require("poste.sql.context").resolve_full_context(buf, line_num)
    local conn = ctx.connection
    if not conn then
      vim.notify("No connection context for database '" .. db_name .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
      return
    end
    local file = vim.api.nvim_buf_get_name(buf)
    if file == "" then file = vim.fn.getcwd() .. "/query.sql" end
    local search_dir = vim.fn.fnamemodify(file, ":h")
    local cmd = string.format("%s introspect %s --type tables --database %s --env %s --path %s",
      vim.fn.shellescape(binary),
      vim.fn.shellescape(conn),
      vim.fn.shellescape(db_name),
      vim.fn.shellescape(state.current_env),
      vim.fn.shellescape(search_dir))
    vim.fn.jobstart(cmd, {
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        if not data then return end
        while #data > 0 and data[#data] == "" do data[#data] = nil end
        if #data == 0 then return end
        local output = table.concat(data, "\n")
        vim.schedule(function()
          local ok, parsed = pcall(vim.json.decode, output)
          if not ok or type(parsed) ~= "table" then
            vim.notify("Failed to list tables", vim.log.levels.ERROR, { title = "Poste SQL" })
            return
          end
          local items = parsed.items
          if not items or #items == 0 then
            vim.notify("No tables found in database '" .. db_name .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
            return
          end
          local lines = {}
          for _, t in ipairs(items) do
            table.insert(lines, "  " .. t.name .. "  (" .. t.type .. ")")
          end
          show_float(lines, "Tables: " .. db_name)
        end)
      end,
      on_stderr = function(_, data)
        if not data then return end
        for _, l in ipairs(data) do
          if l ~= "" then state.log("ERROR", "introspect stderr: " .. l) end
        end
      end,
      on_exit = function(_, code)
        if code ~= 0 then
          vim.schedule(function()
            vim.notify("Table listing failed with exit code " .. code, vim.log.levels.ERROR, { title = "Poste SQL" })
          end)
        end
      end,
    })
    return
  end

  -- Check if cursor is on a -- @connection <name> line → show config
  local conn_match = line_text:match("^%s*--%s*@connection%s+(.+)")
  if conn_match then
    local conn_name = vim.trim(conn_match)
    local config = require("poste.sql.connections").get_connection_config(conn_name)
    if not config then
      vim.notify("Connection '" .. conn_name .. "' not found in connections.json", vim.log.levels.WARN, { title = "Poste SQL" })
      return
    end
    local lines = {}
    local label_width = 10
    local fields = {
      { "Dialect", config.dialect },
      { "Host", config.host },
      { "Port", config.port },
      { "Database", config.database },
      { "User", config.user },
      { "Socket", config.path },
    }
    for _, f in ipairs(fields) do
      if f[2] and f[2] ~= "" then
        table.insert(lines, string.format("  %s%s  %s", string.rep(" ", label_width - #f[1]), f[1], f[2]))
      end
    end
    show_float(lines, "Connection: " .. conn_name)
    return
  end

  local cword = vim.fn.expand("<cword>")
  if not cword or cword == "" then
    vim.notify("No word under cursor", vim.log.levels.WARN, { title = "Poste SQL" })
    return
  end
  local keywords = {}
  local kw_list = { "select","from","where","join","on",
                     "and","or","set","insert","into",
                     "values","update","delete","create","modify",
                     "table","index","drop","alter","add",
                     "column","primary","key","foreign",
                     "references","not","null","default",
                     "unique","check","constraint","as",
                     "left","right","inner","outer","cross",
                     "full","order","by","group","having",
                     "limit","offset","union","all","distinct",
                     "exists","in","like","between","case",
                     "when","then","else","end","count",
                     "sum","avg","min","max","true","false" }
  for _, kw in ipairs(kw_list) do keywords[kw] = true end
  if keywords[cword:lower()] then
    vim.notify("'" .. cword .. "' is a SQL keyword", vim.log.levels.INFO, { title = "Poste SQL" })
    return
  end

  local sql_context = require("poste.sql.context")
  local buf = vim.api.nvim_get_current_buf()
  local ctx = sql_context.resolve_full_context(buf)
  local conn = ctx.connection
  if not conn or conn == "" then
    vim.notify("No SQL connection context. Add -- @connection <name> to the file header.", vim.log.levels.ERROR, { title = "Poste SQL" })
    return
  end

  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then
    file = vim.fn.getcwd() .. "/query.sql"
  end
  local db = ctx.database

  -- Try to detect if cursor is on a column name via Rust context detection
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local col = cursor[2]
  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local line_text = all_lines[line_num] or ""
  local line_len = #line_text

  local end_col = col
  while end_col < line_len do
    local ch = line_text:sub(end_col + 1, end_col + 1)
    if ch:match("[%w_]") then end_col = end_col + 1 else break end
  end

  -- Check for .column suffix (alias.column → column part)
  local after_dot_col = nil
  local nxt = line_text:sub(end_col + 1, end_col + 1)
  if nxt == "." then
    local cm = line_text:match("^([%w_]+)", end_col + 2)
    if cm then after_dot_col = cm end
  end

  if after_dot_col then
    -- alias.column pattern: resolve alias via context detection
    local block_start = 1
    if line_num > 1 then
      for i = line_num - 1, 1, -1 do
        if all_lines[i] and all_lines[i]:match("^###") then block_start = i + 1; break end
      end
    end
    local block_end = #all_lines
    for i = line_num + 1, #all_lines do
      if all_lines[i] and all_lines[i]:match("^###") then block_end = i - 1; break end
    end
    if block_start <= line_num and line_num <= block_end then
      local before_parts = {}
      for i = block_start, line_num - 1 do
        table.insert(before_parts, all_lines[i] or "")
      end
      -- Include alias.column for context: extend end_col past .column
      local xtra = end_col + 1 + #after_dot_col
      table.insert(before_parts, line_text:sub(1, xtra))
      local offset = #table.concat(before_parts, "\n")
      local block_parts = {}
      for i = block_start, block_end do table.insert(block_parts, all_lines[i] or "") end
      local sql_text = table.concat(block_parts, "\n")
      local dial = ""
      local cc = require("poste.sql.connections").get_connection_config(conn)
      if cc and cc.dialect then dial = " --dialect " .. cc.dialect end
      local cmd = string.format("%s context detect %d%s", vim.fn.shellescape(binary), offset, dial)
      local out = vim.fn.system(cmd, sql_text)
      if vim.v.shell_error == 0 and out and out ~= "" then
        local ok, parsed = pcall(vim.json.decode, out)
        if ok and parsed then
          local function cclean(t)
            for k, v in pairs(t) do
              if v == vim.NIL then t[k] = nil elseif type(v) == "table" then cclean(v) end
            end
          end
          cclean(parsed)
          local pt = nil
          local prefix = parsed.ctx_data or cword
          if parsed.tables then
            for _, t in ipairs(parsed.tables) do
              if t.alias and t.alias:lower() == prefix:lower() then pt = t.name; break end
            end
          end
          if pt then
            show_column_info(binary, conn, db, file, pt, after_dot_col)
            return
          end
        end
      end
    end
  end

  -- Check if cword is a column name (not a table) via context detection
  local block_start = 1
  if line_num > 1 then
    for i = line_num - 1, 1, -1 do
      if all_lines[i] and all_lines[i]:match("^###") then block_start = i + 1; break end
    end
  end
  local block_end = #all_lines
  for i = line_num + 1, #all_lines do
    if all_lines[i] and all_lines[i]:match("^###") then block_end = i - 1; break end
  end

  if block_start <= line_num and line_num <= block_end then
    local before_parts = {}
    for i = block_start, line_num - 1 do
      table.insert(before_parts, all_lines[i] or "")
    end
    table.insert(before_parts, line_text:sub(1, end_col))
    local offset = #table.concat(before_parts, "\n")

    local block_parts = {}
    for i = block_start, block_end do table.insert(block_parts, all_lines[i] or "") end
    local sql_text = table.concat(block_parts, "\n")

    local dial = ""
    local cc = require("poste.sql.connections").get_connection_config(conn)
    if cc and cc.dialect then dial = " --dialect " .. cc.dialect end

    local cmd = string.format("%s context detect %d%s",
      vim.fn.shellescape(binary), offset, dial)
    local out = vim.fn.system(cmd, sql_text)
    if vim.v.shell_error == 0 and out and out ~= "" then
      local ok, parsed = pcall(vim.json.decode, out)
      if ok and parsed then
        local function clean(t)
          for k, v in pairs(t) do
            if v == vim.NIL then t[k] = nil
            elseif type(v) == "table" then clean(v) end
          end
        end
        clean(parsed)

        local ct = parsed.ctx_type
        local tables = parsed.tables

        -- Resolve column: check if cword is a known column (not table name)
        local is_column = false
        local parent_table = nil
        local col_name = cword

        if ct == "dot_column" and parsed.ctx_data then
          -- alias.column: resolve alias
          local prefix = parsed.ctx_data
          if tables then
            for _, t in ipairs(tables) do
              if t.alias and t.alias:lower() == prefix:lower() then
                parent_table = t.name; break
              end
            end
          end
          is_column = parent_table ~= nil
        elseif (ct == "column" or ct == "keyword") and tables and #tables > 0 then
          -- Check if cword is NOT a table name → it's a column
          local is_table = false
          for _, t in ipairs(tables) do
            local tn = (t.name or ""):lower()
            local ta = (t.alias or ""):lower()
            if tn == cword:lower() or ta == cword:lower() then is_table = true; break end
          end
          if not is_table then
            -- Not a table name: use first table as parent, cword is column
            parent_table = tables[1].name or tables[1].alias
            is_column = parent_table ~= nil
          end
        end

        if is_column and parent_table then
          show_column_info(binary, conn, db, file, parent_table, cword)
          return
        end
      end
    end
  end

  -- Fallback: show DDL (table mode)
  local cmd = string.format("%s introspect %s --type ddl --table %s --env %s",
    vim.fn.shellescape(binary),
    vim.fn.shellescape(conn),
    vim.fn.shellescape(cword),
    vim.fn.shellescape(state.current_env)
  )
  if file and file ~= "" then
    cmd = cmd .. " --path " .. vim.fn.shellescape(vim.fn.fnamemodify(file, ":h"))
  end
  if db and db ~= vim.NIL and db ~= "" then
    cmd = cmd .. " --database " .. vim.fn.shellescape(db)
  end

  state.log("INFO", "DDL cmd: " .. cmd)

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      while #data > 0 and data[#data] == "" do
        data[#data] = nil
      end
      if #data == 0 then return end

      local output = table.concat(data, "\n")
      vim.schedule(function()
        local ok, parsed = pcall(vim.json.decode, output)
        if not ok or type(parsed) ~= "table" then
          vim.notify("Failed to parse DDL response", vim.log.levels.ERROR, { title = "Poste SQL" })
          return
        end

        local items = parsed.items
        if not items or #items == 0 then
          vim.notify("No DDL found for table '" .. cword .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
          return
        end

        local ddl_text = items[1].ddl
        if not ddl_text or ddl_text == "" then
          vim.notify("No DDL found for table '" .. cword .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
          return
        end

        local lines = vim.split(ddl_text, "\n", { plain = true })
        show_float(lines, "DDL: " .. cword, "sql")
      end)
    end,
    on_stderr = function(_, data)
      if not data then return end
      for _, l in ipairs(data) do
        if l ~= "" then state.log("ERROR", "DDL stderr: " .. l) end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          vim.notify("DDL introspection exited with code " .. code, vim.log.levels.ERROR, { title = "Poste SQL" })
        end)
      end
    end,
  })
end

--- Show column info in a float window.
--- @param binary string
--- @param conn string
--- @param db string|nil
--- @param file string
--- @param table_name string Parent table
--- @param col_name string Column name under cursor
return M
