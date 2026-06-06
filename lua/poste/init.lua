--- Poste: HTTP/Redis client for Neovim.
--- This is the orchestrator module — all subsystems live in separate modules.
local state = require("poste.state")
local highlights = require("poste.highlights")  -- auto-registers autocmds on require
local indicators = require("poste.indicators")
local format = require("poste.format")
local buffer = require("poste.buffer")
local assertions = require("poste.assertions")
local scripts = require("poste.scripts")
local request_vars = require("poste.request_vars")
local completion = require("poste.completion")
local symbols = require("poste.symbols")

local M = {}

---------------------------------------------------------------------------
-- Binary discovery
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
-- View switching
---------------------------------------------------------------------------
function M.show_view(view)
  state.current_view = view
  if not state.last_response then return end

  local lines, filetype
  if view == "body" then
    lines = format.format_body(state.last_response)
    filetype = format.detect_filetype(state.last_response.content_type)
  elseif view == "verbose" then
    lines = format.format_verbose(state.last_response)
    filetype = "markdown"
  elseif view == "assertions" then
    lines = assertions.format_assertions(state.last_assertion_results)
    filetype = "markdown"
  elseif view == "script_logs" then
    lines = scripts.format_script_logs(state.last_script_logs)
    filetype = "markdown"
  else
    lines = { "Unknown view: " .. view }
    filetype = "text"
  end

  buffer.render_buffer(lines, filetype)
  buffer.update_winbar(view)
end

-- Wire up buffer tab-switching callbacks
buffer.on_show_view = M.show_view

