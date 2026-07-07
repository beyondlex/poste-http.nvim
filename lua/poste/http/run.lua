local state = require("poste.state")
local util = require("poste.util")
local indicators = require("poste.indicators")
local request_vars = require("poste.http.request_vars")
local scripts = require("poste.http.scripts")
local assertions = require("poste.http.assertions")
local view = require("poste.http.view")
local response_buf = require("poste.http.buffer")
local import_mod = require("poste.http.import")
local history = require("poste.http.history")
local event = require("poste.state.event")

local uv = vim.uv or vim.loop

local M = {}

---------------------------------------------------------------------------
-- Pipeline helpers
---------------------------------------------------------------------------

--- Clear global mutable state before starting a request.
local function clear_state()
  state.last_response = nil
  state.last_assertion_results = nil
  state.last_script_logs = nil
  state.pending_request = nil
end

--- Build a synthetic response for a script-only block.
local function make_script_response(req_text, req_block)
  return {
    protocol = "script",
    status = 200,
    status_text = "Script executed",
    latency_ms = 0,
    url = vim.trim(req_text),
    content_type = "text/plain",
    headers = req_block and req_block.headers or {},
    body = "Script executed. See Assertions or Script Logs tab for details.",
    cookies = {},
    metadata = {
      method = "SCRIPT",
      exit_code = "0",
      request_line = vim.trim(req_text),
      env = state.current_env,
    },
  }
end

--- Build an error response table for a failed request.
local function make_error_response(req_text, req_block, body_text, err_msg, exit_code)
  return {
    protocol = "error",
    status = 0,
    status_text = err_msg,
    latency_ms = 0,
    url = vim.trim(req_text),
    content_type = "text/plain",
    headers = req_block and req_block.headers or {},
    body = body_text,
    cookies = {},
    metadata = {
      method = "",
      error = body_text,
      exit_code = tostring(exit_code or "?"),
      request_line = vim.trim(req_text),
      env = state.current_env,
    },
  }
end

--- Emit response:ready event with the given data.
local function emit_response(response_data, request_name, file_path, assertion_results, script_logs)
  event.emit("response:ready", {
    response = response_data,
    request_name = request_name,
    file = file_path,
    assertion_results = assertion_results or nil,
    script_logs = script_logs or nil,
  })
end

--- Run assertions and update state.
local function run_and_store_assertions(parsed, assertion_code, script_vars)
  if not assertion_code then return nil end
  local results = assertions.run_assertions(parsed, assertion_code, script_vars)
  state.last_assertion_results = results
  state.log("INFO", string.format("Assertions: %d passed, %d failed", results.passed, results.failed))
  if results.logs and #results.logs > 0 then
    state.last_script_logs = state.last_script_logs or {}
    for _, msg in ipairs(results.logs) do
      table.insert(state.last_script_logs, msg)
    end
  end
  return results
end

--- Choose the appropriate view tab based on status and assertion results.
local function choose_view_tab(parsed, assertion_results)
  if assertion_results and assertion_results.failed > 0 then
    return "assertions"
  end
  if parsed.status and parsed.status >= 400 then
    return "verbose"
  end
  return "body"
end

--- Set indicator based on status and assertions.
local function set_result_indicator(src_buf, line_0, parsed, assertion_results)
  local is_error = parsed.status and parsed.status >= 400
  local has_failures = assertion_results and assertion_results.failed > 0

  if has_failures then
    indicators.set_indicator(src_buf, line_0, "success", parsed.latency_ms, assertion_results)
  elseif is_error then
    indicators.set_indicator(src_buf, line_0, "error", parsed.latency_ms, assertion_results)
  else
    indicators.set_indicator(src_buf, line_0, "success", parsed.latency_ms, assertion_results)
  end
end

--- Add entry to history.
local function add_to_history(name, response_data, file_path)
  history.add_entry(name, response_data, state.last_assertion_results, state.last_script_logs, file_path)
end

