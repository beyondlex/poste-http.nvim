--- SQL execution entry point — supports single-statement (normal mode)
--- and multi-statement (visual selection) execution.
--- Each statement result goes into its own dataset tab.
local state = require("poste.state")
local util = require("poste.util")
local indicators = require("poste.indicators")
local statement = require("poste.sql.statement")
local sql_introspect = require("poste.sql.introspect")
local sql_format = require("poste.sql.format")
local sql_buffer = require("poste.sql.buffer")

local M = {}

-- Execution tracking for callback ordering
local exec_seq = 0
local _vis_active = false
local _vis_start = 0
local _vis_end = 0

-- CursorMoved debounce to avoid jitter from repeated context resolution
local _cursor_moved_timer = nil
local CURSOR_MOVED_DEBOUNCE_MS = 100

-- Shared SQL syntax highlighter
local syntax = require("poste.sql.syntax")

--- Apply shared SQL syntax highlighting to a source buffer.
--- Skips comments, directives, separators, and blank lines.
local _syn_ns = vim.api.nvim_create_namespace("poste_sql_syntax")
local function apply_source_highlights(buf)
  vim.api.nvim_buf_clear_namespace(buf, _syn_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line ~= "" and not line:match("^%s*%-%-") and not line:match("^%s*###") then
      syntax.highlight_line(buf, _syn_ns, i, line, 0)
    end
  end
end

--- Debounced refresh of source buffer highlighting.
local _syn_timer = nil
local function schedule_syn_refresh(buf)
  if _syn_timer then _syn_timer:stop(); _syn_timer:close() end
  _syn_timer = vim.defer_fn(function()
    _syn_timer = nil
    if not vim.api.nvim_buf_is_valid(buf) then return end
    apply_source_highlights(buf)
  end, 150)
end


--- Install keymaps for this SQL buffer (one-time setup).
local function ensure_sql_keymaps(buf)
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if vim.b[buf].poste_sql_keymaps_installed then return end
  vim.b[buf].poste_sql_keymaps_installed = true

  -- Initial apply of shared SQL syntax highlighting
  apply_source_highlights(buf)

  local keymap_opts = { buffer = buf, noremap = true, silent = true }

  -- Normal mode: execute statement at cursor
  local k = state.get_keymap("sql_source", "run", "<CR>")
  if k then
    vim.keymap.set("n", k, function()
      M.run_sql_request()
    end, keymap_opts)
  end

  -- K: show DDL for table under cursor
  k = state.get_keymap("sql_source", "show_ddl", "K")
  if k then
    vim.keymap.set("n", k, function()
      M.show_table_ddl()
    end, keymap_opts)
  end

  -- Visual mode: execute selected statements (uses same key as normal run)
  k = state.get_keymap("sql_source", "run", "<CR>")
  if k then
    vim.keymap.set("x", k, function()
      _vis_start = vim.fn.line("v")
      _vis_end = vim.fn.line(".")
      _vis_active = true
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
        "n", false
      )
      M.run_sql_request()
    end, keymap_opts)
  end

  -- g?: show keymap help
  k = state.get_keymap("sql_source", "help", "g?")
  if k then
    vim.keymap.set("n", k, function() require("poste.help").open() end, keymap_opts)
  end

  -- <leader>l: toggle SQL execution log
  k = state.get_keymap("sql_source", "toggle_log", "<leader>l")
  if k then
    vim.keymap.set("n", k, function()
      require("poste.sql.log_viewer").toggle()
    end, keymap_opts)
  end

  -- Format SQL buffer/selection (default <leader>ff)
  k = state.get_keymap("sql_source", "format", "<leader>ff")
  if k then
    vim.keymap.set("n", k, function()
      local ok, source_format = pcall(require, "poste.sql.source_format")
      if ok then source_format.format() end
    end, keymap_opts)
    vim.keymap.set("x", k, function()
      local ok, source_format = pcall(require, "poste.sql.source_format")
      if ok then source_format.format() end
    end, keymap_opts)
  end

  -- CursorMoved: update context indicator in statusline + statement highlight
  local augroup = "PosteSQLContext_" .. buf
  pcall(vim.api.nvim_del_augroup_by_name, augroup)
  local group = vim.api.nvim_create_augroup(augroup, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    callback = function()
      if _cursor_moved_timer then
        _cursor_moved_timer:stop()
        _cursor_moved_timer:close()
      end
      _cursor_moved_timer = vim.defer_fn(function()
        _cursor_moved_timer = nil
        if vim.api.nvim_get_current_buf() ~= buf then return end
        local ok, ctx_mod = pcall(require, "poste.sql.context")
        if ok and ctx_mod then
          local ok2, text = pcall(ctx_mod.get_cursor_status_text, ctx_mod, buf)
          if ok2 and text then
            vim.b[buf].poste_sql_context = text
          end
        end
        local stmt_indicator = require("poste.sql.statement_indicator")
        stmt_indicator.update(buf, vim.fn.line("."))
      end, CURSOR_MOVED_DEBOUNCE_MS)
    end,
  })

  -- Refresh shared SQL syntax highlighting on text changes
  local syn_group = "PosteSQLSyntax_" .. buf
  pcall(vim.api.nvim_del_augroup_by_name, syn_group)
  local sg = vim.api.nvim_create_augroup(syn_group, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = sg,
    buffer = buf,
    callback = function() schedule_syn_refresh(buf) end,
  })
