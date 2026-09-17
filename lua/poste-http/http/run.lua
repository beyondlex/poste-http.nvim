local state = require("poste-http.state")
local util = require("poste-http.util")
local indicators = require("poste-http.indicators")
local cache = require("poste-http.http.cache")
local request_vars = require("poste-http.http.request_vars")
local resolve = require("poste-http.http.resolve")
local scripts = require("poste-http.http.scripts")
local assertions = require("poste-http.http.assertions")
local view = require("poste-http.http.view")
local response_buf = require("poste-http.http.buffer")
local import_mod = require("poste-http.http.import")
local history = require("poste-http.http.history")
local event = require("poste-http.event")
local session = require("poste-http.http.session")
local describe = require("poste-http.http.describe")
local executors = require("poste-http.http.executors")
local vars = require("poste-http.http.vars")
local orchestration = require("poste-http.http.orchestration")
local errors = require("poste-http.http.errors")
local global_headers = require("poste-http.http.global_headers")
local block_operators = require("poste-http.http.block_operators")
local response_mod = require("poste-http.http.response")

local M = {}

---------------------------------------------------------------------------
-- Pipeline helpers
---------------------------------------------------------------------------

--- Parts the unresolved-variable gate scans: URL, body, and every header's
--- NAME and VALUE. Exposed for specs — the name side used to be missing, so
--- a literal {{var}} header name went to curl verbatim (REVIEW-2026-09-17).
function M.unresolved_var_parts(url, body, headers)
  local parts = { url, body }
  for _, h in ipairs(headers or {}) do
    table.insert(parts, h[1] or "")
    table.insert(parts, h[2] or "")
  end
  return parts
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
    ok = true,
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
    ok = false,
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

--- Find the first line (1-indexed) of `> {%` assertion block in the source buffer.
--- @param src_buf number
--- @param block_start number  1-indexed block start
--- @param block_end number    1-indexed block end
--- @return number|nil
local function find_assertion_line(src_buf, block_start, block_end)
  if not src_buf or not block_start or not block_end then return nil end
  local lines = vim.api.nvim_buf_get_lines(src_buf, block_start - 1, block_end, false)
  for i, l in ipairs(lines) do
    local t = vim.trim(l)
    if t:match("^>%s*{%%") or t:match("^>%s*%.%.?/") then
      return block_start + i - 1
    end
  end
  return nil
end

--- Map a Lua error line inside an assertion block to the source file line.
--- The error message is like `[string "assertions"]:N: ...`. For a multi-line
--- `> {%` block the first code line is the line after the `> {%` marker.
--- @param assertion_line number  1-indexed `> {%` line (or nil)
--- @param err_msg string
--- @return number|nil
local function assertion_error_line(assertion_line, err_msg)
  if not assertion_line or not err_msg then return nil end
  local lua_line = tostring(err_msg):match('%[string "assertions"%]:%s*(%d+)')
  if not lua_line then return assertion_line end
  return assertion_line + tonumber(lua_line)
end

--- Run assertions and update state.
--- @param parsed table|nil
--- @param assertion_code string|nil
--- @param script_vars table|nil
--- @param file string|nil  Source file for error source
--- @param line number|nil  Assertion block line for error source
local function run_and_store_assertions(parsed, assertion_code, script_vars, file, line)
  if not assertion_code then return nil end
  local results = assertions.run_assertions(parsed, assertion_code, script_vars)
  state.set_assertion_results(results)
  if results and results.error then
    local src_line = line and assertion_error_line(line, results.error) or line
    state.add_error(errors.post_request("post_script", tostring(results.error), { file = file, line = src_line }))
  end
  state.log("INFO", string.format("Assertions: %d passed, %d failed", results.passed, results.failed))
  return results
end

--- Choose the appropriate view tab based on status and assertion results.
local function choose_view_tab(parsed, assertion_results)
  if state.last_errors and #state.last_errors > 0 then
    return "errors"
  end
  if not parsed then
    return "verbose"
  end
  if assertion_results and assertion_results.failed > 0 then
    return "assertions"
  end
  if response_mod.is_error(parsed) then
    return "verbose"
  end
  -- WebSocket frame transcripts are the payload: default to Messages.
  if parsed.protocol == "websocket" and parsed.metadata and parsed.metadata.frames then
    return "messages"
  end
  return state.config.default_view or "body"
end