--- Parse JSON response from stdout and dispatch to appropriate handler.
local function handle_job_stdout(data, src_buf, req_line, req_block, req_text, assertion_code, script_vars, current_req_name, file)
  data = util.ensure_job_data(data)
  if #data == 0 then return end

  local output = table.concat(data, "\n")
  state.log("INFO", "stdout: " .. output:sub(1, 200))

  vim.schedule(function()
    state.pending_request = nil
    local ok, parsed = pcall(vim.json.decode, output)
    if ok and parsed and type(parsed) == "table" then
      -- Successful parse
      state._json.query = nil
      state._json.original_lines = nil
      state._json.is_filtered = false
      state.last_response = parsed
      request_vars.cache_response(current_req_name, parsed)
      -- Build multi-response view if deps were auto-executed
      if request_vars._dep_chain and #request_vars._dep_chain > 0 then
        local chain = {}
        for _, item in ipairs(request_vars._dep_chain) do
          table.insert(chain, {name = item.name, response = item.response})
          history.add_entry(item.name, item.response, nil, nil, file)
        end
        table.insert(chain, {name = current_req_name or "Request", response = parsed})
        response_buf.reset_multi_response()
        state.last_responses = chain
        state.response_index = #chain
        request_vars._dep_chain = nil
        pcall(response_buf.prepare_multi_responses, chain)
      else
        state.last_responses = nil
        state.response_index = nil
        response_buf.reset_multi_response()
      end
      emit_response(parsed, current_req_name, file, nil, nil)

      local assertion_results = run_and_store_assertions(parsed, assertion_code, script_vars)
      local view_name = choose_view_tab(parsed, assertion_results)
      view.show_view(view_name)
      set_result_indicator(src_buf, req_line, parsed, assertion_results)
      local hist_name = (current_req_name or "") ~= "" and current_req_name or ("Request #" .. req_line + 1)
      add_to_history(hist_name, state.last_response, file)
    else
      -- JSON parse failed
      state.log("WARN", "JSON parse failed, showing raw output")
      indicators.set_indicator(src_buf, req_line, "error")
      state.last_responses = nil
      state.response_index = nil
      response_buf.reset_multi_response()
      local error_response = make_error_response(req_text, req_block, output, "JSON parse failed", "?")
      state.last_response = error_response
      emit_response(error_response, current_req_name, file, nil, nil)
      view.show_view("verbose")
      local err_name = (current_req_name or "") ~= "" and current_req_name or ("Request #" .. req_line + 1)
      add_to_history(err_name, state.last_response, file)
    end
  end)
end

--- Handle job exit with non-zero code.
local function handle_job_exit(code, stderr_buf, src_buf, req_line, req_block, req_text, current_req_name, file)
  if code == 0 then return end

  state.log("ERROR", string.format("exit code %d", code))
  vim.schedule(function()
    state.pending_request = nil
    indicators.set_indicator(src_buf, req_line, "error")
    local stderr_text = table.concat(stderr_buf, "\n")
    local body = stderr_text ~= "" and stderr_text or "Request failed with exit code " .. code
    local error_response = make_error_response(req_text, req_block, body, "Failed (exit " .. code .. ")", code)
    state.last_response = error_response
    if request_vars._dep_chain and #request_vars._dep_chain > 0 then
      local chain = {}
      for _, item in ipairs(request_vars._dep_chain) do
        table.insert(chain, {name = item.name, response = item.response})
        history.add_entry(item.name, item.response, nil, nil, file)
      end
      table.insert(chain, {name = current_req_name or "Request", response = error_response})
      response_buf.reset_multi_response()
      state.last_responses = chain
      state.response_index = #chain
      request_vars._dep_chain = nil
      pcall(response_buf.prepare_multi_responses, chain)
    else
      state.last_responses = nil
      state.response_index = nil
      response_buf.reset_multi_response()
    end
    emit_response(error_response, current_req_name, file, nil, nil)
    view.show_view("verbose")
    local err_name = (current_req_name or "") ~= "" and current_req_name or ("Request #" .. req_line + 1)
    add_to_history(err_name, state.last_response, file)
  end)
end

