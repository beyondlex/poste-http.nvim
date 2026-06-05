--- SQL execution entry point.
--- Mirrors the HTTP flow in init.lua but dispatches to the dataset buffer.
local state = require("poste.state")
local indicators = require("poste.indicators")
local sql_format = require("poste.sql.format")
local sql_buffer = require("poste.sql.buffer")

local M = {}

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
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "left",
  }
  local ok, win = pcall(vim.api.nvim_open_win, float_buf, true, win_opts)
  if not ok then
    win_opts.title = nil
    win = vim.api.nvim_open_win(float_buf, true, win_opts)
  end

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].scrolloff = 1
  vim.wo[win].cursorline = true

  local sopts = { buffer = float_buf, noremap = true, silent = true }
  vim.keymap.set("n", "j", "<C-e>", sopts)
  vim.keymap.set("n", "k", "<C-y>", sopts)
  vim.keymap.set("n", "d", "<C-d>", sopts)
  vim.keymap.set("n", "u", "<C-u>", sopts)
  vim.keymap.set("n", "g", "gg", sopts)
  vim.keymap.set("n", "G", "G", sopts)
  local close_fn = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close_fn, sopts)
  vim.keymap.set("n", "<Esc>", close_fn, sopts)
end

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

--- Extract the SQL statement under the cursor, delimited purely by semicolons.
--- Collects file-level directives and wraps the statement in a synthetic ### block.
--- Returns (content_string, adjusted_line_number).
local function extract_stmt_at_cursor(buf_lines, cursor_line)
  -- Collect file-level directive lines (comment lines at top of file)
  local directives = {}
  for _, l in ipairs(buf_lines) do
    if l:match("^%s*%-%-") or l:match("^%s*$") then
      table.insert(directives, l)
    else
      break
    end
  end

  -- Find statement start: walk backward from cursor-1, stop at a line containing ';'
  local stmt_start = 1
  for i = cursor_line - 1, 1, -1 do
    if (buf_lines[i] or ""):match(";") then
      stmt_start = i + 1
      break
    end
  end
  -- Skip leading blank lines
  while stmt_start <= cursor_line and (buf_lines[stmt_start] or ""):match("^%s*$") do
    stmt_start = stmt_start + 1
  end

  -- Find statement end: walk forward from cursor, stop at line containing ';'
  local stmt_end = #buf_lines
  for i = cursor_line, #buf_lines do
    if (buf_lines[i] or ""):match(";") then
      stmt_end = i
      break
    end
  end

  local stmt_lines = {}
  for i = stmt_start, stmt_end do
    table.insert(stmt_lines, buf_lines[i] or "")
  end

  local parts = {}
  for _, l in ipairs(directives) do table.insert(parts, l) end
  table.insert(parts, "###")
  for _, l in ipairs(stmt_lines) do table.insert(parts, l) end

  local adjusted_line = #directives + 1 + (cursor_line - stmt_start + 1)
  return table.concat(parts, "\n"), adjusted_line, stmt_start
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

  -- Always extract the statement under the cursor using semicolons as delimiters.
  -- ### in the file is treated as a comment/label, not an execution boundary.
  local buf_content, adjusted_line, stmt_start = extract_stmt_at_cursor(buf_lines, line)
  line = adjusted_line

  -- Indicator at the first non-blank line of the current statement
  local req_line = (stmt_start or 1) - 1  -- 0-indexed for extmark
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

--- Show DDL for the table under the cursor in a floating window.
--- Resolves the connection context and runs `poste introspect --type ddl`.
function M.show_table_ddl()
  local binary = find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found.", vim.log.levels.ERROR, { title = "Poste SQL" })
    return
  end

  -- Get the word under cursor
  local table_name = vim.fn.expand("<cword>")
  if not table_name or table_name == "" then
    vim.notify("No word under cursor", vim.log.levels.WARN, { title = "Poste SQL" })
    return
  end
  -- Skip SQL keywords (use ["key"] form for Lua reserved words)
  local keywords = {}
  local kw_list = { "select","from","where","join","on",
                     "and","or","set","insert","into",
                     "values","update","delete","create",
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
  if keywords[table_name:lower()] then
    vim.notify("'" .. table_name .. "' is a SQL keyword", vim.log.levels.INFO, { title = "Poste SQL" })
    return
  end

  -- Resolve connection context
  local sql_context = require("poste.sql.context")
  local ctx = sql_context.resolve_context(vim.api.nvim_get_current_buf())
  local conn = ctx.connection or state.sql.context.connection
  if not conn or conn == "" then
    vim.notify("No SQL connection context. Add -- @connection <name> to the file header.", vim.log.levels.ERROR, { title = "Poste SQL" })
    return
  end

  -- Get the file path for connections.json discovery
  local file = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  if file == "" then
    file = vim.fn.getcwd() .. "/query.sql"
  end

  local db = state.sql.context.database
  local cmd = string.format("%s introspect %s --type ddl --table %s --env %s",
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
          vim.notify("No DDL found for table '" .. table_name .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
          return
        end

        local ddl_text = items[1].ddl
        if not ddl_text or ddl_text == "" then
          vim.notify("No DDL found for table '" .. table_name .. "'", vim.log.levels.WARN, { title = "Poste SQL" })
          return
        end

        local lines = vim.split(ddl_text, "\n", { plain = true })
        show_float(lines, "DDL: " .. table_name, "sql")
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

return M