--- Set indicator based on status and assertions.
local function set_result_indicator(src_buf, line_0, parsed, assertion_results)
  local failed = response_mod.is_error(parsed)
  local has_failures = assertion_results and assertion_results.failed > 0

  if has_failures or failed then
    indicators.set_indicator(src_buf, line_0, "error", parsed.latency_ms, assertion_results)
  else
    indicators.set_indicator(src_buf, line_0, "success", parsed.latency_ms, assertion_results)
  end
end

--- Add entry to history.
local function add_to_history(name, response_data, file_path)
  history.add_entry(name, response_data, state.last_assertion_results, state.last_script_logs, file_path)
end

--- Handle the parsed response from curl_exec.
--- @param ctx table  Pipeline context with src_buf, req_line, req_block, req_text,
---                   assertion_code, script_vars, current_req_name, file, start_hires
local function handle_curl_response(response, ctx)
  vim.schedule(function()
    local ok, err = pcall(function()
      state._json.query = nil
      state._json.original_lines = nil
      state._json.is_filtered = false

      local src_buf = ctx.src_buf
      local req_line = ctx.req_line
      local current_req_name = ctx.current_req_name
      local file = ctx.file
      local assertion_code = ctx.assertion_code
      local script_vars = ctx.script_vars

      if state.pending_request then
        state.pending_request = vim.tbl_extend("keep", {
          method = (response.metadata and response.metadata.method) or "",
          url = response.url or "",
          timestamp = util.timestamp(),
        }, state.pending_request)
      end

      if response.error then
        response = {
          protocol = "error", status = 0, status_text = response.error,
          latency_ms = 0, url = "", content_type = "text/plain",
          headers = {}, body = response.error, cookies = {},
          ok = false,
          metadata = { method = "", error = response.error, exit_code = "1" },
        }
      end

      if response.error or (response.status == 0 and response.protocol == "error") then
        indicators.set_indicator(src_buf, req_line - 1, "error")
        state.set_response(response)
        response_buf.reset_multi_response()
        emit_response(response, current_req_name, file, nil, nil)
        view.show_view("verbose")
        local err_name = (current_req_name or "") ~= "" and current_req_name or ("Request #" .. req_line)
        add_to_history(err_name, state.last_response, file)
        return
      end

      state.set_response(response)
      if state.pending_request then
        response.metadata = response.metadata or {}
        if not response.metadata.request_headers then
          response.metadata.request_headers = state.pending_request.headers_str or ""
        end
        if not response.metadata.request_body then
          response.metadata.request_body = state.pending_request.body or ""
        end
        if not response.metadata.timestamp then
          response.metadata.timestamp = state.pending_request.timestamp or ""
        end
        if not response.metadata.env then
          response.metadata.env = state.pending_request.env or ""
        end
      end
      response.request_name = current_req_name
      request_vars.cache_response(current_req_name, response)

      local dep_chain = request_vars.get_dep_chain()
      if dep_chain and #dep_chain > 0 then
        local chain = {}
        for _, item in ipairs(dep_chain) do
          table.insert(chain, {name = item.name, response = item.response})
          history.add_entry(item.name, item.response, nil, nil, file)
        end
        table.insert(chain, {name = current_req_name or "Request", response = response})
        response_buf.reset_multi_response()
        state.set_responses(chain, #chain)
        request_vars.clear_dep_chain()
        pcall(response_buf.prepare_multi_responses, chain)
      else
        response_buf.reset_multi_response()
      end

      emit_response(response, current_req_name, file, nil, nil)

      if vim.api.nvim_buf_is_valid(src_buf) then
        local buf_lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
        state._exec_context = { file = file, line = req_line, set_lines = scripts.scan_script_set_calls(buf_lines, ctx.block_start, ctx.block_end) }
        local assertion_line = find_assertion_line(src_buf, ctx.block_start, ctx.block_end)
        local assertion_results = run_and_store_assertions(response, assertion_code, script_vars, file, assertion_line)
        state._exec_context = nil
        local view_name = choose_view_tab(response, assertion_results)
        view.show_view(view_name)
        set_result_indicator(src_buf, req_line - 1, response, assertion_results)
        local hist_name = (current_req_name or "") ~= "" and current_req_name or ("Request #" .. req_line)
        add_to_history(hist_name, state.last_response, file)
      end
    end)
    if not ok then
      vim.notify("Poste: " .. tostring(err), vim.log.levels.ERROR)
    end
    state._busy = false
  end)
end

--- Handle the import/run directive response callback.
local function handle_directive_response(success, response, src_buf, indicator_line, assertion_code, script_vars, resolved, file)
  vim.schedule(function()
    local ok, err = pcall(function()
      if not (success and response) then
        indicators.set_indicator(src_buf, indicator_line, "error")
        return
      end

      if not vim.api.nvim_buf_is_valid(src_buf) then return end

      if type(response) == "table" and response[1] and response[1].response then
        response_buf.reset_multi_response()
        state.set_responses(response, #response)
        state.last_response = response[#response].response
        pcall(response_buf.prepare_multi_responses, response)
      else
        state.set_response(response)
      end

      emit_response(state.last_response, resolved.request_name, resolved.path or file, nil, nil)

      if assertion_code then
        local ass_line = find_assertion_line(src_buf, indicator_line + 1, vim.api.nvim_buf_line_count(src_buf))
        run_and_store_assertions(state.last_response, assertion_code, script_vars, resolved.path or file, ass_line)
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
    if not ok then
      vim.notify("Poste: " .. tostring(err), vim.log.levels.ERROR)
    end
    state._busy = false
  end)
end

--- Render the result of an orchestration script (SCRIPT block with > {% %}).
--- Reuses the multi-response chain view for client.run calls and the
--- Assertions tab for script errors; logs go to the Script Logs tab.
local function render_orchestration_result(result, ctx)
  local req_line = ctx.req_line
  local src_buf = ctx.src_buf
  local current_req_name = ctx.current_req_name
  local file = ctx.file

  local summary = make_script_response(ctx.req_text, ctx.req_block)
  if result.error then
    summary.status = 0
    summary.status_text = "Script error"
    summary.body = result.error
    state.add_error(errors.post_request("post_script", tostring(result.error), { file = ctx.file }))
  end

  local assertion_results = {
    total = 1,
    passed = result.error and 0 or 1,
    failed = result.error and 1 or 0,
    error = result.error,
    tests = {},
    logs = result.logs or {},
  }

  -- set_assertion_results appends its logs into last_script_logs, so set it
  -- BEFORE set_script_logs to avoid self-appending the same table.
  state.set_assertion_results(assertion_results)
  state.clear_json_state()
  if result.logs and #result.logs > 0 then
    state.set_script_logs(result.logs)
  end

  if result.calls and #result.calls > 0 then
    response_buf.reset_multi_response()
    state.set_responses(result.calls, #result.calls)
    state.last_response = result.calls[#result.calls].response
    pcall(response_buf.prepare_multi_responses, result.calls)
  else
    state.set_response(summary)
  end

  emit_response(summary, current_req_name, file, assertion_results, result.logs)

  local view_name = result.error and "assertions"
    or (result.calls and #result.calls > 0 and "body")
    or (result.logs and #result.logs > 0 and "script_logs")
    or "verbose"
  view.show_view(view_name)
  set_result_indicator(src_buf, req_line - 1, summary, assertion_results)

  for _, call in ipairs(result.calls or {}) do
    add_to_history(call.name, call.response, file)
  end
  local hist_name = (current_req_name or "") ~= "" and current_req_name or ("Script #" .. tostring(req_line))
  add_to_history(hist_name, summary, file)
  state._busy = false
end

local function handle_orchestration_result(result, ctx)
  vim.schedule(function()
    local ok, err = pcall(function()
      render_orchestration_result(result, ctx)
    end)
    if not ok then
      vim.notify("Poste: " .. tostring(err), vim.log.levels.ERROR)
    end
    state._busy = false
  end)
end

local function resolve_current_req_name(src_buf, line)
  local requests = request_vars.collect_requests(src_buf)
  for _, req in ipairs(requests) do
    if line >= req.start_line and line <= req.end_line then
      return req.name
    end
  end
  return nil
end

--- Prepare request: resolve prompt variables and request deps → modified content.
--- Fills ctx.modified_content, ctx.req_line, ctx.block_start, ctx.block_end via callback.
local function prepare_request(ctx, callback)
  local src_buf = ctx.src_buf
  local line = ctx.line
  local buf_content = ctx.buf_content
  local file = ctx.file

  local req_line = cache.find_request_line(src_buf, line)
  if not req_line then
    indicators.clear_all(src_buf)
    state._busy = false
    return
  end
  indicators.clear_other_requests(src_buf, req_line - 1)
  indicators.set_indicator(src_buf, req_line - 1, "running")

  local block_start, block_end = cache.find_request_block_bounds(src_buf, line)
  resolve.resolve(buf_content, {
    mode = "request",
    buf = src_buf,
    cursor_line = line,
    block_line = block_start,
    file = file,
    env_name = state.current_env,
  }, function(modified_content)
    if not modified_content then
      indicators.clear_all(src_buf)
      state.set_pending_request(nil)
      state._busy = false
      return
    end
    ctx.modified_content = modified_content
    ctx.req_line = req_line
    ctx.block_start = block_start
    ctx.block_end = block_end
    callback(ctx)
  end)
end

--- Execute request: run scripts, inject vars, build curl cmd, start job.
--- Fills ctx.buf_content, ctx.req_block, ctx.req_text, ctx.assertion_code,
--- ctx.script_vars, ctx.current_req_name, ctx.block_start, ctx.block_end
local function execute_request(ctx, callback)
  local src_buf = ctx.src_buf
  local line = ctx.line
  local file = ctx.file
  local modified_content = ctx.modified_content
  local req_line = ctx.req_line
  local block_start = ctx.block_start
  local block_end = ctx.block_end

  local buf_content = modified_content
  local pre_script_code
  local script_vars = nil
  if block_start then
    buf_content, pre_script_code = scripts.extract_pre_script_blocks(buf_content, block_start, block_end, vim.fn.fnamemodify(file, ":h"))
    script_vars = scripts.collect_script_variables(buf_content, block_start, block_end, vim.fn.fnamemodify(file, ":h"))
  end

  if pre_script_code then
    local set_lines = scripts.scan_script_set_calls(vim.split(buf_content, "\n", { plain = true }), block_start, block_end)
    state._exec_context = { file = file, line = block_start, set_lines = set_lines }
    local pre_result = scripts.run_pre_script(pre_script_code, script_vars)
    state._exec_context = nil
    if pre_result.error then
      state.log("ERROR", pre_result.error)
      indicators.set_indicator(src_buf, req_line - 1, "error")
      state.set_errors({ errors.pre_request("pre_script", tostring(pre_result.error), { line = block_start, file = file }) })
      state.set_response(nil)
      state.set_pending_request(nil)
      view.show_view("errors")
      state._busy = false
      return
    end
    if #pre_result.logs > 0 then
      state.set_script_logs(pre_result.logs)
    end
    if next(pre_result.variables) then
      local injected_count = 0
      for _ in pairs(pre_result.variables) do injected_count = injected_count + 1 end
      buf_content = scripts.inject_pre_script_vars(buf_content, block_start, pre_result.variables)
      block_end = block_end + injected_count
      line = line + injected_count
      for name, value in pairs(pre_result.variables) do
        state.set_script_variable(name, value)
      end
    end
  end

  -- Inject global vars
  local global_count
  buf_content, global_count = scripts.inject_global_vars(buf_content, block_start, state.global_vars)
  block_end = block_end + global_count

  -- Process form data and extract assertion blocks
  buf_content = request_vars.process_form_data(src_buf, line, buf_content)
  local assertion_code
  buf_content, assertion_code = assertions.extract_assertion_blocks(buf_content, block_start, block_end, vim.fn.fnamemodify(file, ":h"))

  local current_req_name = resolve_current_req_name(src_buf, line)

  -- Prefer CLI describe for request semantics; fall back to indicators extract
  local req_block
  local meta = nil
  local blocks = describe.describe_content(buf_content, file)
  if blocks then
    meta = describe.block_at_line(blocks, block_start or line)
  end
  if meta then
    req_block = describe.to_req_block(meta)
  else
    req_block = cache.extract_request_block(src_buf, line)
  end
  local req_text = req_block.request_line

  -- Resolve Lua import references (@var = m.key, {{m.key}})
  local buf_dir = file ~= "" and vim.fn.fnamemodify(file, ":h") or vim.fn.getcwd()
  buf_content = import_mod.resolve_lua_imports(buf_content, buf_dir)

  ctx.buf_content = buf_content
  ctx.req_block = req_block
  ctx.req_text = req_text
  ctx.assertion_code = assertion_code
  ctx.script_vars = script_vars
  ctx.current_req_name = current_req_name
  ctx.block_start = block_start
  ctx.block_end = block_end
  callback(ctx)
end

--- Start curl execution via curl_exec, passing parsed request details.
--- @param ctx table  Pipeline context with file, buf_content, req_line, src_buf,
---                   req_block, req_text, assertion_code, script_vars, current_req_name,
---                   block_start, block_end
local function start_curl_exec(ctx)
  local file = ctx.file
  local buf_content = ctx.buf_content
  local req_line = ctx.req_line
  local src_buf = ctx.src_buf
  local block_start = ctx.block_start
  local block_end = ctx.block_end
  local req_block = ctx.req_block

  local buf_dir = file ~= "" and vim.fn.fnamemodify(file, ":h") or vim.fn.getcwd()

  -- Resolve variables in the content (use buf_content lines, not buffer, so
  -- prompt-injected @var lines like @method = value are visible to the resolver)
  local resolver = vars.build_resolver_from_state({
    lines = vim.split(buf_content, "\n", { plain = true }),
    file_path = file,
    block_start = block_start,
    block_end = block_end,
    env_name = state.current_env,
  })
  local resolved_content = resolver:substitute(buf_content)

  -- Describe the resolved content to extract method, url, headers, body
  local blocks = describe.describe_content(resolved_content, file)
  local meta = blocks and describe.block_at_line(blocks, block_start or 1)
  local method = "GET"
  local url = ""
  local headers = {}
  local body = ""

  if meta then
    method = meta.method or "GET"
    url = meta.path or ""
    headers = meta.headers or {}
    body = meta.body or ""
  elseif req_block then
    local rl = req_block.request_line or ""
    method = vim.trim(rl:match("^(%S+)") or "GET")
    url = vim.trim(rl:match("^%S+%s+(%S+)") or "")
    headers = req_block.headers or {}
    body = req_block.body or ""
  end

  -- Resolve any remaining {{var}} in the URL
  url = resolver:substitute(url)

  if not url or url == "" then
    indicators.set_indicator(src_buf, req_line - 1, "error")
    state._busy = false
    vim.notify("Could not determine request URL", vim.log.levels.ERROR, { title = "Poste" })
    return
  end

  -- Pre-request validation: block if any variable remains unresolved in the
  -- URL, body, or headers — names and values both (REVIEW-2026-09-17 noted
  -- that a literal {{var}} in a header NAME slipped past and went to curl
  -- verbatim). Sending a request with literal {{var}} in it is almost
  -- certainly a mistake, so fail fast instead of hitting the network.
  local unresolved = errors.find_unresolved_vars(M.unresolved_var_parts(url, body, headers))
  if #unresolved > 0 then
    indicators.set_indicator(src_buf, req_line - 1, "error")
    local src_lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
    local errs = {}
    for _, name in ipairs(unresolved) do
      local real_line = errors.find_var_line(src_lines, name, block_start, block_end)
      table.insert(errs, errors.pre_request("variable_resolution",
        string.format("Cannot resolve variable '{{%s}}' in request", name),
        { var = name, line = real_line, file = file }))
    end
    state.set_errors(errs)
    state.set_response(nil)
    state.set_pending_request(nil)
    view.show_view("errors")
    state._busy = false
    return
  end

  local merged_headers = global_headers.merge(headers, resolver)
  state.log("INFO", string.format("%s %s (%d headers, %d global)", method, util.redact_url_query(url), #headers, #merged_headers - #headers))

  local start_hires = (vim.uv or vim.loop).hrtime()

  -- `# @name value` operator comments carry per-protocol executor options
  -- (e.g. `# @grpc-proto echo.proto`); extraction is protocol-neutral.
  local operators = block_operators.extract(
    vim.split(resolved_content, "\n", { plain = true }),
    block_start or 1, block_end)

  -- Interactive WebSocket sessions stream frames through this hook; other
  -- protocols never call it (see make_ws_progress_handler for the guard).
  local on_progress = M.make_ws_progress_handler()

  executors.run({
    method = method,
    url = url,
    headers = merged_headers,
    body = body,
    buf_dir = buf_dir,
    timeout = state.config.timeout,
    operators = operators,
    on_progress = on_progress,
  }, function(response)
    handle_curl_response(response, ctx)
  end)

  local h_parts = {}
  for _, h in ipairs(merged_headers) do
    table.insert(h_parts, h[1] .. ": " .. h[2])
  end
  state.set_pending_request({
    method = method,
    url = url,
    headers_str = #h_parts > 0 and table.concat(h_parts, "\n") or "",
    body = body,
    name = (meta and meta.name) or (req_block and req_block.name) or "",
    env = state.current_env,
    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    start_hires = start_hires,
  })
  view.show_view("verbose")
end

--- Build the progress handler for an interactive WebSocket session.
--- Every progress response is a freshly built table, so the guard compares
--- against the response this handler last published: streaming responses
--- keep replacing each other (Msgs tab refreshes on each frame), but once
--- a different request's response replaced ours in state, the live
--- session's late frames must not stomp the newer view.
function M.make_ws_progress_handler()
  local published = nil
  local switched = false
  return function(resp)
    if published ~= nil and state.last_response ~= published then
      return
    end
    published = resp
    state.set_response(resp)
    state._busy = false
    if not switched or state.current_view == "messages" then
      switched = true
      view.show_view("messages")
    end
  end
end

---------------------------------------------------------------------------
-- Main entry point
---------------------------------------------------------------------------

--- Run the HTTP request at the current cursor position.
function M.run_request()
  if state._busy then
    vim.notify("Request already in progress", vim.log.levels.WARN, { title = "Poste" })
    return
  end
  state._busy = true
  local src_buf = vim.api.nvim_get_current_buf()
  local line = vim.fn.line(".")
  local file = vim.api.nvim_buf_get_name(src_buf)
  if file == "" then
    file = vim.fn.getcwd() .. "/untitled.http"
  end

  -- Fresh session: clears all request-scoped state (Phase 2b)
  session.begin({ buf = src_buf, line = line, file = file })
  state.set_request(src_buf, line)

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
      state._busy = false
      return
    end

    state.log("INFO", string.format("Import/run directive resolved: %s -> %s line %d",
      resolved.action, resolved.path or "", resolved.line or 0))

    -- Extract assertion blocks from the run directive's block in the source buffer
    local block_start, block_end = cache.find_request_block_bounds(src_buf, line)
    local script_vars
    local assertion_code
    if block_start then
      script_vars = scripts.collect_script_variables(buf_content, block_start, block_end, vim.fn.fnamemodify(file, ":h"))
      -- Assign to the outer assertion_code: a `local` here would shadow it
      -- and silently drop the block's assertions from `run` directives.
      assertion_code = select(2, assertions.extract_assertion_blocks(buf_content, block_start, block_end, vim.fn.fnamemodify(file, ":h")))
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
  local ctx = {
    src_buf = src_buf,
    line = line,
    file = file,
    buf_content = buf_content,
  }

  prepare_request(ctx, function(prepared_ctx)
    execute_request(prepared_ctx, function(exec_ctx)
      if exec_ctx.req_text and vim.trim(exec_ctx.req_text):upper() == "SCRIPT" then
        -- A SCRIPT block with a > {% %} body runs as an orchestration script:
        -- client.run() executes imported requests and returns typed responses.
        if exec_ctx.assertion_code then
          orchestration.run_script(exec_ctx.assertion_code, {
            buf = src_buf,
            variables = exec_ctx.script_vars and exec_ctx.script_vars.variables,
            env = exec_ctx.script_vars and exec_ctx.script_vars.env,
            response = make_script_response(exec_ctx.req_text, exec_ctx.req_block),
          }, function(result)
            handle_orchestration_result(result, exec_ctx)
          end)
          return
        end

        -- SCRIPT block without an orchestration body: keep the legacy behavior.
        local script_response = make_script_response(exec_ctx.req_text, exec_ctx.req_block)
        state.set_response(script_response)
        state.clear_json_state()
        emit_response(script_response, exec_ctx.current_req_name, file, nil, nil)

        local ass_line = find_assertion_line(src_buf, exec_ctx.block_start, exec_ctx.block_end)
        local assertion_results = run_and_store_assertions(script_response, exec_ctx.assertion_code, exec_ctx.script_vars, file, ass_line)

        if assertion_results and assertion_results.total > 0 then
          view.show_view("assertions")
        elseif state.last_script_logs and #state.last_script_logs > 0 then
          view.show_view("script_logs")
        else
          view.show_view("verbose")
        end

        set_result_indicator(src_buf, exec_ctx.req_line - 1, script_response, assertion_results)
        local hist_name = (exec_ctx.current_req_name or "") ~= "" and exec_ctx.current_req_name or ("Script #" .. tostring(exec_ctx.req_line))
        add_to_history(hist_name, script_response, file)
        state._busy = false
        return
      end

      start_curl_exec(exec_ctx)
    end)
  end)
end

M.make_script_response = make_script_response
M.make_error_response = make_error_response
M.choose_view_tab = choose_view_tab
M.render_orchestration_result = render_orchestration_result
M.start_curl_exec = start_curl_exec -- exposed for tests

return M
