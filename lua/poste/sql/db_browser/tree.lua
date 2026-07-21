local icons = require("poste.sql.db_browser.icons")
local ICONS = icons.ICONS
local DIALECT_ICONS = icons.DIALECT_ICONS
local MARKER_COLLAPSED = icons.MARKER_COLLAPSED
local MARKER_EXPANDED = icons.MARKER_EXPANDED
local MARKER_LOADING = icons.MARKER_LOADING
local HEADER_LINES = icons.HEADER_LINES
local hl_ns = icons.hl_ns

local M = {}

function M.make_connection_node(conn_info)
  return {
    node_type = "connection",
    name = conn_info.name,
    full_name = conn_info.name,
    children = nil,
    expanded = false,
    loading = false,
    meta = {
      dialect = conn_info.dialect,
      host = conn_info.host,
      port = conn_info.port,
      database = conn_info.database,
      path = conn_info.path,
    },
  }
end

function M.make_database_node(item, conn_name, dialect)
  return {
    node_type = "database",
    name = item.name,
    full_name = conn_name .. "/" .. item.name,
    children = nil,
    expanded = false,
    loading = false,
    meta = { dialect = dialect, connection = conn_name },
  }
end

function M.make_schema_node(item, conn_name, database)
  return {
    node_type = "schema",
    name = item.name,
    full_name = conn_name .. "/" .. database .. "/" .. item.name,
    children = nil,
    expanded = false,
    loading = false,
    meta = { database = database, connection = conn_name },
  }
end

function M.make_table_node(item, schema, database, conn_name)
  return {
    node_type = "table",
    name = item.name,
    full_name = (schema and schema .. "." or "") .. item.name,
    children = nil,
    expanded = false,
    loading = false,
    meta = {
      table_type = item.type or "BASE TABLE",
      schema = schema,
      database = database,
      connection = conn_name,
    },
  }
end

function M.make_column_node(item)
  local icon = ICONS.column
  local is_pk = false
  if item.pk or item.key == "PRI" then
    icon = ICONS.column_pk
    is_pk = true
  elseif item.key == "MUL" or item.is_fk then
    icon = ICONS.column_fk
  end

  return {
    node_type = "column",
    name = item.name,
    full_name = item.name,
    children = {},
    expanded = false,
    loading = false,
    meta = {
      col_type = item.type or "?",
      nullable = item.nullable,
      default = item.default,
      extra = item.extra or "",
      comment = item.comment or "",
      is_pk = is_pk,
      icon = icon,
    },
  }
end

function M.make_index_node(item)
  return {
    node_type = "index",
    name = item.name,
    full_name = item.name,
    children = {},
    expanded = false,
    loading = false,
    meta = { definition = item.definition or "" },
  }
end

