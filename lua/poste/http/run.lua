local state = require("poste.state")
local util = require("poste.util")
local indicators = require("poste.indicators")
local request_vars = require("poste.http.request_vars")
local scripts = require("poste.http.scripts")
local assertions = require("poste.http.assertions")
local view = require("poste.http.view")
local import_mod = require("poste.http.import")
local history = require("poste.http.history")

local uv = vim.uv or vim.loop

local M = {}

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

  state.last_response = nil
  state.last_assertion_results = nil
  state.last_script_logs = nil
  state.pending_request = nil

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
    local local_buf_content = buf_content
    local script_vars
    local assertion_code
    if block_start then
      script_vars = scripts.collect_script_variables(local_buf_content, block_start, block_end)
      local_buf_content, assertion_code = assertions.extract_assertion_blocks(local_buf_content, block_start, block_end)
    end

    -- Place indicator on the run directive line itself
    local indicator_line = (resolved.run_line or line) - 1
    indicators.set_indicator(src_buf, indicator_line, "running")

    import_mod.execute_run_directive(resolved, function(success, response)
      vim.schedule(function()
        if success and response then
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

          if assertion_code then
            state.last_assertion_results = assertions.run_assertions(state.last_response, assertion_code, script_vars)
            state.log("INFO", string.format("Assertions: %d passed, %d failed",
              state.last_assertion_results.passed, state.last_assertion_results.failed))

            if state.last_assertion_results.logs and #state.last_assertion_results.logs > 0 then
              state.last_script_logs = state.last_script_logs or {}
              for _, msg in ipairs(state.last_assertion_results.logs) do
                table.insert(state.last_script_logs, msg)
              end
            end

            local is_error = state.last_response.status and state.last_response.status >= 400
            if state.last_assertion_results.failed > 0 then
              view.show_view("assertions")
              indicators.set_indicator(src_buf, indicator_line, "success", state.last_response.latency_ms, state.last_assertion_results)
            elseif is_error then
              view.show_view("verbose")
              indicators.set_indicator(src_buf, indicator_line, "error", state.last_response.latency_ms, state.last_assertion_results)
            else
              view.show_view("body")
              indicators.set_indicator(src_buf, indicator_line, "success", state.last_response.latency_ms, state.last_assertion_results)
            end
          else
            if state.last_response.status and state.last_response.status >= 400 then
              view.show_view("verbose")
              indicators.set_indicator(src_buf, indicator_line, "error", state.last_response.latency_ms)
            else
              view.show_view("body")
              indicators.set_indicator(src_buf, indicator_line, "success", state.last_response.latency_ms)
            end
          end

          if type(response) == "table" and response[1] and response[1].response then
            for _, item in ipairs(response) do
              local item_name = (item.name or "") ~= "" and item.name or ("Request #" .. (item.line or ""))
              history.add_entry(item_name, item.response, state.last_assertion_results, state.last_script_logs, resolved.path or file)
            end
          else
            history.add_entry(resolved.request_name or "Import", response, state.last_assertion_results, state.last_script_logs, resolved.path or file)
          end
        else
          indicators.set_indicator(src_buf, indicator_line, "error")
        end
      end)
    end)
    return
  end

  request_vars.handle_prompt_variables(src_buf, line, buf_content, binary, file, state.current_env, function(modified_content)
    local req_line = indicators.find_request_line(src_buf, line)
    if not req_line then
      indicators.clear_all(src_buf)
      return
    end
    indicators.clear_other_requests(src_buf, req_line)
    indicators.set_indicator(src_buf, req_line, "running")

    local block_start, block_end = indicators.find_request_block_bounds(src_buf, line)

    request_vars.resolve_request_variables(binary, file, state.current_env, src_buf, line, modified_content, function(buf_content)

      local pre_script_code
      local script_vars = nil
      if block_start then
        buf_content, pre_script_code = scripts.extract_pre_script_blocks(buf_content, block_start, block_end)
        script_vars = scripts.collect_script_variables(buf_content, block_start, block_end)
      end

      if pre_script_code then
        local pre_result = scripts.run_pre_script(pre_script_code, script_vars)
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

      if block_start and state.global_vars and next(state.global_vars) then
        local glines = vim.split(buf_content, "\n", { plain = true })
        local result = {}
        local gcount = 0
        for name, _ in pairs(state.global_vars) do gcount = gcount + 1 end
        for i, line in ipairs(glines) do
          table.insert(result, line)
          if i == block_start then
            for name, value in pairs(state.global_vars) do
              table.insert(result, string.format("@%s = %s", name, value))
            end
          end
        end
        buf_content = table.concat(result, "\n")
        line = line + gcount
      end

      buf_content = request_vars.process_form_data(src_buf, line, buf_content)

      local assertion_code
      buf_content, assertion_code = assertions.extract_assertion_blocks(buf_content, block_start, block_end)

      local requests = request_vars.collect_requests(src_buf)
      local current_req_name = nil
      for _, req in ipairs(requests) do
        if line >= req.start_line and line <= req.end_line then
          current_req_name = req.name
          break
        end
      end

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
          data = util.ensure_job_data(data)
          if #data == 0 then return end

          local output = table.concat(data, "\n")
          state.log("INFO", "stdout: " .. output:sub(1, 200))

          vim.schedule(function()
            state.pending_request = nil
            local ok, parsed = pcall(vim.json.decode, output)
            if ok and parsed and type(parsed) == "table" then
              state._json.query = nil
              state._json.original_lines = nil
              state._json.is_filtered = false
              state.last_response = parsed
              request_vars.cache_response(current_req_name, parsed)

              if assertion_code then
                state.last_assertion_results = assertions.run_assertions(parsed, assertion_code, script_vars)
                state.log("INFO", string.format("Assertions: %d passed, %d failed",
                  state.last_assertion_results.passed, state.last_assertion_results.failed))

                if state.last_assertion_results.logs and #state.last_assertion_results.logs > 0 then
                  state.last_script_logs = state.last_script_logs or {}
                  for _, msg in ipairs(state.last_assertion_results.logs) do
                    table.insert(state.last_script_logs, msg)
                  end
                end

                local is_error = parsed.status and parsed.status >= 400
                if state.last_assertion_results.failed > 0 then
                  view.show_view("assertions")
                  indicators.set_indicator(src_buf, req_line, "success", parsed.latency_ms, state.last_assertion_results)
                elseif is_error then
                  view.show_view("verbose")
                  indicators.set_indicator(src_buf, req_line, "error", parsed.latency_ms, state.last_assertion_results)
                else
                  view.show_view("body")
                  indicators.set_indicator(src_buf, req_line, "success", parsed.latency_ms, state.last_assertion_results)
                end
              else
                if parsed.status and parsed.status >= 400 then
                  view.show_view("verbose")
                  indicators.set_indicator(src_buf, req_line, "error", parsed.latency_ms)
                else
                  view.show_view("body")
                  indicators.set_indicator(src_buf, req_line, "success", parsed.latency_ms)
                end
              end
              local hist_name = (current_req_name or "") ~= "" and current_req_name or ("Request #" .. line)
              history.add_entry(hist_name, state.last_response, state.last_assertion_results, state.last_script_logs, file)
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
              view.show_view("verbose")
              local err_name = (current_req_name or "") ~= "" and current_req_name or ("Request #" .. line)
              history.add_entry(err_name, state.last_response, state.last_assertion_results, state.last_script_logs, file)
            end
          end)
        end,
        on_stderr = function(_, data)
          data = util.ensure_job_data(data)
          if #data == 0 then return end
          for _, l in ipairs(data) do
            table.insert(stderr_buf, l)
          end
        end,
        on_exit = function(_, code)
          if code ~= 0 then
            state.log("ERROR", string.format("exit code %d (line %d, env %s)", code, line, state.current_env))
            vim.schedule(function()
              state.pending_request = nil
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
              view.show_view("verbose")
              local err_name = (current_req_name or "") ~= "" and current_req_name or ("Request #" .. line)
              history.add_entry(err_name, state.last_response, state.last_assertion_results, state.last_script_logs, file)
            end)
          end
        end,
      })

      if job_id > 0 then
        vim.fn.chansend(job_id, buf_content)
        vim.fn.chanclose(job_id, "stdin")

        -- --- Show pending request info immediately ---
        local header_parts = {}
        if req_block.headers then
          for _, h in ipairs(req_block.headers) do
            table.insert(header_parts, h[1] .. ": " .. h[2])
          end
        end
        local headers_str = table.concat(header_parts, "\n")

        -- Resolve @var definitions from the source buffer so the pending
        -- request display shows actual values instead of {{template}} refs.
        local var_map = {}
        local src_lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
        for _, sl in ipairs(src_lines) do
          local vname, vvalue = sl:match("^@([%w_]+)%s*[:=]%s*(.+)$")
          if vname then
            var_map[vname] = vim.trim(vvalue)
          end
        end
        local function resolve_vars(text)
          if not text or text == "" then return text end
          for name, value in pairs(var_map) do
            local safe_value = value:gsub("%%", "%%%%")
            text = text:gsub(vim.pesc("{{" .. name .. "}}"), safe_value)
          end
          return text
        end

        -- Extract the resolved URL and body from buf_content: find the
        -- current request block's ### separator, then read the request line
        -- (which may still have templates until resolved) and the body.
        local req_method = ""
        local req_url = ""
        local body = ""
        if block_start then
          -- Get the ### line text from the source buffer
          local header_text = vim.trim(vim.api.nvim_buf_get_lines(src_buf, block_start - 1, block_start, false)[1] or "")
          local sep_pos = header_text ~= "" and buf_content:find(vim.pesc(header_text), 1, true)
          if sep_pos then
            -- The request line is right after the ### line
            local after_sep = buf_content:find("\n", sep_pos)
            if after_sep then
              local req_line_end = buf_content:find("\n", after_sep + 1)
              if req_line_end then
                local resolved_req = buf_content:sub(after_sep + 1, req_line_end - 1)
                req_method, req_url = resolved_req:match("^(%S+)%s+(.+)$")
              end
            end
            -- Body: find the blank line after headers within this block
            local next_sep = buf_content:find("\n###", sep_pos + 1)
            local block_end_pos = next_sep or #buf_content + 1
            -- Look for the first \n\n after the request line position
            local after_req = (buf_content:find("\n", sep_pos) or sep_pos) + 1
            local header_end = buf_content:find("\n\n", after_req)
            if header_end and header_end < block_end_pos then
              body = buf_content:sub(header_end + 2, block_end_pos - 1)
              -- Trim trailing whitespace
              body = body:gsub("\n+$", "")
            end
          end
        end

        -- Resolve @var templates in the pending display values
        req_url = resolve_vars(req_url)
        body = resolve_vars(body)
        headers_str = resolve_vars(headers_str)

        state.pending_request = {
          method = req_method,
          url = req_url,
          headers_str = headers_str,
          body = body,
          env = state.current_env,
          timestamp = os.date("%Y-%m-%d %H:%M:%S"),
          start_hires = uv.hrtime(),
        }

        -- Open response window with Verb tab; on_stdout will update it
        -- with the full response data once the response arrives.
        view.show_view("verbose")
      else
        indicators.set_indicator(src_buf, req_line, "error")
        vim.notify("Failed to start poste job", vim.log.levels.ERROR, { title = "Poste" })
      end
    end)
  end)
end

return M