---------------------------------------------------------------------------
-- Run request
---------------------------------------------------------------------------
function M.run_request()
  -- SQL filetype: delegate to SQL module
  local ft = vim.bo.filetype
  if ft == "poste_sql" or ft == "poste_sqlite" then
    require("poste.sql.init").run_sql_request()
    return
  end

  local binary = find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found. Make sure it's in PATH or built locally.", vim.log.levels.ERROR)
    return
  end

  -- Reset assertion and script state for this request run
  state.last_assertion_results = nil
  state.last_script_logs = nil

  local src_buf = vim.api.nvim_get_current_buf()
  local line = vim.fn.line(".")

  -- Use buffer name (file path) for env.json discovery and extension detection.
  -- The file may not exist on disk — that's fine with --stdin.
  local file = vim.api.nvim_buf_get_name(src_buf)
  if file == "" then
    -- Unnamed buffer: use cwd with default .http extension
    file = vim.fn.getcwd() .. "/untitled.http"
  end

  -- Read content directly from the buffer (unsaved changes included)
  local buf_lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
  local buf_content = table.concat(buf_lines, "\n")

  -- Handle @prompt directives asynchronously, then continue with request execution
  request_vars.handle_prompt_variables(src_buf, line, buf_content, binary, file, state.current_env, function(modified_content)
    -- Show spinner immediately before any async operations
    local req_line = indicators.find_request_line(src_buf, line)
    indicators.set_indicator(src_buf, req_line, "running")

    -- Capture block bounds early (from original buffer, before content transforms)
    local block_start, block_end = indicators.find_request_block_bounds(src_buf, line)

    -- Resolve request variables asynchronously (callback chain, non-blocking)
    request_vars.resolve_request_variables(binary, file, state.current_env, src_buf, line, modified_content, function(buf_content)

      -- Extract and run pre-request scripts (< {% ... %} and < ./script.lua)
      local pre_script_code
      if block_start then
        buf_content, pre_script_code = scripts.extract_pre_script_blocks(buf_content, block_start, block_end)
      end

      if pre_script_code then
        local pre_result = scripts.run_pre_script(pre_script_code)
        if pre_result.error then
          state.log("ERROR", pre_result.error)
          indicators.set_indicator(src_buf, req_line, "error")
          state.last_response = {
            protocol = "error",
            status = 0,
            status_text = "Pre-script error",
            latency_ms = 0,
            url = "Pre-request script failed",
            content_type = "text/plain",
            headers = {},
            body = pre_result.error,
            cookies = {},
            metadata = { method = "", error = pre_result.error },
          }
          M.show_view("verbose")
          return
        end
        if #pre_result.logs > 0 then
          state.last_script_logs = pre_result.logs
        end
        if next(pre_result.variables) then
          local injected_count = 0
          for _ in pairs(pre_result.variables) do injected_count = injected_count + 1 end
          buf_content = scripts.inject_pre_script_vars(buf_content, block_start, pre_result.variables)
          block_end = block_end + injected_count
          for name, value in pairs(pre_result.variables) do
            state.script_variables[name] = value
          end
        end
      end

      -- Inject client.global vars as @var lines so {{var}} works across HTTP files
      if block_start and state.global_vars and next(state.global_vars) then
        local glines = vim.split(buf_content, "\n", { plain = true })
        local result = {}
        for i, line in ipairs(glines) do
          table.insert(result, line)
          if i == block_start then
            for name, value in pairs(state.global_vars) do
              table.insert(result, string.format("@%s = %s", name, value))
            end
          end
        end
        buf_content = table.concat(result, "\n")
      end

      -- Process form data magic variables and file inclusions
      buf_content = request_vars.process_form_data(src_buf, line, buf_content)

      -- Extract and strip assertion blocks before sending to Rust
      local assertion_code
      buf_content, assertion_code = assertions.extract_assertion_blocks(buf_content, block_start, block_end)

      -- Get the current request name for caching
      local requests = request_vars.collect_requests(src_buf)
      local current_req_name = nil
      for _, req in ipairs(requests) do
        if line >= req.start_line and line <= req.end_line then
          current_req_name = req.name
          break
        end
      end

      -- Extract the full request block (request line + headers) for error display
      local req_block = indicators.extract_request_block(src_buf, line)
      local req_text = req_block.request_line

      local cmd = string.format("%s run %s --line %d --env %s --json --stdin",
        vim.fn.shellescape(binary),
        vim.fn.shellescape(file),
        line,
        vim.fn.shellescape(state.current_env)
      )

      state.log("INFO", string.format("cmd: %s", cmd))

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
          state.log("INFO", "stdout: " .. output:sub(1, 200))

          vim.schedule(function()
            local ok, parsed = pcall(vim.json.decode, output)
            if ok and parsed and type(parsed) == "table" then
              state.last_response = parsed
              request_vars.cache_response(current_req_name, parsed)

              if assertion_code then
                state.last_assertion_results = assertions.run_assertions(parsed, assertion_code)
                state.log("INFO", string.format("Assertions: %d passed, %d failed",
                  state.last_assertion_results.passed, state.last_assertion_results.failed))

                if state.last_assertion_results.logs and #state.last_assertion_results.logs > 0 then
                  state.last_script_logs = state.last_script_logs or {}
                  for _, msg in ipairs(state.last_assertion_results.logs) do
                    table.insert(state.last_script_logs, msg)
                  end
                end

                if state.last_assertion_results.failed > 0 then
                  M.show_view("assertions")
                  indicators.set_indicator(src_buf, req_line, "success", parsed.latency_ms, state.last_assertion_results)
                else
                  M.show_view("body")
                  indicators.set_indicator(src_buf, req_line, "success", parsed.latency_ms, state.last_assertion_results)
                end
              else
                M.show_view("body")
                indicators.set_indicator(src_buf, req_line, "success", parsed.latency_ms)
              end
            else
              state.log("WARN", "JSON parse failed, showing raw output")
              indicators.set_indicator(src_buf, req_line, "error")
              state.last_response = {
                protocol = "error",
                status = 0,
                status_text = "JSON parse failed",
                latency_ms = 0,
                url = vim.trim(req_text),
                content_type = "text/plain",
                headers = req_block.headers,
                body = output,
                cookies = {},
                metadata = {
                  method = "",
                  error = "JSON parse failed",
                  exit_code = "?",
                  request_line = vim.trim(req_text),
                  env = state.current_env,
                },
              }
              M.show_view("verbose")
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
            state.log("ERROR", string.format("exit code %d (line %d, env %s)", code, line, state.current_env))
            vim.schedule(function()
              indicators.set_indicator(src_buf, req_line, "error")
              local stderr_text = table.concat(stderr_buf, "\n")
              state.last_response = {
                protocol = "error",
                status = 0,
                status_text = "Failed (exit " .. code .. ")",
                latency_ms = 0,
                url = vim.trim(req_text),
                content_type = "text/plain",
                headers = req_block.headers,
                body = stderr_text ~= "" and stderr_text or "Request failed with exit code " .. code,
                cookies = {},
                metadata = {
                  method = "",
                  error = stderr_text,
                  exit_code = tostring(code),
                  request_line = vim.trim(req_text),
                  env = state.current_env,
                },
              }
              M.show_view("verbose")
            end)
          end
        end,
      })

      if job_id > 0 then
        vim.fn.chansend(job_id, buf_content)
        vim.fn.chanclose(job_id, "stdin")
      else
        indicators.set_indicator(src_buf, req_line, "error")
        vim.notify("Failed to start poste job", vim.log.levels.ERROR, { title = "Poste" })
      end
    end)  -- end of resolve_request_variables callback
  end)  -- end of handle_prompt_variables callback
