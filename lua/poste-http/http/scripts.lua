--- Pre-request scripts (< {% ... %} syntax): extraction, sandboxed execution, variable injection.
--- Also handles external script references (< ./path.lua).
local state = require("poste-http.state")
local script_block = require("poste-http.http.script_block")
local script_sandbox = require("poste-http.http.script_sandbox")
local vars = require("poste-http.http.vars")

local M = {}

---------------------------------------------------------------------------
-- Variable and env collection for sandbox injection
---------------------------------------------------------------------------

--- Resolve {{var}} references iteratively within collected vars.
--- Same reference grammar as vars.lua: {{([^}]+)}} — names may start with
--- `_` or contain dashes, not just %w.
local function resolve_var_refs(vars_table)
  for _ = 1, 20 do
    local changed = false
    for k, v in pairs(vars_table) do
      local resolved = v:gsub("{{([^}]+)}}", function(ref)
        if vars_table[ref] ~= nil then
          changed = true
          return vars_table[ref]
        end
        return "{{" .. ref .. "}}"
      end)
      if resolved ~= v then
        vars_table[k] = resolved
        changed = true
      end
    end
    if not changed then break end
  end
  return vars_table
end

--- Find and read env.json, returning the current env's variables.
--- @param env_name string|nil  Current env name (nil = use state.current_env)
--- @param file_dir string|nil  Directory of the .http file being executed
---                             (nil = derive from current buffer)
--- @return table  { key = value, ... }
local function read_env_vars(env_name, file_dir)
  env_name = env_name or state.current_env
  if not env_name then return {} end

  local dir = file_dir
  if not dir or dir == "" then
    local bufname = vim.api.nvim_buf_get_name(0)
    if bufname == "" then return {} end
    dir = vim.fn.fnamemodify(bufname, ":h")
  end

  while dir and dir ~= "" and dir ~= "/" do
    local candidate = vim.fs.joinpath(dir, "env.json")
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

--- Collect all script-available variables: file-level vars, block-level vars,
--- and env vars. Block-level vars override file-level vars.
--- @param content string     Full buffer content
--- @param block_start number|nil  Start line of block (1-indexed)
--- @param block_end number|nil    End line of block
--- @param file_dir string|nil  Directory of the .http file being executed
---                             (nil = derive env.json location from current buffer)
--- Returns { variables = { name = value, ... }, env = { key = value, ... } }
function M.collect_script_variables(content, block_start, block_end, file_dir)
  local lines = vim.split(content, "\n", { plain = true })
  local file_vars = vars.collect_file_vars(lines)
  local block_vars = block_start and vars.collect_block_vars(lines, block_start, block_end) or {}

  local variables = {}
  for k, v in pairs(file_vars) do
    variables[k] = v
  end
  for k, v in pairs(block_vars) do
    variables[k] = v
  end

  resolve_var_refs(variables)

  local env = read_env_vars(nil, file_dir)

  return { variables = variables, env = env }
end

---------------------------------------------------------------------------
-- Extract pre-request script blocks from request content
---------------------------------------------------------------------------