--- Build pending request info from buf_content for the Verb tab.
local function build_pending_request(src_buf, buf_content, req_block, block_start, block_end, file)
  local header_parts = {}
  if req_block.headers then
    for _, h in ipairs(req_block.headers) do
      table.insert(header_parts, h[1] .. ": " .. h[2])
    end
  end
  local headers_str = table.concat(header_parts, "\n")

  -- Resolve via poste resolve CLI
  local resolved_content = nil
  local poste_bin = state.find_poste_binary()
  if poste_bin and file and file ~= "" then
    local args = {
      poste_bin, "resolve",
      "--stdin",
      "--file", file,
      "--block", tostring(block_start or 1),
      "--format", "content",
    }
    if state.global_vars and next(state.global_vars) then
      table.insert(args, "--session-vars")
      table.insert(args, vim.json.encode(state.global_vars))
    end
    if state.script_variables and next(state.script_variables) then
      table.insert(args, "--script-vars")
      table.insert(args, vim.json.encode(state.script_variables))
    end
    table.insert(args, "--env")
    table.insert(args, state.current_env)

    -- Pipe buffer content as stdin (handles unsaved changes)
    local ok, sys_obj = pcall(vim.system, args, { stdin = buf_content, text = true })
    if ok then
      local ok2, result = pcall(sys_obj.wait, sys_obj)
      if ok2 and result.code == 0 then
        local stdout = result.stdout or ""
        if stdout ~= "" then
          resolved_content = stdout
        end
      end
    end
  end

  -- Extract method, URL, headers, body from resolved (or raw) content
  local content = resolved_content or buf_content
  local req_method = ""
  local req_url = ""
  local body = ""
  local resolved_headers = {}
  local lines = vim.split(content, "\n", { plain = true })
  local request_found = false
  local in_headers = false
  local body_start_idx = nil

  for i = 1, #lines do
    local text = lines[i] or ""
    local trimmed = vim.trim(text)

    if trimmed:match("^###") then
      -- skip ### header line
    elseif trimmed:match("^@%S+") then
      -- skip @var definitions
    elseif not request_found then
      if trimmed ~= "" and not trimmed:match("^#") then
        req_method, req_url = text:match("^(%S+)%s+(.+)$")
        if req_method then
          request_found = true
          in_headers = true
        end
      end
    elseif in_headers then
      if trimmed == "" then
        in_headers = false
        body_start_idx = i + 1
      else
        local key, value = text:match("^([^:]+):%s*(.+)$")
        if key and value then
          table.insert(resolved_headers, { vim.trim(key), vim.trim(value) })
        end
      end
    end
  end

  if body_start_idx and body_start_idx <= #lines then
    local body_lines = {}
    for i = body_start_idx, #lines do
      table.insert(body_lines, lines[i] or "")
    end
    body = table.concat(body_lines, "\n"):gsub("[\r\n]+$", "")
  end

  -- Use resolved headers if CLI succeeded, else fall back to req_block headers
  local resolved_headers_str = headers_str
  if resolved_content and #resolved_headers > 0 then
    local h_parts = {}
    for _, h in ipairs(resolved_headers) do
      table.insert(h_parts, h[1] .. ": " .. h[2])
    end
    resolved_headers_str = table.concat(h_parts, "\n")
  end

  state.pending_request = {
    method = req_method,
    url = req_url,
    headers_str = resolved_headers_str,
    body = body,
    env = state.current_env,
    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    start_hires = uv.hrtime(),
  }
end

--- Handle the import/run directive response callback.
local function handle_directive_response(success, response, src_buf, indicator_line, assertion_code, script_vars, resolved, file)
  vim.schedule(function()
    if not (success and response) then
      indicators.set_indicator(src_buf, indicator_line, "error")
      return
    end

    -- Batch execution: response is an array of {name, response}
    if type(response) == "table" and response[1] and response[1].response then
      state.last_responses = response
      state.response_index = 1
      state.last_response = response[1].response
    else
      state.last_responses = nil
      state.response_index = 1
      state.last_response = response
    end

    emit_response(state.last_response, resolved.request_name, resolved.path or file, nil, nil)

    if assertion_code then
      run_and_store_assertions(state.last_response, assertion_code, script_vars)
      local view_name = choose_view_tab(state.last_response, state.last_assertion_results)
      view.show_view(view_name)
      set_result_indicator(src_buf, indicator_line, state.last_response, state.last_assertion_results)
    else
      local view_name = choose_view_tab(state.last_response, nil)
      view.show_view(view_name)
      set_result_indicator(src_buf, indicator_line, state.last_response, nil)
    end

    if type(response) == "table" and response[1] and response[1].response then
      for _, item in ipairs(response) do
        local item_name = (item.name or "") ~= "" and item.name or ("Request #" .. (item.line or ""))
        add_to_history(item_name, item.response, resolved.path or file)
      end
    else
      add_to_history(resolved.request_name or "Import", response, resolved.path or file)
    end
  end)
end

