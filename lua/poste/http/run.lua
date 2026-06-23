local state = require("poste.state")
local util = require("poste.util")
local indicators = require("poste.indicators")
local request_vars = require("poste.http.request_vars")
local scripts = require("poste.http.scripts")
local assertions = require("poste.http.assertions")
local view = require("poste.http.view")

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

  state.last_assertion_results = nil
  state.last_script_logs = nil

  local src_buf = vim.api.nvim_get_current_buf()
  local line = vim.fn.line(".")
  state.last_request = { buf = src_buf, line = line }

  local file = vim.api.nvim_buf_get_name(src_buf)
  if file == "" then
    file = vim.fn.getcwd() .. "/untitled.http"
  end

  local buf_lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
  local buf_content = table.concat(buf_lines, "\n")

  request_vars.handle_prompt_variables(src_buf, line, buf_content, binary, file, state.current_env, function(modified_content)
    local req_line = indicators.find_request_line(src_buf, line)
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
          for name, value in pairs(pre_result.variables) do
            state.script_variables[name] = value
          end
        end
      end

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
            local ok, parsed = pcall(vim.json.decode, output)
            if ok and parsed and type(parsed) == "table" then
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
    end)
  end)
end

return M
