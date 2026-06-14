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
    local trimmed = line:match("^%s*(.-)%s*$") or ""
    if trimmed ~= "" and not trimmed:match("^%-%-") and not trimmed:match("^###") then
      syntax.highlight_line(buf, _syn_ns, i, trimmed, 0)
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
        local ctx_mod = require("poste.sql.context")
        local text = ctx_mod.get_cursor_status_text(buf)
        vim.b[buf].poste_sql_context = text
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
    local sql_buffer = require("poste.sql.buffer")
    if sql_buffer.is_open() then
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

return M
