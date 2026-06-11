--- Context menu for DB Browser nodes.
--- Single trigger (x) → floating menu with letter-shortcut actions.
--- Dispatches to operations module.
local state = require("poste.state")
local tree = require("poste.sql.db_browser.tree")
local operations = require("poste.sql.db_browser.operations")

local M = {}

-- Menu items per node type.
-- Each: { letter, label, action, group }
-- group: "query" | "generate" | "modify" | "danger"
local MENU_DEFS = {
  connection = {
    { letter = "r", label = "Refresh All",         action = "refresh",    group = "query" },
    { letter = "e", label = "Edit Connection",     action = "edit_conn",  group = "modify" },
    { letter = "c", label = "Copy Name",           action = "copy_name",  group = "query" },
  },
  database = {
    { letter = "q", label = "New Query",           action = "new_query",   group = "query" },
    { letter = "r", label = "Refresh",             action = "refresh",     group = "query" },
    { letter = "s", label = "Set as Default",      action = "set_default", group = "query" },
    { letter = "c", label = "Copy Name",           action = "copy_name",   group = "query" },
    { letter = "t", label = "New Table",           action = "new_table",   group = "modify" },
  },
  schema = {
    { letter = "s", label = "Set as Default",      action = "set_default", group = "query" },
    { letter = "r", label = "Refresh",             action = "refresh",     group = "query" },
    { letter = "c", label = "Copy Name",           action = "copy_name",   group = "query" },
    { letter = "t", label = "New Table",           action = "new_table",   group = "modify" },
  },
  table = {
    { letter = "s", label = "SELECT * LIMIT 100",  action = "select_star",      group = "query" },
    { letter = "D", label = "Show DDL",            action = "show_ddl",         group = "query" },
    { letter = "c", label = "Copy Name",           action = "copy_name",        group = "query" },
    { letter = "i", label = "INSERT template",     action = "insert_template",  group = "generate" },
    { letter = "u", label = "UPDATE template",     action = "update_template",  group = "generate" },
    { letter = "d", label = "DELETE template",     action = "delete_template",  group = "generate" },
    { letter = "n", label = "New Column",          action = "new_column",       group = "modify" },
    { letter = "r", label = "Rename Table",        action = "rename",           group = "modify" },
  },
  view = {
    { letter = "s", label = "SELECT *",            action = "select_star", group = "query" },
    { letter = "D", label = "Show DDL",            action = "show_ddl",    group = "query" },
    { letter = "c", label = "Copy Name",           action = "copy_name",   group = "query" },
  },
  column = {
    { letter = "y", label = "Yank Name",           action = "copy_name",  group = "query" },
    { letter = "r", label = "Rename Column",       action = "rename",     group = "modify" },
    { letter = "m", label = "Modify Column",       action = "modify_col", group = "modify" },
  },
  key_item = {
    { letter = "y", label = "Yank Name",           action = "copy_name",  group = "query" },
  },
  fk_item = {
    { letter = "y", label = "Yank Name",           action = "copy_name",  group = "query" },
  },
  index = {
    { letter = "D", label = "Show DDL",            action = "show_ddl",   group = "query" },
  },
  index_item = {
    { letter = "y", label = "Yank Name",           action = "copy_name",  group = "query" },
  },
}

local GROUP_NAMES = {
  query = "Query",
  generate = "Generate",
  modify = "Modify",
  danger = "Danger",
}

local DANGER_GROUPS = { danger = true }

local ns_floating = vim.api.nvim_create_namespace("poste_db_context_menu")

