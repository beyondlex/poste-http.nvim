--- Row navigation and interactive cell editing (vim.ui dependent).
--- Handles cursor movement, cell editing dialogs, row ops.

local cell = require("poste.sql.editor.cell")

local M = {}

local D = nil
local function get_dataset()
  if not D then D = require("poste.sql.dataset") end
  return D
end

local state = nil
local function get_state()
  if not state then state = require("poste.state") end
  return state
end

local function check_edit_guards(tab)
  if not tab or not tab.layout then return false end
  if get_state().sql._raw_mode then
    vim.notify("Editing is not supported in raw mode", vim.log.levels.WARN)
    return false
  end
  if tab.layout.rows and #tab.layout.rows > 5000 then
    vim.notify("Editing is not supported for result sets > 5000 rows", vim.log.levels.WARN)
    return false
  end
  if tab.original_sql and cell.has_join(tab.original_sql) then
    vim.notify("Editing is not supported for multi-table (JOIN) queries", vim.log.levels.WARN)
    return false
  end
  local column = require("poste.sql.editor.column")
  column.ensure_primary_key(tab)
  return true
end

---------------------------------------------------------------------------
-- Editable row check
---------------------------------------------------------------------------

--- Check if a row index is a data row (not header/border).
--- @param tab table Tab state
--- @param row_idx number 1-based buffer line index
--- @return boolean
function M.is_data_row(tab, row_idx)
  if not tab or not tab.meta then return false end
  local meta = tab.meta
  if meta.type ~= "resultset" then return false end
  if not meta.row_count then return false end
  return row_idx >= 1 and row_idx <= meta.row_count
end

---------------------------------------------------------------------------
-- Interactive edit functions (vim.ui dependent)
---------------------------------------------------------------------------

local function ensure_edit_state(tab)
  if not tab.edit_state then
    tab.edit_state = cell.create_edit_state()
  end
  return tab.edit_state
end

