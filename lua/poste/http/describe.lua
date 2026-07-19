--- Single parse authority for HTTP block metadata.
---
--- Calls `poste run --describe` (Rust parser) so Lua never re-parses
--- method/path/headers from buffer text. See docs/dev/refactoring-plan.md Phase 2a.

local cli = require("poste.cli")
local state = require("poste.state")

local M = {}

--- Describe all request blocks in content via the CLI.
---
--- @param content string  Full file/buffer content
--- @param file string     Path used for extension + env.json discovery
--- @param opts? table
---   - env: string|nil  Environment name (default: state.current_env)
---   - binary: string|nil
--- @return table|nil, string|nil  array of BlockMeta, error
function M.describe_content(content, file, opts)
  opts = opts or {}
  if not content or content == "" then
    return {}, nil
  end
  if not file or file == "" then
    file = "untitled.http"
  end

  local args = {
    "run",
    file,
    "--stdin",
    "--describe",
  }
  local env = opts.env or state.current_env
  if env then
    table.insert(args, "--env")
    table.insert(args, env)
  end

  local blocks, err = cli.run_json(args, {
    stdin = content,
    binary = opts.binary,
  })
  if not blocks then
    return nil, err
  end
  if type(blocks) ~= "table" then
    return nil, "describe returned non-array JSON"
  end
  return blocks, nil
end

--- Find the block whose line range contains `line` (1-indexed).
---
--- @param blocks table  BlockMeta array from describe_content
--- @param line number   1-indexed cursor/block line
--- @return table|nil
function M.block_at_line(blocks, line)
  if not blocks or not line then return nil end
  for _, b in ipairs(blocks) do
    local start_l = b.line or 0
    local end_l = b.end_line or start_l
    if line >= start_l and line <= end_l then
      return b
    end
  end
  -- Fallback: nearest block whose start_line <= line
  local best = nil
  for _, b in ipairs(blocks) do
    if (b.line or 0) <= line then
      best = b
    end
  end
  return best
end

--- Convert a BlockMeta into the shape expected by pending_request / error paths.
---
--- @param meta table  BlockMeta
--- @return table  { request_line, headers, name, method, path, body }
function M.to_req_block(meta)
  if not meta then
    return { request_line = "", headers = {}, name = "", method = "", path = "", body = "" }
  end
  local headers = meta.headers or {}
  -- Ensure headers are { {k,v}, ... } even if empty
  return {
    request_line = meta.request_line or "",
    headers = headers,
    name = meta.name or "",
    method = meta.method or "",
    path = meta.path or "",
    body = meta.body or "",
  }
end

--- Build headers_str from BlockMeta headers.
--- @param meta table
--- @return string
function M.headers_str(meta)
  if not meta or not meta.headers then return "" end
  local parts = {}
  for _, h in ipairs(meta.headers) do
    if type(h) == "table" and h[1] then
      table.insert(parts, h[1] .. ": " .. (h[2] or ""))
    end
  end
  return table.concat(parts, "\n")
end

return M
