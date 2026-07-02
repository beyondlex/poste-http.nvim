--- SQL Dataset buffer — core: state, keymaps, tab switching, render, close.
local D = require("poste.sql.dataset")
local state = require("poste.state")
local sql_highlights = require("poste.sql.highlights")

local M = {}

--------------------------------------------------------------------------------
-- Buffer creation + keymaps
--------------------------------------------------------------------------------

function M.get_error_buffer()
  if D.error_buffer and vim.api.nvim_buf_is_valid(D.error_buffer) then
    return D.error_buffer
  end
  D.error_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = D.error_buffer })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = D.error_buffer })
  vim.api.nvim_set_option_value("swapfile", false, { buf = D.error_buffer })
  vim.api.nvim_set_option_value("modifiable", false, { buf = D.error_buffer })
  vim.api.nvim_buf_set_name(D.error_buffer, "poste://error")
  return D.error_buffer
end

function M.get_dataset_buffer()
  if D.dataset_buffer and vim.api.nvim_buf_is_valid(D.dataset_buffer) then
    return D.dataset_buffer
  end

  D.dataset_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = D.dataset_buffer })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = D.dataset_buffer })
  vim.api.nvim_set_option_value("swapfile", false, { buf = D.dataset_buffer })
  vim.api.nvim_set_option_value("modifiable", false, { buf = D.dataset_buffer })
  vim.api.nvim_buf_set_name(D.dataset_buffer, "poste://dataset")
  vim.bo[D.dataset_buffer].filetype = "poste_dataset"

  local opts = { buffer = D.dataset_buffer, noremap = true, silent = true }

  local k = state.get_keymap("sql_dataset", "close", "q")
  if k then vim.keymap.set("n", k, function() M.close() end, opts) end
  k = state.get_keymap("sql_dataset", "move_left", "h")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").move_cell(0, -1) end, opts) end
  k = state.get_keymap("sql_dataset", "move_down", "j")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").move_cell(1, 0) end, opts) end
  k = state.get_keymap("sql_dataset", "move_up", "k")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").move_cell(-1, 0) end, opts) end
  k = state.get_keymap("sql_dataset", "move_right", "l")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").move_cell(0, 1) end, opts) end
  k = state.get_keymap("sql_dataset", "prev_page", "H")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_page").prev_page() end, opts) end
  k = state.get_keymap("sql_dataset", "next_page", "L")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_page").next_page() end, opts) end
  k = state.get_keymap("sql_dataset", "first_col", "0")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").goto_first_col() end, opts) end
  k = state.get_keymap("sql_dataset", "last_col", "$")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").goto_last_col() end, opts) end
  k = state.get_keymap("sql_dataset", "first_row", "gg")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").goto_first_row() end, opts) end
  k = state.get_keymap("sql_dataset", "last_row", "G")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").goto_last_row() end, opts) end
  k = state.get_keymap("sql_dataset", "preview_cell", "K")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").preview_cell() end, opts) end
  k = state.get_keymap("sql_dataset", "yank_cell", "yy")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").yank_cell() end, opts) end
  k = state.get_keymap("sql_dataset", "yank_column", "yc")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").yank_column() end, opts) end
  k = state.get_keymap("sql_dataset", "sort_column", "s")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").sort_by_current_col() end, opts) end
  k = state.get_keymap("sql_dataset", "toggle_cell_highlight", "zh")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").toggle_cell_highlight() end, opts) end
  k = state.get_keymap("sql_dataset", "toggle_header_float", "zH")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").toggle_header_float() end, opts) end
  k = state.get_keymap("sql_dataset", "toggle_row_numbers", "zN")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").toggle_row_numbers() end, opts) end
  k = state.get_keymap("sql_dataset", "toggle_raw_mode", "<leader>gp")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_nav").toggle_raw_mode() end, opts) end
  k = state.get_keymap("sql_dataset", "next_tab", "<Tab>")
  if k then vim.keymap.set("n", k, function() M.next_tab() end, opts) end
  k = state.get_keymap("sql_dataset", "prev_tab", "<S-Tab>")
  if k then vim.keymap.set("n", k, function() M.prev_tab() end, opts) end
  k = state.get_keymap("sql_dataset", "rerun", "R")
  if k then
    vim.keymap.set("n", k, function()
      local tab = D.T()
      if not tab or not tab.original_sql then return end
      if tab.edit_state and tab.edit_state.dirty then
        require("poste.sql.editor").rollback_edits()
      else
        vim.schedule(function()
          require("poste.sql.edit_commit").refresh_dataset(tab)
        end)
      end
    end, opts)
  end
  k = state.get_keymap("sql_dataset", "goto_first_page", "<leader>hh")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_page").goto_first_page() end, opts) end
  k = state.get_keymap("sql_dataset", "goto_last_page", "<leader>ll")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_page").goto_last_page() end, opts) end
  k = state.get_keymap("sql_dataset", "toggle_pagination", "<leader>pa")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_page").toggle_pagination() end, opts) end
  k = state.get_keymap("sql_dataset", "find_column", "<leader>fc")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_search").find_column() end, opts) end
  k = state.get_keymap("sql_dataset", "filter_by_cell", "<leader>ce")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_search").filter_by_current_cell() end, opts) end
  k = state.get_keymap("sql_dataset", "show_search", "<leader>/")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_search").show_search() end, opts) end
  k = state.get_keymap("sql_dataset", "clear_filter_search", "<leader>cr")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_search").clear_filter_search() end, opts) end
  k = state.get_keymap("sql_dataset", "next_search", "n")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_search").next_search_match() end, opts) end
  k = state.get_keymap("sql_dataset", "prev_search", "N")
  if k then vim.keymap.set("n", k, function() require("poste.sql.buffer_search").prev_search_match() end, opts) end

  -- Export
  k = state.get_keymap("sql_dataset", "export", "E")
  if k then vim.keymap.set("n", k, function() require("poste.sql.export").run() end, opts) end

  -- Edit keymaps
  k = state.get_keymap("sql_dataset", "edit_cell", "i")
  if k then vim.keymap.set("n", k, function() require("poste.sql.editor").edit_cell() end, opts) end
  k = state.get_keymap("sql_dataset", "edit_cell_replace", "cc")
  if k then vim.keymap.set("n", k, function() require("poste.sql.editor").edit_cell() end, opts) end
  k = state.get_keymap("sql_dataset", "delete_row", "dd")
  if k then vim.keymap.set("n", k, function() require("poste.sql.editor").delete_row() end, opts) end
  k = state.get_keymap("sql_dataset", "insert_row", "o")
  if k then vim.keymap.set("n", k, function() require("poste.sql.editor").insert_row() end, opts) end
  k = state.get_keymap("sql_dataset", "commit_edits", "<leader>w")
  if k then vim.keymap.set("n", k, function() require("poste.sql.edit_commit").commit_edits() end, opts) end

  -- BufWriteCmd: :w triggers commit
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = D.dataset_buffer,
    callback = function()
      local tab = D.T()
      if tab and tab.edit_state and tab.edit_state.dirty then
        require("poste.sql.edit_commit").commit_edits()
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = D.dataset_buffer,
    callback = function()
      vim.schedule(function()
        if not M.is_open() then
          D.close_header_float()
          sql_highlights.clear_cell_highlight(D.dataset_buffer)
  if D.resize_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, D.resize_autocmd_id)
    D.resize_autocmd_id = nil
  end
  if D.scroll_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, D.scroll_autocmd_id)
    D.scroll_autocmd_id = nil
  end
  if D.winclose_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, D.winclose_autocmd_id)
    D.winclose_autocmd_id = nil
  end
          if D.scroll_autocmd_id then
            pcall(vim.api.nvim_del_autocmd, D.scroll_autocmd_id)
            D.scroll_autocmd_id = nil
          end
          if D.winclose_autocmd_id then
            pcall(vim.api.nvim_del_autocmd, D.winclose_autocmd_id)
            D.winclose_autocmd_id = nil
          end
        end
      end)
    end,
  })

  return D.dataset_buffer
