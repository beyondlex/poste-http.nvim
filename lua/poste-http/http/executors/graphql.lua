--- GraphQL executor: lowers GRAPHQL blocks to HTTP POST via curl.
---
--- Block shape (docs/dev/multi-protocol-design.md):
---   body = query text, blank line, optional variables JSON
---
--- The executor synthesizes `{"query": ..., "variables": ...}` and sets
--- `Content-Type: application/json` unless the block already carries a
--- Content-Type. `Content-Type: application/graphql` sends the raw query
--- text untouched.

local M = {}
local curl_exec = require("poste-http.http.curl_exec")
local state = require("poste-http.state")

--- Split a raw body into blank-line-separated chunks, dropping empty
--- leading/trailing chunks. Internal blank lines inside a chunk are
--- normalized away only when the chunk list is re-joined; when the whole
--- body is a query the original text is preserved instead.
local function split_chunks(body)
  local chunks = {}
  local current = {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    if vim.trim(line) == "" then
      if #current > 0 then
        table.insert(chunks, table.concat(current, "\n"))
        current = {}
      end
    else
      table.insert(current, line)
    end
  end
  if #current > 0 then
    table.insert(chunks, table.concat(current, "\n"))
  end
  return chunks
end

local function json_shaped(chunk)
  local t = vim.trim(chunk)
  return t:sub(1, 1) == "{" or t:sub(1, 1) == "["
end

--- Split a raw body into query text and an optional variables JSON chunk.
--- Returns query, variables_json (nil when absent) on success, or nil, err.
--- Rules:
---   - no blank-line tail            → the whole body is the query
---   - tail parses as a JSON object  → tail is the variables block
---   - tail is {/[ shaped but broken → error (fail fast, never send it)
---   - tail is any other text        → treated as query continuation
function M.split_body(body)
  if not body or vim.trim(body) == "" then
    return "", nil
  end
  local chunks = split_chunks(body)
  if #chunks < 2 then
    return vim.trim(body), nil
  end
  local tail = chunks[#chunks]
  if not json_shaped(tail) then
    return vim.trim(body), nil
  end
  local ok, decoded = pcall(vim.json.decode, tail)
  -- A JSON array tail is rejected, not passed through: the GraphQL spec
  -- requires `variables` to be an object, so `[1,2]` would only surface as
  -- a server-side "variables must be an object" error after the round trip.
  if not ok or type(decoded) ~= "table" or vim.islist(decoded) then
    return nil, "GraphQL variables block must be a JSON object: " .. tail
  end
  local parts = {}
  for i = 1, #chunks - 1 do
    table.insert(parts, chunks[i])
  end
  return vim.trim(table.concat(parts, "\n\n")), tail
end

--- Build the JSON request body sent to the server.
--- Returns json_string, err (exactly one is nil).
function M.build_request_body(body)
  local query, variables_json = M.split_body(body)
  if not query then
    return nil, variables_json
  end
  if vim.trim(query) == "" then
    return nil, "GraphQL query is empty"
  end

  local payload = { query = query }
  if variables_json then
    payload.variables = vim.json.decode(variables_json)
  end
  return vim.json.encode(payload), nil
end

local response_mod = require("poste-http.http.response")
local function error_response(req, msg)
  return response_mod.error_response(req, "GRAPHQL", msg)
end

local function find_content_type(headers)
  for _, h in ipairs(headers or {}) do
    if h[1] and h[1]:lower() == "content-type" then
      return h[2]
    end
  end
  return nil
end

--- Run the request: lower to POST and hand off to curl_exec.
function M.run(req, callback)
  local raw_ct = find_content_type(req.headers)
  local out_body = req.body
  local headers = {}
  for _, h in ipairs(req.headers or {}) do
    table.insert(headers, h)
  end

  local raw_graphql = raw_ct and raw_ct:lower():find("application/graphql", 1, true)
  if not raw_graphql then
    local json, err = M.build_request_body(req.body)
    if err then
      state.log("ERROR", "graphql: " .. err)
      callback(error_response(req, err))
      return
    end
    out_body = json
    if not raw_ct then
      table.insert(headers, { "Content-Type", "application/json" })
    end
  end

  curl_exec.execute({
    method = "POST",
    url = req.url,
    headers = headers,
    body = out_body,
    buf_dir = req.buf_dir,
    timeout = req.timeout,
    cookie_jar = req.cookie_jar,
  }, callback)
end

return M