end

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------
function M.jump_next()
  local line = vim.fn.line(".")
  local total = vim.fn.line("$")
  for i = line + 1, total do
    local text = vim.fn.getline(i)
    if text:match("^###") then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  vim.notify("No more requests", vim.log.levels.INFO)
end

function M.jump_prev()
  local line = vim.fn.line(".")
  for i = line - 1, 1, -1 do
    local text = vim.fn.getline(i)
    if text:match("^###") then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  vim.notify("No previous requests", vim.log.levels.INFO)
end

function M.goto_definition()
  local ft = vim.bo.filetype
  -- SQL filetypes: delegate to DDL viewer
  if ft == "poste_sql" or ft == "poste_sqlite" then
    require("poste.sql.init").show_table_ddl()
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local col = cursor[2]  -- 0-indexed

  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""

  -- Find the {{...}} reference under the cursor on this line
  local req_name = nil
  local start_pos = 1
  while true do
    local s, e = line_text:find("{{[^}]+}}", start_pos)
    if not s then break end
    if col + 1 >= s and col + 1 <= e then  -- col is 0-indexed, s/e are 1-indexed
      local ref_text = line_text:sub(s + 2, e - 2)  -- strip {{ and }}
      -- Extract request name (part before the first dot)
      req_name = vim.trim(ref_text:match("^([^%.]+)%.") or ref_text)
      break
    end
    start_pos = e + 1
  end

  if not req_name then
    vim.notify("No named request reference under cursor", vim.log.levels.INFO)
    return
  end

  -- Use collect_requests to find the matching ### line
  local requests = request_vars.collect_requests(buf)
  for _, req in ipairs(requests) do
    if req.name == req_name then
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { req.start_line, 0 })
      return
    end
  end

  -- Not a named request: look for @var definition
  -- Priority: request-level (within current block) > file-level (before first ###)
  local total = vim.api.nvim_buf_line_count(buf)

  -- Find current request block
  local current_req = nil
  for _, req in ipairs(requests) do
    if line_num >= req.start_line and line_num <= req.end_line then
      current_req = req
      break
    end
  end

  -- Search for @varname definition
  local var_pattern = "^%s*@" .. vim.pesc(req_name) .. "[%s=]"
  local found_line = nil

  -- 1. Request-level: within current block
  if current_req then
    for i = current_req.start_line, current_req.end_line do
      local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
      if text:match(var_pattern) then
        found_line = i
        break
      end
    end
  end

  -- 2. File-level: before first ### (or entire file if no blocks)
  if not found_line then
    local end_line = #requests > 0 and requests[1].start_line - 1 or total
    for i = 1, end_line do
      local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
      if text:match(var_pattern) then
        found_line = i
        break
      end
    end
  end

  if found_line then
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { found_line, 0 })
    return
  end

  -- 3. env.json: search for variable in environment file
  local buf_path = vim.api.nvim_buf_get_name(buf)
  if buf_path == "" then
    vim.notify("Definition not found: " .. req_name, vim.log.levels.WARN)
    return
  end

  -- Search for env.json: start from buffer directory, walk up
  local search_dir = vim.fn.fnamemodify(buf_path, ":h")
  local env_file = nil

  while search_dir and search_dir ~= "" and search_dir ~= "/" do
    local candidate = search_dir .. "/env.json"
    if vim.fn.filereadable(candidate) == 1 then
      env_file = candidate
      break
    end
    local parent = vim.fn.fnamemodify(search_dir, ":h")
    if parent == search_dir then break end
    search_dir = parent
  end

  if not env_file then
    vim.notify("Definition not found: " .. req_name, vim.log.levels.WARN)
    return
  end

  -- Read and parse env.json
  local env_lines = vim.fn.readfile(env_file)
  if not env_lines or #env_lines == 0 then
    vim.notify("Cannot read env.json", vim.log.levels.WARN)
    return
  end

  local env_content = table.concat(env_lines, "\n")
  local ok, env_data = pcall(vim.json.decode, env_content)
  if not ok or type(env_data) ~= "table" then
    vim.notify("Cannot parse env.json", vim.log.levels.WARN)
    return
  end

  -- Get current environment (e.g., "dev")
  local current_env = state.current_env
  local env_vars = env_data[current_env]
  if not env_vars or type(env_vars) ~= "table" then
    vim.notify(string.format("Environment '%s' not found in env.json", current_env), vim.log.levels.WARN)
    return
  end

  -- Check if variable exists in this environment
  if env_vars[req_name] then
    -- Find the line in env.json
    local target_line = nil
    for i, line in ipairs(env_lines) do
      -- Match "varname": or "varname" :
      if line:match('^%s*"' .. vim.pesc(req_name) .. '"%s*:') then
        target_line = i
        break
      end
    end

    if target_line then
      -- Jump to env.json file
      vim.cmd("normal! m'")
      vim.cmd("edit " .. vim.fn.fnameescape(env_file))
      vim.api.nvim_win_set_cursor(0, { target_line, 0 })
      return
    end
  end

  vim.notify("Definition not found: " .. req_name, vim.log.levels.WARN)
