local M = {}

function M.generate_http_block(name, method, url, headers, body, prompts)
  local lines = {}
  table.insert(lines, "### " .. name)
  for _, p in ipairs(prompts or {}) do
    table.insert(lines, "<<" .. p.name .. " " .. p.options)
  end
  table.insert(lines, method .. " " .. url)
  local has_content_type
  for _, h in ipairs(headers or {}) do
    table.insert(lines, h.key .. ": " .. h.value)
    if h.key:lower() == "content-type" then
      has_content_type = true
    end
  end
  if body and body ~= "" then
    if not has_content_type then
      table.insert(lines, "Content-Type: application/json")
    end
    table.insert(lines, "")
    table.insert(lines, body)
  end
  table.insert(lines, "")
  return table.concat(lines, "\n")
end

function M.generate_env_json(env_name, vars)
  local env = {}
  env[env_name] = vars
  return vim.json.encode(env)
end

function M.generate_file_vars(vars)
  local lines = {}
  for _, v in ipairs(vars or {}) do
    table.insert(lines, "@" .. v.name .. " = " .. v.value)
  end
  if #lines > 0 then
    table.insert(lines, "")
  end
  return table.concat(lines, "\n")
end

function M.resolve_ref(ref, spec)
  if not ref then return nil end
  if ref:sub(1, 2) ~= "#/" then return nil end
  local parts = vim.split(ref:sub(3), "/", { plain = true })
  local current = spec
  for _, part in ipairs(parts) do
    if current == nil then return nil end
    local decoded = part:gsub("~1", "/"):gsub("~0", "~")
    current = current[decoded]
  end
  return current
end

function M.resolve_schema(schema, spec)
  if not schema then return nil end
  if schema["$ref"] then
    return M.resolve_ref(schema["$ref"], spec)
  end
  return schema
end

function M.schema_to_example(schema, spec, depth)
  depth = depth or 0
  if depth > 5 then return {} end
  if not schema then return {} end

  local resolved = M.resolve_schema(schema, spec)
  if not resolved then return {} end

  if resolved.example ~= nil then
    return resolved.example
  end

  if resolved.type == "object" or resolved.properties then
    local obj = {}
    if resolved.properties then
      for k, v in pairs(resolved.properties) do
        obj[k] = M.schema_to_example(v, spec, depth + 1)
      end
    end
    return obj
  end

  if resolved.type == "array" then
    return { M.schema_to_example(resolved.items, spec, depth + 1) }
  end

  if resolved.type == "string" then
    if resolved.enum and #resolved.enum > 0 then
      return resolved.enum[1]
    end
    if resolved.default ~= nil then return resolved.default end
    if resolved.format == "date" then return "2024-01-01"
    elseif resolved.format == "date-time" then return "2024-01-01T00:00:00Z"
    elseif resolved.format == "email" then return "user@example.com"
    elseif resolved.format == "uri" then return "https://example.com"
    elseif resolved.format == "uuid" then return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    end
    return "string"
  end

  if resolved.type == "integer" then
    if resolved.default ~= nil then return resolved.default end
    return 0
  elseif resolved.type == "number" then
    if resolved.default ~= nil then return resolved.default end
    return 0.0
  elseif resolved.type == "boolean" then
    if resolved.default ~= nil then return resolved.default end
    return true
  end

  return {}
end

local function example_to_string(value)
  if type(value) == "table" then
    local parts = {}
    for _, v in ipairs(value) do
      table.insert(parts, example_to_string(v))
    end
    if #parts > 0 then
      return '["' .. table.concat(parts, '","') .. '"]'
    end
    return "[]"
  end
  return tostring(value)
end

function M.collect_parameters(openapi_params, path_params, spec)
  local headers = {}
  local query_parts = {}
  local url_vars = {}
  local prompts = {}
  local has_body = false

  for _, param in ipairs(openapi_params or {}) do
    local resolved = M.resolve_schema(param, spec)
    if resolved then
      local name = resolved.name or ""
      local in_location = resolved["in"] or ""
      local schema = resolved.schema or resolved
      local resolved_schema = M.resolve_schema(schema, spec)
      local example = M.schema_to_example(resolved_schema or schema, spec)
      local str_example = example_to_string(example)

      -- Check if parameter has enum values
      local enum_values = nil
      if resolved_schema and resolved_schema.items and resolved_schema.items.enum then
        enum_values = resolved_schema.items.enum
      elseif resolved_schema and resolved_schema.enum then
        enum_values = resolved_schema.enum
      end

      if enum_values and #enum_values > 0 then
        -- Add a prompt with enum values directly as options
        local options_str = "[" .. table.concat(enum_values, ", ") .. "]"
        table.insert(prompts, { name = name, options = options_str })
        -- Use {{varname}} instead of a hardcoded value wherever the
        -- parameter lands: query params go into the query string, header
        -- params into a header line. Path params already reference
        -- {{name}} via the {{param}} URL rewrite, so they need nothing
        -- here. (Header params with an enum used to emit no header at
        -- all — the prompt line existed, the request was missing it.)
        if in_location == "query" then
          table.insert(query_parts, name .. "={{" .. name .. "}}")
        elseif in_location == "header" then
          table.insert(headers, { key = name, value = "{{" .. name .. "}}" })
        end
      else
        if in_location == "header" then
          table.insert(headers, { key = name, value = "{{" .. name .. "}}" })
          table.insert(url_vars, { name = name, value = str_example })
        elseif in_location == "query" then
          table.insert(query_parts, name .. "=" .. str_example)
          table.insert(url_vars, { name = name, value = str_example })
        elseif in_location == "path" then
          table.insert(url_vars, { name = name, value = str_example })
        end
      end
    end
  end

  return headers, query_parts, url_vars, has_body, prompts
