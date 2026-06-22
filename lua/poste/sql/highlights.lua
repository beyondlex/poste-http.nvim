--- Highlight groups and extmark application for SQL dataset buffer.
local state = require("poste.state")
local M = {}

local function row_nums_hidden()
  return state.sql._hide_row_numbers
end

local ns = vim.api.nvim_create_namespace("poste_sql_dataset")
local ns_cell = vim.api.nvim_create_namespace("poste_sql_dataset_cell")

--- Resolve highlight group links fully (follow chains of `link`).
local function resolve_hl(name)
  local hl = vim.api.nvim_get_hl(0, { name = name })
  while hl.link do
    hl = vim.api.nvim_get_hl(0, { name = hl.link })
  end
  return hl
end

--- Check if a color value indicates a dark background (luminance < 0.5).
local function is_dark(color)
  if not color then return true end  -- assume dark if unset
  local r = math.floor(color / 0x10000) % 0x100 / 255
  local g = math.floor(color / 0x100) % 0x100 / 255
  local b = color % 0x100 / 255
  return (0.299 * r + 0.587 * g + 0.114 * b) < 0.5
end

--- Define all SQL highlight groups and register autocmds.
function M.setup()
  -- Groups that keep link-based defaults (not dataset-specific)
  local groups = {
    { "PosteSqlModified",   "DiffChange" },
    { "PosteSqlDeleted",    "DiffDelete" },
  }

  for _, pair in ipairs(groups) do
    local existing = vim.api.nvim_get_hl(0, { name = pair[1] })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, pair[1], { link = pair[2] })
    end
  end

  -- Detect dark/light from Normal background luminance.
  local normal = resolve_hl("Normal")
  local dark = is_dark(normal.bg)

  -- Added rows: green background (override, not link to DiffAdd)
  vim.api.nvim_set_hl(0, "PosteSqlAdded", {
    bg = dark and 0x001e00 or 0xc6efc6,
  })

  -- Winbar pending status: fg-only
  vim.api.nvim_set_hl(0, "PosteWinbarAdded",    { fg = dark and 0x4ec94e or 0x2d8a2d })
  vim.api.nvim_set_hl(0, "PosteWinbarModified",  { fg = dark and 0xd7d700 or 0x9a7d00 })
  vim.api.nvim_set_hl(0, "PosteWinbarDeleted",   { fg = dark and 0xf07070 or 0xc04040 })

  -- Cell text: ensure readable fg for data cells
  vim.api.nvim_set_hl(0, "PosteSqlCellText", {
    fg = dark and 0xd4d4d4 or 0x333333,
  })
  -- Separators (│): visible but subtle
  vim.api.nvim_set_hl(0, "PosteSqlSep", {
    fg = dark and 0x5c6370 or 0x999999,
  })
  -- Borders (┌─┬─┐): slightly brighter than separators
  vim.api.nvim_set_hl(0, "PosteSqlBorder", {
    fg = dark and 0x636d83 or 0x888888,
  })
  -- Header row: bright and bold
  vim.api.nvim_set_hl(0, "PosteSqlHeader", {
    fg = dark and 0xe5c07b or 0x8b6914,
    bold = true,
  })
  -- Winbar top border (┌─┬─┐): same color as cell borders
  vim.api.nvim_set_hl(0, "PosteSqlWinbarBorder", {
    link = "PosteSqlBorder",
  })
  -- Winbar │ separators: invisible (blend with winbar background)
  local winbar_hl = resolve_hl("WinBar")
  local winbar_bg = (winbar_hl and winbar_hl.bg) or normal.bg or (dark and 0x1e1e1e or 0xffffff)
  vim.api.nvim_set_hl(0, "PosteSqlWinbarSep", {
    fg = winbar_bg,
    bg = winbar_bg,
  })
  -- Meta footer
  vim.api.nvim_set_hl(0, "PosteSqlMeta", {
    fg = dark and 0x7f848e or 0x6a737d,
    italic = true,
  })
  -- Pagination info in winbar: dimmer version of Meta
  vim.api.nvim_set_hl(0, "PosteSqlMetaDim", {
    fg = dark and 0x4a4f5a or 0x8b8f96,
    italic = true,
  })
  -- NULL values
  vim.api.nvim_set_hl(0, "PosteSqlNull", {
    fg = dark and 0x5c6370 or 0x999999,
    italic = true,
  })
  -- Numbers: distinct color (green/cyan for dark, blue for light)
  vim.api.nvim_set_hl(0, "PosteSqlNumber", {
    fg = dark and 0x98c379 or 0x005cc5,
  })
  -- Booleans: distinct color (orange for dark, purple for light)
  vim.api.nvim_set_hl(0, "PosteSqlBool", {
    fg = dark and 0xd19a66 or 0x6f42c1,
  })
  -- Sort indicator (↑/↓): cyan for dark, red for light - stands out from header
  vim.api.nvim_set_hl(0, "PosteSqlSortIndicator", {
    fg = dark and 0x56b6c2 or 0xcf222e,
    bold = true,
  })
  -- Row number column: muted/subtle color
  vim.api.nvim_set_hl(0, "PosteSqlRowNum", {
    fg = dark and 0x5c6370 or 0x999999,
  })

  -- Cell selection: bright bg with contrasting fg
  vim.api.nvim_set_hl(0, "PosteSqlCellSelected", {
    fg = 0xffffff,
    bg = dark and 0x3b6fa0 or 0x2563eb,
    bold = true,
  })

  -- Search match: purple background, white text
  vim.api.nvim_set_hl(0, "PosteSearchMatch", {
    fg = 0xffffff,
    bg = dark and 0x6b21a8 or 0xd8b4fe,
    bold = true,
  })
  -- Current search match: brighter purple
  vim.api.nvim_set_hl(0, "PosteSearchCurrent", {
    fg = 0xffffff,
    bg = dark and 0x9333ea or 0x7e22ce,
    bold = true,
  })
  -- Filter indicator in winbar: green
  vim.api.nvim_set_hl(0, "PosteFilterActive", {
    fg = dark and 0x4ade80 or 0x16a34a,
    bold = true,
  })
  -- Search indicator in winbar: purple
  vim.api.nvim_set_hl(0, "PosteSearchActive", {
    fg = dark and 0xc084fc or 0x7e22ce,
    bold = true,
  })
  -- INSERT INTO value-to-column hint: yellow/gold underline for dark, blue for light
  vim.api.nvim_set_hl(0, "PosteInsertHint", {
    fg = dark and 0xe5c07b or 0x0550ae,
    bold = true,
    underline = true,
  })

  -- Editor: cell error indicator (red background)
  vim.api.nvim_set_hl(0, "PosteSqlError", {
    fg = dark and 0xff6b6b or 0xcf222e,
    bold = true,
  })

  -- SQL Log viewer: status icons
  vim.api.nvim_set_hl(0, "PosteLogSuccess", { fg = dark and 0x4ec94e or 0x2d8a2d })
  vim.api.nvim_set_hl(0, "PosteLogError",   { fg = dark and 0xf07070 or 0xc04040 })
  vim.api.nvim_set_hl(0, "PosteLogSQL",     { fg = dark and 0x9cdcfe or 0x0a6db5 })
  vim.api.nvim_set_hl(0, "PosteLogSQLKeyword", { fg = dark and 0xc586c0 or 0x8250df, bold = true })
  vim.api.nvim_set_hl(0, "PosteLogFilter",  { fg = dark and 0xd7d700 or 0x9a7d00, bold = true })
  -- Detail background: subtle green
  vim.api.nvim_set_hl(0, "PosteLogDetail", { bg = dark and 0x1a3a1a or 0xe8f5e9 })

  state.apply_highlight_overrides({
    "PosteSqlModified", "PosteSqlDeleted", "PosteSqlAdded",
    "PosteSqlCellText", "PosteSqlSep", "PosteSqlBorder",
    "PosteSqlHeader", "PosteSqlWinbarBorder", "PosteSqlWinbarSep",
    "PosteSqlMeta", "PosteSqlMetaDim", "PosteSqlNull",
    "PosteSqlNumber", "PosteSqlBool", "PosteSqlSortIndicator",
    "PosteSqlRowNum", "PosteSqlCellSelected",
    "PosteSearchMatch", "PosteSearchCurrent",
    "PosteFilterActive", "PosteSearchActive",
    "PosteInsertHint", "PosteSqlError",
    "PosteWinbarAdded", "PosteWinbarModified", "PosteWinbarDeleted",
    "PosteLogSuccess", "PosteLogError", "PosteLogSQL", "PosteLogSQLKeyword", "PosteLogFilter",
  })