function M.flatten_tree(nodes, depth)
  depth = depth or 0
  local lines = {}
  local node_map = {}
  local count_ranges = {}

  for _, node in ipairs(nodes) do
    local indent = string.rep("  ", depth)
    local icon = ICONS[node.node_type] or "  "

    if node.node_type == "connection" and node.meta and node.meta.dialect then
      icon = DIALECT_ICONS[node.meta.dialect] or icon
    end
    if node.node_type == "column" and node.meta and node.meta.icon then
      icon = node.meta.icon
    end
    if node.node_type == "key_item" and node.meta and not node.meta.is_pk then
      icon = ICONS.index
    end
    if node.node_type == "index_item" and node.meta and node.meta.is_pk then
      icon = ICONS.column_pk
    end

    local marker
    if node.node_type == "column" or node.node_type == "index"
        or node.node_type == "key_item" or node.node_type == "fk_item"
        or node.node_type == "index_item" then
      marker = "  "
    elseif node.loading then
      marker = MARKER_LOADING .. " "
    elseif node.expanded then
      marker = MARKER_EXPANDED .. " "
    else
      marker = MARKER_COLLAPSED .. " "
    end

    local suffix = ""
    if node.node_type == "column" and node.meta then
      suffix = " " .. (node.meta.col_type or "?")
      if node.meta.is_pk then
        suffix = suffix .. " PK"
      end
      if node.meta.extra and node.meta.extra:lower():find("auto_increment") then
        suffix = suffix .. " auto_increment"
      end
    end

    local type_suffix = ""
    if node.node_type == "table" and node.meta and node.meta.table_type == "VIEW" then
      type_suffix = " (view)"
    end

    local prefix = indent .. marker .. icon .. " " .. node.name .. type_suffix
    local count_text = ""
    if node.children and #node.children > 0 then
      count_text = " " .. #node.children
    end

    local line = prefix .. suffix .. count_text
    table.insert(lines, line)
    table.insert(node_map, node)

    if count_text ~= "" then
      local col_start = #prefix + #suffix
      table.insert(count_ranges, { #lines, col_start, col_start + #count_text })
    end

    if node.expanded and node.children then
      local line_offset = #lines
      local child_lines, child_map, child_ranges = M.flatten_tree(node.children, depth + 1)
      for _, cl in ipairs(child_lines) do table.insert(lines, cl) end
      for _, cn in ipairs(child_map) do table.insert(node_map, cn) end
      for _, cr in ipairs(child_ranges) do
        table.insert(count_ranges, { cr[1] + line_offset, cr[2], cr[3] })
      end
    end
  end

  return lines, node_map, count_ranges
end

local function calc_icon_position(text)
  local first_content = 0
  for ci = 1, #text do
    if text:byte(ci) ~= 0x20 then first_content = ci; break end
  end
  if first_content == 0 then return -1 end

  local first_3 = text:sub(first_content, first_content + 2)
  if first_3 == MARKER_EXPANDED or first_3 == MARKER_COLLAPSED or first_3 == MARKER_LOADING then
    return first_content + 3
  else
    return first_content - 1
  end
end

local icon_hl = {
  connection  = "PosteSqlBrowserIconConn",
  database    = "PosteSqlBrowserIconDb",
  schema      = "PosteSqlBrowserIconSchema",
  table       = "PosteSqlBrowserIconTable",
  column      = "PosteSqlBrowserIconCol",
  index       = "PosteSqlBrowserCount",
  key_group   = "PosteSqlBrowserIconPk",
  fk_group    = "PosteSqlBrowserIconFk",
  index_group = "PosteSqlBrowserCount",
  key_item    = "PosteSqlBrowserCount",
  fk_item     = "PosteSqlBrowserIconFk",
  index_item  = "PosteSqlBrowserCount",
}

function M.apply_highlights(buf, line_count, count_ranges, line_to_node)
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)

  vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteSqlBrowserHeader", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteSqlBrowserSeparator", 1, 0, -1)

  for _, cr in ipairs(count_ranges or {}) do
    local lnum, col_start, col_end = cr[1], cr[2], cr[3]
    vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteSqlBrowserCount",
      lnum + HEADER_LINES - 1, col_start, col_end)
  end

  for i = HEADER_LINES + 1, line_count do
    local node_idx = i - HEADER_LINES
    local node = line_to_node[node_idx]
    if not node then goto continue end

    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""

    local first_content = 0
    for ci = 1, #text do
      if text:byte(ci) ~= 0x20 then first_content = ci; break end
    end
    if first_content == 0 then goto continue end

    local first_3 = text:sub(first_content, first_content + 2)
    local icon_byte_start
    if first_3 == MARKER_EXPANDED or first_3 == MARKER_COLLAPSED or first_3 == MARKER_LOADING then
      icon_byte_start = first_content + 3
    else
      icon_byte_start = first_content - 1
    end

    local icon_hl_group = icon_hl[node.node_type]

    if node.node_type == "column" and node.meta then
      if node.meta.is_pk then
        icon_hl_group = "PosteSqlBrowserIconPk"
      elseif node.meta.icon == ICONS.column_fk then
        icon_hl_group = "PosteSqlBrowserIconFk"
      end
    end
    if node.node_type == "key_item" and node.meta and node.meta.is_pk then
      icon_hl_group = "PosteSqlBrowserIconPk"
    end
    if node.node_type == "fk_item" then
      icon_hl_group = "PosteSqlBrowserIconFk"
    end
    if node.node_type == "index_item" and node.meta then
      icon_hl_group = node.meta.is_pk and "PosteSqlBrowserIconPk" or "PosteSqlBrowserCount"
    end

    local icon_char = text:sub(icon_byte_start + 1)
    local icon_len = 3
    local first_byte = icon_char:byte(1)
    if first_byte and first_byte < 128 then icon_len = 1 end

    if icon_hl_group then
      vim.api.nvim_buf_add_highlight(buf, hl_ns, icon_hl_group,
        i - 1, icon_byte_start, icon_byte_start + icon_len)
    end

    if node.node_type == "index" or node.node_type == "index_item"
        or node.node_type == "key_item" or node.node_type == "fk_item" then
      local text_start = icon_byte_start + icon_len
      if text_start < #text then
        vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteSqlBrowserCount",
          i - 1, text_start, -1)
      end
    end

    if node.node_type == "column" and node.meta then
      local name_pos = text:find(node.name, 1, true)
      if name_pos then
        local name_end = name_pos + #node.name - 1
        local after_name = text:sub(name_end + 1)
        local type_match = after_name:match("^ (%w+)")
        local parens = after_name:match("^ %w+(%([%d,]*%))")
        if type_match then
          local type_end = name_end + 1 + #type_match
          if parens then type_end = type_end + #parens end
          local remaining = text:sub(type_end)
          if remaining:find("^ auto_increment") then
            type_end = type_end + 15
          end
          vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteSqlBrowserType",
            i - 1, name_end, type_end)
        end
      end
    end

    ::continue::
  end