end

--------------------------------------------------------------------------------
-- Tab switching
--------------------------------------------------------------------------------

local function save_active_tab_state()
  local tab = D.T()
  if not tab then return end
  tab.cursor = { row = state.sql.cell.row, col = state.sql.cell.col }
  if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
    tab.leftcol = vim.api.nvim_win_call(D.dataset_window, function()
      return vim.fn.winsaveview().leftcol
    end)
  end
end

local function apply_tab_state(tab)
  state.sql.cell.row = tab.cursor.row
  state.sql.cell.col = tab.cursor.col
  if tab.data then state.sql.last_dataset = tab.data end
end

local function switch_tab(idx)
  if not D.tabs[idx] then return end
  -- Block tab switch if current tab has dirty edits
  local current = D.T()
  if current and current.edit_state and current.edit_state.dirty then
    vim.notify("Unsaved changes, commit (<leader>w) or revert (R) first", vim.log.levels.WARN)
    return
  end
  save_active_tab_state()
  D.close_header_float()
  D.active_tab_idx = idx
  local tab = D.tabs[idx]
  apply_tab_state(tab)

  if not D.dataset_window or not vim.api.nvim_win_is_valid(D.dataset_window) then return end

  if tab.padded then
    vim.api.nvim_set_option_value("modifiable", true, { buf = D.dataset_buffer })
    vim.api.nvim_buf_set_lines(D.dataset_buffer, 0, -1, false, tab.padded)
    vim.api.nvim_set_option_value("modifiable", false, { buf = D.dataset_buffer })
    sql_highlights.apply_dataset_highlights(D.dataset_buffer, tab.padded, tab.meta)
  end

  vim.api.nvim_win_set_buf(D.dataset_window, D.dataset_buffer)

  pcall(vim.api.nvim_win_call, D.dataset_window, function()
    vim.fn.winrestview({ leftcol = tab.leftcol or 0 })
  end)

  local meta = tab.meta
  if meta and meta.type == "resultset" and meta.row_count > 0 then
    local line_idx = (meta.data_start_line or 1) + tab.cursor.row - 1
    pcall(vim.api.nvim_win_set_cursor, D.dataset_window, { line_idx, 0 })
    local cs = tab.buffer_col_starts and tab.buffer_col_starts[line_idx]
    sql_highlights.highlight_cell(D.dataset_buffer, tab.cursor.row, tab.cursor.col, meta, nil, cs)
  end

  if tab.header_text then
    require("poste.sql.buffer_nav").update_header_float()
  end

  local winbar_text = require("poste.sql.buffer_nav").build_status_winbar(meta)
  if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
    pcall(vim.api.nvim_set_option_value, "winbar", winbar_text or "", { win = D.dataset_window })
  end

  require("poste.sql.buffer_search").apply_search_highlights()
