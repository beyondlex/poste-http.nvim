--- Table operations UI — triggered from DB Browser or SQL file.
--- Generates DDL SQL and inserts it into the source buffer for review/execution.
--- Keymaps registered on the DB Browser buffer: ma/mr/md/mt
local state = require("poste.state")

local M = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Insert DDL lines into the source buffer and notify.
local function insert_ddl(source_buf, ddl, label)
  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
    vim.notify("No source SQL buffer", vim.log.levels.WARN)
    return
  end

  local lines = {
    "",
    "### " .. label,
    ddl,
    "",
  }

  local line_count = vim.api.nvim_buf_line_count(source_buf)
  vim.api.nvim_buf_set_lines(source_buf, line_count, line_count, false, lines)

  -- Move cursor to the ### line in source buf
  local target_win = vim.fn.bufwinid(source_buf)
  if target_win and target_win ~= -1 then
    vim.api.nvim_set_current_win(target_win)
    vim.api.nvim_win_set_cursor(target_win, { line_count + 2, 0 })
  end

  vim.notify("DDL inserted — review and execute with <leader>rr", vim.log.levels.INFO)
end

--- Quote an identifier based on dialect.
local function quote(name, dialect)
  if dialect == "mysql" then
    return "`" .. name:gsub("`", "``") .. "`"
  else
    return '"' .. name:gsub('"', '""') .. '"'
  end
end

---------------------------------------------------------------------------
-- DDL generation (pure Lua — no CLI round-trip needed for simple DDL)
---------------------------------------------------------------------------

--- Generate ADD COLUMN DDL.
local function gen_add_column(table_name, col_name, col_type, nullable, default_val, dialect)
  local q = function(n) return quote(n, dialect) end
  local sql = string.format("ALTER TABLE %s ADD COLUMN %s %s", q(table_name), q(col_name), col_type)
  if not nullable then
    sql = sql .. " NOT NULL"
  end
  if default_val and default_val ~= "" then
    sql = sql .. " DEFAULT " .. default_val
  end
  return sql .. ";"
end

--- Generate RENAME COLUMN DDL.
local function gen_rename_column(table_name, old_name, new_name, dialect)
  local q = function(n) return quote(n, dialect) end
  return string.format(
    "ALTER TABLE %s RENAME COLUMN %s TO %s;",
    q(table_name), q(old_name), q(new_name)
  )
end

--- Generate DROP COLUMN DDL.
local function gen_drop_column(table_name, col_name, dialect)
  local q = function(n) return quote(n, dialect) end
  return string.format("ALTER TABLE %s DROP COLUMN %s;", q(table_name), q(col_name))
end

--- Generate ALTER COLUMN TYPE DDL.
local function gen_alter_type(table_name, col_name, new_type, dialect)
  local q = function(n) return quote(n, dialect) end
  if dialect == "mysql" then
    return string.format("ALTER TABLE %s MODIFY COLUMN %s %s;", q(table_name), q(col_name), new_type)
  elseif dialect == "sqlite" then
    return string.format(
      "-- SQLite does not support ALTER COLUMN TYPE directly.\n"
      .. "-- Recreate %s to change %s to %s.",
      table_name, col_name, new_type
    )
  else
    return string.format(
      "ALTER TABLE %s ALTER COLUMN %s TYPE %s;",
      q(table_name), q(col_name), new_type
    )
  end
end

---------------------------------------------------------------------------
-- Interactive prompts
---------------------------------------------------------------------------

--- Prompt sequence for adding a column.
--- @param table_name string
--- @param dialect string
--- @param source_buf number
local function prompt_add_column(table_name, dialect, source_buf)
  vim.ui.input({ prompt = "Column name: " }, function(col_name)
    if not col_name or col_name == "" then return end
    vim.ui.input({ prompt = "Column type (e.g. TEXT, INT): " }, function(col_type)
      if not col_type or col_type == "" then return end
      vim.ui.input({ prompt = "Nullable? [y/N]: " }, function(nullable_ans)
        local nullable = nullable_ans and nullable_ans:lower() == "y"
        vim.ui.input({ prompt = "Default value (leave blank for none): " }, function(default_val)
          local ddl = gen_add_column(table_name, col_name, col_type, nullable, default_val, dialect)
          insert_ddl(source_buf, ddl, "Add column: " .. table_name .. "." .. col_name)
        end)
      end)
    end)
  end)