--- Inject global variables into buf_content after the block start line.
local function inject_global_vars(buf_content, block_start, global_vars)
  if not block_start or not global_vars or not next(global_vars) then
    return buf_content, 0
  end
  local glines = vim.split(buf_content, "\n", { plain = true })
  local result = {}
  local gcount = 0
  for _ in pairs(global_vars) do gcount = gcount + 1 end
  for i, line_text in ipairs(glines) do
    table.insert(result, line_text)
    if i == block_start then
      for name, value in pairs(global_vars) do
        table.insert(result, string.format("@%s = %s", name, value))
      end
    end
  end
  return table.concat(result, "\n"), gcount
end

--- Resolve the current request name from collected requests.
local function resolve_current_req_name(src_buf, line)
  local requests = request_vars.collect_requests(src_buf)
  for _, req in ipairs(requests) do
    if line >= req.start_line and line <= req.end_line then
      return req.name
    end
  end
  return nil
end

--- Prepare request: resolve prompt variables → modified content.
--- Returns (modified_content, req_line, block_start, block_end) via callback.
local function prepare_request(src_buf, line, buf_content, binary, file, callback)
  request_vars.handle_prompt_variables(src_buf, line, buf_content, binary, file, state.current_env, function(modified_content)
    if not modified_content then
      indicators.clear_all(src_buf)
      state.pending_request = nil
      return
    end
    local req_line = indicators.find_request_line(src_buf, line)
    if not req_line then
      indicators.clear_all(src_buf)
      return
    end
    indicators.clear_other_requests(src_buf, req_line)
    indicators.set_indicator(src_buf, req_line, "running")

    local block_start, block_end = indicators.find_request_block_bounds(src_buf, line)
    callback(modified_content, req_line, block_start, block_end)
  end)
end

--- Execute request: resolve vars, extract/run scripts, build curl cmd, start job.
local function execute_request(src_buf, line, binary, file, modified_content, req_line, block_start, block_end, callback)
  request_vars.resolve_request_variables(binary, file, state.current_env, src_buf, line, modified_content, function(buf_content)
    local pre_script_code
    local script_vars = nil
    if block_start then
      buf_content, pre_script_code = scripts.extract_pre_script_blocks(buf_content, block_start, block_end)
      script_vars = scripts.collect_script_variables(buf_content, block_start, block_end)
    end

    -- Run pre-request script if present
    if pre_script_code then
      local pre_result = scripts.run_pre_script(pre_script_code, script_vars)
      if pre_result.error then
        state.log("ERROR", pre_result.error)
        indicators.set_indicator(src_buf, req_line, "error")
        local err_resp = make_error_response("", nil, pre_result.error, "Pre-script error", 1)
        state.last_response = err_resp
        emit_response(err_resp, nil, file, nil, nil)
        view.show_view("verbose")
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
        line = line + injected_count
        for name, value in pairs(pre_result.variables) do
          state.script_variables[name] = value
        end
      end
    end

    -- Inject global vars
    local global_count
    buf_content, global_count = inject_global_vars(buf_content, block_start, state.global_vars)
    block_end = block_end + global_count

    -- Process form data and extract assertion blocks
    buf_content = request_vars.process_form_data(src_buf, line, buf_content)
    local assertion_code
    buf_content, assertion_code = assertions.extract_assertion_blocks(buf_content, block_start, block_end)

    local current_req_name = resolve_current_req_name(src_buf, line)
    local req_block = indicators.extract_request_block(src_buf, line)
    local req_text = req_block.request_line

    callback(buf_content, req_block, req_text, assertion_code, script_vars, current_req_name, block_start, block_end)
  end)
end

--- Start curl job via vim.fn.jobstart with stdin piped.
local function start_curl_job(binary, file, line, buf_content, req_line, src_buf, req_block, req_text, assertion_code, script_vars, current_req_name, block_start, block_end)
  local cmd = string.format("%s run %s --line %d --env %s --json --stdin",
    vim.fn.shellescape(binary),
    vim.fn.shellescape(file),
    line,
    vim.fn.shellescape(state.current_env)
  )
  state.log("INFO", string.format("cmd: %s", cmd))

  local stderr_buf = {}
  local env = { POSTE_CACHE_DIR = state.config.response_cache_dir }

  local job_id = vim.fn.jobstart(cmd, {
    env = env,
    stdin = "pipe",
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      handle_job_stdout(data, src_buf, req_line, req_block, req_text, assertion_code, script_vars, current_req_name, file)
    end,
    on_stderr = function(_, data)
      data = util.ensure_job_data(data)
      if #data == 0 then return end
      for _, l in ipairs(data) do
        table.insert(stderr_buf, l)
      end
    end,
    on_exit = function(_, code)
      handle_job_exit(code, stderr_buf, src_buf, req_line, req_block, req_text, current_req_name, file)
    end,
  })

  if job_id > 0 then
    vim.fn.chansend(job_id, buf_content)
    vim.fn.chanclose(job_id, "stdin")
    build_pending_request(src_buf, buf_content, req_block, block_start, block_end, file)
    view.show_view("verbose")
  else
    indicators.set_indicator(src_buf, req_line, "error")
    vim.notify("Failed to start poste job", vim.log.levels.ERROR, { title = "Poste" })
  end
