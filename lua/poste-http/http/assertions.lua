--- Test assertions (> {% ... %} syntax): extraction, sandboxed execution, formatting.
local state = require("poste-http.state")
local util = require("poste-http.util")
local script_block = require("poste-http.http.script_block")
local script_sandbox = require("poste-http.http.script_sandbox")

local M = {}

---------------------------------------------------------------------------
-- Extract assertion blocks from request content
---------------------------------------------------------------------------

--- Extract `> {% ... %}` assertion blocks from request content.
--- @param content string  Full buffer content
--- @param start_line integer|nil  1-indexed lower bound (inclusive)
--- @param end_line integer|nil    1-indexed upper bound (inclusive)
--- @param file_dir string|nil     Directory of the .http file (for external script resolution)
--- @return string stripped_content
--- @return string|nil script_code
function M.extract_assertion_blocks(content, start_line, end_line, file_dir)
  return script_block.extract_script_blocks(content, ">", start_line, end_line, file_dir)
end

---------------------------------------------------------------------------
-- Run assertions in a sandboxed environment
---------------------------------------------------------------------------

--- Run assertion code in a sandboxed environment.
--- @param response_data table  Parsed response data
--- @param code string  Assertion code to execute
--- @param script_vars table|nil  { variables = { name = value }, env = { key = value } }
--- Returns: { tests = [...], logs = [...], total = N, passed = N, failed = N }
function M.run_assertions(response_data, code, script_vars)
  local tests = {}
  local logs = {}
  local current_test = nil
  -- Set when client.assert records a failure and raises, so client.test's
  -- pcall doesn't record the same failure twice.
  local assertion_raised = false
  script_vars = script_vars or { variables = {}, env = {} }

  -- Build case-insensitive headers table
  local headers = {}
  if response_data.headers then
    for _, pair in ipairs(response_data.headers) do
      if pair[1] then
        headers[pair[1]:lower()] = pair[2]
      end
    end
  end

  -- Build response object with lazy JSON body decoding
  local raw_body = response_data.body
  local decoded_body = nil
  local response = setmetatable({
    status = response_data.status,
    headers = setmetatable(headers, {
      __index = function(t, k)
        return rawget(t, k:lower())
      end,
    }),
    latency_ms = response_data.latency_ms,
    content_type = response_data.content_type,
    url = response_data.url,
  }, {
    __index = function(t, k)
      if k == "body" then
        if decoded_body == nil then
          local ok, parsed = pcall(vim.json.decode, raw_body)
          if ok and parsed then
            decoded_body = util.json_to_table(parsed)
          else
            decoded_body = raw_body
          end
        end
        return decoded_body
      end
      return rawget(t, k)
    end,
  })

  -- Build request object (for post-request scripting within assertion blocks)
  local request = {
    variables = {
      set = function(name, value)
        state.script_variables[name] = tostring(value)
        local ctx = state._exec_context
        local line = ctx and ctx.set_lines and ctx.set_lines[name] or (ctx and ctx.line)
        if line then
          state.script_variables_sources[name] = { file = ctx.file, line = line }
        end
        state.log("INFO", string.format("Post-script: request.variables.set('%s', '%s')", name, tostring(value)))
      end,
      get = function(name)
        return state.script_variables[name]
      end,
    },
  }

  local client = {
    global = {
      set = function(name, value)
        local ctx = state._exec_context
        local line = ctx and ctx.set_lines and ctx.set_lines[name] or (ctx and ctx.line)
        state.set_global_var(name, tostring(value))
        if line then
          state.global_vars_sources[name] = { file = ctx.file, line = line }
        end
        state.log("INFO", string.format("Post-script: client.global.set('%s', '%s')", name, tostring(value)))
      end,
      get = function(name)
        return state.global_vars[name]
      end,
      header = {
        set = function(name, value)
          local ctx = state._exec_context
          local line = ctx and ctx.line
          state.set_global_header(name, tostring(value))
          if line then
            state.global_headers_sources[name] = { file = ctx.file, line = line }
          end
          state.log("INFO", string.format("Post-script: client.global.header.set('%s', '%s')", name, tostring(value)))
        end,
        get = function(name)
          return state.global_headers[name]
        end,
        remove = function(name)
          state.remove_global_header(name)
          state.log("INFO", string.format("Post-script: client.global.header.remove('%s')", name))
        end,
        clear = function()
          state.clear_global_headers()
          state.log("INFO", "Post-script: client.global.header.clear()")
        end,
      },
    },
    test = function(name, fn)
      current_test = { name = name, passed = 0, failed = 0, errors = {} }
      table.insert(tests, current_test)
      assertion_raised = false
      local ok, err = pcall(fn)
      if not ok and not assertion_raised then
        -- client.assert already recorded its own failure before raising;
        -- only unexpected errors are recorded here.
        table.insert(current_test.errors, tostring(err))
        current_test.failed = current_test.failed + 1
      end
      current_test = nil
    end,
    assert = function(cond, msg)
      if not cond then
        local err_msg = msg or "Assertion failed"
        if current_test then
          table.insert(current_test.errors, err_msg)
          current_test.failed = current_test.failed + 1
        end
        assertion_raised = true
        error(err_msg, 2)
      else
        if current_test then
          current_test.passed = current_test.passed + 1
        end
      end
    end,
    log = function(msg)
      table.insert(logs, tostring(msg))
    end,
  }

  -- Top-level assert shorthand (outside client.test)
  local assert_fn = function(cond, msg)
    if not cond then
      local err_msg = msg or "Assertion failed"
      error(err_msg, 2)
    end
  end

  -- Build sandbox environment
  local sandbox_env = script_sandbox.build_sandbox_env({
    request = request,
    client = client,
    response = response,
    assert = assert_fn,
    variables = script_vars.variables,
    env = script_vars.env,
  })

  -- Execute code in sandbox
  local fn, load_err = load(code, "assertions", "t", sandbox_env)
  if not fn then
    return {
      tests = {},
      logs = {},
      total = 1,
      passed = 0,
      failed = 1,
      error = "Syntax error: " .. tostring(load_err),
    }
  end

  local ok, run_err = pcall(fn)
  if not ok then
    -- Summarize from the tests that already ran; hardcoding passed=0 would
    -- report passing tests as failed.
    local error_passed, error_failed = 0, 0
    for _, test in ipairs(tests) do
      if test.failed == 0 and #test.errors == 0 then
        error_passed = error_passed + 1
      else
        error_failed = error_failed + 1
      end
    end
    return {
      tests = tests,
      logs = logs,
      total = #tests,
      passed = error_passed,
      failed = error_failed,
      error = "Runtime error: " .. tostring(run_err),
    }
  end

  -- Count totals
  local total_passed = 0
  local total_failed = 0
  for _, test in ipairs(tests) do
    if test.failed == 0 and #test.errors == 0 then
      total_passed = total_passed + 1
    else
      total_failed = total_failed + 1
    end
  end

  return {
    tests = tests,
    logs = logs,
    total = #tests,
    passed = total_passed,
    failed = total_failed,
  }