end

function M.goto_references()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local col = cursor[2]  -- 0-indexed

  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""
  local total = vim.api.nvim_buf_line_count(buf)

  local symbol_name = nil
  local is_request = false

  -- 1. Check for {{...}} reference under cursor
  local start_pos = 1
  while true do
    local s, e = line_text:find("{{[^}]+}}", start_pos)
    if not s then break end
    if col + 1 >= s and col + 1 <= e then
      local ref_text = line_text:sub(s + 2, e - 2)
      symbol_name = vim.trim(ref_text:match("^([^%.]+)%.") or ref_text)
      -- If it contains .response. or .request., it's a named request reference
      if ref_text:match("%.response%.") or ref_text:match("%.request%.") then
        is_request = true
      end
      break
    end
    start_pos = e + 1
  end

  -- 2. Check for @var definition under cursor
  if not symbol_name then
    local var_name = line_text:match("^%s*@(.-)[%s=]")
    if var_name then
      symbol_name = vim.trim(var_name)
    end
  end

  -- 3. Check for ### Request Name
  if not symbol_name then
    local req_name = line_text:match("^%s*###%s*(.+)")
    if req_name then
      symbol_name = vim.trim(req_name)
      is_request = true
    end
  end

  if not symbol_name then
    vim.notify("No variable or request reference under cursor", vim.log.levels.INFO)
    return
  end

  local results = {}
  local seen = {}

  -- Read all lines in a single API call (was N calls, now 1)
  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local function add(line_i, text, ref_col)
    if not seen[line_i] and line_i ~= line_num then
      seen[line_i] = true
      table.insert(results, { line = line_i, text = text, col = ref_col })
    end
  end

  local esc = vim.pesc(symbol_name)

  -- Comment pattern: lines starting with # or -- (after optional whitespace)
  local comment_pat = "^%s*[#%-]"

  if is_request then
    local def_pat = "^%s*###%s*" .. esc .. "%s*$"
    local ref_pat = "{{" .. esc .. "[%}%.]"
    for i = 1, total do
      local text = all_lines[i] or ""
      if text:match(def_pat) then
        add(i, vim.trim(text), 0)
      elseif not text:match(comment_pat) then
        -- Skip comment lines — they are documentation, not actual references
        local ref_col = text:find(ref_pat)
        if ref_col then
          add(i, vim.trim(text), ref_col - 1)
        end
      end
    end
  else
    local def_pat = "^%s*@" .. esc .. "[%s=]"
    local ref_pat = "{{" .. esc .. "[%}%.]"
    for i = 1, total do
      local text = all_lines[i] or ""
      if text:match(def_pat) then
        add(i, vim.trim(text), 0)
      elseif not text:match(comment_pat) then
        local ref_col = text:find(ref_pat)
        if ref_col then
          add(i, vim.trim(text), ref_col - 1)
        end
      end
    end
  end

  -- Remove current line from results (manual filter to preserve array structure)
  local filtered_results = {}
  for _, r in ipairs(results) do
    if r.line ~= line_num then
      table.insert(filtered_results, r)
    end
  end
  results = filtered_results

  if #results == 0 then
    vim.notify("No other references found for: " .. symbol_name, vim.log.levels.INFO)
    return
  end

  -- Sort by line number
  table.sort(results, function(a, b) return a.line < b.line end)

  -- Single result: jump directly
  if #results == 1 then
    local r = results[1]
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { r.line, r.col })
    return
  end

  -- Multiple results: use custom picker with lazy preview loading
  local items = {}
  local filetype = vim.api.nvim_get_option_value("filetype", {buf = buf})

  for idx, r in ipairs(results) do
    table.insert(items, string.format("L%d:%d: %s", r.line, r.col, r.text))
  end

  -- Lazy preview loader: only build preview when needed
  local preview_data = setmetatable({}, {
    __index = function(_, idx)
      local r = results[idx]
      if not r then return nil end

      -- Build preview on demand
      local ctx = 5
      local start_l = math.max(1, r.line - ctx)
      local end_l = math.min(total, r.line + ctx)
      local preview_lines = {}
      for i = start_l, end_l do
        local ltext = all_lines[i] or ""
        local prefix = (i == r.line) and "▶ " .. i .. " " or "  " .. i .. " "
        preview_lines[i - start_l + 1] = prefix .. ltext
      end

      return {
        lines = preview_lines,
        filetype = filetype,
        highlight_line = r.line - start_l + 1,
      }
    end
  })

  local function jump_to(item)
    xpcall(function()
      local target_line, target_col = item:match("^L(%d+):(%d+):")
      if not target_line then return end

      local line = tonumber(target_line)
      local col = tonumber(target_col)
      if not line or not col then return end

      -- Ensure line and col are integers
      line = math.floor(line)
      col = math.floor(col)

      -- Validate line is within buffer bounds
      local line_count = vim.fn.line("$")
      if line < 1 or line > line_count then return end

      -- Validate col is within line bounds
      local lines = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)
      local line_text = (lines and lines[1]) or ""
      if col < 0 or col > #line_text then col = 0 end

      -- Save position to jumplist and jump
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { line, col })
    end, function(err)
      -- Silently ignore any errors
    end)
  end

  local select = require("poste.select")
  select.select(items, "References to '" .. symbol_name .. "'", function(selected)
    if selected then
      jump_to(selected)
    end
  end, preview_data)
