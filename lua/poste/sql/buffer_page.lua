local D = require("poste.sql.dataset")
local state = require("poste.state")
local sql_highlights = require("poste.sql.highlights")
local M = {}

function M.goto_header()
  require("poste.sql.buffer_nav").goto_first_row()
end

--- Refresh buffer content from layout (new path) or padded_full (legacy).
function M.refresh_page()
  local tab = D.T()
  if not tab or not D.dataset_window then return end

  -- Layout-aware path: render page from layout (no padded_full needed)
  if tab.layout then
    local fmt = require("poste.sql.format")
    local total_rows
    if tab.view_indices then
      total_rows = #tab.view_indices
    else
      total_rows = tab.layout.total_rows or #tab.layout.rows
    end

    if total_rows and tab.pagination_enabled and total_rows > tab.page_size then
      tab.num_pages = math.ceil(total_rows / tab.page_size)
      tab.page = math.min(tab.page or 1, tab.num_pages)
      local page_rows = math.min(tab.page_size, total_rows - (tab.page - 1) * tab.page_size)
      tab.visible_rows = page_rows

      if tab.view_indices then
        lines, meta = fmt.render_view(tab.layout, tab.view_indices, tab.page, tab.page_size,
          { row_number_mode = tab.row_number_mode or "source" })
      else
        lines, meta = fmt.render_page(tab.layout, tab.page, tab.page_size)
      end

      meta.table_name = tab.meta and tab.meta.table_name
      local buffer = require("poste.sql.buffer")
      buffer.apply_rendered_page(tab, lines, meta)

      if state.sql.cell.row > page_rows then
        state.sql.cell.row = page_rows
      end
      if tab.cursor.row > page_rows then
        tab.cursor.row = page_rows
      end
    else
      tab.visible_rows = total_rows or 0
      local page_size = total_rows or 0
      if tab.view_indices then
        lines, meta = fmt.render_view(tab.layout, tab.view_indices, 1, page_size,
          { row_number_mode = tab.row_number_mode or "source" })
      else
        lines, meta = fmt.render_page(tab.layout, 1, page_size)
      end
      meta.table_name = tab.meta and tab.meta.table_name
      local buffer = require("poste.sql.buffer")
      buffer.apply_rendered_page(tab, lines, meta)
    end

    -- Re-create header float if it was closed (e.g. after raw mode toggle)
    if tab.header_text and not state.sql._hide_header_float then
      require("poste.sql.buffer_nav").update_header_float()
    end

    return
  end

  -- Legacy path: slice from padded_full
  if not tab.padded_full then return end

  local meta = tab.meta
  local total_rows = tab.meta_full and tab.meta_full.row_count or meta.row_count or 0

  if tab.pagination_enabled and total_rows > tab.page_size then
    tab.num_pages = math.ceil(total_rows / tab.page_size)
    tab.page = math.min(tab.page or 1, tab.num_pages)
    local page_rows = math.min(tab.page_size, total_rows - (tab.page - 1) * tab.page_size)
    tab.visible_rows = page_rows
    local data_start = meta.data_start_line
    local page_start_idx = data_start + (tab.page - 1) * tab.page_size + 1 - 1
    local page_end_idx = page_start_idx + page_rows - 1
    local sliced = {}
    for i = 1, data_start - 1 do
      sliced[#sliced + 1] = tab.padded_full[i]
    end
    for i = page_start_idx, page_end_idx do
      sliced[#sliced + 1] = tab.padded_full[i]
    end
    tab.padded = sliced
    meta.row_count = page_rows
    meta.data_end_line = data_start + page_rows - 1

    if state.sql.cell.row > page_rows then
      state.sql.cell.row = page_rows
    end
    if tab.cursor.row > page_rows then
      tab.cursor.row = page_rows
    end
  else
    tab.padded = tab.padded_full
    local full = tab.meta_full
    if full then
      meta.row_count = full.row_count
      meta.data_end_line = full.data_end_line
    end
    tab.visible_rows = meta.row_count
  end

  local buf = require("poste.sql.buffer").get_dataset_buffer()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, tab.padded)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  sql_highlights.apply_dataset_highlights(buf, tab.padded, meta)

  local winbar_text = require("poste.sql.buffer_nav").build_status_winbar(meta)
  if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
    pcall(vim.api.nvim_set_option_value, "winbar", winbar_text or "", { win = D.dataset_window })
  end

  require("poste.sql.buffer_search").apply_search_highlights()
end

local function is_dirty()
  local tab = D.T()
  return tab and tab.edit_state and tab.edit_state.dirty
end

local function block_if_dirty()
  if is_dirty() then
    vim.notify("Unsaved changes, commit (<leader>w) or revert (R) first", vim.log.levels.WARN)
    return true
  end
  return false
end

function M.prev_page()
  if block_if_dirty() then return end
  local tab = D.T()
  if not tab or not tab.pagination_enabled or tab.num_pages <= 1 then return end
  if not tab.padded_full and not tab.layout then return end
  tab.page = tab.page - 1
  if tab.page < 1 then tab.page = tab.num_pages end
  M.refresh_page()
end

function M.next_page()
  if block_if_dirty() then return end
  local tab = D.T()
  if not tab or not tab.pagination_enabled or tab.num_pages <= 1 then return end
  if not tab.padded_full and not tab.layout then return end
  tab.page = tab.page + 1
  if tab.page > tab.num_pages then tab.page = 1 end
  M.refresh_page()
end

function M.goto_first_page()
  if block_if_dirty() then return end
  local tab = D.T()
  if not tab or not tab.pagination_enabled or tab.num_pages <= 1 then return end
  if not tab.padded_full and not tab.layout then return end
  tab.page = 1
  M.refresh_page()
end

function M.goto_last_page()
  if block_if_dirty() then return end
  local tab = D.T()
  if not tab or not tab.pagination_enabled or tab.num_pages <= 1 then return end
  if not tab.padded_full and not tab.layout then return end
  tab.page = tab.num_pages
  M.refresh_page()
end

function M.toggle_pagination()
  local tab = D.T()
  if not tab then return end
  tab.pagination_enabled = not tab.pagination_enabled
  M.refresh_page()
  local status = tab.pagination_enabled and ("Page " .. tab.page .. "/" .. tab.num_pages) or "All"
  vim.notify(string.format("Pagination: %s", status),
    vim.log.levels.INFO, { title = "Poste SQL" })
end

function M.update_winbar()
  if not D.dataset_window or not vim.api.nvim_win_is_valid(D.dataset_window) then return end
  local meta = D.T() and D.T().meta
  if not meta then return end
  local text = require("poste.sql.buffer_nav").build_status_winbar(meta)
  pcall(vim.api.nvim_set_option_value, "winbar", text or "", { win = D.dataset_window })
end

return M