end

function M.next_tab()
  if #D.tabs < 2 then return end
  local idx = D.active_tab_idx + 1
  if idx > #D.tabs then idx = 1 end
  switch_tab(idx)
end

function M.prev_tab()
  if #D.tabs < 2 then return end
  local idx = D.active_tab_idx - 1
  if idx < 1 then idx = #D.tabs end
  switch_tab(idx)
end

function M.tab_count()
  return #D.tabs
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

--- Process rendered table lines and write to buffer. Shared by
--- render_dataset and buffer_page.refresh_page. Handles header
--- extraction, padding, buffer write, highlights, winbar.
function M.apply_rendered_page(tab, lines, meta)
  local clean = {}
  for i, line in ipairs(lines) do
    if type(line) ~= "string" then line = tostring(line or "") end
    for seg in (line .. "\n"):gmatch("(.-)\n") do
      clean[#clean + 1] = seg
    end
  end

  local has_header = meta and meta.type == "resultset" and meta.header_line
  if has_header then
    local header_line = clean[meta.header_line]
    if header_line then
      tab.header_text = header_line
      if tab.sort then
        local range = sql_highlights.find_cell_range(tab.header_text, tab.sort.col + 1)
        if range then
          local text_end = range.ext_end
          while text_end > range.ext_start + 1 do
            if tab.header_text:byte(text_end) ~= 0x20 then break end
            text_end = text_end - 1
          end
          if text_end > range.ext_start then
            local indicator = (tab.sort.ascending and " ↑" or " ↓")
            local before = tab.header_text:sub(1, text_end)
            local after = tab.header_text:sub(text_end + 3)
            tab.header_text = before .. indicator .. after
            tab.header_col_starts = nil  -- invalidated by sort modification
           end
        end
      end
      local padded_h = "  " .. tab.header_text
      tab.header_index = require("poste.sql.buffer_nav").build_header_index(padded_h)

      table.remove(clean, meta.header_line + 1)
      table.remove(clean, meta.header_line)
      if meta.header_line > 1 then table.remove(clean, meta.header_line - 1) end
      meta.header_line = nil
      meta.data_start_line = meta.data_start_line - 3
      meta.data_end_line = meta.data_end_line - 3
    end
  end

  local padded = {}
  for _, line in ipairs(clean) do
    if line == "" then
      padded[#padded + 1] = ""
    else
      padded[#padded + 1] = D.PADDING_SPACES .. line
    end
  end
  if has_header then
    table.insert(padded, 1, "")
    meta.data_start_line = meta.data_start_line + 1
    meta.data_end_line = meta.data_end_line + 1
  end

  tab.padded = padded
  tab.meta = meta

  -- Store pre-computed column byte offsets + display positions for O(1) navigation
  tab.buffer_col_starts = {}
  if meta and meta.col_starts then
    for i, starts in ipairs(meta.col_starts) do
      local line_idx = meta.data_start_line + i - 1
      local padded_starts = {}
      local cum = D.LEFT_PADDING + 2  -- position after first cell's leading space
      for col_idx, cell in ipairs(starts) do
        local w = meta.col_widths and meta.col_widths[col_idx] or 0
        local disp_start = cum
        local disp_end = disp_start + w + 1  -- position of │ after cell
        padded_starts[col_idx] = {
          ext_start = cell.ext_start + D.LEFT_PADDING,
          ext_end = cell.ext_end + D.LEFT_PADDING,
          disp_start = disp_start,
          disp_end = disp_end,
        }
        cum = disp_end + 2  -- skip │ + leading space for next cell
      end
      tab.buffer_col_starts[line_idx] = padded_starts
    end
  end
  -- Also store header col_starts with left padding offset and display-width positions.
  -- Uses cumulative byte-count (ASCII column names: byte = display) instead of
  -- strdisplaywidth of byte-prefixed substrings, which can return wrong values
  -- when ext_end is near the end of the string.
  tab.header_col_starts = nil
  if meta and meta.header_col_starts then
    local hdr = {}
    local cum_disp = D.LEFT_PADDING
    for col_idx, cell in ipairs(meta.header_col_starts) do
      local cell_disp = cell.ext_end - cell.ext_start
      local ext_start = cell.ext_start + D.LEFT_PADDING
      local ext_end = cell.ext_end + D.LEFT_PADDING
      hdr[col_idx] = {
        ext_start = ext_start,
        ext_end = ext_end,
        disp_start = cum_disp + 1,
        disp_end = cum_disp + 1 + cell_disp,
      }
      cum_disp = cum_disp + 1 + cell_disp
    end
    tab.header_col_starts = hdr
  end

  local buf = M.get_dataset_buffer()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, padded)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  sql_highlights.apply_dataset_highlights(buf, padded, meta)

  -- Re-apply edit highlights if dirty
  if tab.edit_state and tab.edit_state.dirty then
    sql_highlights.apply_edit_highlights(buf, tab)
  end

  local winbar_text = require("poste.sql.buffer_nav").build_status_winbar(meta)
  if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
    pcall(vim.api.nvim_set_option_value, "winbar", winbar_text or "", { win = D.dataset_window })
  end

  require("poste.sql.buffer_search").apply_search_highlights()
end

function M.render_dataset(lines, meta, opts)
  opts = opts or {}
  local tab_idx = opts.tab_index or 1
  local is_error = meta and meta.type ~= "resultset"

  if tab_idx == 1 and not opts.keep_tabs then
    D.tabs = {}
    D.active_tab_idx = 0
  end

  D.close_header_float()

  local tab = D.alloc_tab(tab_idx)
  D.active_tab_idx = tab_idx

  local buf = M.get_dataset_buffer()

  sql_highlights.invalidate_sep_cache()

  if tab.is_sorting then  -- luacheck: ignore 542
  else
    tab.sort = nil
    tab.original_rows = nil
  end

  if meta and meta.type == "resultset" then
    local data = opts.data
    if not data then
      if opts.keep_tabs then
        data = tab.data
      else
        local ok, d = pcall(vim.json.decode, state.last_response and state.last_response.body or "{}")
        if ok then data = d end
      end
    end
    if data then
      tab.data = data
      state.sql.last_dataset = data
    end
  end

  if not tab.is_sorting then
    tab.cursor = { row = 1, col = 1 }
  end

  -- Layout-aware path: store layout, render current page, no padded_full
  if opts.layout and meta and meta.type == "resultset" then
    tab.layout = opts.layout
    tab.rows_source = tab.rows_source or opts.layout.rows
    tab.view_indices = opts.view_indices or nil
    tab.row_number_mode = opts.row_number_mode or "source"

    -- Store original SQL for JOIN detection
    if opts.original_sql then
      tab.original_sql = opts.original_sql
    end

    -- Store source file path for PK introspection (poste needs a real file for connections.json discovery)
    if opts.src_file then
      tab.src_file = opts.src_file
    end
    -- Store source buffer handle for rerun after commit
    if opts.src_buf then
      tab.src_buf = opts.src_buf
    end

    -- Store connection name & database for dataset operations (commit, refresh, PK introspection)
    -- These persist even if state.sql.context is cleared later
    local conn_name = state.sql.context.connection
    if conn_name and conn_name ~= "" then
      tab.layout._conn_name = conn_name
    end
    local db_name = state.sql.context.database
    if db_name and db_name ~= "" then
      tab.layout._database = db_name
    end
    -- Also try to get from data response (full connection string → extract name later)
    if not tab.layout._conn_name and tab.data and tab.data.connection then
      tab.layout._conn_str = tab.data.connection
    end

    -- Sync table_name from meta to layout if missing
    if meta.table_name and (not tab.layout.table_name or tab.layout.table_name == "") then
      tab.layout.table_name = meta.table_name
    end

    local total_for_pagination = meta.total_rows or meta.row_count
    if tab.pagination_enabled and total_for_pagination > tab.page_size then
      tab.num_pages = math.ceil(total_for_pagination / tab.page_size)
      tab.page = math.min(tab.page or 1, tab.num_pages)
      tab.visible_rows = tab.page_size
    else
      tab.visible_rows = meta.row_count
    end

    M.apply_rendered_page(tab, lines, meta)
  else
    -- Legacy path: pre-rendered lines with padded_full slicing
    local clean = {}
    for i, line in ipairs(lines) do
      if type(line) ~= "string" then line = tostring(line or "") end
      for seg in (line .. "\n"):gmatch("(.-)\n") do
        clean[#clean + 1] = seg
      end
    end

    local has_header = meta and meta.type == "resultset" and meta.header_line
    if has_header then
      local header_line = clean[meta.header_line]
      if header_line then
        tab.header_text = header_line
        if tab.sort then
          local range = sql_highlights.find_cell_range(tab.header_text, tab.sort.col + 1)
          if range then
            local text_end = range.ext_end
            while text_end > range.ext_start + 1 do
              if tab.header_text:byte(text_end) ~= 0x20 then break end
              text_end = text_end - 1
            end
            if text_end > range.ext_start then
              local indicator = (tab.sort.ascending and " ↑" or " ↓")
              local before = tab.header_text:sub(1, text_end)
              local after = tab.header_text:sub(text_end + 3)
              tab.header_text = before .. indicator .. after
              tab.header_col_starts = nil
             end
          end
        end
        local padded_h = "  " .. tab.header_text
        tab.header_index = require("poste.sql.buffer_nav").build_header_index(padded_h)

        table.remove(clean, meta.header_line + 1)
        table.remove(clean, meta.header_line)
        if meta.header_line > 1 then table.remove(clean, meta.header_line - 1) end
        meta.header_line = nil
        meta.data_start_line = meta.data_start_line - 3
        meta.data_end_line = meta.data_end_line - 3
      end
    end

    local padded = {}
    for _, line in ipairs(clean) do
      if line == "" then
        padded[#padded + 1] = ""
      else
        padded[#padded + 1] = D.PADDING_SPACES .. line
      end
    end
    if has_header then
      table.insert(padded, 1, "")
      meta.data_start_line = meta.data_start_line + 1
      meta.data_end_line = meta.data_end_line + 1
    end

    tab.padded = padded
    tab.meta = meta

    tab.padded_full = vim.deepcopy(padded)
    tab.meta_full = vim.deepcopy(meta)
    if meta and meta.type == "resultset" and meta.row_count then
      if tab.pagination_enabled and meta.row_count > tab.page_size then
        local total_rows = meta.row_count
        tab.num_pages = math.ceil(total_rows / tab.page_size)
        tab.page = math.min(tab.page or 1, tab.num_pages)
        local page_rows = math.min(tab.page_size, total_rows - (tab.page - 1) * tab.page_size)
        tab.visible_rows = page_rows
        local data_start = meta.data_start_line
        local page_start_idx = data_start + (tab.page - 1) * tab.page_size + 1 - 1
        local page_end_idx = page_start_idx + page_rows - 1
        local sliced = {}
        for i = 1, data_start - 1 do
          sliced[#sliced + 1] = padded[i]
        end
        for i = page_start_idx, page_end_idx do
          sliced[#sliced + 1] = padded[i]
        end
        padded = sliced
        meta.row_count = page_rows
        meta.data_end_line = data_start + page_rows - 1
        tab.padded = padded
      else
        tab.visible_rows = meta.row_count
      end
    end

    local write_buf = is_error and M.get_error_buffer() or buf
    vim.api.nvim_set_option_value("modifiable", true, { buf = write_buf })
    vim.api.nvim_buf_set_lines(write_buf, 0, -1, false, padded)
    vim.api.nvim_set_option_value("modifiable", false, { buf = write_buf })

    if not is_error then
      sql_highlights.apply_dataset_highlights(write_buf, padded, meta)
      require("poste.sql.buffer_search").apply_search_highlights()
    elseif meta and meta.type == "error" then
      sql_highlights.apply_dataset_highlights(write_buf, padded, meta)
    end
  end

  if not D.dataset_window or not vim.api.nvim_win_is_valid(D.dataset_window) then
    local src_win = vim.api.nvim_get_current_win()
    local src_view = vim.fn.winsaveview()
    local height = math.floor(vim.o.lines * 0.4)
    vim.cmd("botright " .. height .. "split")
    D.dataset_window = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(src_win)
    vim.fn.winrestview(src_view)
  end

  vim.api.nvim_win_set_buf(D.dataset_window, is_error and M.get_error_buffer() or buf)
  pcall(vim.api.nvim_win_call, D.dataset_window, function()
    vim.fn.winrestview({ leftcol = 0 })
  end)

  if is_error then
    vim.api.nvim_set_option_value("wrap", true, { win = D.dataset_window })
    vim.api.nvim_set_option_value("cursorline", false, { win = D.dataset_window })
    vim.api.nvim_set_option_value("conceallevel", 0, { win = D.dataset_window })
    vim.api.nvim_set_option_value("number", true, { win = D.dataset_window })
    vim.api.nvim_set_option_value("relativenumber", false, { win = D.dataset_window })
    vim.api.nvim_set_option_value("signcolumn", "auto", { win = D.dataset_window })
    pcall(vim.api.nvim_set_option_value, "statuscolumn", "", { win = D.dataset_window })
    vim.api.nvim_set_option_value("foldcolumn", "0", { win = D.dataset_window })
    vim.api.nvim_set_option_value("foldenable", false, { win = D.dataset_window })
  else
    vim.api.nvim_set_option_value("wrap", false, { win = D.dataset_window })
    vim.api.nvim_set_option_value("sidescrolloff", 0, { win = D.dataset_window })
    vim.api.nvim_set_option_value("cursorline", false, { win = D.dataset_window })
    vim.api.nvim_set_option_value("cursorcolumn", false, { win = D.dataset_window })
    vim.api.nvim_set_option_value("conceallevel", 0, { win = D.dataset_window })
    vim.api.nvim_set_option_value("number", false, { win = D.dataset_window })
    vim.api.nvim_set_option_value("relativenumber", false, { win = D.dataset_window })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = D.dataset_window })
    pcall(vim.api.nvim_set_option_value, "statuscolumn", "", { win = D.dataset_window })
    vim.api.nvim_set_option_value("foldcolumn", "0", { win = D.dataset_window })
    vim.api.nvim_set_option_value("foldenable", false, { win = D.dataset_window })
  end

  if not is_error then
    local winbar_text = require("poste.sql.buffer_nav").build_status_winbar(meta)
    if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
      pcall(vim.api.nvim_set_option_value, "winbar", winbar_text or "", { win = D.dataset_window })
    end

    if tab.header_text then
      require("poste.sql.buffer_nav").update_header_float()
    end
  end

  if not is_error then
    if D.resize_autocmd_id then
      pcall(vim.api.nvim_del_autocmd, D.resize_autocmd_id)
      D.resize_autocmd_id = nil
    end
    if D.scroll_autocmd_id then
      pcall(vim.api.nvim_del_autocmd, D.scroll_autocmd_id)
      D.scroll_autocmd_id = nil
    end
    if D.dataset_buffer then
      D.resize_autocmd_id = vim.api.nvim_create_autocmd("WinResized", {
        callback = function()
          require("poste.sql.buffer_nav").update_header_float()
        end,
      })
      D.scroll_autocmd_id = vim.api.nvim_create_autocmd("WinScrolled", {
        buffer = D.dataset_buffer,
        callback = function()
          require("poste.sql.buffer_nav").update_header_float()
        end,
      })
      D.winclose_autocmd_id = vim.api.nvim_create_autocmd("WinClosed", {
        callback = function()
          vim.schedule(function()
            require("poste.sql.buffer_nav").update_header_float()
          end)
        end,
      })
    end
  end

  if is_error then
    pcall(vim.api.nvim_win_set_cursor, D.dataset_window, { 1, 0 })
  elseif not tab.is_sorting then
    if meta and meta.type == "resultset" and meta.row_count > 0 then
      state.sql.cell.row = 1
      state.sql.cell.col = 1
      pcall(vim.api.nvim_win_set_cursor, D.dataset_window, { meta.data_start_line, 0 })
      local cs = tab.buffer_col_starts and tab.buffer_col_starts[meta.data_start_line]
      sql_highlights.highlight_cell(D.dataset_buffer, 1, 1, meta, nil, cs)
    else
      pcall(vim.api.nvim_win_set_cursor, D.dataset_window, { 1, 0 })
    end
  end

  if not is_error then
    vim.api.nvim_set_option_value("sidescrolloff", 5, { win = D.dataset_window })
  end
end

--------------------------------------------------------------------------------
-- Panel clear / Close
--------------------------------------------------------------------------------

function M.clear_panel(seq)
  D.tabs = {}
  D.active_tab_idx = 0
  if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
    local all_wins = vim.api.nvim_tabpage_list_wins(0)
    for _, win in ipairs(all_wins) do
      if win ~= D.dataset_window then
        local ok, config = pcall(vim.api.nvim_win_get_config, win)
        if ok and config.relative == "win" and config.win == D.dataset_window then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
  end
  D.close_header_float()
  if D.dataset_buffer and vim.api.nvim_buf_is_valid(D.dataset_buffer) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = D.dataset_buffer })
    vim.api.nvim_buf_set_lines(D.dataset_buffer, 0, -1, false, { "" })
    vim.api.nvim_set_option_value("modifiable", false, { buf = D.dataset_buffer })
  end
end

function M.close()
  if D.resize_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, D.resize_autocmd_id)
    D.resize_autocmd_id = nil
  end
  if D.scroll_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, D.scroll_autocmd_id)
    D.scroll_autocmd_id = nil
  end
  D.close_header_float()
  if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
    local all_wins = vim.api.nvim_tabpage_list_wins(0)
    for _, win in ipairs(all_wins) do
      if win ~= D.dataset_window then
        local ok, config = pcall(vim.api.nvim_win_get_config, win)
        if ok and config.relative == "win" and config.win == D.dataset_window then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
    vim.api.nvim_win_close(D.dataset_window, true)
    D.dataset_window = nil
  end
  sql_highlights.clear_cell_highlight(D.dataset_buffer)
  D.tabs = {}
  D.active_tab_idx = 0
end

function M.is_open()
  return D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window)
end

M._test = {
  set_header = function(header)
    local tab = D.alloc_tab(1)
    tab.header_text = header
    tab.header_index = header and require("poste.sql.buffer_nav").build_header_index("  " .. header) or nil
  end,
  reset = function()
    D.tabs = {}
    D.active_tab_idx = 0
  end,
  tab_count = function() return #D.tabs end,
  active_tab_idx = function() return D.active_tab_idx end,
  create_tab = function(idx, overrides)
    local tab = D.alloc_tab(idx)
    if overrides then
      for k, v in pairs(overrides) do tab[k] = v end
    end
    return tab
  end,
  get_tab = function(idx)
    local t = D.tabs[idx]
    if not t then return nil end
    return {
      meta = t.meta,
      sort = t.sort,
      original_rows = t.original_rows,
      is_sorting = t.is_sorting,
      data = t.data,
      cursor = { row = t.cursor.row, col = t.cursor.col },
      leftcol = t.leftcol,
      header_text = t.header_text,
      header_index = t.header_index,
      has_padded = t.padded ~= nil,
    }
  end,
  set_active = function(idx)
    local old = D.active_tab_idx
    D.active_tab_idx = idx
    return old
  end,
}

return M