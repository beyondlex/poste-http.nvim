--- Pre-request scripts (< {% ... %} syntax): extraction, sandboxed execution, variable injection.
--- Also handles external script references (< ./path.lua).
local state = require("poste.state")

local M = {}

---------------------------------------------------------------------------
-- Extract pre-request script blocks from request content
---------------------------------------------------------------------------

--- Extract `< {% ... %}` inline pre-script blocks and `< ./path.lua` external
--- script references from request content.
--- Always strips ALL matching blocks (replacing with empty lines to preserve line count).
--- Only collects script code within the optional start_line/end_line range (1-indexed).
--- When start_line/end_line are nil, collects from all blocks.
--- Returns (stripped_content, script_code_or_nil).
function M.extract_pre_script_blocks(content, start_line, end_line)
  local lines = vim.split(content, "\n", { plain = true })
  local result = {}
  local code_parts = {}
  local in_block = false
  local block_lines = {}
  local block_start_line = 0

  -- Determine the .http file directory for resolving external scripts
  local file_dir = vim.fn.expand("%:p:h")

  for i, line in ipairs(lines) do
    local trimmed = vim.trim(line)

    if not in_block then
      -- Single-line inline: < {% code %}
      local code = trimmed:match("^<%s*{%%(.-)%%}$")
      if code then
        if not start_line or (i >= start_line and i <= end_line) then
          table.insert(code_parts, code)
        end
        table.insert(result, "")  -- preserve line count

      -- External script: < ./path.lua or < ../path.lua
      elseif trimmed:match("^<%s*%.?%.") and trimmed:match("%.lua%s*$") then
        local path = trimmed:match("^<%s*(%S+)%s*$")
        if path and (not start_line or (i >= start_line and i <= end_line)) then
          -- Resolve relative path against .http file directory
          if path:sub(1, 1) == "." then
            path = file_dir .. "/" .. path
          end
          -- Read external script file
          local f = io.open(path, "r")
          if f then
            local script_content = f:read("*a")
            f:close()
            table.insert(code_parts, "-- external: " .. path .. "\n" .. script_content)
            state.log("INFO", "Loaded external pre-script: " .. path)
          else
            state.log("ERROR", "Cannot open pre-script file: " .. path)
            table.insert(code_parts, 'error("Cannot open pre-script file: ' .. path .. '")')
          end
        end
        table.insert(result, "")  -- preserve line count

      -- Multi-line start: < {%
      elseif trimmed:match("^<%s*{%%") then
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
-- Run pre-request script in a sandboxed environment
---------------------------------------------------------------------------

--- Run pre-request script code in a sandboxed environment.
--- Returns: { variables = {...}, logs = {...}, error = nil|string }
function M.run_pre_script(code)
  local variables = {}
  local logs = {}

  -- Build request object (no response available pre-request)
  local request = {
    variables = {
      set = function(name, value)
        variables[name] = tostring(value)
        state.log("INFO", string.format("Pre-script: request.variables.set('%s', '%s')", name, tostring(value)))
      end,
      get = function(name)
        return variables[name]
      end,
    },
  }

  -- Build client object (global only, no test/assert in pre-scripts)
  local client = {
    global = {
      set = function(name, value)
        state.global_vars[name] = tostring(value)
        state.log("INFO", string.format("Pre-script: client.global.set('%s', '%s')", name, tostring(value)))
      end,
      get = function(name)
        return state.global_vars[name]
      end,
    },
    log = function(msg)
      table.insert(logs, tostring(msg))
    end,
  }

  -- Build sandbox environment
  local env = {
    request = request,
    client = client,
    error = error,
    pcall = pcall,
    tostring = tostring,
    tonumber = tonumber,
    type = type,
    string = string,
    table = table,
    math = math,
    os = os,
    io = io,
    ipairs = ipairs,
    pairs = pairs,
  }

  -- Execute code in sandbox
  local fn, load_err = load(code, "pre_script", "t", env)
  if not fn then
    return {
      variables = {},
      logs = logs,
      error = "Pre-script syntax error: " .. tostring(load_err),
    }
  end

  local ok, run_err = pcall(fn)
  if not ok then
    return {
      variables = variables,
      logs = logs,
      error = "Pre-script runtime error: " .. tostring(run_err),
    }
  end

  return {
    variables = variables,
    logs = logs,
    error = nil,
  }
end

---------------------------------------------------------------------------
-- Inject pre-script variables into request content
---------------------------------------------------------------------------

--- Inject pre-script variables as @var = value lines after the ### header.
--- This ensures the Rust parser picks them up as request-scoped variables
--- with highest substitution priority.
--- Returns modified content (line count increases by number of variables).
function M.inject_pre_script_vars(content, block_start, variables)
  if not variables or not next(variables) then
    return content
  end

  local lines = vim.split(content, "\n", { plain = true })
  local result = {}

  for i, line in ipairs(lines) do
    table.insert(result, line)
    -- Insert variables right after the ### header line (block_start is 1-indexed)
    if i == block_start then
      for name, value in pairs(variables) do
        table.insert(result, string.format("@%s = %s", name, value))
      end
    end
  end

  return table.concat(result, "\n")
end

---------------------------------------------------------------------------
-- Format script logs for display
---------------------------------------------------------------------------

function M.format_script_logs(logs)
  if not logs or #logs == 0 then
    return { "No script output" }
  end

  local lines = {
    "## Script Output",
    "",
  }

  for _, msg in ipairs(logs) do
    table.insert(lines, msg)
  end

  return lines
end

return M
