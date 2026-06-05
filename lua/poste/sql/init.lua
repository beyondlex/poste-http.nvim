--- SQL execution entry point.
--- Mirrors the HTTP flow in init.lua but dispatches to the dataset buffer.
local state = require("poste.state")
local indicators = require("poste.indicators")
local sql_format = require("poste.sql.format")
local sql_buffer = require("poste.sql.buffer")

local M = {}

---------------------------------------------------------------------------
-- Binary discovery (reuse from main init)
---------------------------------------------------------------------------
local function find_poste_binary()
  if state.config.poste_binary ~= "" then
    return state.config.poste_binary
  end
  local local_paths = {
    "./target/debug/poste",
    "./target/release/poste",
  }
  for _, path in ipairs(local_paths) do
    if vim.fn.filereadable(path) == 1 then
      return vim.fn.fnamemodify(path, ":p")
    end
  end
  return nil
end

--- Given buffer lines and a 1-based cursor line, return the content to send
--- to the CLI when there are no ### separators around the cursor.
--- Extracts file-level directives (@connection, @database, -- @...) plus
--- the SQL statement under the cursor (delimited by semicolons or blank lines).
--- Returns (content_string, adjusted_line_number).
local function extract_stmt_at_cursor(buf_lines, cursor_line)
  -- Collect file-level directive lines (before any non-directive content)
  local directives = {}
  for _, l in ipairs(buf_lines) do
    if l:match("^%s*%-%-") or l:match("^%s*$") then
      table.insert(directives, l)
    else
      break
    end
  end

  -- Find the statement containing cursor_line using ; as delimiter.
  -- Walk backward to find start (previous ; or start of file).
  local stmt_start = 1
  for i = cursor_line - 1, 1, -1 do
    local l = buf_lines[i] or ""
    if l:match(";%s*$") or l:match(";%s*%-%-") then
      stmt_start = i + 1
      break
    end
  end

  -- Walk forward to find end (next ; or end of file).
  local stmt_end = #buf_lines
  for i = cursor_line, #buf_lines do
    local l = buf_lines[i] or ""
    if l:match(";") then
      stmt_end = i
      break
    end
  end

  -- Extract the statement lines
  local stmt_lines = {}
  for i = stmt_start, stmt_end do
    table.insert(stmt_lines, buf_lines[i] or "")
  end

  -- Build content: directives + ### + statement
  local parts = {}
  for _, l in ipairs(directives) do table.insert(parts, l) end
  table.insert(parts, "###")
  for _, l in ipairs(stmt_lines) do table.insert(parts, l) end

  local content = table.concat(parts, "\n")
  -- The cursor line in the new content: directives + 1 (for ###) + offset within stmt
  local adjusted_line = #directives + 1 + (cursor_line - stmt_start + 1)
  return content, adjusted_line
end

--- Execute the SQL request at the cursor position.
--- Sends the buffer content to the poste CLI and renders the dataset.
function M.run_sql_request()
  local binary = find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found. Make sure it's in PATH or built locally.", vim.log.levels.ERROR)
    return
  end

  local src_buf = vim.api.nvim_get_current_buf()
  local line = vim.fn.line(".")

  local file = vim.api.nvim_buf_get_name(src_buf)
  if file == "" then
    file = vim.fn.getcwd() .. "/untitled.sql"
  end

  local buf_lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
  local buf_content = table.concat(buf_lines, "\n")

  -- If the cursor is not inside a ### block, extract the statement at cursor
  -- delimited by semicolons and wrap it in a synthetic ### block.
  local in_hash_block = false
  for i = line, 1, -1 do
    if (buf_lines[i] or ""):match("^%s*###") then
      in_hash_block = true
      break
    end
  end
  local orig_line = line  -- keep for indicator fallback
  if not in_hash_block then
    local new_content, new_line = extract_stmt_at_cursor(buf_lines, line)
    buf_content = new_content
    line = new_line
  end

  -- Show spinner (fall back to original cursor line when no ### block)
  local req_line = indicators.find_request_line(src_buf, orig_line)
  if not req_line then req_line = orig_line - 1 end  -- 0-indexed fallback
  indicators.set_indicator(src_buf, req_line, "running")

  local cmd = string.format("%s run %s --line %d --env %s --json --stdin",
    vim.fn.shellescape(binary),
    vim.fn.shellescape(file),
    line,
    vim.fn.shellescape(state.current_env)
  )

  -- Resolve context from buffer at cursor position (block-level @connection,
  -- @database, and preceding USE statements take priority over global state)
  local sql_context = require("poste.sql.context")
  local ctx = sql_context.resolve_context(src_buf)

  -- Pass database context: prefer block-resolved, fall back to global state
  local db = ctx.database or state.sql.context.database
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

      vim.schedule(function()
        local ok, parsed = pcall(vim.json.decode, output)
        if ok and parsed and type(parsed) == "table" then
          state.last_response = parsed

          -- Handle USE statement: update context
          local sql_context = require("poste.sql.context")
          sql_context.handle_use_statement(parsed)

          -- Format and render the dataset
          local lines, meta = sql_format.format_dataset(parsed)
          sql_buffer.render_dataset(lines, meta)

          indicators.set_indicator(src_buf, req_line, "success", parsed.latency_ms)
        else
          state.log("WARN", "SQL JSON parse failed, showing raw output")
          indicators.set_indicator(src_buf, req_line, "error")
          local lines = sql_format.format_error("JSON parse failed\n\n" .. output, "")
          sql_buffer.render_dataset(lines, { type = "error" })
        end
      end)
    end,
    on_stderr = function(_, data)
      if not data then return end
      while #data > 0 and data[#data] == "" do
        data[#data] = nil
      end
      if #data == 0 then return end
      for _, l in ipairs(data) do
        table.insert(stderr_buf, l)
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        state.log("ERROR", string.format("SQL exit code %d (line %d)", code, line))
        vim.schedule(function()
          indicators.set_indicator(src_buf, req_line, "error")
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
    indicators.set_indicator(src_buf, req_line, "error")
    vim.notify("Failed to start poste job", vim.log.levels.ERROR, { title = "Poste SQL" })
  end
end

M._test = { extract_stmt_at_cursor = extract_stmt_at_cursor }

return M