end
M.ensure_sql_keymaps = ensure_sql_keymaps

-- INSERT INTO value-to-column hint
require("poste.sql.insert_hint").setup()

-- Global: clear filter/search from any buffer
local ck = state.get_keymap("sql_source", "clear_filter", "<leader>cr")
if ck then
  vim.keymap.set("n", ck, function()
    local sql_buf = require("poste.sql.buffer")
    if sql_buf.is_open() then
      sql_buffer.clear_filter_search()
    end
  end, { noremap = true, silent = true, desc = "Poste: clear filter/search" })
end

--------------------------------------------------------------------------------
-- Main entry point
--------------------------------------------------------------------------------

function M.run_sql_request()
  local src_buf = vim.api.nvim_get_current_buf()

  local binary = state.find_poste_binary()
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

  -- Fresh SQL session: clears request-scoped dataset/response state (Phase 2b)
  require("poste.sql.session").begin({
    buf = src_buf,
    line = vim.fn.line("."),
    file = file,
  })

  local is_visual = _vis_active
  _vis_active = false

  local buf_content
  local adjusted_line
  local visual_sel_end

  if is_visual then
    local sel_start = math.min(_vis_start, _vis_end)
    local sel_end = math.max(_vis_start, _vis_end)
    sel_start = math.max(1, sel_start)
    sel_end = math.min(#buf_lines, sel_end)
    visual_sel_end = sel_end
    local directive_count
    buf_content, stmt_lines, directive_count = statement.extract_visual_block(buf_lines, sel_start, sel_end)

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
    local stmt_start
    buf_content, adjusted_line, stmt_start = statement.extract_stmt_at_cursor(buf_lines, line)
    if not buf_content then return end
    stmt_lines = { stmt_start or 1 }
  end

  -- Only clear after we confirm there's something to execute
  exec_seq = exec_seq + 1
  local current_seq = exec_seq
  indicators.clear_all(src_buf)
  sql_buffer.clear_panel(current_seq)

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
  -- Persist resolved context so it's available for dataset editing (PK introspection etc.)
  if ctx.connection then state.sql.context.connection = ctx.connection end
  if ctx.database then state.sql.context.database = ctx.database end
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
      data = util.ensure_job_data(data)
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

          -- Clear completion cache to pick up schema changes from DDL
          require("poste.sql.completion_data").clear_cache()

          -- If raw mode was active, restore dataset buffer before rendering new results
          require("poste.sql.buffer_nav").restore_from_raw_mode()

          sql_context.handle_use_statement(parsed)

          -- Decode body to get actual SQL results
          local ok_body, decoded = pcall(vim.json.decode, parsed.body)
          if not ok_body or type(decoded) ~= "table" then
            decoded = nil
          end

            local results = decoded and decoded.results or {}
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
                local sql_text = statement.get_stmt_sql(buf_lines, stmt_lines, i, visual_sel_end)
                local table_name = statement.extract_table_name(sql_text)
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
                sql_buffer.render_dataset(lines, meta, {
                  tab_index = i,
                  exec_seq = seq,
                  data = single_data,
                  layout = layout,
                  original_sql = buf_content,
                  src_file = file,
                  src_buf = src_buf,
                })

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
              table_name = statement.extract_table_name(table.concat(vis_lines, " "))
            else
              table_name = statement.extract_table_name(buf_content)
            end
            local lines, meta, layout = sql_format.format_dataset(parsed)
            if table_name then meta.table_name = table_name end
            sql_buffer.render_dataset(lines, meta, {
              exec_seq = seq,
              layout = layout,
              original_sql = buf_content,
              src_file = file,
              src_buf = src_buf,
            })

            local has_err = results[1] and results[1].error
            if has_err then
              indicators.set_indicator(src_buf, first_line - 1, "error")
            else
              indicators.set_indicator(src_buf, first_line - 1, "success", parsed.latency_ms)
              -- Log successful manual execution
              local edit_commit = require("poste.sql.edit_commit")
              local context = require("poste.sql.context").resolve_full_context(src_buf, first_line)
              edit_commit.write_log({
                source = "manual_exec",
                connection = context.connection or "",
                dialect = data and data.dialect or "",
                database = context.database or "",
                sql = buf_content or "",
                status = "success",
                elapsed_ms = tonumber(parsed.latency_ms) or 0,
              })
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
          -- Log failed execution
          local edit_commit = require("poste.sql.edit_commit")
          local context = require("poste.sql.context").resolve_full_context(src_buf, #buf_lines)
          edit_commit.write_log({
            source = "manual_exec",
            connection = context.connection or "",
            dialect = state.sql.context.dialect or "",
            database = context.database or "",
            sql = buf_content or "",
            status = "error",
            elapsed_ms = 0,
            error_msg = stderr_text:sub(1, 500),
          })
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

-- Delegate introspection to the dedicated module
M.show_table_ddl = sql_introspect.show_table_ddl

M._test = statement._test

-------------------------------------------------------------------------------
-- SQL setup — called from poste.init.setup()
-------------------------------------------------------------------------------

local buffer_setup = require("poste.buffer_setup")

local function register_sql_completion()
  local adapter = require("poste.sql.completion_adapter")
  if not adapter.is_available() then return end

  adapter.register_source({
    name = "poste_sql",
    module = "poste.sql.completion",
    label = "PosteSQL",
    async = true,
    score_offset = 1000,
    min_keyword_length = 0,
    should_show_items = true,
  })
  adapter.register_filetype("poste_sql", "poste_sql")
  adapter.register_filetype("poste_sqlite", "poste_sql")

  adapter.set_per_filetype("poste_sql", { "poste_sql" })
  adapter.set_per_filetype("poste_sqlite", { "poste_sql" })

  adapter.patch_blocked_trigger_chars()
end

local function setup_db_browser_keymap(buf)
  local k = state.get_keymap("sql_source", "toggle_db_browser", "<leader>db")
  if k then
    vim.keymap.set("n", k, function()
      require("poste.sql.db_browser").toggle()
    end, { buffer = buf, noremap = true, silent = true, desc = "Toggle DB Browser" })
  end
end

function M.setup(_)
  local ok = pcall(register_sql_completion)
  if not ok then
    local group = vim.api.nvim_create_augroup("PosteSQLCmpRegister", { clear = true })
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = group,
      once = true,
      callback = function()
        pcall(register_sql_completion)
        vim.api.nvim_del_augroup_by_name("PosteSQLCmpRegister")
      end,
    })
  end

  vim.api.nvim_create_user_command("PosteSQLCmpStatus", function()
    local sql_comp = require("poste.sql.completion")
    local ft = vim.bo.filetype
    local buf = vim.api.nvim_get_current_buf()

    local status = {
      "SQL Completion Status:",
      "  Current filetype: " .. ft,
      "  Buffer: " .. buf,
    }

    local instance = sql_comp.new()
    table.insert(status, "  Enabled: " .. tostring(instance:enabled()))

    table.insert(status, "  blink.cmp loaded: " .. tostring(require("poste.sql.completion_adapter").is_available()))
    local adapter = require("poste.sql.completion_adapter")
    if adapter.is_available() then
      local has_sql = adapter.has_provider("poste_sql")
      table.insert(status, "  poste_sql provider registered: " .. tostring(has_sql))
    end

    local ctx_mod = require("poste.sql.context")
    local ctx = ctx_mod.resolve_context(buf)
    table.insert(status, "  Connection: " .. (ctx.connection or "none"))
    table.insert(status, "  Database: " .. (ctx.database or "none"))

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    local col = cursor[2]
    local line_before = line:sub(1, col)

    table.insert(status, "\nAt cursor position (col=" .. col .. "):")
    table.insert(status, "  Line: " .. line)
    table.insert(status, "  Before cursor: '" .. line_before .. "'")
    table.insert(status, "  After cursor: '" .. line:sub(col + 1) .. "'")

    if sql_comp._test then
      local ctx_type, ctx_data = sql_comp._test.detect_context_for_completion(line_before)
      table.insert(status, "  Detected context: " .. tostring(ctx_type))
      if ctx_data then
        table.insert(status, "  Context data: " .. tostring(ctx_data))
      end
    end

    vim.notify(table.concat(status, "\n"), vim.log.levels.INFO)
  end, { desc = "Check SQL completion status" })

  vim.api.nvim_create_user_command("PosteSQLAutoTrigger", function()
    local group = vim.api.nvim_create_augroup("PosteSQLAutoComplete", { clear = true })
    vim.api.nvim_create_autocmd("TextChangedI", {
      group = group,
      buffer = 0,
      callback = function()
        local line = vim.api.nvim_get_current_line()
        local col = vim.api.nvim_win_get_cursor(0)[2]

        if col > 0 and line:sub(col, col) == " " then
          local before = line:sub(1, col - 1)
          local last_word = before:match("(%w+)%s*$")

          if last_word then
            local lw = last_word:lower()
            if lw == "from" or lw == "join" or lw == "where" or
               lw == "set" or lw == "on" or lw == "having" or
               lw == "by" or lw == "and" or lw == "or" then
              vim.schedule(function()
                pcall(function() require("poste.sql.completion_adapter").show() end)
              end)
            end
          end
        end
      end
    })
    vim.notify("SQL auto-trigger installed for current buffer", vim.log.levels.INFO)
  end, { desc = "Install SQL auto-trigger for completion" })

  vim.api.nvim_create_user_command("PosteSQLCmpReload", function()
    package.loaded["poste.sql.completion"] = nil
    require("poste.sql.completion")
    local adapter = require("poste.sql.completion_adapter")

    if not adapter.is_available() then
      vim.notify("blink.cmp not loaded, cannot re-register", vim.log.levels.WARN)
      return
    end
    adapter.register_source({
      name = "poste_sql",
      module = "poste.sql.completion",
      label = "PosteSQL",
      score_offset = 1000,
      min_keyword_length = 0,
      should_show_items = true,
    })
    adapter.register_filetype("poste_sql", "poste_sql")
    adapter.register_filetype("poste_sqlite", "poste_sql")
    vim.notify("SQL completion reloaded and re-registered with blink.cmp", vim.log.levels.INFO)
  end, { desc = "Reload SQL completion provider" })

  vim.api.nvim_create_user_command("PosteSQLDiag", function()
    local sql_comp = require("poste.sql.completion")
    local buf = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    local col = cursor[2]
    local line_before = line:sub(1, col)
    local cursor_lnum = cursor[1]

    local ctx_type, _ = sql_comp._test.detect_context_for_completion(line_before)
    local tbls, alias_map = sql_comp._test.extract_from_tables(buf, cursor_lnum)
    local conn = sql_comp._test.conn_key()

    local blink_src = require("poste.sql.completion_adapter").get_source_lib()
    local blink_config = require("poste.sql.completion_adapter").get_config()
    local active_providers = blink_src.get_enabled_provider_ids("insert")
    local per_ft = "(unavailable)"
    if blink_config.sources and blink_config.sources.per_filetype then
      per_ft = vim.inspect(blink_config.sources.per_filetype["poste_sql"])
    end
    local runtime_ft = vim.inspect(blink_src.per_filetype_provider_ids)

    local msg = {
      "line_before: '" .. line_before .. "'",
      "ctx: " .. tostring(ctx_type),
      "conn_key: " .. tostring(conn),
      "cursor_lnum: " .. cursor_lnum,
      "ft: " .. vim.bo.filetype,
      "active blink providers: " .. vim.inspect(active_providers),
      "static per_filetype[poste_sql]: " .. per_ft,
      "runtime per_filetype_provider_ids: " .. runtime_ft,
    }
    local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, cursor_lnum, false)
    for i, l in ipairs(buf_lines) do
      table.insert(msg, "  " .. i .. ": " .. l)
    end
    table.insert(msg, "tables: " .. vim.inspect(tbls))
    table.insert(msg, "alias_map: " .. vim.inspect(alias_map))

    sql_comp._test.get_items(buf, line_before, cursor_lnum, function(items)
      table.insert(msg, "items(" .. #items .. "): " .. vim.inspect(vim.list_slice(items, 1, 3)))
      vim.notify(table.concat(msg, "\n"), vim.log.levels.WARN)
    end)
  end, { desc = "Diagnose SQL completion at cursor" })

  vim.api.nvim_create_user_command("PosteSQLDebugSpace", function()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)
    local last_word = before:match("(%w+)%s*$")

    local adapter = require("poste.sql.completion_adapter")

    local msg = {
      "PosteSQLDebugSpace:",
      "  line_before cursor: '" .. before .. "'",
      "  last_word: " .. tostring(last_word),
      "  blink loaded: " .. tostring(adapter.is_available()),
      "  blink.show exists: " .. tostring(adapter.is_available()),
      "  menu currently open: " .. tostring(adapter.is_menu_open()),
    }

    if adapter.is_available() then
      vim.notify(table.concat(msg, "\n") .. "\n  → calling blink.show() now...", vim.log.levels.WARN)
      adapter.show()
    else
      vim.notify(table.concat(msg, "\n"), vim.log.levels.ERROR)
    end
  end, { desc = "Debug SQL space completion trigger" })

  vim.api.nvim_create_user_command("PosteSQLCmpTest", function()
    local sql_comp = require("poste.sql.completion")
    local buf = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    local col = cursor[2]
    local line_before = line:sub(1, col)
    local cursor_line = cursor[1]

    local status = {
      "SQL Completion Test:",
      "  line_before: '" .. line_before .. "'",
      "  cursor_line: " .. cursor_line,
    }

    if sql_comp._test then
      local ctx_type = sql_comp._test.detect_context_for_completion(line_before)
      table.insert(status, "  Context: " .. tostring(ctx_type))

      if ctx_type == "column" and sql_comp._test.extract_from_tables then
        local tbls = sql_comp._test.extract_from_tables(buf, cursor_line)
        table.insert(status, "  Tables found: " .. #tbls .. " - " .. vim.inspect(tbls))
      end

      local conn = sql_comp._test.conn_key and sql_comp._test.conn_key()
      table.insert(status, "  Connection key: " .. tostring(conn))
    end

    if sql_comp._test and sql_comp._test.get_items then
      sql_comp._test.get_items(buf, line_before, cursor_line, function(items)
        table.insert(status, "\nReturned " .. #items .. " items:")
        for i, item in ipairs(items) do
          if i <= 10 then
            table.insert(status, "  " .. item.label .. " (" .. (item.documentation or "") .. ")")
          end
        end
        if #items > 10 then
          table.insert(status, "  ... and " .. (#items - 10) .. " more")
        end
        vim.notify(table.concat(status, "\n"), vim.log.levels.INFO)
      end)
    else
      vim.notify(table.concat(status, "\n"), vim.log.levels.INFO)
    end
  end, { desc = "Test SQL completion at cursor" })

  vim.api.nvim_create_user_command("PosteSQLCmpDebug", function()
    require("poste.sql.completion_debug").toggle()
  end, { desc = "Toggle SQL completion debug floating window" })

  vim.api.nvim_create_user_command("PosteConnection", function()
    require("poste.sql.connections").show_menu()
  end, { desc = "Manage SQL connections" })

  vim.api.nvim_create_user_command("PosteFormat", function()
    local _, source_format = pcall(require, "poste.sql.source_format")
    if source_format then
      source_format.format_buffer()
    else
      vim.notify("Poste source_format module not available", vim.log.levels.ERROR)
    end
  end, { desc = "Format SQL buffer/selection using detected formatter (sqlfluff/sqlfmt/...)" })

  vim.api.nvim_create_user_command("PosteFormatStatus", function()
    local _, source_format = pcall(require, "poste.sql.source_format")
    if source_format then
      source_format.status()
    else
      vim.notify("Poste source_format module not available", vim.log.levels.ERROR)
    end
  end, { desc = "Show formatter status: installed, priority, dialect" })

  vim.api.nvim_create_user_command("PosteDBBrowser", function()
    require("poste.sql.db_browser").toggle()
  end, { desc = "Toggle database structure browser sidebar" })

  vim.api.nvim_create_user_command("PosteExport", function(args)
    local parts = {}
    for word in args.args:gmatch("%S+") do
      table.insert(parts, word)
    end
    require("poste.sql.export").run(parts[1], parts[2], parts[3])
  end, {
    nargs = "*",
    complete = function(ArgLead, CmdLine)
      return require("poste.sql.export").complete(ArgLead, CmdLine)
    end,
    desc = "Export dataset — :PosteExport [format] [destination] [path]",
  })

  vim.api.nvim_create_user_command("PosteSqlLog", function()
    require("poste.sql.log_viewer").toggle()
  end, { desc = "Toggle SQL execution log viewer" })

  vim.api.nvim_create_user_command("PosteSQLContext", function(args)
    local context = require("poste.sql.context")
    local parts = {}
    for word in args.args:gmatch("%S+") do
      table.insert(parts, word)
    end
    context.switch_context(parts)
  end, {
    nargs = "*",
    desc = "Switch SQL execution context (connection/database)",
  })

  vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    pattern = { "*.sql", "*.sqlite" },
    callback = function()
      local name = vim.api.nvim_buf_get_name(0)
      if name:match("%.sqlite$") then
        vim.bo.filetype = "poste_sqlite"
      else
        vim.bo.filetype = "poste_sql"
      end
      buffer_setup.setup_buffer_keymaps(0)
      ensure_sql_keymaps(0)
      setup_db_browser_keymap(0)

      local k = state.get_keymap("sql_source", "trigger_completion", "<C-Space>")
      if k then
        vim.keymap.set("i", k, function()
          pcall(function() require("poste.sql.completion_adapter").show() end)
        end, { buffer = 0, noremap = true, silent = true, desc = "Trigger completion" })
      end

      local sql_keywords = { from=true, join=true, where=true, set=true,
                              on=true, having=true, by=true, ["and"]=true, ["or"]=true,
                              use=true }
      local group = vim.api.nvim_create_augroup("PosteSQLTrigger_" .. vim.api.nvim_get_current_buf(), { clear = true })
      vim.api.nvim_create_autocmd("CursorMovedI", {
        group = group,
        buffer = 0,
        callback = function()
          local line = vim.api.nvim_get_current_line()
          local col  = vim.api.nvim_win_get_cursor(0)[2]
          if col < 1 or line:sub(col, col) ~= " " then return end
          local last_word = line:sub(1, col - 1):match("(%w+)%s*$")
          if last_word and sql_keywords[last_word:lower()] then
            local adapter = require("poste.sql.completion_adapter")
            adapter.show({ force = true, trigger_kind = "manual" })
          end
        end,
      })

      vim.api.nvim_create_autocmd("InsertEnter", {
        group = group,
        buffer = 0,
        callback = function()
          local line = vim.api.nvim_get_current_line()
          local col = vim.api.nvim_win_get_cursor(0)[2]
          local before = line:sub(1, col)
          local prefix = before:match("[%w_]*$") or ""
          if #prefix > 0 then
            vim.schedule(function()
              local adapter = require("poste.sql.completion_adapter")
              adapter.show({ force = true, trigger_kind = "manual" })
            end)
          end
        end,
      })

      vim.b.blink_cmp_min_keyword_length = 0
    end,
  })

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("%.sqlite$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_sqlite")
      buffer_setup.setup_buffer_keymaps(buf)
      ensure_sql_keymaps(buf)
      setup_db_browser_keymap(buf)
    elseif name:match("%.sql$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
      buffer_setup.setup_buffer_keymaps(buf)
      ensure_sql_keymaps(buf)
      setup_db_browser_keymap(buf)
    end
  end
end

return M
