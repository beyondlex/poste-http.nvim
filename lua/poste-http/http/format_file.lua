local M = {}

local function json_pretty(value, indent)
  indent = indent or 0
  local indent_str = string.rep("  ", indent)
  local indent_str_inner = string.rep("  ", indent + 1)
  if type(value) == "table" then
    local is_array = true
    local max_idx = 0
    for k in pairs(value) do
      if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
        is_array = false
        break
      end
      max_idx = math.max(max_idx, k)
    end
    is_array = is_array and max_idx == #value
    if is_array then
      if #value == 0 then return "[]" end
      local items = {}
      for _, v in ipairs(value) do
        table.insert(items, indent_str_inner .. json_pretty(v, indent + 1))
      end
      return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent_str .. "]"
    else
      local keys = {}
      for k in pairs(value) do table.insert(keys, k) end
      table.sort(keys)
      if #keys == 0 then return "{}" end
      local items = {}
      for _, k in ipairs(keys) do
        local v = value[k]
        table.insert(items, indent_str_inner .. '"' .. k .. '": ' .. json_pretty(v, indent + 1))
      end
      return "{\n" .. table.concat(items, ",\n") .. "\n" .. indent_str .. "}"
    end
  elseif type(value) == "string" then
    return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
  elseif type(value) == "number" then
    return tostring(value)
  elseif type(value) == "boolean" then
    return value and "true" or "false"
  elseif value == nil or value == vim.NIL then
    return "null"
  else
    return tostring(value)
  end
end

local function fix_json_commas(text)
  -- Insert missing commas before newlines followed by a key (")
  -- but not after {, [, :, ,, or at the start of the file
  return text:gsub('([^}{%[%]:,])%s*\n%s*"', function(before)
    return before .. ',\n"'
  end)
end

local function format_json_body(body)
  if not body or body == "" then return body end
  local trimmed = vim.trim(body)
  if trimmed:sub(1, 1) ~= "{" and trimmed:sub(1, 1) ~= "[" then return body end

  -- Replace {{var}} references with JSON-valid placeholders.
  -- Quoted (inside string): "{{var}}" → '"__POSTE_VAR_Q_N__"'
  -- Unquoted (as value): {{var}} → '"__POSTE_VAR_U_N__"'
  local quoted_ph = {}
  local unquoted_ph = {}
  local q_idx = 0
  local u_idx = 0
  local stripped = body:gsub('"{{.-}}"', function(m)
    q_idx = q_idx + 1
    table.insert(quoted_ph, m)
    return '"__POSTE_VAR_Q_' .. q_idx .. '__"'
  end)
  stripped = stripped:gsub("{{.-}}", function(m)
    u_idx = u_idx + 1
    table.insert(unquoted_ph, m)
    return '"__POSTE_VAR_U_' .. u_idx .. '__"'
  end)

  local ok, decoded = pcall(vim.json.decode, stripped)
  if not ok then
    -- Try to fix common JSON issues: missing commas
    local fixed = fix_json_commas(stripped)
    if fixed ~= stripped then
      ok, decoded = pcall(vim.json.decode, fixed)
    end
  end
  if not ok then return body end
  local formatted = json_pretty(decoded)

  -- Restore unquoted {{var}} first (replace "__POSTE_VAR_U_N__" with {{var}})
  for i, ph in ipairs(unquoted_ph) do
    formatted = formatted:gsub('"__POSTE_VAR_U_' .. i .. '__"', function() return ph end, 1)
  end
  -- Restore quoted {{var}} (replace "__POSTE_VAR_Q_N__" with "{{var}}")
  for i, ph in ipairs(quoted_ph) do
    formatted = formatted:gsub('"__POSTE_VAR_Q_' .. i .. '__"', function() return ph end, 1)
  end
  return formatted
end

function M.format(content)
  if not content or content == "" then return content end

  local lines = vim.split(content, "\n", { plain = true })
  local result = {}
  local i = 1

  while i <= #lines do
    local line = lines[i]
    local trimmed = vim.trim(line)

    if trimmed:match("^###") then
      if #result > 0 and result[#result] ~= "" then
        table.insert(result, "")
      end
      local name = trimmed:match("^###%s*(.*)")
      if name and name ~= "" then
        table.insert(result, "### " .. vim.trim(name))
      else
        table.insert(result, "###")
      end
      i = i + 1
    elseif trimmed:match("^@") then
      local name, value = trimmed:match("^@(%S+)%s*=%s*(.+)")
      if not name then
        name, value = trimmed:match("^@(%S+)%s+(.+)")
      end
      if name and value then
        table.insert(result, "@" .. name .. " = " .. value)
      else
        table.insert(result, line)
      end
      i = i + 1
    elseif trimmed:match("^[A-Z]+%s+%S") and not trimmed:match("^[%w%-]+%s*:") then
      local method = trimmed:match("^(%S+)")
      local rest = trimmed:match("^%S+%s+(.+)")
      if method and rest then
        table.insert(result, method .. " " .. rest)
      else
        table.insert(result, trimmed)
      end
      i = i + 1
    elseif trimmed:match("^[%w%-]+%s*:") and not trimmed:match("^###") then
      local key, value = trimmed:match("^([^:]+):%s*(.*)")
      if key then
        table.insert(result, vim.trim(key) .. ": " .. vim.trim(value))
      else
        table.insert(result, line)
      end
      i = i + 1
    elseif trimmed == "" then
      if #result > 0 and result[#result] ~= "" then
        table.insert(result, "")
      end
      i = i + 1
    elseif trimmed:match("^#") then
      table.insert(result, line)
      i = i + 1
    elseif trimmed:match("^[<>]%s+{%%") then
      -- Ensure blank line before script block
      if #result > 0 and result[#result] ~= "" then
        table.insert(result, "")
      end
      -- Collect entire pre/post script block
      local script_lines = { line }
      i = i + 1
      while i <= #lines do
        local sl = lines[i]
        table.insert(script_lines, sl)
        i = i + 1
        if vim.trim(sl):match("^%%}") then break end
      end
      table.insert(result, table.concat(script_lines, "\n"))
    else
      local body_lines = {}
      local _ = i
      while i <= #lines do
        local bl = lines[i]
        local bt = vim.trim(bl)
        -- Stop at new section markers (including pre/post script blocks)
        if bt:match("^###") or bt:match("^@") or bt:match("^#") or bt:match("^[<>]%s+{%%") then
          break
        end
        if bt:match("^[A-Z]+%s+%S") and not bt:match("^[%w%-]+%s*:") then
          -- Request line starts a new section, but only if we've already
          -- collected some body (to avoid false positive on first line)
          if #body_lines > 0 then break end
        end
        table.insert(body_lines, bl)
        i = i + 1
      end
      local body = table.concat(body_lines, "\n")
      body = body:gsub("^(\n*)", "")
      body = format_json_body(body)
      if body ~= "" then
        if #result > 0 and result[#result] ~= "" then
          table.insert(result, "")
        end
        table.insert(result, body)
      end
    end
  end

  local formatted = table.concat(result, "\n")
  formatted = formatted:gsub("\n\n\n+", "\n\n")
  formatted = formatted:gsub("^\n+", "")
  formatted = formatted:gsub("\n+$", "") .. "\n"

  return formatted
end

function M.format_buffer(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, "\n")
  local formatted = M.format(content)
  if formatted == content then
    return false
  end
  local new_lines = vim.split(formatted, "\n", { plain = true })
  if new_lines[#new_lines] == "" then
    table.remove(new_lines)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  return true
end

return M