end

--- Prompt sequence for renaming a column.
local function prompt_rename_column(table_name, dialect, source_buf)
  vim.ui.input({ prompt = "Current column name: " }, function(old_name)
    if not old_name or old_name == "" then return end
    vim.ui.input({ prompt = "New column name: " }, function(new_name)
      if not new_name or new_name == "" then return end
      local ddl = gen_rename_column(table_name, old_name, new_name, dialect)
      insert_ddl(source_buf, ddl, "Rename column: " .. table_name .. "." .. old_name .. " → " .. new_name)
    end)
  end)
end

--- Prompt sequence for dropping a column.
local function prompt_drop_column(table_name, dialect, source_buf)
  vim.ui.input({ prompt = "Column name to drop: " }, function(col_name)
    if not col_name or col_name == "" then return end
    vim.ui.input({ prompt = "Confirm drop '" .. col_name .. "'? [y/N]: " }, function(ans)
      if not ans or ans:lower() ~= "y" then
        vim.notify("Cancelled", vim.log.levels.INFO)
        return
      end
      local ddl = gen_drop_column(table_name, col_name, dialect)
      insert_ddl(source_buf, ddl, "Drop column: " .. table_name .. "." .. col_name)
    end)
  end)
end

--- Prompt sequence for altering a column type.
local function prompt_alter_type(table_name, dialect, source_buf)
  vim.ui.input({ prompt = "Column name: " }, function(col_name)
    if not col_name or col_name == "" then return end
    vim.ui.input({ prompt = "New type: " }, function(new_type)
      if not new_type or new_type == "" then return end
      local ddl = gen_alter_type(table_name, col_name, new_type, dialect)
      insert_ddl(source_buf, ddl, "Alter type: " .. table_name .. "." .. col_name .. " → " .. new_type)
    end)
  end)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Add a column to the table at the current browser position.
--- @param table_name string
--- @param dialect string "postgres"|"mysql"|"sqlite"
--- @param source_buf number Buffer handle of the SQL source file
function M.add_column(table_name, dialect, source_buf)
  prompt_add_column(table_name, dialect or "postgres", source_buf)
end

--- Rename a column.
function M.rename_column(table_name, dialect, source_buf)
  prompt_rename_column(table_name, dialect or "postgres", source_buf)
end

--- Drop a column.
function M.drop_column(table_name, dialect, source_buf)
  prompt_drop_column(table_name, dialect or "postgres", source_buf)
end

--- Alter a column's type.
function M.alter_type(table_name, dialect, source_buf)
  prompt_alter_type(table_name, dialect or "postgres", source_buf)
end

--- Register table_ops keymaps onto the DB browser buffer.
--- Called by db_browser.lua after the browser buffer is created.
--- @param browser_buf number
--- @param get_table_context function() -> {table_name, dialect, source_buf}
function M.register_keymaps(browser_buf, get_table_context)
  local opts = { buffer = browser_buf, noremap = true, silent = true }

  local k = state.get_keymap("sql_table_ops", "select_all", "ma")
  if k then
    vim.keymap.set("n", k, function()
      local ctx = get_table_context()
      if ctx then M.add_column(ctx.table_name, ctx.dialect, ctx.source_buf) end
    end, vim.tbl_extend("force", opts, { desc = "Add column" }))
  end

  k = state.get_keymap("sql_table_ops", "refresh_all", "mr")
  if k then
    vim.keymap.set("n", k, function()
      local ctx = get_table_context()
      if ctx then M.rename_column(ctx.table_name, ctx.dialect, ctx.source_buf) end
    end, vim.tbl_extend("force", opts, { desc = "Rename column" }))
  end

  k = state.get_keymap("sql_table_ops", "describe_all", "md")
  if k then
    vim.keymap.set("n", k, function()
      local ctx = get_table_context()
      if ctx then M.drop_column(ctx.table_name, ctx.dialect, ctx.source_buf) end
    end, vim.tbl_extend("force", opts, { desc = "Drop column" }))
  end

  k = state.get_keymap("sql_table_ops", "toggle_menu", "mt")
  if k then
    vim.keymap.set("n", k, function()
      local ctx = get_table_context()
      if ctx then M.alter_type(ctx.table_name, ctx.dialect, ctx.source_buf) end
    end, vim.tbl_extend("force", opts, { desc = "Alter column type" }))
  end
end

return M
