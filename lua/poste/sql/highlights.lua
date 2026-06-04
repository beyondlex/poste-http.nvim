--- Highlight groups and extmark application for SQL dataset buffer.
local M = {}

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
    { "PosteSqlAdded",      "DiffAdd" },
  }

  for _, pair in ipairs(groups) do
    local existing = vim.api.nvim_get_hl(0, { name = pair[1] })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, pair[1], { link = pair[2] })
    end
  end

  -- Theme-aware colors for dataset buffer text.
  -- Detect dark/light from Normal background luminance.
  local normal = resolve_hl("Normal")
  local dark = is_dark(normal.bg)

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
  -- Meta footer
  vim.api.nvim_set_hl(0, "PosteSqlMeta", {
    fg = dark and 0x7f848e or 0x6a737d,
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

  -- Cell selection: bright bg with contrasting fg
  vim.api.nvim_set_hl(0, "PosteSqlCellSelected", {
    fg = 0xffffff,
    bg = dark and 0x3b6fa0 or 0x2563eb,
    bold = true,
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

  if not meta or meta.type ~= "resultset" then
    -- For non-resultset types, just highlight meta lines
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

  -- Data rows: highlight NULL cells and numbers
  if meta.data_start_line and meta.data_end_line then
    for row_idx = meta.data_start_line, meta.data_end_line do
      local line = lines[row_idx] or ""
      -- Find NULL occurrences
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
  end

  -- Meta footer line
  if meta.meta_line then
    local mline = lines[meta.meta_line] or ""
    vim.api.nvim_buf_set_extmark(buf, ns, meta.meta_line - 1, 0, {
      end_row = meta.meta_line - 1,
      end_col = #mline,
      hl_group = "PosteSqlMeta",
    })
  end
end

-- NOTE: Cell text color is now handled via syntax highlighting in
-- syntax/poste_dataset.vim (PosteDatasetCellText group) instead of extmarks.
-- Extmarks always override syntax highlighting's fg attribute regardless
-- of priority or hl_mode setting.

--- Find the byte range and cursor column for a cell in a rendered dataset line.
--- Reads the actual line content to locate │ separators, so it works
--- regardless of CJK widths, truncation, or multi-byte characters.
--- @param line string The rendered line (from buffer or format output)
--- @param col number 1-based column index
--- @return table|nil { ext_start, ext_end, cursor_col } or nil if not found
function M.find_cell_range(line, col)
  if not line or line == "" then return nil end
  local sep = "│"
  local sep_len = #sep  -- 3 bytes in UTF-8

  -- Find all separator positions
  local seps = {}
  local pos = 1
  while true do
    pos = line:find(sep, pos, true)
    if not pos then break end
    seps[#seps + 1] = pos
    pos = pos + sep_len
  end

  -- Cell col is between seps[col] and seps[col+1]
  if col > #seps - 1 then return nil end

  local next_sep = seps[col]
  local close_sep = seps[col + 1]

  -- extmark range: include leading+trailing spaces
  local ext_start = next_sep + sep_len - 1  -- 0-based, the leading space
  local ext_end = close_sep - 1             -- 0-based exclusive, up to trailing space

  -- cursor column: 0-based byte offset of content start (same as ext_start)
  local cursor_col = next_sep + sep_len - 1

  return { ext_start = ext_start, ext_end = ext_end, cursor_col = cursor_col }
end

--- Highlight the currently selected cell in the dataset.
--- @param buf number Buffer handle
--- @param row number 1-based row in data
--- @param col number 1-based column index
--- @param meta table Dataset metadata
function M.highlight_cell(buf, row, col, meta)
  -- Clear previous cell highlight
  vim.api.nvim_buf_clear_namespace(buf, ns_cell, 0, -1)

  if not meta or meta.type ~= "resultset" then return end
  if not meta.data_start_line or not meta.data_end_line then return end

  local line_idx = meta.data_start_line + row - 1
  if line_idx > meta.data_end_line then return end

  local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
  local range = M.find_cell_range(line, col)
  if not range then return end

  -- Clamp to line byte length
  if range.ext_start > #line then return end
  range.ext_end = math.min(range.ext_end, #line)

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

return M
