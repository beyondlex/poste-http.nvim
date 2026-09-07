local state = require("poste-http.state")
local block_boundary = require("poste-http.http.block_boundary")

local M = {}

local function get_node_text(node, source)
  local ok, sr, sc, er, ec = pcall(node.range, node)
  if not ok then return "" end
  local lines = vim.split(source, "\n", { plain = true })
  -- A node range past the source (stale/partial parse) would index nil.
  if sr < 0 or er >= #lines or er < sr then return "" end
  if sr == er then
    return lines[sr + 1]:sub(sc + 1, ec)
  end
  local parts = { lines[sr + 1]:sub(sc + 1) }
  for i = sr + 2, er do
    table.insert(parts, lines[i])
  end
  parts[#parts + 1] = lines[er + 1]:sub(1, ec)
  return table.concat(parts, "\n")
end

local function get_children_by_type(node, type_name)
  local results = {}
  for child in node:iter_children() do
    if child:type() == type_name then
      table.insert(results, child)
    end
  end
  return results
end

--- Line-based body assembly: every non-excluded line from body_start to
--- end_line. Used when the grammar's body nodes don't cover the body's
--- first line (e.g. GRAPHQL query text precedes the variables JSON).
local function assemble_line_body(block, body_start, end_line, lines)
  local parts = {}
  for i = body_start, end_line do
    if not block._non_body_lines[i] then
      table.insert(parts, lines[i])
    end
  end
  return table.concat(parts, "\n")
end

local function describe_via_treesitter(content)
  if not content or content == "" then
    return {}, nil
  end

  local ok, parser = pcall(vim.treesitter.get_string_parser, content, "poste_http")
  if not ok or not parser then
    return nil, "tree-sitter parser not available"
  end

  local trees = parser:parse()
  if not trees or #trees == 0 then
    return nil, "tree-sitter parse returned empty tree"
  end

  local root = trees[1]:root()
  local lines = vim.split(content, "\n", { plain = true })
  local line_count = #lines

  local blocks = {}
  local current_block = nil
  local block_count = 0

  local function finalize_block()
    if not current_block then return end
    local end_line, last_content = block_boundary.compute_block_range(lines, current_block._line)
    current_block.end_line = end_line

    -- Mirror cache.lua's last_content_line so trailing comments / separators
    -- after a request body are not part of the block range.
    current_block.last_content_line = last_content

    -- Track trailing comment lines so block_at_line can still resolve a cursor
    -- sitting on a comment below the request body (see cache.get_block_at_line).
    -- Without this, describe and cache would disagree on such lines.
    current_block.comment_lines = {}
    for i = last_content + 1, end_line do
      if block_boundary.is_comment(lines[i]) then
        current_block.comment_lines[i] = true
      end
    end

    current_block.body = ""
    if current_block._body_parts and #current_block._body_parts > 0 then
      local body_start = (current_block._last_header_row or current_block._request_line_row or -1) + 1
      while body_start <= end_line do
        local line = lines[body_start]
        if line and line:match("%S") then
          break
        end
        body_start = body_start + 1
      end

      if current_block._body_parts[1].start_row == body_start then
        -- The grammar covered the body from its first line. Multiple
        -- segments (an anonymous GRAPHQL query plus its variables block)
        -- are joined with the blank line that separated them.
        local texts = {}
        for _, part in ipairs(current_block._body_parts) do
          table.insert(texts, part.text)
        end
        current_block.body = table.concat(texts, "\n\n")
      else
        -- Content precedes the first body node (a GRAPHQL query text):
        -- fall back to line-based assembly so nothing is dropped.
        current_block.body = assemble_line_body(current_block, body_start, end_line, lines)
      end
    elseif current_block._request_line_row then
      local body_start = (current_block._last_header_row or current_block._request_line_row) + 1
      while body_start <= end_line do
        local line = lines[body_start]
        if line and line:match("%S") then
          break
        end
        body_start = body_start + 1
      end
      if body_start <= end_line then
        local first_line = lines[body_start]
        if first_line and not current_block._non_body_lines[body_start] then
          current_block.body = assemble_line_body(current_block, body_start, end_line, lines)
        end
      end
    end
    current_block._line = nil
    current_block._request_line_row = nil
    current_block._last_header_row = nil
    current_block._body_parts = nil
    current_block._non_body_lines = nil
    table.insert(blocks, current_block)
    current_block = nil
  end

  for child in root:iter_children() do
    local type = child:type()
    local sr, sc, er, ec = child:range()
    local line_num = sr + 1

    if type == "request_block" then
      finalize_block()
      block_count = block_count + 1
      local name_nodes = get_children_by_type(child, "request_name")
      local name = ""
      if #name_nodes > 0 then
        name = get_node_text(name_nodes[1], content)
      end
      current_block = {
        name = vim.trim(name),
        line = line_num,
        end_line = line_count,
        method = "",
        path = "",
        headers = {},
        body = "",
        request_line = "",
        _line = line_num,
        _request_line_row = nil,
        _last_header_row = nil,
        _body_parts = {},
        _non_body_lines = {},
      }
    elseif type == "request_line" then
      if current_block then
        local text = get_node_text(child, content)
        current_block.request_line = vim.trim(text)
        local method = text:match("^(%S+)")
        local path = text:match("^%S+%s+(%S+)")
        current_block.method = vim.trim(method or "")
        current_block.path = vim.trim(path or "")
        current_block._request_line_row = line_num
      end
    elseif type == "header" then
      if current_block then
        local key = ""
        local value = ""
        for gc in child:iter_children() do
          local gt = gc:type()
          if gt == "header_key" then
            key = get_node_text(gc, content) or ""
          elseif gt == "header_value" then
            value = get_node_text(gc, content) or ""
          end
        end
        table.insert(current_block.headers, { vim.trim(key), vim.trim(value) })
        current_block._last_header_row = line_num
      end
    elseif type == "json_body" or type == "form_body" or type == "graphql_body" then
      if current_block then
        -- Collect every body node in order; finalize_block decides between
        -- node texts and line-based assembly (see the GRAPHQL case).
        table.insert(current_block._body_parts, {
          start_row = line_num,
          text = get_node_text(child, content),
        })
      end
    elseif type == "external_assertion" or type == "external_script" or type == "file_upload" or type == "comment" or type == "pre_script" or type == "post_script" then
      if current_block then
        for l = sr + 1, er + 1 do
          current_block._non_body_lines[l] = true
        end
      end
    end
  end

  finalize_block()

  if #blocks == 0 and line_count > 0 then
    local first_content = 1
    for i, l in ipairs(lines) do
      if l:match("%S") then
        first_content = i
        break
      end
    end
    local end_line, last_content = block_boundary.compute_block_range(lines, first_content)
    local comment_lines = {}
    for i = last_content + 1, end_line do
      if block_boundary.is_comment(lines[i]) then
        comment_lines[i] = true
      end
    end
    table.insert(blocks, {
      name = "",
      line = first_content,
      end_line = end_line,
      last_content_line = last_content,
      comment_lines = comment_lines,
      method = "",
      path = "",
      headers = {},
      body = table.concat(lines, "\n", first_content, end_line),
      request_line = "",
    })
  end

  return blocks, nil
end

function M.describe_content(content, file, opts)
  opts = opts or {}
  if not content or content == "" then
    return {}, nil
  end
  if not file or file == "" then
    file = "untitled.http"
  end

  local blocks, err = describe_via_treesitter(content)
  if blocks then
    return blocks, nil
  end

  state.log("WARN", "tree-sitter describe unavailable: " .. tostring(err))
  return {}, nil
end

function M.block_at_line(blocks, line)
  if not blocks or not line then return nil end
  -- A line belongs to a block within its content range (up to
  -- last_content_line) OR on a trailing comment line after the request body.
  -- Blank separator lines belong to no block — same rule as cache.get_block_at_line.
  for _, b in ipairs(blocks) do
    local start_l = b.line or 0
    local end_l = b.last_content_line or (b.end_line or start_l)
    if line >= start_l and line <= end_l then
      return b
    end
    if line > end_l then
      local b_end = b.end_line or end_l
      if line <= b_end and b.comment_lines and b.comment_lines[line] then
        return b
      end
    end
  end
  return nil
end

function M.to_req_block(meta)
  if not meta then
    return { request_line = "", headers = {}, name = "", method = "", path = "", body = "" }
  end
  local headers = meta.headers or {}
  return {
    request_line = meta.request_line or "",
    headers = headers,
    name = meta.name or "",
    method = meta.method or "",
    path = meta.path or "",
    body = meta.body or "",
  }
end

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