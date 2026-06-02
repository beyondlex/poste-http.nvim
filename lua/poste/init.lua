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
      -- normal! m' pushes current pos to the window jumplist;
      -- nvim_win_set_cursor moves without adding to jumplist.
      -- Result: exactly one jumplist entry → one Ctrl-o jumps back.
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { req.start_line, 0 })
      return
    end
  end

  vim.notify("Request not found: " .. req_name, vim.log.levels.WARN)
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

  local function setup_buffer_keymaps(buf)
    local keymap_opts = { buffer = buf, noremap = true, silent = true }
    vim.keymap.set("n", "<leader>rr", M.run_request, keymap_opts)
    vim.keymap.set("n", "]]", M.jump_next, keymap_opts)
    vim.keymap.set("n", "[[", M.jump_prev, keymap_opts)
    vim.keymap.set("n", "gd", M.goto_definition, keymap_opts)
    vim.keymap.set("n", "<leader>rp", function()
      local curl = require("poste.curl")
      curl.paste_curl("+")
    end, keymap_opts)
    vim.keymap.set("n", "<leader>rc", function()
      local copy = require("poste.copy")
      copy.copy_to_clipboard("+")
    end, keymap_opts)
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

  -- Already-open buffers
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("%.http$") or name:match("%.rest$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_http")
      setup_buffer_keymaps(buf)
    elseif name:match("%.redis$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_redis")
      setup_buffer_keymaps(buf)
    end
  end

  -- Status line integration
  _G.poste_status = function()
    return string.format("[env: %s]", state.current_env)
  end
end

return M