--- Build display lines for a menu.
--- Returns { lines, item_map } where item_map[i] = { letter, action, node, context }
local function build_menu_lines(node, context)
  local defs = MENU_DEFS[node.node_type]
  if not defs or #defs == 0 then return nil end

  local max_label = 0
  for _, item in ipairs(defs) do
    max_label = math.max(max_label, #item.label)
  end
  local width = math.max(#("  [x] " .. node.name) + 8, #("  [x] " .. string.rep("X", max_label)) + 4)
  local title = node.node_type:sub(1, 1):upper() .. node.node_type:sub(2) .. ": " .. node.name
  width = math.max(width, #title + 4)
  local title_pad = width - #title - 2

  local lines = {}
  local item_map = {}

  table.insert(lines, "┌ " .. title .. " " .. string.rep("─", title_pad) .. "┐")
  table.insert(lines, "")

  local last_group = nil
  for _, item in ipairs(defs) do
    if item.group ~= last_group then
      if last_group then table.insert(lines, "") end
      local gname = GROUP_NAMES[item.group] or item.group
      table.insert(lines, "  " .. gname)
      last_group = item.group
    end
    local display = "  [" .. item.letter .. "] " .. item.label
    table.insert(lines, display)
    item_map[#lines] = { letter = item.letter, action = item.action, node = node, context = context }
  end

  table.insert(lines, "")
  table.insert(lines, "└" .. string.rep("─", width) .. "┘")

  return lines, item_map
end

--- Find item_map entry by letter (case-insensitive).
local function find_by_letter(item_map, letter)
  letter = letter:lower()
  for _, entry in pairs(item_map) do
    if entry.letter:lower() == letter then return entry end
  end
  return nil
end

--- Open the context menu for a node.
--- @param node table The node from tree.get_node_at_line
--- @param context table The browser context from make_context()
function M.open(node, context)
  if not node then return end

  local lines, item_map = build_menu_lines(node, context)
  if not lines then return end

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.max(width, 24)
  local height = #lines

  local row = vim.fn.winline() - 1
  local col = vim.fn.wincol() + 2
  if row + height > vim.o.lines then
    row = math.max(0, vim.o.lines - height - 2)
  end
  if col + width > vim.o.columns then
    col = math.max(0, vim.o.columns - width - 2)
  end

  local menu_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(menu_buf, 0, -1, false, lines)
  vim.bo[menu_buf].modifiable = false

  local win_opts = {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "none",
  }
  local ok, menu_win = pcall(vim.api.nvim_open_win, menu_buf, true, win_opts)
  if not ok then return end

  vim.wo[menu_win].cursorline = true
  vim.wo[menu_win].winhl = "Normal:NormalFloat"

  -- Highlight group labels
  for i, line in ipairs(lines) do
    for gname, label in pairs(GROUP_NAMES) do
      if line == "  " .. label then
        vim.api.nvim_buf_add_highlight(menu_buf, ns_floating,
          DANGER_GROUPS[gname] and "DiagnosticError" or "Comment", i - 1, 0, -1)
        break
      end
    end
  end

  -- Position cursor on first actionable item
  for i = 1, #lines do
    if item_map[i] then
      vim.api.nvim_win_set_cursor(menu_win, { i, 0 })
      break
    end
  end

  local closed = false

  local function close()
    if closed then return end
    closed = true
    if menu_win and vim.api.nvim_win_is_valid(menu_win) then
      vim.api.nvim_win_close(menu_win, true)
    end
  end

  local function execute_item(map_entry)
    if not map_entry then return end
    local op = operations[map_entry.action]
    if not op then
      vim.notify("Unknown action: " .. tostring(map_entry.action), vim.log.levels.WARN)
      return
    end
    close()
    vim.schedule(function() op(map_entry.node, map_entry.context) end)
  end

  local km_opts = { buffer = menu_buf, noremap = true, silent = true, nowait = true }

  vim.keymap.set("n", "j", function()
    local cursor = vim.api.nvim_win_get_cursor(menu_win)
    local next_line = cursor[1] + 1
    while next_line <= #lines do
      if item_map[next_line] then
        vim.api.nvim_win_set_cursor(menu_win, { next_line, 0 })
        return
      end
      next_line = next_line + 1
    end
  end, km_opts)

  vim.keymap.set("n", "k", function()
    local cursor = vim.api.nvim_win_get_cursor(menu_win)
    local prev_line = cursor[1] - 1
    while prev_line >= 1 do
      if item_map[prev_line] then
        vim.api.nvim_win_set_cursor(menu_win, { prev_line, 0 })
        return
      end
      prev_line = prev_line - 1
    end
  end, km_opts)

  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(menu_win)
    execute_item(item_map[cursor[1]])
  end, km_opts)

  vim.keymap.set("n", "q", close, km_opts)
  vim.keymap.set("n", "<Esc>", close, km_opts)

  -- Letter shortcuts: one key per menu item
  for _, item in ipairs(MENU_DEFS[node.node_type] or {}) do
    vim.keymap.set("n", item.letter, function()
      execute_item(find_by_letter(item_map, item.letter))
    end, km_opts)
    if item.letter ~= item.letter:lower() then
      vim.keymap.set("n", item.letter:lower(), function()
        execute_item(find_by_letter(item_map, item.letter:lower()))
      end, km_opts)
    end
  end
end

return M