end

function M.parameters_to_url_vars(params)
  local vars = {}
  for _, param in ipairs(params or {}) do
    if param.name and param.value then
      table.insert(vars, { name = param.name, value = param.value })
    end
  end
  return vars
end

function M.extract_auth_header(spec)
  local security = spec.security or {}
  local schemes = (spec.components and spec.components.securitySchemes) or {}
  for _, req in ipairs(security) do
    for name, _ in pairs(req) do
      local scheme = schemes[name]
      if scheme then
        local st = scheme.type or ""
        if st == "http" and scheme.scheme == "bearer" then
          return { key = "Authorization", value = "Bearer {{token}}" }
        elseif st == "http" and scheme.scheme == "basic" then
          return { key = "Authorization", value = "Basic {{credentials}}" }
        elseif st == "apiKey" then
          if scheme["in"] == "header" then
            return { key = scheme.name or "X-API-Key", value = "{{api_key}}" }
          end
        end
      end
    end
  end
  return nil
end

--- Read and parse a JSON spec file.
--- @param path string
--- @return table|nil, string|nil
function M.read_spec(path)
  local fd = io.open(path, "r")
  if not fd then return nil, "Cannot read file: " .. path end
  local content = fd:read("*a")
  fd:close()
  local ok, spec = pcall(vim.json.decode, content)
  if not ok then
    -- A YAML spec (the other common OpenAPI format) fails JSON decode; name
    -- the actual limitation instead of a bare "Invalid JSON".
    if content:match("^%s*[%w_]+:%s") or content:match("^%s*-") then
      return nil, path .. " looks like YAML — only JSON specs are supported"
    end
    return nil, "Invalid JSON: " .. tostring(spec)
  end
  return spec, nil
end

--- Sanitize a title into a filename.
--- @param title string
--- @return string
function M.make_filename(title)
  return title:lower():gsub("%s+", "_"):gsub("[^%w_]", "") .. ".http"
end

--- Run the shared finder interaction flow for importing specs.
--- @param opts table  { extensions = string[], mode = string, import_fn = function(spec_path, out_dir), title = string }
function M.run_importer(opts)
  local ok, finder = pcall(require, "finder")
  if not ok then
    vim.notify("beyondlex/finder plugin required for file selection", vim.log.levels.ERROR)
    return
  end
  finder.open({
    mode = opts.mode or "file",
    initial_path = vim.fn.getcwd(),
    extensions = opts.extensions or { "json" },
    on_confirm = function(spec_path)
      if not spec_path then return end
      local default_dir = vim.fn.fnamemodify(spec_path, ":h")
      vim.schedule(function()
        finder.open({
          mode = "dir",
          initial_path = default_dir,
          title = " Select output directory ",
          on_confirm = function(out_dir)
            if not out_dir then return end
            local result, err = opts.import_fn(spec_path, out_dir)
            if result then
              vim.notify(string.format("%s: %d blocks → %s/%s",
                opts.title, result.block_count, out_dir, result.filename),
                vim.log.levels.INFO, { title = "Import " .. opts.title })
            else
              vim.notify(string.format("%s import failed: %s", opts.title, err or "unknown"),
                vim.log.levels.ERROR, { title = "Import " .. opts.title })
            end
          end,
          on_cancel = function() end,
        })
      end)
    end,
    on_cancel = function() end,
  })
end

function M.write_output(out_dir, http_content, env_json, filename)
  vim.fn.mkdir(out_dir, "p")
  local http_path = out_dir .. "/" .. filename
  local fd = io.open(http_path, "w")
  if fd then
    fd:write(http_content)
    fd:close()
  end
  if env_json then
    local env_path = out_dir .. "/env.json"
    local env_fd = io.open(env_path, "w")
    if env_fd then
      env_fd:write(env_json)
      env_fd:close()
    end
  end
end

return M