end

-- Apply highlights on require
M.setup()
vim.api.nvim_create_autocmd("ColorScheme", { callback = M.setup })
vim.api.nvim_create_autocmd("VimEnter", { callback = M.setup, once = true })

--- Apply dataset highlights to a buffer.
--- @param buf number Buffer handle
--- @param lines string[] Buffer lines
--- @param meta table Dataset metadata from format.lua
function M.apply_dataset_highlights(buf, lines, meta)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  M.invalidate_sep_cache()

  if not meta or meta.type ~= "resultset" then
    if meta and meta.type == "error" then
      for i, line in ipairs(lines) do
        if line:match("^%s*ERROR") then
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
            end_row = i - 1,
            end_col = #line,
            hl_group = "PosteSqlError",
          })
        end
      end
      return
    end
    -- For other non-resultset types, highlight meta lines
    for i, line in ipairs(lines) do
      if line:match("^%s*%d+ row") or line:match("^%s*Page") or line:match("^%s*Context") then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
          end_row = i - 1,
          end_col = #line,
          hl_group = "PosteSqlMeta",
        })
      end
    end
    return
  end

  -- Header line: bold
  if meta.header_line then
    local hline = lines[meta.header_line] or ""
    vim.api.nvim_buf_set_extmark(buf, ns, meta.header_line - 1, 0, {
      end_row = meta.header_line - 1,
      end_col = #hline,
      hl_group = "PosteSqlHeader",
    })
  end

  -- Border lines (┌, ├, └ start borders; │ starts data rows)
  -- Must use explicit prefix check — Lua's [...] character class matches
  -- bytes, not Unicode codepoints, so [┌├└] also matches │ (same UTF-8 prefix).
  for i, line in ipairs(lines) do
    if line:sub(1, 3) == "┌" or line:sub(1, 3) == "├" or line:sub(1, 3) == "└" then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        end_row = i - 1,
        end_col = #line,
        hl_group = "PosteSqlBorder",
      })
    end
  end

  -- Data rows: highlight NULL cells and row number column
  if meta.data_start_line and meta.data_end_line then
    local row_count = meta.data_end_line - meta.data_start_line + 1
    local defer_row_nums = row_count > 1000

    for row_idx = meta.data_start_line, meta.data_end_line do
      local line = lines[row_idx] or ""

      -- Row number column (immediate for ≤1000 rows; deferred via schedule for large unpaginated)
      if not row_nums_hidden() and not defer_row_nums then
        local row_range = M.find_cell_range(line, 1)
        if row_range and row_range.ext_start <= #line then
          vim.api.nvim_buf_set_extmark(buf, ns, row_idx - 1, row_range.ext_start, {
            end_row = row_idx - 1,
            end_col = math.min(row_range.ext_end, #line),
            hl_group = "PosteSqlRowNum",
            priority = 100,
          })
        end
      end

      -- Find NULL occurrences (always immediate)
      local col = 0
      while true do
        local start, stop = line:find("%(NULL%)", col + 1)
        if not start then break end
        vim.api.nvim_buf_set_extmark(buf, ns, row_idx - 1, start - 1, {
          end_row = row_idx - 1,
          end_col = stop,
          hl_group = "PosteSqlNull",
        })
        col = stop
      end
    end

    if not row_nums_hidden() and defer_row_nums then
      local captured_lines = lines
      vim.schedule(function()
        if row_nums_hidden() or not vim.api.nvim_buf_is_valid(buf) then return end
        for row_idx = meta.data_start_line, meta.data_end_line do
          local line = captured_lines[row_idx] or ""
          local row_range = M.find_cell_range(line, 1)
          if row_range and row_range.ext_start <= #line then
            pcall(vim.api.nvim_buf_set_extmark, buf, ns, row_idx - 1, row_range.ext_start, {
              end_row = row_idx - 1,
              end_col = math.min(row_range.ext_end, #line),
              hl_group = "PosteSqlRowNum",
              priority = 100,
            })
          end
        end
      end)
    end
  end

end

-- NOTE: Cell text color is now handled via syntax highlighting in
-- syntax/poste_dataset.vim (PosteDatasetCellText group) instead of extmarks.
-- Extmarks always override syntax highlighting's fg attribute regardless
-- of priority or hl_mode setting.

--- O(1) lookup: find cell byte range from pre-computed column positions.
--- `col_starts` is a 1-indexed array of `{ ext_start, ext_end }` in padded-line
--- 0-based byte offsets, as stored in tab.buffer_col_starts.
--- @param col_starts table[] Array of { ext_start, ext_end } for each column
--- @param col number 1-based column index (1 = row number column)
--- @return table|nil { ext_start, ext_end, cursor_col } or nil
local function find_cell_range_by_starts(col_starts, col)
  local cell = col_starts[col]
  if not cell then return nil end
  return { ext_start = cell.ext_start, ext_end = cell.ext_end, cursor_col = cell.ext_start }
end

--- Fallback: scan line for │ separators to find cell byte range.
--- Used when col_starts are not available (legacy path).
local function find_cell_range_scan(line, col)
  if not line or line == "" then return nil end
  local sep = "│"
  local sep_len = #sep
  local seps = {}
  local pos = 1
  while true do
    pos = line:find(sep, pos, true)
    if not pos then break end
    seps[#seps + 1] = pos
    pos = pos + sep_len
  end
  if col > #seps - 1 then return nil end
  return { ext_start = seps[col] + 2, ext_end = seps[col + 1] - 1, cursor_col = seps[col] + 2 }
end

--- Find cell byte range, trying pre-computed col_starts first.
--- @param line string|nil The rendered line (for fallback scan)
--- @param col number 1-based column index
--- @param col_starts table|nil Pre-computed column positions (from tab.buffer_col_starts)
--- @return table|nil { ext_start, ext_end, cursor_col } or nil
function M.find_cell_range(line, col, col_starts)
  if col_starts then
    local r = find_cell_range_by_starts(col_starts, col)
    if r then return r end
  end
  return find_cell_range_scan(line, col)
end

--- Find byte ranges for target and optionally last column.
--- Prefers pre-computed col_starts when available.
--- @param line string The rendered line (for fallback scan)
--- @param target_col number 1-based target column index
--- @param last_col number|nil 1-based last column index
--- @param col_starts table|nil Pre-computed column positions (from tab.buffer_col_starts)
--- @return table|nil { target: { ext_start, ext_end, cursor_col }, last?: { ext_start, ext_end, cursor_col } } or nil
function M.find_cell_ranges(line, target_col, last_col, col_starts)
  if col_starts then
    local target = find_cell_range_by_starts(col_starts, target_col)
    if not target then return nil end
    local result = { target = target }
    if last_col then
      local last = find_cell_range_by_starts(col_starts, last_col)
      if last then result.last = last end
    end
    return result
  end
  return M.find_cell_ranges_fallback(line, target_col, last_col)
end

--- Legacy fallback: scan line for │ separators.
function M.find_cell_ranges_fallback(line, target_col, last_col)
  if not line or line == "" then return nil end
  local sep = "│"
  local sep_len = #sep
  local seps = {}
  local pos = 1
  while true do
    pos = line:find(sep, pos, true)
    if not pos then break end
    seps[#seps + 1] = pos
    pos = pos + sep_len
  end
  if target_col > #seps - 1 then return nil end
  local function range_for(col)
    return { ext_start = seps[col] + 2, ext_end = seps[col + 1] - 1, cursor_col = seps[col] + 2 }
  end
  local result = { target = range_for(target_col) }
  if last_col and last_col <= #seps - 1 then
    result.last = range_for(last_col)
  end
  return result
end

--- Stub: kept for backward compatibility (called from buffer.lua).
function M.invalidate_sep_cache() end

--- Highlight the currently selected cell in the dataset.
--- @param buf number Buffer handle
--- @param row number 1-based row in data
--- @param col number 1-based column index
--- @param meta table Dataset metadata
--- @param line string|nil Pre-fetched buffer line (avoids extra nvim_buf_get_lines call)
--- @param col_starts table|nil Pre-computed column positions (from tab.buffer_col_starts[line_idx])
function M.highlight_cell(buf, row, col, meta, line, col_starts)
  -- Clear previous cell highlight
  vim.api.nvim_buf_clear_namespace(buf, ns_cell, 0, -1)
  if not state.sql.highlight_cell then return end

  if not meta or meta.type ~= "resultset" then return end
  if not meta.data_start_line or not meta.data_end_line then return end

  local line_idx = meta.data_start_line + row - 1
  if line_idx > meta.data_end_line then return end

  -- +1 offset: visual column 1 is the row number column
  local range
  if col_starts then
    range = find_cell_range_by_starts(col_starts, col + 1)
  else
    line = line or vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
    range = M.find_cell_range(line, col + 1)
  end
  if not range then return end

  -- Clamp to line byte length
  if not col_starts and range.ext_start > #line then return end

  vim.api.nvim_buf_set_extmark(buf, ns_cell, line_idx - 1, range.ext_start, {
    end_row = line_idx - 1,
    end_col = range.ext_end,
    hl_group = "PosteSqlCellSelected",
    priority = 200,
  })
end

--- Clear cell selection highlight.
function M.clear_cell_highlight(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns_cell, 0, -1)
end

---------------------------------------------------------------------------
-- Edit highlights namespace
---------------------------------------------------------------------------

local ns_edit = vim.api.nvim_create_namespace("poste_sql_dataset_edit")

--- Apply edit highlights (modified/deleted/added rows, cell errors).
--- @param buf number Buffer handle
--- @param tab table Tab state with edit_state
function M.apply_edit_highlights(buf, tab)
  vim.api.nvim_buf_clear_namespace(buf, ns_edit, 0, -1)
  if not tab or not tab.edit_state or not tab.edit_state.dirty then return end
  if not tab.meta or tab.meta.type ~= "resultset" then return end
  if not tab.meta.data_start_line then return end

  local es = tab.edit_state
  local meta = tab.meta

  -- Deleted rows: full line strikethrough
  for row_idx, _ in pairs(es.deleted_rows) do
    local line_idx = meta.data_start_line + row_idx - 1
    if line_idx <= meta.data_end_line then
      local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
      vim.api.nvim_buf_set_extmark(buf, ns_edit, line_idx - 1, 0, {
        end_row = line_idx - 1,
        end_col = #line,
        hl_group = "PosteSqlDeleted",
        hl_mode = "combine",
        priority = 300,
      })
    end
  end

  -- Added rows: full line green
  for _, added in ipairs(es.added_rows) do
    local row_idx = added.row_idx
    if row_idx then
      local line_idx = meta.data_start_line + row_idx - 1
      if line_idx <= meta.data_end_line then
        local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
        vim.api.nvim_buf_set_extmark(buf, ns_edit, line_idx - 1, 0, {
          end_row = line_idx - 1,
          end_col = #line,
          hl_group = "PosteSqlAdded",
          hl_mode = "combine",
          priority = 300,
        })
      end
    end
  end

  -- Modified cells: highlight individual cells
  for row_key, mod in pairs(es.modified_cells) do
    local row_idx = tonumber(row_key:match("^(%d+):"))
    if row_idx then
      local line_idx = meta.data_start_line + row_idx - 1
      if line_idx <= meta.data_end_line then
        local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
        local range = M.find_cell_range(line, mod.col + 1)  -- +1 for row number column
        if range then
          local ext_start = math.min(range.ext_start, #line)
          local ext_end = math.min(range.ext_end, #line)
          if ext_start < ext_end then
            vim.api.nvim_buf_set_extmark(buf, ns_edit, line_idx - 1, ext_start, {
              end_row = line_idx - 1,
              end_col = ext_end,
              hl_group = "PosteSqlModified",
              hl_mode = "combine",
              priority = 250,
            })
          end
        end
      end
    end
  end

  -- Cell errors: red highlight
  for row_key, msg in pairs(es.cell_errors) do
    local row_idx = tonumber(row_key:match("^(%d+):"))
    local col_idx = tonumber(row_key:match(":(%d+)$"))
    if row_idx and col_idx then
      local line_idx = meta.data_start_line + row_idx - 1
      if line_idx <= meta.data_end_line then
        local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
        local range = M.find_cell_range(line, col_idx + 1)
        if range then
          local ext_start = math.min(range.ext_start, #line)
          local ext_end = math.min(range.ext_end, #line)
          if ext_start < ext_end then
            vim.api.nvim_buf_set_extmark(buf, ns_edit, line_idx - 1, ext_start, {
              end_row = line_idx - 1,
              end_col = ext_end,
              hl_group = "PosteSqlError",
              hl_mode = "combine",
              priority = 350,
            })
          end
        end
      end
    end
  end
end

--- Clear all edit highlights.
function M.clear_edit_highlights(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns_edit, 0, -1)
end

return M
