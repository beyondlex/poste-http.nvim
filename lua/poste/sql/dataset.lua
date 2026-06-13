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
M._float_cache_leftcol = nil
M._float_cache_width = nil
M._float_cache_header = nil
M.scroll_autocmd_id = nil
M.resize_autocmd_id = nil
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
      filter_active = false, filtered_indices = nil,
      search_text = nil, search_matches = {}, search_idx = 0,
      search_matches_by_page = nil, search_total_matches = 0,
      layout = nil, rows_source = nil, view_indices = nil,
      row_number_mode = "source",
      edit_state = nil,
      original_sql = nil,
      src_file = nil,
      src_buf = nil,
    }
  end
  return M.tabs[idx]
end

--- Compute view_indices from filtered_indices + sort state.
--- Operates on tab state only; no poste module deps.
function M.compute_view_indices(tab)
  local src = tab.rows_source
  if not src then return end
  local indices = {}
  if tab.filtered_indices then
    for i, idx in ipairs(tab.filtered_indices) do indices[i] = idx end
  else
    for i = 1, #src do indices[i] = i end
  end
  if tab.sort then
    local col = tab.sort.col
    local ascending = tab.sort.ascending
    table.sort(indices, function(a, b)
      local va, vb = src[a][col], src[b][col]
      if va == nil or va == vim.NIL then return false end
      if vb == nil or vb == vim.NIL then return true end
      local ta, tb = type(va), type(vb)
      if ta == "number" and tb == "number" then
        if ascending then return va < vb else return va > vb end
      end
      if ta == "boolean" and tb == "boolean" then
        if ascending then return not va and vb else return va and not vb end
      end
      local sa, sb = tostring(va), tostring(vb)
      if ascending then return sa < sb else return sa > sb end
    end)
  end
  tab.view_indices = indices
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
  M._float_cache_leftcol = nil
  M._float_cache_width = nil
  M._float_cache_header = nil
end

return M