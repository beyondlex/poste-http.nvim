--- Test assertions (> {% ... %} syntax): extraction, sandboxed execution, formatting.
local state = require("poste.state")

local M = {}

local md5 = require("poste.http.md5").md5

---------------------------------------------------------------------------
-- Extract assertion blocks from request content
---------------------------------------------------------------------------

--- Extract `> {% ... %}` assertion blocks from request content.
--- Always strips ALL assertion blocks (replacing with empty lines to preserve line count).
--- Only collects assertion code within the optional start_line/end_line range (1-indexed).
--- When start_line/end_line are nil, collects from all blocks.
--- Returns (stripped_content, assertion_code_or_nil).
function M.extract_assertion_blocks(content, start_line, end_line)
  local lines = vim.split(content, "\n", { plain = true })
  local result = {}
  local code_parts = {}
  local in_block = false
  local block_lines = {}
  local block_start_line = 0

  for i, line in ipairs(lines) do
    local trimmed = vim.trim(line)

    -- Single-line: > {% code %}
    if not in_block then
      local code = trimmed:match("^>%s*{%%(.-)%%}$")
      if code then
        -- Only collect code if within range (or no range specified)
        if not start_line or (i >= start_line and i <= end_line) then
          table.insert(code_parts, code)
        end
        table.insert(result, "")  -- preserve line count

      -- External assertion script: > ./path.lua or > ../path.lua
      elseif trimmed:match("^>%s*%.?%.") and trimmed:match("%.lua%s*$") then
        local path = trimmed:match("^>%s*(%S+)%s*$")
        if path and (not start_line or (i >= start_line and i <= end_line)) then
          -- Resolve relative path against .http file directory
          local file_dir = vim.fn.expand("%:p:h")
          if path:sub(1, 1) == "." then
            path = file_dir .. "/" .. path
          end
          -- Read external script file
          local f = io.open(path, "r")
          if f then
            local script_content = f:read("*a")
            f:close()
            table.insert(code_parts, "-- external: " .. path .. "\n" .. script_content)
            state.log("INFO", "Loaded external assertion script: " .. path)
          else
            state.log("ERROR", "Cannot open assertion script file: " .. path)
            table.insert(code_parts, 'error("Cannot open assertion script file: ' .. path .. '")')
          end
        end
        table.insert(result, "")  -- preserve line count

      elseif trimmed:match("^>%s*{%%") then
        -- Multi-line start: > {%
        in_block = true
        block_lines = {}
        block_start_line = i
        table.insert(result, "")  -- preserve line count
      else
        table.insert(result, line)
      end
    else
      -- Inside multi-line block
      if trimmed == "%}" then
        -- End of block
        if not start_line or (block_start_line >= start_line and i <= end_line) then
          table.insert(code_parts, table.concat(block_lines, "\n"))
        end
        in_block = false
        block_lines = {}
      else
        table.insert(block_lines, line)
      end
      table.insert(result, "")  -- preserve line count
    end
  end

  if #code_parts == 0 then
    return table.concat(result, "\n"), nil
  end

  return table.concat(result, "\n"), table.concat(code_parts, "\n")
end

---------------------------------------------------------------------------
-- Run assertions in a sandboxed environment
---------------------------------------------------------------------------

--- Run assertion code in a sandboxed environment.
--- @param response_data table  Parsed response from Rust CLI
--- @param code string  Assertion code to execute
--- @param script_vars table|nil  { variables = { name = value }, env = { key = value } }
--- Returns: { tests = [...], logs = [...], total = N, passed = N, failed = N }
function M.run_assertions(response_data, code, script_vars)
  local tests = {}
  local logs = {}
  local current_test = nil
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
            decoded_body = parsed
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
        state.log("INFO", string.format("Post-script: request.variables.set('%s', '%s')", name, tostring(value)))
      end,
      get = function(name)
        return state.script_variables[name]
      end,
    },
  }

  -- Build client object
  local client = {
    global = {
      set = function(name, value)
        state.global_vars[name] = tostring(value)
        state.log("INFO", string.format("Post-script: client.global.set('%s', '%s')", name, tostring(value)))
      end,
      get = function(name)
        return state.global_vars[name]
      end,
    },
    test = function(name, fn)
      current_test = { name = name, passed = 0, failed = 0, errors = {} }
      table.insert(tests, current_test)
      local ok, err = pcall(fn)
      if not ok then
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
  local sandbox_env = {
    response = response,
    request = request,
    client = client,
    assert = assert_fn,
    variables = script_vars.variables,
    env = script_vars.env,
    error = error,
    pcall = pcall,
    tostring = tostring,
    tonumber = tonumber,
    next = next,
    type = type,
    string = string,
    table = table,
    math = math,
    os = os,
    io = io,
    ipairs = ipairs,
    pairs = pairs,
    md5 = md5,
  }

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
    return {
      tests = tests,
      logs = logs,
      total = #tests,
      passed = 0,
      failed = #tests,
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
-- Format assertion results for display
---------------------------------------------------------------------------

function M.format_assertions(results)
  if not results then
    return { "No assertions defined" }
  end

  local lines = {
    string.format("## Test Results: %d passed, %d failed", results.passed, results.failed),
    "",
  }

  if results.error then
    table.insert(lines, "**Error**: " .. results.error)
    table.insert(lines, "")
  end

  for _, test in ipairs(results.tests) do
    local icon = (test.failed == 0 and #test.errors == 0) and "✓" or "✘"
    table.insert(lines, string.format("### %s %s", icon, test.name))

    if #test.errors > 0 then
      for _, err in ipairs(test.errors) do
        table.insert(lines, string.format("  ✘ %s", err))
      end
    end
  end

  if #results.logs > 0 then
    table.insert(lines, "")
    table.insert(lines, "## Logs")
    table.insert(lines, "")
    for _, msg in ipairs(results.logs) do
      for line in msg:gmatch("[^\r\n]+") do
        table.insert(lines, line)
      end
    end
  end

  return lines
end

return M