local function apply_cell_edit(row_idx, col_idx, new_val)
  local tab = get_dataset().T()
  if not tab or not tab.layout then return end

  local es = ensure_edit_state(tab)
  local row_key = tostring(row_idx) .. ":" .. tostring(col_idx)

  -- Check if this row is an added row — update data directly, no modified_cell entry
  local is_added = false
  for _, added in ipairs(es.added_rows) do
    if added.row_idx == row_idx then
      is_added = true
      break
    end
  end

  if is_added then
    tab.layout.rows[row_idx][col_idx] = new_val
    es.dirty = #es.added_rows > 0
  else
    local existing = es.modified_cells[row_key]
    local old_val = existing and existing.old_val or tab.layout.rows[row_idx][col_idx]
    cell.track_cell_edit(es, row_key, col_idx, old_val, new_val)
    tab.layout.rows[row_idx][col_idx] = new_val
  end

  -- Also update rows_source so refresh_page shows the edit
  if tab.rows_source and tab.rows_source[row_idx] then
    tab.rows_source[row_idx][col_idx] = new_val
  end

  -- Clear any previous error for this cell
  cell.clear_cell_error(es, row_key)

  -- Re-render the buffer line
  local buf = get_dataset().dataset_buffer
  if buf and vim.api.nvim_buf_is_valid(buf) and tab.padded and tab.meta then
    local meta = tab.meta
    if meta.data_start_line then
      local line_idx = meta.data_start_line + row_idx - 1
      local fmt = require("poste.sql.format")
      local row = tab.rows_source and tab.rows_source[row_idx] or tab.layout.rows[row_idx]
      if row then
        local new_line = fmt.render_row(row, tab.layout, #tostring(row_idx))
        if new_line then
          -- Update padded table
          if tab.padded[line_idx] then
            tab.padded[line_idx] = "  " .. new_line
          end
          vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
          vim.api.nvim_buf_set_lines(buf, line_idx - 1, line_idx, false, { "  " .. new_line })
          vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
          local sql_highlights = require("poste.sql.highlights")
          sql_highlights.invalidate_sep_cache()
          sql_highlights.apply_edit_highlights(buf, tab)
        end
      end
    end
  end

  -- Update winbar
  if tab.edit_state.dirty then
    local winbar_base = require("poste.sql.buffer_nav").build_status_winbar(tab.meta)
    if get_dataset().dataset_window and vim.api.nvim_win_is_valid(get_dataset().dataset_window) then
      pcall(vim.api.nvim_set_option_value, "winbar", winbar_base or "", { win = get_dataset().dataset_window })
    end
  end
end

function M.detect_cell_type(col_meta)
  if cell.is_boolean_column(col_meta) then return "boolean" end
  if cell.is_datetime_column(col_meta) then return "datetime" end
  if cell.is_enum_column(col_meta) then return "enum" end
  return "text"
end

local cell_editors = {}

function cell_editors.boolean(row_idx, col_idx, col_meta, old_val)
  local choices = { "(NULL)", "true", "false" }
  vim.ui.select(choices, {
    prompt = col_meta.name or "value",
    format_item = function(item) return item end,
  }, function(choice)
    if not choice then return end
    local new_val
    if choice == "(NULL)" then
      new_val = vim.NIL
    elseif choice == "true" then
      new_val = true
    else
      new_val = false
    end
    apply_cell_edit(row_idx, col_idx, new_val)
  end)
end

function cell_editors.datetime(row_idx, col_idx, col_meta, old_val)
  local choices
  if col_meta.ctype == "date" then
    choices = { "(NULL)", os.date("%Y-%m-%d") }
  elseif col_meta.ctype == "time" then
    choices = { "(NULL)", os.date("%H:%M:%S") }
  else
    choices = { "(NULL)", os.date("%Y-%m-%d %H:%M:%S"), "CURRENT_TIMESTAMP" }
  end
  table.insert(choices, "Custom…")
  vim.ui.select(choices, {
    prompt = (col_meta.name or "value") .. " (" .. (col_meta.ctype or "") .. ")",
    format_item = function(item) return item end,
  }, function(choice)
    if not choice or choice == "(NULL)" then
      if choice == "(NULL)" then
        apply_cell_edit(row_idx, col_idx, vim.NIL)
      end
      return
    end
    if choice == "Custom…" then
      vim.ui.input({
        prompt = (col_meta.name or "value") .. ": ",
        default = os.date(col_meta.ctype == "date" and "%Y-%m-%d" or "%Y-%m-%d %H:%M:%S"),
      }, function(input)
        if not input then return end
        apply_cell_edit(row_idx, col_idx, input)
      end)
      return
    end
    if choice == "CURRENT_TIMESTAMP" then
      apply_cell_edit(row_idx, col_idx, "__expr:CURRENT_TIMESTAMP")
    else
      apply_cell_edit(row_idx, col_idx, choice)
    end
  end)
end

function cell_editors.enum(row_idx, col_idx, col_meta, old_val)
  local choices = {}
  local current_value = (old_val ~= nil and old_val ~= vim.NIL) and tostring(old_val) or nil
  for _, v in ipairs(col_meta.enum_values) do
    local display = v
    if current_value and v == current_value then
      display = v .. " (current)"
      table.insert(choices, 1, { value = v, display = display })
    else
      table.insert(choices, { value = v, display = display })
    end
  end
  if col_meta.default then
    table.insert(choices, { value = nil, display = "<default>" })
  end
  table.insert(choices, { value = vim.NIL, display = "(NULL)" })
  vim.ui.select(choices, {
    prompt = (col_meta.name or "value") .. "  (i=insert, ENTER=confirm)",
    format_item = function(item) return item.display end,
  }, function(choice)
    if not choice then return end
    apply_cell_edit(row_idx, col_idx, choice.value)
  end)
end

function cell_editors.text(row_idx, col_idx, col_meta, old_val)
  local initial_text
  if cell.is_json_column(col_meta) and type(old_val) == "table" then
    initial_text = cell.format_json_input(old_val)
  else
    initial_text = (old_val == nil or old_val == vim.NIL) and "" or tostring(old_val)
  end
  if not initial_text or initial_text == "" then
    if type(old_val) == "string" then
      local expr = old_val:match("^__expr:(.*)$")
      if expr then initial_text = expr end
    end
  end
  vim.ui.input({
    prompt = (col_meta.name or "value") .. ": ",
    default = initial_text,
  }, function(input)
    if input == nil then return end
    local new_val = cell.parse_value(input, old_val)
    if new_val == nil then return end
    local ok, err = cell.validate_value(new_val, col_meta)
    if not ok then
      local tab = get_dataset().T()
      if tab then
        local es = ensure_edit_state(tab)
        local row_key = tostring(row_idx) .. ":" .. tostring(col_idx)
        cell.set_cell_error(es, row_key, err)
        vim.notify("Validation error: " .. err, vim.log.levels.ERROR)
      end
      return
    end
    local tab = get_dataset().T()
    if tab then
      local es = ensure_edit_state(tab)
      local row_key = tostring(row_idx) .. ":" .. tostring(col_idx)
      cell.clear_cell_error(es, row_key)
    end
    apply_cell_edit(row_idx, col_idx, new_val)
  end)
end

--- Edit the current cell via floating input.
function M.edit_cell()
  local tab = get_dataset().T()
  if not check_edit_guards(tab) then return end

  local state = get_state()
  local row_idx = state.sql.cell.row
  local col_idx = state.sql.cell.col
  local col_meta = tab.layout.columns[col_idx]

  if not M.is_data_row(tab, row_idx) then return end

  if not cell.is_editable_field(col_meta) then
    vim.notify("Cannot edit " .. (col_meta.ctype or "unknown") .. " field", vim.log.levels.WARN)
    return
  end

  local old_val = tab.layout.rows[row_idx][col_idx]
  local handler = cell_editors[M.detect_cell_type(col_meta)]
  handler(row_idx, col_idx, col_meta, old_val)
end

--- Delete the current row.
function M.delete_row()
  local tab = get_dataset().T()
  if not check_edit_guards(tab) then return end

  local state = get_state()
  local row_idx = state.sql.cell.row

  if not M.is_data_row(tab, row_idx) then return end

  local es = ensure_edit_state(tab)
  cell.track_row_delete(es, row_idx)

  -- Visual feedback: strikethrough the line
  local buf = get_dataset().dataset_buffer
  if buf and vim.api.nvim_buf_is_valid(buf) and tab.padded then
    local sql_highlights = require("poste.sql.highlights")
    sql_highlights.apply_edit_highlights(buf, tab)
  end

  -- Update winbar
  local winbar_base = require("poste.sql.buffer_nav").build_status_winbar(tab.meta)
  if get_dataset().dataset_window and vim.api.nvim_win_is_valid(get_dataset().dataset_window) then
    pcall(vim.api.nvim_set_option_value, "winbar", winbar_base or "", { win = get_dataset().dataset_window })
  end
end

--- Insert a new row at the end of the table.
function M.insert_row()
  local tab = get_dataset().T()
  if not check_edit_guards(tab) then return end

  local es = ensure_edit_state(tab)
  local num_cols = #tab.layout.columns
  local row_data = {}
  for i = 1, num_cols do
    local col_meta = tab.layout.columns[i]
    if col_meta.primary_key and col_meta.ctype and cell.is_integer_type(col_meta.ctype) then
      row_data[i] = "[Auto]"
    else
      row_data[i] = nil
    end
  end

  -- Append to layout rows and track in edit_state
  local new_row_idx = #tab.layout.rows + 1
  tab.layout.rows[new_row_idx] = vim.deepcopy(row_data)
  cell.track_row_add(es, row_data, new_row_idx)

  -- Re-render current page to show the new row
  local sql_format = require("poste.sql.format")
  local sql_buffer = require("poste.sql.buffer")
  local buf = get_dataset().dataset_buffer
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local lines, meta = sql_format.render_page(tab.layout, tab.page or 1, tab.page_size or 50)
    meta.table_name = tab.meta and tab.meta.table_name
    sql_buffer.apply_rendered_page(tab, lines, meta)
    -- Re-apply edit highlights (green for added row)
    local sql_highlights = require("poste.sql.highlights")
    sql_highlights.apply_edit_highlights(buf, tab)
    -- Move cursor to new row if visible
    if new_row_idx <= meta.row_count then
      get_state().sql.cell.row = new_row_idx
      local line_idx = meta.data_start_line + new_row_idx - 1
      pcall(vim.api.nvim_win_set_cursor, get_dataset().dataset_window, { line_idx, 0 })
      sql_highlights.highlight_cell(buf, new_row_idx, get_state().sql.cell.col or 1, meta)
    end
  end

  -- Update winbar
  local winbar_base = require("poste.sql.buffer_nav").build_status_winbar(tab.meta)
  if get_dataset().dataset_window and vim.api.nvim_win_is_valid(get_dataset().dataset_window) then
    pcall(vim.api.nvim_set_option_value, "winbar", winbar_base or "", { win = get_dataset().dataset_window })
  end

  vim.notify("Row queued for insertion (commit with <leader>w)", vim.log.levels.INFO)
end

--- Rollback all edits and re-run query.
function M.rollback_edits()
  local tab = get_dataset().T()
  if not tab then return end
  if not tab.edit_state or not tab.edit_state.dirty then
    vim.notify("No pending changes", vim.log.levels.INFO)
    return
  end

  cell.reset_edit_state(tab.edit_state)
  tab.edit_state = nil

  vim.schedule(function()
    require("poste.sql.edit_commit").refresh_dataset(tab)
  end)
end

return M
