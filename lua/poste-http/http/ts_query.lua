local state = require("poste-http.state")

local M = {}

local LANG = "poste_http"

function M.get_parser(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, LANG)
  if not ok then return nil end
  return parser
end

--- Whether the poste_http tree-sitter parser can be created for the buffer.
--- Returns false when the parser is missing or broken (e.g. stale binary or
--- invalid injection query), so callers can fall back to regex-based logic.
function M.is_available(buf)
  return M.get_parser(buf) ~= nil
end

--- Whether tree-sitter is switched on for `feature` in the config:
--- `use_treesitter = true`, or a per-feature table without
--- `use_treesitter[feature] = false`. Callers needing the parser check too
--- want M.enabled_for.
function M.feature_enabled(feature)
  local cfg = state.config.use_treesitter
  if not cfg then return false end
  if type(cfg) ~= "table" then return true end
  return cfg[feature] ~= false
end

--- feature_enabled + parser availability — the shared "should this feature
--- use tree-sitter on this buffer" switch (nav, outline, context_detector).
--- A nil buf skips the parser check (callers without a concrete buffer
--- assume the feature works and fall back at parse time).
function M.enabled_for(buf, feature)
  if not buf then return M.feature_enabled(feature) end
  return M.feature_enabled(feature) and M.is_available(buf)
end

function M.get_root(buf)
  local parser = M.get_parser(buf)
  if not parser then return nil end
  local ok, trees = pcall(parser.parse, parser)
  if not ok or not trees or #trees == 0 then return nil end
  return trees[1]:root()
end

function M.node_at_point(buf, row, col)
  local root = M.get_root(buf)
  if not root then return nil end
  return root:named_descendant_for_range(row, col, row, col)
end

function M.node_text(node, buf)
  if not node then return "" end
  buf = buf or 0
  local ok, sr, sc, er, ec = pcall(node.range, node)
  if not ok then return "" end
  local ok2, lines = pcall(vim.api.nvim_buf_get_lines, buf, sr, er + 1, false)
  if not ok2 or #lines == 0 then return "" end
  if sr == er then
    return lines[1]:sub(sc + 1, ec)
  end
  local parts = { lines[1]:sub(sc + 1) }
  for i = 2, #lines - 1 do
    table.insert(parts, lines[i])
  end
  parts[#parts + 1] = lines[#lines]:sub(1, ec)
  return table.concat(parts, "\n")
end

function M.parent_of_type(node, ...)
  local types = { ... }
  local type_set = {}
  for _, t in ipairs(types) do
    type_set[t] = true
  end
  while node do
    local ok, t = pcall(node.type, node)
    if not ok or not t then return nil end
    if type_set[t] then
      return node
    end
    local ok2, parent = pcall(node.parent, node)
    if not ok2 then return nil end
    node = parent
  end
  return nil
end

local function parse_capture_names(query_string)
  local names = {}
  for name in query_string:gmatch("@(%w+)") do
    table.insert(names, name)
  end
  return names
end

local function collect_matches(root, buf, query_string, start_row, end_row)
  local ok, query = pcall(vim.treesitter.query.parse, LANG, query_string)
  if not ok then return {} end
  local capture_names = parse_capture_names(query_string)
  local results = {}
  for pattern, match in query:iter_matches(root, buf, start_row, end_row) do
    local captures = {}
    for id, nodes in pairs(match) do
      if type(id) == "number" and nodes then
        local name = capture_names[id] or query.captures[id] or query.captures[id + 1]
        if name then
          for _, node in ipairs(nodes) do
            table.insert(captures, { name = name, node = node })
          end
        end
      end
    end
    table.insert(results, { pattern = pattern, captures = captures })
  end
  return results
end

function M.query_nodes(buf, query_string)
  local root = M.get_root(buf)
  if not root then return {} end
  return collect_matches(root, buf, query_string, 0, -1)
end

function M.query_nodes_in_range(buf, query_string, start_row, end_row)
  local root = M.get_root(buf)
  if not root then return {} end
  return collect_matches(root, buf, query_string, start_row, end_row)
end

function M.find_nodes_of_type(buf, type_name)
  local root = M.get_root(buf)
  if not root then return {} end
  local results = {}
  local function walk(node)
    if not node then return end
    local ok, t = pcall(node.type, node)
    if ok and t == type_name then
      table.insert(results, node)
      return
    end
    local ok2, child_count = pcall(node.named_child_count, node)
    if ok2 then
      for i = 0, child_count - 1 do
        local ok3, child = pcall(node.named_child, node, i)
        if ok3 and child then
          walk(child)
        end
      end
    end
  end
  walk(root)
  return results
end

function M.find_child_by_field(node, field_name)
  if not node then return nil end
  local ok, child = pcall(function() return node:child_by_field_name(field_name) end)
  if ok and child then return child end
  return nil
end

function M.find_child_by_type(node, type_name)
  if not node then return nil end
  local ok, count = pcall(node.named_child_count, node)
  if ok then
    for i = 0, count - 1 do
      local ok2, child = pcall(node.named_child, node, i)
      if ok2 and child then
        local ok3, t = pcall(child.type, child)
        if ok3 and t == type_name then
          return child
        end
      end
    end
  end
  return nil
end

return M