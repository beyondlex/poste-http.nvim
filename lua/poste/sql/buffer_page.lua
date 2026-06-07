local D = require("poste.sql.dataset")
local state = require("poste.state")
local sql_highlights = require("poste.sql.highlights")
local sql_format = require("poste.sql.format")
local M = {}

function M.goto_header()
  require("poste.sql.buffer_nav").goto_first_row()
end

--- Refresh buffer content and winbar from current tab's padded_full and page state.
function M.refresh_page()
  local tab = D.T()
  if not tab or not tab.padded_full or not D.dataset_window then return end

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
  pcall(vim.api.nvim_set_option_value, "winbar", winbar_text or "", { win = D.dataset_window })

  require("poste.sql.buffer_search").apply_search_highlights()
end

function M.prev_page()
  local tab = D.T()
  if not tab or not tab.padded_full or not tab.pagination_enabled or tab.num_pages <= 1 then return end
  tab.page = tab.page - 1
  if tab.page < 1 then tab.page = tab.num_pages end
  M.refresh_page()
end

function M.next_page()
  local tab = D.T()
  if not tab or not tab.padded_full or not tab.pagination_enabled or tab.num_pages <= 1 then return end
  tab.page = tab.page + 1
  if tab.page > tab.num_pages then tab.page = 1 end
  M.refresh_page()
end

function M.goto_first_page()
  local tab = D.T()
  if not tab or not tab.padded_full or not tab.pagination_enabled or tab.num_pages <= 1 then return end
  tab.page = 1
  M.refresh_page()
end

function M.goto_last_page()
  local tab = D.T()
  if not tab or not tab.padded_full or not tab.pagination_enabled or tab.num_pages <= 1 then return end
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
