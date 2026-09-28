local M = {}

local function parse_path_segments(path)
  local segments = {}
  local i = 1
  while i <= #path do
    if path:sub(i, i) == "." then
      i = i + 1
    else
      local start = i
      local depth = 0
      while i <= #path do
        local c = path:sub(i, i)
        if c == "[" then
          depth = depth + 1
        elseif c == "]" then
          depth = depth - 1
        elseif c == "." and depth == 0 then
          break
        end
        i = i + 1
      end
      table.insert(segments, path:sub(start, i - 1))
    end
  end
  return segments
end

--- Split one segment into its base key plus the bracket tokens that trail
--- it: "items" → ("items", {}), "items[0]" → ("items", {"0"}),
--- "data[0][1]" → ("data", {"0", "1"}), "grid[][0]" → ("grid", {"", "0"}).
--- An empty token is the `[]` wildcard; a numeric token is a 0-based index.
--- A non-numeric bracket (`x[weird]`) stops the scan so the whole segment
--- stays one literal key, matching the old single-bracket behavior.
local function parse_bracket_tokens(part)
  local base = part
  local tokens = {}
  while true do
    local head, inner = base:match("^(.*)%[([^%[%]]*)%]$")
    if not head then break end
    if inner ~= "" and not inner:match("^%d+$") then break end
    table.insert(tokens, 1, inner)
    base = head
  end
  return base, tokens
end

--- Decode a string value that is itself JSON (a body stored as text), once.
local function ensure_traversable(value)
  if type(value) == "string" then
    local ok, parsed = pcall(vim.json.decode, value)
    if ok and type(parsed) == "table" then
      return parsed
    end
    return nil
  end
  return value
end

--- Apply this segment's bracket tokens, then hand the result to the next
--- segment. `[]` fans out over a list and collects the non-nil results of
--- the remaining path per element (a missing element is filtered, matching
--- the old wildcard contract); `[n]` descends 0-based.
local resolve_segments

local function apply_tokens(value, tokens, token_idx, segments, seg_idx)
  if token_idx > #tokens then
    return resolve_segments(value, segments, seg_idx)
  end
  value = ensure_traversable(value)
  if type(value) ~= "table" then return nil end
  local token = tokens[token_idx]
  if token == "" then
    if not vim.islist(value) then return nil end
    local results = {}
    for _, elem in ipairs(value) do
      local r = apply_tokens(elem, tokens, token_idx + 1, segments, seg_idx)
      if r ~= nil then
        table.insert(results, r)
      end
    end
    return results
  end
  return apply_tokens(value[tonumber(token) + 1], tokens, token_idx + 1, segments, seg_idx)
end

--- Resolve a plain-key (or base-key) segment, honoring the `key[]`-style
--- fallback key a stored list may use, then apply its bracket tokens.
local function resolve_segment(current, part, segments, seg_idx)
  local base, tokens = parse_bracket_tokens(part)
  local value
  if base == "" then
    value = current
  else
    value = current[base]
    if value == nil then value = current[base .. "[]"] end
  end
  return apply_tokens(value, tokens, 1, segments, seg_idx + 1)
end

resolve_segments = function(current, segments, idx)
  if idx > #segments then return current end
  current = ensure_traversable(current)
  if type(current) ~= "table" then return nil end
  return resolve_segment(current, segments[idx], segments, idx)
end

function M.get_nested_value(obj, path)
  -- Non-string paths (a number from a scripted jq filter, say) pass through
  -- as "nothing found" instead of crashing on `#path`.
  if not obj or type(path) ~= "string" or path == "" then return nil end
  local segments = parse_path_segments(path)
  return resolve_segments(obj, segments, 1)
end

function M.parse_path_segments(path)
  return parse_path_segments(path)
end

return M