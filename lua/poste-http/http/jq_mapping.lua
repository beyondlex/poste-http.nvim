local nested_access = require("poste-http.http.nested_access")

local M = {}

function M.parse_structured_options(options_str)
  local result = {}
  -- The option text normally comes from a buffer-line match (always a
  -- string); a non-string converges to "no options" like the sibling
  -- parsers instead of raising on `:gmatch`.
  if type(options_str) ~= "string" then
    return result
  end
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

  -- Both iteration modes walk the same item list: the value itself when it
  -- is an array, else the value wrapped as a one-element list.
  local items
  if vim.islist(value) then
    items = value
  else
    items = { value }
  end
  -- Path cleanup per mode: array paths drop their `.[]` iteration prefix
  -- (the iteration is the outer loop here); plain paths drop one leading
  -- dot. Either way the remainder is a per-item walk path. Non-string paths
  -- (a hand-built mapping) are dropped — the `:find`/`:gsub` below would
  -- raise on them.
  local clean = {}
  if uses_array_iteration then
    for field, path in pairs(mapping) do
      if type(path) == "string" then
        local cleaned = path:gsub("^%.[%[%]][%[%]](%.?)", "")
        cleaned = cleaned:gsub("^%.", "")
        clean[field] = cleaned
      end
    end
  else
    for field, path in pairs(mapping) do
      if type(path) == "string" then
        clean[field] = path:match("^%.(.+)") or path
      end
    end
  end
  mapping = clean

  local result = {}
  for _, item in ipairs(items) do
    if type(item) == "table" then
      local entry = {}
      local has_field = false
      for _, field in ipairs({ "name", "key", "description" }) do
        if mapping[field] then
          local resolved = nested_access.get_nested_value(item, mapping[field])
          if resolved ~= nil then
            -- A path that lands on an object/array (user shorthand like
            -- `desc: .items` while iterating the parent) is JSON-encoded,
            -- not tostring()ed — a "table: 0x…" option label is never what
            -- anyone wants to select.
            if type(resolved) == "table" then
              local ok, encoded = pcall(vim.json.encode, resolved)
              entry[field] = ok and encoded or "…"
            else
              entry[field] = tostring(resolved)
            end
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