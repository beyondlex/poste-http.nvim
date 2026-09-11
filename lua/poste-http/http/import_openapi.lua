local M = {}
local import_parser = require("poste-http.http.import_parser")

local function parse_servers(spec)
  local servers = spec.servers or {}
  return servers
end

-- server_url is accepted for signature parity with import_swagger; the
-- host is deliberately swapped for the {{base_url}} env variable.
local function build_url(server_url, path)
  local clean_path = path or ""
  if clean_path:sub(1, 1) ~= "/" then
    clean_path = "/" .. clean_path
  end
  -- Replace OpenAPI path params {param} with HTTP variable syntax {{param}}
  clean_path = clean_path:gsub("{([^}]+)}", "{{%1}}")
  return "{{base_url}}" .. clean_path
end

local function parse_request_body(operation, spec)
  if not operation.requestBody then return "" end
  local content = operation.requestBody.content or {}
  local json_content = content["application/json"]
  if json_content and json_content.schema then
    local example = import_parser.schema_to_example(json_content.schema, spec)
    if type(example) == "table" and next(example) then
      return vim.json.encode(example)
    end
  end
  return ""
end

local function parse_operation(path, method, operation, spec, server_url)
  local name = (operation.summary or operation.operationId or (method:upper() .. " " .. path))
  local url = build_url(server_url, path)
  local headers = {}
  local body = ""
  local op_vars = {}

  local auth = import_parser.extract_auth_header(spec)
  if auth then
    table.insert(headers, auth)
  end

  local api_params = operation.parameters or {}
  local path_params = spec.paths and spec.paths[path] and spec.paths[path].parameters or {}
  local all_params = {}
  for _, p in ipairs(api_params) do table.insert(all_params, p) end
  for _, p in ipairs(path_params) do
    local found = false
    for _, ap in ipairs(all_params) do
      if ap.name == p.name and ap["in"] == p["in"] then found = true break end
    end
    if not found then table.insert(all_params, p) end
  end

  local hdrs, qs, vars, _, prompts = import_parser.collect_parameters(all_params, {}, spec)
  for _, h in ipairs(hdrs) do table.insert(headers, h) end
  for _, v in ipairs(vars) do
    if not op_vars[v.name] then
      op_vars[v.name] = v.value
    end
  end
  if #qs > 0 then
    url = url .. "?" .. table.concat(qs, "&")
  end

  if method:lower() == "post" or method:lower() == "put" or method:lower() == "patch" then
    body = parse_request_body(operation, spec)
  end

  return import_parser.generate_http_block(name, method:upper(), url, headers, body, prompts), op_vars
end

function M.import_spec(spec_path, out_dir)
  local spec, err = import_parser.read_spec(spec_path)
  if not spec then return nil, err end

  if spec.openapi == nil then
    return nil, "Not an OpenAPI 3.x spec (missing 'openapi' field)"
  end

  local servers = parse_servers(spec)
  local server_url = (#servers > 0 and servers[1].url) or "http://localhost"

  local title = (spec.info and spec.info.title) or "api"
  local filename = import_parser.make_filename(title)

  local file_vars = {}
  table.insert(file_vars, { name = "base_url", value = server_url })

  local auth = import_parser.extract_auth_header(spec)
  if auth then
    table.insert(file_vars, { name = "token", value = "your-token-here" })
  end

  local blocks = {}
  local all_op_vars = {}
  local paths = spec.paths or {}
  for path, path_item in pairs(paths) do
    local methods = { "get", "post", "put", "patch", "delete", "options", "head", "trace" }
    for _, method in ipairs(methods) do
      local operation = path_item[method]
      if operation then
        local block, op_vars = parse_operation(path, method, operation, spec, server_url)
        if block then
          table.insert(blocks, block)
          for k, v in pairs(op_vars) do
            all_op_vars[k] = v
          end
        end
      end
    end
  end

  -- Add operation-level variables as file-level @var definitions
  for name, value in pairs(all_op_vars) do
    table.insert(file_vars, { name = name, value = value })
  end

  local file_vars_str = import_parser.generate_file_vars(file_vars)
  local http_content = file_vars_str .. table.concat(blocks, "\n")
  local env_vars = {}
  env_vars["base_url"] = server_url
  local env_json = import_parser.generate_env_json("dev", env_vars)

  import_parser.write_output(out_dir, http_content, env_json, filename)

  return { filename = filename, block_count = #blocks }
end

function M.run()
  import_parser.run_importer({
    mode = "both",
    -- read_spec is JSON-only; advertising yaml/yml here would let the picker
    -- offer files the importer then rejects.
    extensions = { "json" },
    title = "OpenAPI",
    import_fn = function(spec_path, out_dir)
      return M.import_spec(spec_path, out_dir)
    end,
  })
end

return M