end

---------------------------------------------------------------------------
-- Environment
---------------------------------------------------------------------------
function M.set_env(env_name)
  state.current_env = env_name
  vim.notify("Environment switched to: " .. env_name, vim.log.levels.INFO)
end

function M.get_env()
  return state.current_env
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
function M.setup(opts)
  opts = opts or {}
  state.config = vim.tbl_deep_extend("force", state.config, opts)

  -- Register nvim-cmp source (if available)
  completion.register()

  -- Register SQL completion source (blink.cmp or nvim-cmp)
  local sql_comp = require("poste.sql.completion")
  local function register_sql_completion()
    -- Try blink.cmp first
    local blink_ok, blink = pcall(require, "blink.cmp")
    if blink_ok and blink.add_source_provider then
      blink.add_source_provider("poste_sql", {
        module = "poste.sql.completion",
        name = "PosteSQL",
        async = true,
        score_offset = 1000,
        min_keyword_length = 0,
        should_show_items = true,
      })
      blink.add_filetype_source("poste_sql", "poste_sql")
      blink.add_filetype_source("poste_sqlite", "poste_sql")

      -- Only show poste_sql source in SQL buffers (suppress buffer/lsp word noise)
      local blink_config = require("blink.cmp.config")
      blink_config.sources.per_filetype["poste_sql"]    = { "poste_sql" }
      blink_config.sources.per_filetype["poste_sqlite"] = { "poste_sql" }

      -- Allow space as a trigger character in SQL buffers by removing it from the blocked list
      local orig_blocked = blink_config.completion.trigger.show_on_blocked_trigger_characters
      blink_config.completion.trigger.show_on_blocked_trigger_characters = function()
        local ft = vim.bo.filetype
        if ft == "poste_sql" or ft == "poste_sqlite" then
          local blocked = type(orig_blocked) == "function" and orig_blocked() or orig_blocked
          return vim.tbl_filter(function(c) return c ~= " " end, blocked)
        end
        return type(orig_blocked) == "function" and orig_blocked() or orig_blocked
      end

      return true
    end
    -- Fall back to nvim-cmp
    local cmp_ok = pcall(sql_comp.register)
    return cmp_ok
  end

  if not pcall(register_sql_completion) then
    -- Neither loaded yet — defer to InsertEnter
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

  local function setup_buffer_keymaps(buf)
    local keymap_opts = { buffer = buf, noremap = true, silent = true }
    vim.keymap.set("n", "<CR>", M.run_request, keymap_opts)
    vim.keymap.set("n", "]]", M.jump_next, keymap_opts)
    vim.keymap.set("n", "[[", M.jump_prev, keymap_opts)
    vim.keymap.set("n", "gd", M.goto_definition, keymap_opts)
    vim.keymap.set("n", "grr", M.goto_references, keymap_opts)
    vim.keymap.set("n", "]q", function() vim.cmd("cnext") end, keymap_opts)
    vim.keymap.set("n", "[q", function() vim.cmd("cprev") end, keymap_opts)
    vim.keymap.set("n", "<leader>rp", function()
      local curl = require("poste.curl")
      curl.paste_curl("+")
    end, keymap_opts)
    vim.keymap.set("n", "<leader>rc", function()
      local copy = require("poste.copy")
      copy.copy_to_clipboard("+")
    end, keymap_opts)
    vim.keymap.set("n", "gs", function()
      symbols.show_symbols()
    end, keymap_opts)

    -- Clear indicators when buffer content changes (dd, x, etc.)
    local indicator_ns = vim.api.nvim_create_namespace("poste_indicator")
    local group = vim.api.nvim_create_augroup("PosteClearIndicators_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd("TextChanged", {
      group = group,
      buffer = buf,
      callback = function()
        vim.api.nvim_buf_clear_namespace(buf, indicator_ns, 0, -1)
      end,
    })
  end

  -- Commands
  vim.api.nvim_create_user_command("PosteRun", function()
    M.run_request()
  end, { desc = "Run request at cursor" })

  vim.api.nvim_create_user_command("PosteEnv", function(args)
    if args.args == "" then
      vim.notify("Current environment: " .. state.current_env, vim.log.levels.INFO)
    else
      M.set_env(args.args)
    end
  end, {
    nargs = "?",
    desc = "Switch environment or show current",
  })

  vim.api.nvim_create_user_command("PostePasteCurl", function()
    local curl = require("poste.curl")
    curl.paste_curl("+")
  end, { desc = "Paste curl command from clipboard as HTTP request" })

  vim.api.nvim_create_user_command("PosteCopyAsCurl", function()
    local copy = require("poste.copy")
    copy.copy_to_clipboard("+")
  end, { desc = "Copy current request as curl command to clipboard" })

  vim.api.nvim_create_user_command("PosteCmpStatus", function()
    vim.notify(completion.status(), vim.log.levels.INFO)
  end, { desc = "Check poste completion status" })

  vim.api.nvim_create_user_command("PosteCmpProfile", function()
    completion.profile()
  end, { desc = "Profile poste completion performance" })

  vim.api.nvim_create_user_command("PosteSQLCmpStatus", function()
    local sql_comp = require("poste.sql.completion")
    local ft = vim.bo.filetype
    local buf = vim.api.nvim_get_current_buf()
    
    local status = {
      "SQL Completion Status:",
      "  Current filetype: " .. ft,
      "  Buffer: " .. buf,
    }
    
    -- Test if source is enabled
    local instance = sql_comp.new()
    table.insert(status, "  Enabled: " .. tostring(instance:enabled()))
    
    -- Check blink.cmp registration
    local blink_ok, blink = pcall(require, "blink.cmp")
    if blink_ok then
      local config_ok, config = pcall(require, "blink.cmp.config")
      if config_ok then
        table.insert(status, "  blink.cmp loaded: true")
        if config.sources and config.sources.providers then
          local has_sql = config.sources.providers.poste_sql ~= nil
          table.insert(status, "  poste_sql provider registered: " .. tostring(has_sql))
        end
      end
    else
      table.insert(status, "  blink.cmp loaded: false")
    end
    
    -- Check connection
    local ctx_mod = require("poste.sql.context")
    local ctx = ctx_mod.resolve_context(buf)
    table.insert(status, "  Connection: " .. (ctx.connection or "none"))
    table.insert(status, "  Database: " .. (ctx.database or "none"))
    
    -- Test context detection at cursor
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    local col = cursor[2]  -- 0-based column
    local line_before = line:sub(1, col)  -- up to but not including cursor position
    
    table.insert(status, "\nAt cursor position (col=" .. col .. "):")
    table.insert(status, "  Line: " .. line)
    table.insert(status, "  Before cursor: '" .. line_before .. "'")
    table.insert(status, "  After cursor: '" .. line:sub(col + 1) .. "'")
    
    -- Call the test interface if available
    if sql_comp._test then
      local ctx_type, ctx_data = sql_comp._test.detect_context(line_before)
      table.insert(status, "  Detected context: " .. tostring(ctx_type))
      if ctx_data then
        table.insert(status, "  Context data: " .. tostring(ctx_data))
      end
    end
    
    vim.notify(table.concat(status, "\n"), vim.log.levels.INFO)
  end, { desc = "Check SQL completion status" })

  vim.api.nvim_create_user_command("PosteSQLAutoTrigger", function()
    local blink_ok, blink = pcall(require, "blink.cmp")
    if not blink_ok or not blink.show then
      vim.notify("blink.cmp not available", vim.log.levels.ERROR)
      return
    end
    
    local group = vim.api.nvim_create_augroup("PosteSQLAutoComplete", { clear = true })
    vim.api.nvim_create_autocmd("TextChangedI", {
      group = group,
      buffer = 0,
      callback = function()
        local line = vim.api.nvim_get_current_line()
        local col = vim.api.nvim_win_get_cursor(0)[2]
        
        -- Check if just typed a space after SQL keyword
        if col > 0 and line:sub(col, col) == " " then
          local before = line:sub(1, col - 1)
          local last_word = before:match("(%w+)%s*$")
          
          if last_word then
            local lw = last_word:lower()
            if lw == "from" or lw == "join" or lw == "where" or 
               lw == "set" or lw == "on" or lw == "having" or
               lw == "by" or lw == "and" or lw == "or" then
              vim.schedule(function()
                blink.show()
              end)
            end
          end
        end
      end
    })
    vim.notify("SQL auto-trigger installed for current buffer", vim.log.levels.INFO)
  end, { desc = "Install SQL auto-trigger for completion" })

  vim.api.nvim_create_user_command("PosteSQLCmpReload", function()
    -- Reload the completion module
    package.loaded["poste.sql.completion"] = nil
    local sql_comp = require("poste.sql.completion")
    
    -- Re-register with blink.cmp
    local blink_ok, blink = pcall(require, "blink.cmp")
    if blink_ok and blink.add_source_provider then
      blink.add_source_provider("poste_sql", {
        module = "poste.sql.completion",
        name = "PosteSQL",
        score_offset = 1000,
        min_keyword_length = 0,
        should_show_items = true,
      })
      blink.add_filetype_source("poste_sql", "poste_sql")
      blink.add_filetype_source("poste_sqlite", "poste_sql")
      vim.notify("SQL completion reloaded and re-registered with blink.cmp", vim.log.levels.INFO)
    else
      vim.notify("blink.cmp not available", vim.log.levels.ERROR)
    end
  end, { desc = "Reload SQL completion provider" })

  vim.api.nvim_create_user_command("PosteSQLDiag", function()
    local sql_comp = require("poste.sql.completion")
    local buf = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    local col = cursor[2]
    local line_before = line:sub(1, col)
    local cursor_lnum = cursor[1]

    local ctx_type, ctx_data = sql_comp._test.detect_context(line_before)
    local tbls, alias_map = sql_comp._test.extract_from_tables(buf, cursor_lnum)
    local conn = sql_comp._test.conn_key()

    -- Check what blink sources are active for this filetype
    local blink_src_ok, blink_src = pcall(require, "blink.cmp.sources.lib")
    local active_providers = blink_src_ok and blink_src.get_enabled_provider_ids("insert") or {}
    local per_ft = "(unavailable)"
    local blink_config_ok, blink_config = pcall(require, "blink.cmp.config")
    if blink_config_ok then
      per_ft = vim.inspect(blink_config.sources and blink_config.sources.per_filetype and blink_config.sources.per_filetype["poste_sql"])
    end
    local runtime_ft = blink_src_ok and vim.inspect(blink_src.per_filetype_provider_ids) or "(unavailable)"

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
    -- Test exactly what happens when Space is pressed after WHERE
    local buf = vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)
    local last_word = before:match("(%w+)%s*$")

    local blink_ok, blink = pcall(require, "blink.cmp")
    local menu_open = blink_ok and require("blink.cmp.completion.windows.menu").win:is_open()

    local msg = {
      "PosteSQLDebugSpace:",
      "  line_before cursor: '" .. before .. "'",
      "  last_word: " .. tostring(last_word),
      "  blink loaded: " .. tostring(blink_ok),
      "  blink.show exists: " .. tostring(blink_ok and blink.show ~= nil),
      "  menu currently open: " .. tostring(menu_open),
    }

    if blink_ok and blink.show then
      vim.notify(table.concat(msg, "\n") .. "\n  → calling blink.show() now...", vim.log.levels.WARN)
      blink.show()
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
    
    -- Test context detection
    if sql_comp._test then
      local ctx_type, ctx_data = sql_comp._test.detect_context(line_before)
      table.insert(status, "  Context: " .. tostring(ctx_type))
      
      -- If column context, test extract_from_tables
      if ctx_type == "column" and sql_comp._test.extract_from_tables then
        local tbls = sql_comp._test.extract_from_tables(buf, cursor_line)
        table.insert(status, "  Tables found: " .. #tbls .. " - " .. vim.inspect(tbls))
      end
      
      -- Test connection
      local conn = sql_comp._test.conn_key and sql_comp._test.conn_key()
      table.insert(status, "  Connection key: " .. tostring(conn))
    end
    
    -- Call get_items directly
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

  vim.api.nvim_create_user_command("PosteSymbols", function()
    symbols.show_symbols()
  end, { desc = "Show symbol outline (all HTTP requests)" })

  -- SQL connection management
  vim.api.nvim_create_user_command("PosteConnection", function()
    require("poste.sql.connections").show_menu()
  end, { desc = "Manage SQL connections" })

  -- DB Browser (Phase 3)
  vim.api.nvim_create_user_command("PosteDBBrowser", function()
    require("poste.sql.db_browser").toggle()
  end, { desc = "Toggle database structure browser sidebar" })

  -- SQL context switching
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

  -- Autocommand: set up keymaps for supported file types
  vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    pattern = { "*.http", "*.rest", "*.redis" },
    callback = function()
      local name = vim.api.nvim_buf_get_name(0)
      if name:match("%.redis$") then
        vim.bo.filetype = "poste_redis"
      else
        vim.bo.filetype = "poste_http"
      end
      setup_buffer_keymaps(0)
    end,
  })

  -- SQL files: set up keymaps (same keymaps as HTTP) + DB browser keymap
  vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    pattern = { "*.sql", "*.sqlite" },
    callback = function()
      local name = vim.api.nvim_buf_get_name(0)
      if name:match("%.sqlite$") then
        vim.bo.filetype = "poste_sqlite"
      else
        vim.bo.filetype = "poste_sql"
      end
      setup_buffer_keymaps(0)
      require("poste.sql.init").ensure_sql_keymaps(0)
      vim.keymap.set("n", "<leader>db", function()
        require("poste.sql.db_browser").toggle()
      end, { buffer = 0, noremap = true, silent = true, desc = "Toggle DB Browser" })
      
      -- Manual completion trigger for testing
      vim.keymap.set("i", "<C-Space>", function()
        local blink_ok, blink = pcall(require, "blink.cmp")
        if blink_ok and blink.show then
          blink.show()
        else
          vim.notify("blink.cmp not available", vim.log.levels.WARN)
        end
      end, { buffer = 0, noremap = true, silent = true, desc = "Trigger completion" })
      
      -- Trigger completion after SQL keywords via CursorMovedI
      -- (Space keymap is intercepted by blink.cmp before buffer-local keymaps fire,
      --  and TextChangedI may not fire for expr-mapped keys)
      local sql_keywords = { from=true, join=true, where=true, set=true,
                              on=true, having=true, by=true, ["and"]=true, ["or"]=true,
                              use=true }
      local group = vim.api.nvim_create_augroup("PosteSQLTrigger_" .. vim.api.nvim_get_current_buf(), { clear = true })
      vim.api.nvim_create_autocmd("CursorMovedI", {
        group = group,
        buffer = 0,
        callback = function()
          local line = vim.api.nvim_get_current_line()
          local col  = vim.api.nvim_win_get_cursor(0)[2]  -- 0-based
          -- Only act when cursor is right after a space: char at col-1 is space (1-indexed = col)
          if col < 1 or line:sub(col, col) ~= " " then return end
          local last_word = line:sub(1, col - 1):match("(%w+)%s*$")
          if last_word and sql_keywords[last_word:lower()] then
            local ok, t = pcall(require, "blink.cmp.completion.trigger")
            if ok then t.show({ force = true, trigger_kind = "manual" }) end
          end
        end,
      })

      -- Configure buffer-local blink.cmp settings
      vim.b.blink_cmp_min_keyword_length = 0
    end,
  })

  -- Already-open buffers
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("%.http$") or name:match("%.rest$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_http")
      setup_buffer_keymaps(buf)
    elseif name:match("%.redis$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_redis")
      setup_buffer_keymaps(buf)
    elseif name:match("%.sqlite$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_sqlite")
      setup_buffer_keymaps(buf)
      require("poste.sql.init").ensure_sql_keymaps(buf)
      vim.keymap.set("n", "<leader>db", function()
        require("poste.sql.db_browser").toggle()
      end, { buffer = buf, noremap = true, silent = true, desc = "Toggle DB Browser" })
    elseif name:match("%.sql$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
      setup_buffer_keymaps(buf)
      require("poste.sql.init").ensure_sql_keymaps(buf)
      vim.keymap.set("n", "<leader>db", function()
        require("poste.sql.db_browser").toggle()
      end, { buffer = buf, noremap = true, silent = true, desc = "Toggle DB Browser" })
    end
  end

  -- Status line integration
  _G.poste_status = function()
    local parts = { string.format("[env: %s]", state.current_env) }
    -- Add SQL context if in SQL file
    local ft = vim.bo.filetype
    if ft == "poste_sql" or ft == "poste_sqlite" then
      local sql_status = require("poste.sql.context").get_status_text()
      if sql_status ~= "" then
        parts[#parts + 1] = sql_status
      end
    end
    return table.concat(parts, " ")
  end
end

return M
