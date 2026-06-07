--- Shared dataset state extracted from buffer.lua.
--- Tabs, floats, scroll state — no poste deps, only vim.api.*.

local M = {}

M.dataset_buffer = nil
M.dataset_window = nil

M.LEFT_PADDING = 2
M.PADDING_SPACES = string.rep(" ", M.LEFT_PADDING)

M.tabs = {}
M.active_tab_idx = 0

M.float_buf = nil
M.float_win = nil
M.scroll_autocmd_id = nil
M.search_ns = vim.api.nvim_create_namespace("poste_sql_search")

function M.tab_count()
  return #M.tabs
end

function M.T()
  return M.tabs[M.active_tab_idx]
end

function M.alloc_tab(idx)
  if not M.tabs[idx] then
    M.tabs[idx] = {
      meta = nil, lines = nil, padded = nil,
      header_text = nil, header_index = nil,
      sort = nil, original_rows = nil, is_sorting = false,
      data = nil,
      cursor = { row = 1, col = 1 },
      leftcol = 0,
      padded_full = nil, meta_full = nil,
      page = 1, page_size = 50, num_pages = 1,
      pagination_enabled = true, visible_rows = nil,
      filter_col = nil, filter_val = nil, filter_col_name = nil,
      filter_active = false, original_data = nil,
      search_text = nil, search_matches = {}, search_idx = 0,
    }
  end
  return M.tabs[idx]
end

function M.close_header_float()
  local win = M.dataset_window
  if win and vim.api.nvim_win_is_valid(win) then
    local all_wins = vim.api.nvim_tabpage_list_wins(0)
    for _, w in ipairs(all_wins) do
      if w ~= win then
        local ok, config = pcall(vim.api.nvim_win_get_config, w)
        if ok and config.relative == "win" and config.win == win then
          pcall(vim.api.nvim_win_close, w, true)
        end
      end
    end
  end
  if M.float_win and vim.api.nvim_win_is_valid(M.float_win) then
    pcall(vim.api.nvim_win_close, M.float_win, true)
  end
  if M.float_buf and vim.api.nvim_buf_is_valid(M.float_buf) then
    pcall(vim.api.nvim_buf_delete, M.float_buf, { force = true })
  end
  M.float_win = nil
  M.float_buf = nil
end

return M