end

---------------------------------------------------------------------------
-- Assertions highlight namespace
---------------------------------------------------------------------------

local assertions_ns = vim.api.nvim_create_namespace("poste_assertions")

--- Apply extmark-based highlights to the assertions response buffer.
function M.apply_highlights(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, assertions_ns, 0, -1)

  for i, line in ipairs(lines) do
    local row = i - 1
    local matched = false

    -- Summary line: "▸ Test Results: N passed, M failed"
    if not matched then
      local summary_passed, summary_failed = line:match("^▸ Test Results: (%d+) passed, (%d+) failed")
      if summary_passed then
        local hl = tonumber(summary_failed) > 0 and "PosteAssertSummaryFail" or "PosteAssertSummary"
        vim.api.nvim_buf_set_extmark(buf, assertions_ns, row, 0, {
          end_row = row, end_col = #line,
          hl_group = hl, priority = 100,
        })
        matched = true
      end
    end

    -- Error line: "  ✘ Syntax/Runtime error" (top-level) or "    ✘ <msg>" (indented under test)
    if not matched then
      if line:match("^  ✘ Syntax error:") or line:match("^  ✘ Runtime error:") or line:match("^    ✘ ") then
        vim.api.nvim_buf_set_extmark(buf, assertions_ns, row, 0, {
          end_row = row, end_col = #line,
          hl_group = "PosteAssertError", priority = 100,
        })
        matched = true
      end
    end

    -- Hint line (no assertions)
    if not matched then
      if line:match("^  ⓘ ") then
        vim.api.nvim_buf_set_extmark(buf, assertions_ns, row, 0, {
          end_row = row, end_col = #line,
          hl_group = "PosteAssertHint", priority = 100,
        })
        matched = true
      end
    end

    -- Test passed: "  ✓ test name"
    if not matched then
      local pass_name = line:match("^  ✓ (.+)$")
      if pass_name then
        vim.api.nvim_buf_set_extmark(buf, assertions_ns, row, 0, {
          end_row = row, end_col = 3,
          hl_group = "PosteAssertIconPass", priority = 100,
        })
        vim.api.nvim_buf_set_extmark(buf, assertions_ns, row, 4, {
          end_row = row, end_col = #line,
          hl_group = "PosteAssertPass", priority = 100,
        })
        matched = true
      end
    end

    -- Test failed: "  ✘ test name"
    if not matched then
      local fail_name = line:match("^  ✘ (.+)$")
      if fail_name then
        vim.api.nvim_buf_set_extmark(buf, assertions_ns, row, 0, {
          end_row = row, end_col = 3,
          hl_group = "PosteAssertIconFail", priority = 100,
        })
        vim.api.nvim_buf_set_extmark(buf, assertions_ns, row, 4, {
          end_row = row, end_col = #line,
          hl_group = "PosteAssertFail", priority = 100,
        })
        matched = true
      end
    end

    -- Separator line: "──"
    if not matched then
      if line:match("^──") then
        vim.api.nvim_buf_set_extmark(buf, assertions_ns, row, 0, {
          end_row = row, end_col = #line,
          hl_group = "PosteAssertSep", priority = 100,
        })
        matched = true
      end
    end

    -- "╰ Logs" section header
    if not matched then
      local log_header = line:match("^╰ (.+)$")
      if log_header then
        vim.api.nvim_buf_set_extmark(buf, assertions_ns, row, 0, {
          end_row = row, end_col = #line,
          hl_group = "PosteAssertLogHeader", priority = 100,
        })
        matched = true
      end
    end

    -- Log content: indented under Logs section
    if not matched then
      if line:match("^    ") and line:match("%S") then
        vim.api.nvim_buf_set_extmark(buf, assertions_ns, row, 0, {
          end_row = row, end_col = #line,
          hl_group = "PosteAssertLog", priority = 100,
        })
      end
    end
  end
