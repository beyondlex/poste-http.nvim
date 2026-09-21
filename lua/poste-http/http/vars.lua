local M = {}
local state = require("poste-http.state")
local util = require("poste-http.util")

local VarResolver = {}
VarResolver.__index = VarResolver

function VarResolver.new()
  return setmetatable({
    import_params = {},
    request_vars = {},
    file_vars = {},
    session_vars = {},
    script_vars = {},
    env = {},
  }, VarResolver)
end

function VarResolver:resolve(name)
  return self.import_params[name]
      or self.request_vars[name]
      or self.file_vars[name]
      or self.session_vars[name]
      or self.script_vars[name]
      or self.env[name]
      or self:_resolve_magic(name)
end

function VarResolver:_resolve_magic(name)
  util.seed_random() -- first random draw must not repeat across sessions
  if name == "$timestamp" then
    return tostring(os.time()) .. math.random(100000, 999999)
  elseif name == "$uuid" then
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return template:gsub("[xy]", function(c)
      local r = math.random(0, 15)
      local v = c == "x" and r or (r % 4) + 8
      return string.format("%x", v)
    end)
  elseif name == "$date" then
    return os.date("%Y-%m-%d")
  elseif name == "$randomInt" then
    return tostring(math.random(0, 9999999))
  end
  return nil
end

local function value_to_string(v)
  local t = type(v)
  if t == "string" then
    return v
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  elseif t == "table" and v ~= vim.NIL then
    local ok, encoded = pcall(vim.json.encode, v)
    if ok then return encoded end
    return tostring(v)
  end
  return ""
end

function VarResolver:substitute(input)
  local result = input
  for _ = 1, 20 do
    -- `next_result`, not `next` — a local named `next` shadows the global.
    local next_result = result:gsub("{{([^}]+)}}", function(var_name)
      local v = self:resolve(var_name)
      if v ~= nil then return value_to_string(v) end
      return "{{" .. var_name .. "}}"
    end)
    if next_result == result then break end
    result = next_result
  end
  return result
end

function M.new()
  return VarResolver.new()
end

function M.resolve_var(var_name, resolver)
  return resolver:resolve(var_name)
end

function M.substitute_vars(content, resolver)
  return resolver:substitute(content)
end

function M.collect_var_defs(lines, start_idx, end_idx)
  local vars = {}
  end_idx = end_idx or #lines
  local i = start_idx or 1
  while i <= end_idx do
    local line = lines[i]
    if not line then break end
    local trimmed = vim.trim(line)
    if trimmed:sub(1, 1) == "@" then
      local name, value = trimmed:match("^@(%S+)%s*=%s*(.+)")
      if not name then
        name, value = trimmed:match("^@(%S+)%s+(.+)")
      end
      if name and value then
        if value:match("^>>>%s*$") then
          local multiline = {}
          i = i + 1
          while i <= end_idx do
            local ml = lines[i]
            if not ml then break end
            if vim.trim(ml):match("^<<<%s*$") then
              break
            end
            table.insert(multiline, ml)
            i = i + 1
          end
          value = table.concat(multiline, "\n")
        else
          value = value:match("^'(.-)'$") or value:match('^"(.-)"$') or value
        end
        vars[name] = value
      end
    end
    i = i + 1
  end
  return vars
end

function M.collect_var_defs_with_lines(lines, start_idx, end_idx)
  local vars = {}
  end_idx = end_idx or #lines
  local i = start_idx or 1
  while i <= end_idx do
    local line = lines[i]
    if not line then break end
    local line_num = i
    local trimmed = vim.trim(line)
    if trimmed:sub(1, 1) == "@" then
      local name, value = trimmed:match("^@(%S+)%s*=%s*(.+)")
      if not name then
        name, value = trimmed:match("^@(%S+)%s+(.+)")
      end
      if name and value then
        if value:match("^>>>%s*$") then
          local multiline = {}
          i = i + 1
          while i <= end_idx do
            local ml = lines[i]
            if not ml then break end
            if vim.trim(ml):match("^<<<%s*$") then
              break
            end
            table.insert(multiline, ml)
            i = i + 1
          end
          value = table.concat(multiline, "\n")
        else
          value = value:match("^'(.-)'$") or value:match('^"(.-)"$') or value
        end
        vars[name] = { value = value, line = line_num }
      end
    end
    i = i + 1
  end
  return vars
end

