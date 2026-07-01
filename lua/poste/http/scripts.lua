--- Pre-request scripts (< {% ... %} syntax): extraction, sandboxed execution, variable injection.
--- Also handles external script references (< ./path.lua).
local state = require("poste.state")

local M = {}

local md5 = require("poste.http.md5").md5

---------------------------------------------------------------------------
-- Variable and env collection for sandbox injection
---------------------------------------------------------------------------

--- Parse @var definitions from content (file-level and block-level).
--- Resolves {{var}} references iteratively within collected vars.
--- Returns a table of { varname = value }
local function parse_vars_from_content(content)
  local vars = {}
  local lines = vim.split(content, "\n", { plain = true })
  for _, line in ipairs(lines) do
    -- Stop at first request block (file-level vars only)
    if line:match("^%s*###") then break end
    local name, value = line:match("^%s*@(%w[%w_]*)%s*=%s*(.+)%s*$")
    if not name then
      name, value = line:match("^%s*@(%w[%w_]*)%s+(%S+)%s*$")
    end
    if name then
      value = vim.trim(value)
      vars[name] = value
    end
  end

  -- Resolve {{var}} references iteratively
  for _ = 1, 20 do
    local changed = false
    for k, v in pairs(vars) do
      local resolved = v:gsub("{{(%w[%w_]*)}}", function(ref)
        if vars[ref] ~= nil then
          changed = true
          return vars[ref]
        end
        return "{{" .. ref .. "}}"
      end)
      if resolved ~= v then
        vars[k] = resolved
        changed = true
      end
    end
    if not changed then break end
  end

  return vars
end

--- Find and read env.json, returning the current env's variables.
--- @param env_name string|nil  Current env name (nil = use state.current_env)
--- @return table  { key = value, ... }
local function read_env_vars(env_name)
  env_name = env_name or state.current_env
  if not env_name then return {} end

  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then return {} end

  local dir = vim.fn.fnamemodify(bufname, ":h")
  while dir and dir ~= "" and dir ~= "/" do
    local candidate = dir .. "/env.json"
    local f = io.open(candidate, "r")
    if f then
      local content = f:read("*a")
      f:close()
      local ok, data = pcall(vim.json.decode, content)
      if ok and type(data) == "table" and data[env_name] then
        return data[env_name]
      end
      return {}
    end
    dir = vim.fn.fnamemodify(dir, ":h")
  end

  return {}
end

--- Collect block-level @var definitions from a specific request block.
--- @param content string  Full buffer content
--- @param block_start number  1-indexed start line of block
--- @param block_end number    1-indexed end line of block
--- @return table  { varname = value }
local function collect_block_vars(content, block_start, block_end)
  local lines = vim.split(content, "\n", { plain = true })
  local vars = {}
  for i = block_start, block_end do
    local line = lines[i] or ""
    local name, value = line:match("^%s*@(%w[%w_]*)%s*=%s*(.+)%s*$")
    if not name then
      name, value = line:match("^%s*@(%w[%w_]*)%s+(%S+)%s*$")
    end
    if name then
      value = vim.trim(value)
      vars[name] = value
    end
  end
  return vars
end

--- Collect all script-available variables: file-level vars, block-level vars,
--- and env vars. Block-level vars override file-level vars.
--- Returns { variables = { name = value, ... }, env = { key = value, ... } }
function M.collect_script_variables(content, block_start, block_end)
  local file_vars = parse_vars_from_content(content)
  local block_vars = collect_block_vars(content, block_start, block_end)

  local variables = {}
  for k, v in pairs(file_vars) do
    variables[k] = v
  end
  for k, v in pairs(block_vars) do
    variables[k] = v
  end

  local env = read_env_vars()

  return { variables = variables, env = env }
end

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
--- @param code string  Script code to execute
--- @param script_vars table|nil  { variables = { name = value }, env = { key = value } }
--- Returns: { variables = {...}, logs = {...}, error = nil|string }
function M.run_pre_script(code, script_vars)
  local variables = {}
  local logs = {}

  script_vars = script_vars or { variables = {}, env = {} }

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
  local sandbox_env = {
    request = request,
    client = client,
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
  local fn, load_err = load(code, "pre_script", "t", sandbox_env)
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
    for line in msg:gmatch("[^\r\n]+") do
      table.insert(lines, line)
    end
  end

  return lines
end

return M
