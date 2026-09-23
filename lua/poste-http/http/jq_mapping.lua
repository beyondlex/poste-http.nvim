local nested_access = require("poste-http.http.nested_access")

local M = {}

function M.parse_structured_options(options_str)
  local result = {}
  for opt in options_str:gmatch("[^,]+") do
    local trimmed = vim.trim(opt)
    if trimmed ~= "" then
      local parts = vim.split(trimmed, "|", { plain = true })
      if #parts == 1 then
        local name = vim.trim(parts[1])
        table.insert(result, { name = name, key = name, description = "" })
      else
        local name = vim.trim(parts[1])
        local key = vim.trim(parts[2])
        local desc_parts = {}
        for i = 3, #parts do
          table.insert(desc_parts, parts[i])
        end
        local description = vim.trim(table.concat(desc_parts, "|"))
        table.insert(result, { name = name, key = key, description = description })
      end
    end
  end
  return result
end

function M.parse_dynamic_mapping(options_str)
  local ref = options_str:match("{{(.+)}}")
  if not ref then return nil, nil end
  ref = vim.trim(ref)
  local response_ref, mapping_expr = ref:match("^(.-)%s*|%s*{(.-)}$")
  if not response_ref then
    return ref, nil
  end
  local mapping = {}
  for field_expr in mapping_expr:gmatch("[^,]+") do
    local field, path = field_expr:match("^%s*(%w+)%s*:%s*(.+)$")
    if field and path then
      field = field == "desc" and "description" or field
      mapping[field] = vim.trim(path)
    end
  end
  return response_ref, mapping
end

function M.apply_jq_mapping(value, mapping)
  if type(value) ~= "table" then return {} end

  local uses_array_iteration = false
  for _, path in pairs(mapping) do
    if type(path) == "string" and path:find("[]", 1, true) then
      uses_array_iteration = true
      break
    end
  end

  local items
  if uses_array_iteration then
    if vim.islist(value) then
      items = value
    else
      items = { value }
    end
    local clean = {}
    for field, path in pairs(mapping) do
      local cleaned = path:gsub("^%.[%[%]][%[%]](%.?)", "")
      cleaned = cleaned:gsub("^%.", "")
      clean[field] = cleaned
    end
    mapping = clean
  else
    if vim.islist(value) then
      items = value
    else
      items = { value }
    end
    local clean = {}
    for field, path in pairs(mapping) do
      clean[field] = path:match("^%.(.+)") or path
    end
    mapping = clean
  end

  local result = {}
  for _, item in ipairs(items) do
    if type(item) == "table" then
      local entry = {}
      local has_field = false
      for _, field in ipairs({ "name", "key", "description" }) do
        if mapping[field] then
          local resolved = nested_access.get_nested_value(item, mapping[field])
          if resolved ~= nil then
            entry[field] = tostring(resolved)
            has_field = true
          else
            entry[field] = ""
          end
        end
      end
      if has_field then
        table.insert(result, entry)
      end
    end
  end
  return result
end

return M