end

---------------------------------------------------------------------------
-- Format assertion results for display
---------------------------------------------------------------------------

function M.format_assertions(results)
  if not results then
    return { "  ⓘ No assertions defined — add `> {% client.test(...) %}` blocks" }
  end

  local lines = {}
  local all_passed = results.failed == 0 and #results.tests > 0
  local status_icon = all_passed and "✓" or "✘"

  -- Summary bar
  table.insert(lines, string.format("▸ Test Results: %d passed, %d failed  %s",
    results.passed, results.failed, status_icon))
  table.insert(lines, "──")

  -- Runtime error (syntax or execution failure)
  if results.error then
    table.insert(lines, "")
    table.insert(lines, "  ✘ " .. results.error)
    table.insert(lines, "")
  end

  -- No tests but no error either
  if #results.tests == 0 and not results.error then
    table.insert(lines, "  ⓘ No test assertions executed")
  end

  -- Test results
  for _, test in ipairs(results.tests) do
    local passed = test.failed == 0 and #test.errors == 0
    local icon = passed and "✓" or "✘"
    table.insert(lines, string.format("  %s %s", icon, test.name))

    if not passed then
      for _, err in ipairs(test.errors) do
        table.insert(lines, string.format("    ✘ %s", err))
      end
    end
  end

  -- Logs section
  if #results.logs > 0 then
    table.insert(lines, "")
    table.insert(lines, "╰ Logs")
    for _, msg in ipairs(results.logs) do
      for line in msg:gmatch("[^\r\n]+") do
        table.insert(lines, "    " .. line)
      end
    end
  end

  return lines
end

return M