end

---------------------------------------------------------------------------
-- Main entry point
---------------------------------------------------------------------------

--- Run the HTTP request at the current cursor position.
function M.run_request()
  local ft = vim.bo.filetype
  if ft == "poste_sql" or ft == "poste_sqlite" then
    require("poste.sql.init").run_sql_request()
    return
  end

  local binary = state.find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found. Make sure it's in PATH or built locally.", vim.log.levels.ERROR)
    return
  end

  clear_state()

  local src_buf = vim.api.nvim_get_current_buf()
  local line = vim.fn.line(".")
  state.last_request = { buf = src_buf, line = line }

  local file = vim.api.nvim_buf_get_name(src_buf)
  if file == "" then
    file = vim.fn.getcwd() .. "/untitled.http"
  end

  local buf_lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
  local buf_content = table.concat(buf_lines, "\n")

  -- Check if this is a `run` directive (import/run cross-file execution)
  local resolved = import_mod.resolve_run_at_cursor(src_buf, line)
  if resolved.action ~= "none" then
    if resolved.warnings and #resolved.warnings > 0 then
      for _, w in ipairs(resolved.warnings) do
        state.log("WARN", w)
      end
    end

    if resolved.error then
      vim.notify(resolved.error, vim.log.levels.ERROR, { title = "Poste" })
      indicators.set_indicator(src_buf, (resolved.run_line or line) - 1, "error")
      return
    end

    state.log("INFO", string.format("Import/run directive resolved: %s -> %s line %d",
      resolved.action, resolved.path or "", resolved.line or 0))

    -- Extract assertion blocks from the run directive's block in the source buffer
    local block_start, block_end = indicators.find_request_block_bounds(src_buf, line)
    local script_vars
    local assertion_code
    if block_start then
      script_vars = scripts.collect_script_variables(buf_content, block_start, block_end)
      _, assertion_code = assertions.extract_assertion_blocks(buf_content, block_start, block_end)
    end

    -- Place indicator on the run directive line itself
    local indicator_line = (resolved.run_line or line) - 1
    indicators.set_indicator(src_buf, indicator_line, "running")

    import_mod.execute_run_directive(resolved, function(success, response)
      handle_directive_response(success, response, src_buf, indicator_line, assertion_code, script_vars, resolved, file)
    end)
    return
  end

  -- Standard request pipeline
  prepare_request(src_buf, line, buf_content, binary, file, function(modified_content, req_line, block_start, block_end)
    execute_request(src_buf, line, binary, file, modified_content, req_line, block_start, block_end,
      function(inner_content, req_block, req_text, assertion_code, script_vars, current_req_name, blk_start, blk_end)
        if req_text and vim.trim(req_text):upper() == "SCRIPT" then
          local script_response = make_script_response(req_text, req_block)
          state.last_response = script_response
          state._json.query = nil
          state._json.original_lines = nil
          state._json.is_filtered = false
          emit_response(script_response, current_req_name, file, nil, nil)

          local assertion_results = run_and_store_assertions(script_response, assertion_code, script_vars)

          if assertion_results and assertion_results.total > 0 then
            view.show_view("assertions")
          elseif state.last_script_logs and #state.last_script_logs > 0 then
            view.show_view("script_logs")
          else
            view.show_view("verbose")
          end

          set_result_indicator(src_buf, req_line, script_response, assertion_results)
          local hist_name = (current_req_name or "") ~= "" and current_req_name or ("Script #" .. tostring(req_line + 1))
          add_to_history(hist_name, script_response, file)
          return
        end

        start_curl_job(binary, file, line, inner_content, req_line, src_buf, req_block, req_text,
          assertion_code, script_vars, current_req_name, blk_start, blk_end)
      end)
  end)
end

return M
