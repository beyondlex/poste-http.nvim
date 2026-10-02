local M = {}
local import_parser = require("poste-http.http.import_parser")

local function resolve_postman_var(value, vars)
  if not value then return "" end
  if type(value) == "string" then
    return value:gsub("{{([^}]+)}}", function(name)
      return vars[name] or "{{" .. name .. "}}"
    end)
  end
  return tostring(value)
end

local function parse_url(request_url)
  if not request_url then return "", {} end
  if type(request_url) == "string" then
    return request_url, {}
  end
  local raw = request_url.raw or ""
  local query_parts = {}
  local query = request_url.query
  if type(query) == "table" then
    for _, q in ipairs(query) do
      -- `disabled` params are off in Postman's UI: exporting them into the
      -- .http request line would silently send what the collection author
      -- switched off.
      if type(q) == "table" and not q.disabled then
        local key = q.key or ""
        local value = q.value or ""
        table.insert(query_parts, key .. "=" .. value)
      end
    end
  end
  if #query_parts > 0 then
    local sep = raw:find("?") and "&" or "?"
    return raw .. sep .. table.concat(query_parts, "&"), query_parts
  end
  return raw, {}
end

local function parse_body(request_body)
  if not request_body then return "" end
  local mode = request_body.mode or ""
  if mode == "raw" then
    -- Raw is a string by spec; a drifted table/number would flow into
    -- generate_http_block and crash its line concat.
    local raw = request_body.raw
    return (type(raw) == "string") and raw or ""
  elseif mode == "urlencoded" then
    local parts = {}
    local entries = request_body.urlencoded
    for _, p in ipairs(type(entries) == "table" and entries or {}) do
      if type(p) == "table" and not p.disabled then
        table.insert(parts, (p.key or "") .. "=" .. (p.value or ""))
      end
    end
    return table.concat(parts, "&")
  elseif mode == "formdata" then
    local parts = {}
    local entries = request_body.formdata
    for _, p in ipairs(type(entries) == "table" and entries or {}) do
      if type(p) == "table" and not p.disabled then
        if p.type == "file" then
          table.insert(parts, "< " .. (p.src or ""))
        else
          table.insert(parts, (p.key or "") .. "=" .. (p.value or ""))
        end
      end
    end
    return table.concat(parts, "\n")
  elseif mode == "file" then
    return "< " .. (request_body.file and request_body.file.src or "")
  end
  return ""
end

local function parse_item(item, vars, collection_vars)
  -- Total on any entry shape: callers outside the read_spec boundary (the
  -- _test_parse_item hook, future import paths) may hand through a
  -- vim.NIL/scalar that clean_nil never saw.
  if type(item) ~= "table" then return nil end

  -- A folder's item list must be a table; a drifted scalar has no
  -- representable children and imports as an empty folder.
  if type(item.item) == "table" then
    local blocks = {}
    for _, sub in ipairs(item.item) do
      local result = type(sub) == "table" and parse_item(sub, vars, collection_vars) or nil
      if result then
        for _, b in ipairs(result) do
          table.insert(blocks, b)
        end
      end
    end
    return blocks
  end

  if not item.request or type(item.request) ~= "table" then return nil end

  local req = item.request
  local method = (type(req.method) == "string" and req.method ~= "") and req.method or "GET"
  local name = item.name or (method .. " Request")

  local url, _ = parse_url(req.url)
  url = resolve_postman_var(url, vars)

  local headers = {}
  local header_list = req.header
  for _, h in ipairs(type(header_list) == "table" and header_list or {}) do
    if type(h) == "table" and h.key and h.key ~= "" and not h.disabled then
      local value = resolve_postman_var(h.value, vars)
      table.insert(headers, { key = h.key, value = value })
    end
  end

  local body = parse_body(req.body)

  local block = import_parser.generate_http_block(name, method, url, headers, body)
  return { block }
end

local function collect_variables(collection)
  local vars = {}
  local collection_vars = collection.variable
  for _, v in ipairs(type(collection_vars) == "table" and collection_vars or {}) do
    -- A drifted scalar entry carries no key/value pair; skipping it beats
    -- indexing userdata mid-import.
    if type(v) == "table" then
      vars[v.key or v.name or ""] = v.value or ""
    end
  end
  return vars
end

function M.import_spec(spec_path, out_dir)
  local collection, err = import_parser.read_spec(spec_path)
  if not collection then return nil, err end

  if collection.info == nil then
    return nil, "Not a Postman Collection (missing 'info' field)"
  end

  local vars = collect_variables(collection)
  local title = (collection.info and collection.info.name) or "collection"
  local filename = import_parser.make_filename(title)

  local file_vars = {}
  for k, v in pairs(vars) do
    table.insert(file_vars, { name = k, value = v })
  end

  local blocks = {}
  local items = collection.item or {}
  for _, item in ipairs(items) do
    local result = parse_item(item, vars, vars)
    if result then
      for _, b in ipairs(result) do
        table.insert(blocks, b)
      end
    end
  end

  local file_vars_str = import_parser.generate_file_vars(file_vars)
  local http_content = file_vars_str .. table.concat(blocks, "\n")
  local env_vars = {}
  for k, v in pairs(vars) do
    env_vars[k] = tostring(v):gsub("^\"(.*)\"$", "%1")
  end
  local env_json = import_parser.generate_env_json("dev", env_vars)

  import_parser.write_output(out_dir, http_content, env_json, filename)

  return { filename = filename, block_count = #blocks }
end

-- Exposed for tests (family _test convention): one item/folder → blocks.
M._test_parse_item = parse_item

function M.run()
  import_parser.run_importer({
    mode = "file",
    extensions = { "json" },
    title = "Postman",
    import_fn = function(spec_path, out_dir)
      return M.import_spec(spec_path, out_dir)
    end,
  })
end

return M