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

---------------------------------------------------------------------------
-- Run SQL request
---------------------------------------------------------------------------

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

  -- Show spinner
  local req_line = indicators.find_request_line(src_buf, line)
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

return M