function M.collect_file_vars(lines)
  local first_block_line = nil
  for i, line in ipairs(lines) do
    if line:match("^%s*###") then
      first_block_line = i
      break
    end
  end
  if not first_block_line then
    return M.collect_var_defs(lines, 1, #lines)
  end
  return M.collect_var_defs(lines, 1, first_block_line - 1)
end

function M.collect_block_vars(lines, block_start, block_end)
  return M.collect_var_defs(lines, block_start, block_end)
end

function M.load_env_vars(file_path, env_name)
  if not file_path or file_path == "" then return {} end
  if not env_name or env_name == "" then return {} end
  local dir = vim.fn.fnamemodify(file_path, ":h")
  local seen = {}
  while true do
    local candidate = vim.fs.joinpath(dir, "env.json")
    if not seen[dir] and vim.fn.filereadable(candidate) == 1 then
      seen[dir] = true
      local f = io.open(candidate, "r")
      if f then
        local content = f:read("*a")
        f:close()
        local ok, data = pcall(vim.json.decode, content)
        if ok and type(data) == "table" then
          return data[env_name] or {}
        end
      end
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return {}
end

-- Net { minus } on one line, counting only braces OUTSIDE JSON string
-- literals. A value like "pattern": "{" is legal JSON but used to shift the
-- section boundary, leaking the next env section's keys into this one.
local function brace_delta_outside_strings(s)
  local depth, in_str, i = 0, false, 1
  while i <= #s do
    local c = s:sub(i, i)
    if in_str then
      if c == "\\" then
        i = i + 1 -- skip the escaped char
      elseif c == '"' then
        in_str = false
      end
    elseif c == '"' then
      in_str = true
    elseif c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
    end
    i = i + 1
  end
  return depth
end

function M.load_env_vars_with_lines(file_path, env_name)
  local result = {}
  if not file_path or file_path == "" then return result end
  if not env_name or env_name == "" then return result end
  local dir = vim.fn.fnamemodify(file_path, ":h")
  local seen = {}
  local env_path = nil
  while true do
    local candidate = vim.fs.joinpath(dir, "env.json")
    if not seen[dir] and vim.fn.filereadable(candidate) == 1 then
      env_path = candidate
      break
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  if not env_path then return result end

  local lines = {}
  local f = io.open(env_path, "r")
  if not f then return result end
  for line in f:lines() do
    table.insert(lines, line)
  end
  f:close()

  local in_section = false
  local brace_depth = 0
  for i, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if not in_section then
      if trimmed:match('^"' .. vim.pesc(env_name) .. '"%s*:') then
        in_section = true
        brace_depth = brace_depth + brace_delta_outside_strings(trimmed)
      end
    else
      local key = trimmed:match('^"([^"]+)"%s*:')
      if key then
        local value = trimmed:match('^"[^"]+"%s*:%s*(.+)')
        if value then
          value = value:gsub(",%s*$", "")
          value = value:match("^%s*'(.-)'%s*$") or value:match('^%s*"(.-)"%s*$') or value:match("^%s*(%S.-)%s*$") or value
          result[key] = { value = value, line = i }
        end
      end
      brace_depth = brace_depth + brace_delta_outside_strings(trimmed)
      if brace_depth <= 0 then
        break
      end
    end
  end
  return result
end

function M.build_resolver_from_state(opts)
  opts = opts or {}
  local resolver = VarResolver.new()

  local lines = opts.lines
  if not lines and opts.buf then
    lines = vim.api.nvim_buf_get_lines(opts.buf, 0, -1, false)
  end
  if not lines then
    lines = {}
  end

  local file_path = opts.file_path
  if not file_path and opts.buf then
    file_path = vim.api.nvim_buf_get_name(opts.buf)
  end

  resolver.file_vars = M.collect_file_vars(lines)
  for name, value in pairs(resolver.file_vars) do
    resolver.file_vars[name] = resolver:substitute(value)
  end

  if opts.block_start and opts.block_end then
    resolver.request_vars = M.collect_block_vars(lines, opts.block_start, opts.block_end)
    for name, value in pairs(resolver.request_vars) do
      resolver.request_vars[name] = resolver:substitute(value)
    end
  end

  if file_path and file_path ~= "" then
    local env_name = opts.env_name or state.current_env
    resolver.env = M.load_env_vars(file_path, env_name)
  end

  if state.global_vars then
    resolver.session_vars = vim.deepcopy(state.global_vars)
  end

  if state.script_variables then
    resolver.script_vars = vim.deepcopy(state.script_variables)
  end

  if opts.import_params then
    resolver.import_params = vim.deepcopy(opts.import_params)
  end

  return resolver
end

return M