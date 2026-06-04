--- Highlight groups and extmark application for SQL dataset buffer.
local M = {}

local ns = vim.api.nvim_create_namespace("poste_sql_dataset")

--- Resolve highlight group links fully (follow chains of `link`).
local function resolve_hl(name)
  local hl = vim.api.nvim_get_hl(0, { name = name })
  while hl.link do
    hl = vim.api.nvim_get_hl(0, { name = hl.link })
  end
  return hl
end

--- Define all SQL highlight groups and register autocmds.
function M.setup()
  local groups = {
    { "PosteSqlHeader",     "Title" },
    { "PosteSqlNull",       "Comment" },
    { "PosteSqlMeta",       "Comment" },
    { "PosteSqlBorder",     "Delimiter" },
    { "PosteSqlCellSelected", "Visual" },
    { "PosteSqlModified",   "DiffChange" },
    { "PosteSqlDeleted",    "DiffDelete" },
    { "PosteSqlAdded",      "DiffAdd" },
    { "PosteSqlNumber",     "Number" },
    { "PosteSqlBool",       "Boolean" },
  }

  for _, pair in ipairs(groups) do
    local existing = vim.api.nvim_get_hl(0, { name = pair[1] })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, pair[1], { link = pair[2] })
    end
  end
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

  -- Border lines
  for i, line in ipairs(lines) do
    if line:match("^[┌├└]") then
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

--- Highlight the currently selected cell in the dataset.
--- @param buf number Buffer handle
--- @param row number 1-based row in data
--- @param col number 1-based column index
--- @param meta table Dataset metadata
function M.highlight_cell(buf, row, col, meta)
  -- Clear previous cell highlight
  vim.api.nvim_buf_clear_namespace(buf, ns .. "_cell", 0, -1)
  -- Note: using a separate namespace for cell selection to avoid
  -- clearing all dataset highlights on cursor move.

  if not meta or meta.type ~= "resultset" then return end
  if not meta.data_start_line or not meta.data_end_line then return end

  local line_idx = meta.data_start_line + row - 1
  if line_idx > meta.data_end_line then return end

  local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
  if not meta.col_positions or not meta.col_widths then return end

  local col_start = meta.col_positions[col]
  if not col_start then return end
  local col_end = col_start + (meta.col_widths[col] or 0) + 1

  -- Clamp to line length
  if col_start > #line then return end
  col_end = math.min(col_end, #line)

  vim.api.nvim_buf_set_extmark(buf, ns .. "_cell", line_idx - 1, col_start - 1, {
    end_row = line_idx - 1,
    end_col = col_end - 1,
    hl_group = "PosteSqlCellSelected",
    priority = 200,
  })
end

--- Clear cell selection highlight.
function M.clear_cell_highlight(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns .. "_cell", 0, -1)
end

return M