--- Extract `< {% ... %}` inline pre-script blocks and `< ./path.lua` external
--- script references from request content.
--- @param content string  Full buffer content
--- @param start_line integer|nil  1-indexed lower bound (inclusive)
--- @param end_line integer|nil    1-indexed upper bound (inclusive)
--- @param file_dir string|nil     Directory of the .http file (for external script resolution)
--- @return string stripped_content
--- @return string|nil script_code
function M.extract_pre_script_blocks(content, start_line, end_line, file_dir)
  return script_block.extract_script_blocks(content, "<", start_line, end_line, file_dir)
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
        local stored = script_sandbox.coerce_set_value("Pre-script: request.variables.set", name, value)
        if stored == nil then return end
        variables[name] = stored
        local ctx = state._exec_context
        local line = ctx and ctx.set_lines and ctx.set_lines[name] or (ctx and ctx.line)
        if line then
          state.script_variables_sources[name] = { file = ctx.file, line = line }
        end
        -- The stored VALUE never reaches the log: script variables are where
        -- tokens land (client.global.set('token', ...)), and the log file is
        -- a sync/screenshot leak surface. Name + length stay for debugging.
        state.log("INFO", string.format("Pre-script: request.variables.set('%s', [REDACTED len=%d])", name, #stored))
      end,
      get = function(name)
        return variables[name]
      end,
    },
  }

  local client = {
    global = {
      set = function(name, value)
        local stored = script_sandbox.coerce_set_value("Pre-script: client.global.set", name, value)
        if stored == nil then return end
        local ctx = state._exec_context
        local line = ctx and ctx.set_lines and ctx.set_lines[name] or (ctx and ctx.line)
        state.set_global_var(name, stored)
        if line then
          state.global_vars_sources[name] = { file = ctx.file, line = line }
        end
        -- The stored VALUE never reaches the log: script variables are where
        -- tokens land (client.global.set('token', ...)), and the log file is
        -- a sync/screenshot leak surface. Name + length stay for debugging.
        state.log("INFO", string.format("Pre-script: client.global.set('%s', [REDACTED len=%d])", name, #stored))
      end,
      get = function(name)
        return state.global_vars[name]
      end,
      header = {
        set = function(name, value)
          local stored = script_sandbox.coerce_set_value("Pre-script: client.global.header.set", name, value)
          if stored == nil then return end
          local ctx = state._exec_context
          local line = ctx and ctx.line
          state.set_global_header(name, stored)
          if line then
            state.global_headers_sources[name] = { file = ctx.file, line = line }
          end
          -- The stored VALUE never reaches the log: script variables are where
        -- tokens land (client.global.set('token', ...)), and the log file is
        -- a sync/screenshot leak surface. Name + length stay for debugging.
        state.log("INFO", string.format("Pre-script: client.global.header.set('%s', [REDACTED len=%d])", name, #stored))
        end,
        get = function(name)
          return state.global_headers[name]
        end,
        remove = function(name)
          local ctx = state._exec_context
          local _ = ctx and ctx.line
          state.remove_global_header(name)
          state.log("INFO", string.format("Pre-script: client.global.header.remove('%s')", name))
        end,
        clear = function()
          state.clear_global_headers()
          state.log("INFO", "Pre-script: client.global.header.clear()")
        end,
      },
    },
    log = function(msg)
      table.insert(logs, tostring(msg))
    end,
  }

  -- Build sandbox environment
  local sandbox_env = script_sandbox.build_sandbox_env({
    request = request,
    client = client,
    variables = script_vars.variables,
    env = script_vars.env,
  })

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

--- Serialize one injected value as @var syntax that parses back to the same
--- string. Single-line values use the plain form; a value with embedded
--- newlines (client.global.set of a multi-line body, a heredoc file var
--- copied through a script) MUST use the grammar's >>>/<<< multiline form —
--- the old `@name = value` string.format left the value's second line as a
--- bare request line (silently corrupting the request) and made the caller's
--- "one line per variable" line accounting under-count.
--- A value of exactly ">>>" would re-parse as the multiline opener, so it is
--- quote-wrapped (the quoted form strips its quotes back off on parse).
local function serialize_var_line(name, value)
  if type(value) ~= "string" then
    value = tostring(value)
  end
  if value:find("\n", 1, true) then
    return { string.format("@%s = >>>", name), value, "<<<" }
  end
  if value:match("^>>>%s*$") then
    return { string.format('@%s = "%s"', name, value) }
  end
  return { string.format("@%s = %s", name, value) }
end

--- Physical buffer lines a serialized entry occupies (an entry may carry
--- embedded newlines — the heredoc value does — and block_end/line
--- bookkeeping must advance by physical lines, not entries).
local function physical_lines(s)
  return select(2, s:gsub("\n", "")) + 1
end

--- Inject pre-script variables as @var = value lines after the ### header.
--- This ensures the tree-sitter parser picks them up as request-scoped variables
--- with highest substitution priority.
--- Returns modified content and the number of lines actually inserted —
--- multi-line values occupy three lines (>>>/value/<<<), so callers must use
--- the returned count for block_end/line bookkeeping, never pairs(variables).
--- @return string, number
function M.inject_pre_script_vars(content, block_start, variables)
  if not variables or not next(variables) then
    return content, 0
  end

  local lines = vim.split(content, "\n", { plain = true })
  local result = {}
  local injected = 0

  for i, line in ipairs(lines) do
    table.insert(result, line)
    -- Insert variables right after the ### header line (block_start is 1-indexed)
    if i == block_start then
      for name, value in pairs(variables) do
        for _, serialized_line in ipairs(serialize_var_line(name, value)) do
          table.insert(result, serialized_line)
          injected = injected + physical_lines(serialized_line)
        end
      end
    end
  end

  return table.concat(result, "\n"), injected
end

---------------------------------------------------------------------------
-- Inject global variables into content
---------------------------------------------------------------------------

--- Inject global variables as @var = value lines after the given line.
--- Mirrors inject_pre_script_vars but for client.global.set() values.
--- @param content string
--- @param block_start number  1-indexed line to inject after
--- @param global_vars table  { name = value, ... }
--- @return string, number  modified content, lines actually injected
function M.inject_global_vars(content, block_start, global_vars)
  if not block_start or not global_vars or not next(global_vars) then
    return content, 0
  end

  local lines = vim.split(content, "\n", { plain = true })
  local result = {}
  local count = 0

  for i, line in ipairs(lines) do
    table.insert(result, line)
    if i == block_start then
      for name, value in pairs(global_vars) do
        for _, serialized_line in ipairs(serialize_var_line(name, value)) do
          table.insert(result, serialized_line)
          count = count + physical_lines(serialized_line)
        end
      end
    end
  end

  return table.concat(result, "\n"), count
end

---------------------------------------------------------------------------
-- Scan script set calls
---------------------------------------------------------------------------

--- Scan buf_lines in [block_start, block_end] for client.global.set() and
--- request.variables.set() calls and return a map of name -> line.
function M.scan_script_set_calls(buf_lines, block_start, block_end)
  local map = {}
  for i = block_start or 1, block_end or #buf_lines do
    local line = buf_lines[i]
    if line then
      local name = line:match('client%.global%.set%s*%(%s*"([^"]+)"')
      if not name then
        name = line:match("client%.global%.set%s*%(%s*'([^']+)'")
      end
      if not name then
        name = line:match('request%.variables%.set%s*%(%s*"([^"]+)"')
      end
      if not name then
        name = line:match("request%.variables%.set%s*%(%s*'([^']+)'")
      end
      if not name then
        name = line:match('client%.global%.header%.set%s*%(%s*"([^"]+)"')
      end
      if not name then
        name = line:match("client%.global%.header%.set%s*%(%s*'([^']+)'")
      end
      if name then
        map[name] = i
      end
    end
  end
  return map
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