end

local function highlight_footer_keys(buf, line_nr)
  local text = vim.api.nvim_buf_get_lines(buf, line_nr, line_nr + 1, false)[1] or ""
  -- <KEY> patterns
  for s, e in text:gmatch("()<[^>]+>()") do
    vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteSqlBrowserKeyHint", line_nr, s - 1, e - 1)
  end
  -- h/l
  local hls = text:find("h/l", 1, true)
  if hls then
    vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteSqlBrowserKeyHint", line_nr, hls - 1, hls + 2)
  end
  -- Single-char keys: r s d q /
  for i = 1, #text do
    local c = text:sub(i, i)
    if c:match("[rsdq/]") then
      local before = i == 1 and " " or text:sub(i - 1, i - 1)
      local after = i == #text and " " or text:sub(i + 1, i + 1)
      if not before:match("%w") and not after:match("%w") then
        vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteSqlBrowserKeyHint", line_nr, i - 1, i)
      end
    end
  end
end

function M.render_tree(browser_buf, line_to_node, root_nodes, conn_label)
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end

  local lines, node_map, count_ranges = M.flatten_tree(root_nodes)

  local si = _G.poste_search_info
  local title
  if si and si.pattern ~= "" then
    if si.total == 0 then
      title = " Search: " .. si.pattern .. " (0 matches)"
    else
      title = " Search: " .. si.pattern .. " (" .. si.current .. "/" .. si.total .. ")"
    end
  else
    title = " DB Browser [" .. conn_label .. "]"
  end

  local header = {
    title,
    string.rep("─", 40),
    "",
  }
  for _, line in ipairs(lines) do
    table.insert(header, line)
  end

  if #lines == 0 then
    table.insert(header, "  (no connections found)")
    table.insert(header, "  need: connections.json")
  else
    table.insert(header, "")
    table.insert(header, " <CR> open     h/l nav")
    table.insert(header, " r reload     s SELECT")
    table.insert(header, " / find       q close")
    table.insert(header, " n next       N prev")
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = browser_buf })
  vim.api.nvim_buf_set_lines(browser_buf, 0, -1, false, header)
  vim.api.nvim_set_option_value("modifiable", false, { buf = browser_buf })

  M.apply_highlights(browser_buf, #header, count_ranges, node_map)

  -- Highlight key hints in footer lines with green bold
  if #lines > 0 then
    highlight_footer_keys(browser_buf, #header - 4)
    highlight_footer_keys(browser_buf, #header - 3)
    highlight_footer_keys(browser_buf, #header - 2)
    highlight_footer_keys(browser_buf, #header - 1)
  end

  return node_map
end

function M.get_node_at_line(line_to_node, buf_line)
  local idx = buf_line - HEADER_LINES
  if idx < 1 or idx > #line_to_node then return nil end
  return line_to_node[idx]
end

function M.calc_icon_position(text)
  return calc_icon_position(text)
end

return M