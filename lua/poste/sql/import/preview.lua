local M = {}

local function build_preview_lines(table_info, total_rows, valid_count, bad_rows,
    col_map, unmatched_import, unmatched_table, parsed_cols, parsed_rows, max_preview_cols)
  local lines = {}
  local function add(l) table.insert(lines, l) end

  add(string.format("Table: %s.%s    Connection: %s (%s)",
    table_info.schema or "(default)", table_info.name,
    table_info.connection, table_info.dialect))
  add("")
  add(string.format("Parsed: %d rows total, %d valid, %d with errors",
    total_rows, valid_count, #bad_rows))

  if parsed_rows and #parsed_rows > 0 then
    add("")
    add("Data preview (first rows):")

    local num_preview_cols = math.min(max_preview_cols, #parsed_cols)
    local has_more_cols = num_preview_cols < #parsed_cols
    local num_preview_rows = math.min(3, #parsed_rows)

    local col_vals = {}
    for ci = 1, num_preview_cols do
      local vals = { parsed_cols[ci] }
      for ri = 1, num_preview_rows do
        local v = parsed_rows[ri][ci]
        local display
        if v == nil or v == vim.NIL then display = "NULL"
        elseif type(v) == "string" then display = v
        else display = tostring(v) end
        table.insert(vals, display)
      end
      table.insert(col_vals, vals)
    end

    local col_widths = {}
    for ci = 1, num_preview_cols do
      local max_w = 0
      for _, val in ipairs(col_vals[ci]) do
        max_w = math.max(max_w, vim.fn.strdisplaywidth(val))
      end
      col_widths[ci] = max_w
    end

    local function pad_val(vals, ri, cw)
      local val = vals[ri]
      local pad = cw - vim.fn.strdisplaywidth(val)
      if pad > 0 then val = val .. string.rep(" ", pad) end
      return val
    end

    local sep_parts = {}
    for ci = 1, num_preview_cols do
      sep_parts[ci] = string.rep("-", col_widths[ci])
    end

    local ext_suffix = ""
    if has_more_cols then ext_suffix = " | ..." end

    local header_cells = {}
    for ci = 1, num_preview_cols do
      table.insert(header_cells, pad_val(col_vals[ci], 1, col_widths[ci]))
    end
    add("  " .. table.concat(header_cells, " | ") .. ext_suffix)

    add("  " .. table.concat(sep_parts, "-|-") .. ext_suffix)

    for ri = 1, num_preview_rows do
      local data_cells = {}
      for ci = 1, num_preview_cols do
        table.insert(data_cells, pad_val(col_vals[ci], ri + 1, col_widths[ci]))
      end
      add("  " .. table.concat(data_cells, " | ") .. ext_suffix)
    end

    if #parsed_rows > 3 then
      add("  ... (" .. (#parsed_rows - 3) .. " more row(s))")
    end
  end

  add("")
  add("Column mapping:")
  local max_import_w = math.max(4, 0)
  local max_table_w = math.max(5, 0)
  for _, mc in ipairs(col_map) do
    local iw = vim.fn.strdisplaywidth(mc.import_name)
    local tw = vim.fn.strdisplaywidth(mc.table_col.name .. " (" .. mc.table_col.col_type .. ")")
    if iw > max_import_w then max_import_w = iw end
    if tw > max_table_w then max_table_w = tw end
  end
  local sep = "  " .. string.rep("-", max_import_w) .. "-+-" .. string.rep("-", max_table_w)
  local function fmt_row(left, right)
    local l = left .. string.rep(" ", max_import_w - vim.fn.strdisplaywidth(left))
    local r = right .. string.rep(" ", max_table_w - vim.fn.strdisplaywidth(right))
    return "  " .. l .. " | " .. r
  end
  add(fmt_row("file", "table"))
  add(sep)
  local orange_rows = {}
  for i, mc in ipairs(col_map) do
    local tc = mc.table_col
    local right = tc.name .. " (" .. tc.col_type .. ")"
    add(fmt_row(mc.import_name, right))
    if tc and not tc.nullable and not tc.is_pk and (tc.default == nil or tc.default == vim.NIL) then
      table.insert(orange_rows, #lines)
    end
  end

  add(sep)
  if #unmatched_import > 0 then
    add(string.format("  (unmatched: %s)", table.concat(unmatched_import, ", ")))
  end
  if #unmatched_table > 0 then
    local names = {}
    for _, tc in ipairs(unmatched_table) do
      table.insert(names, tc.name)
    end
    add(string.format("  (missing: %s <- DEFAULT)", table.concat(names, ", ")))
  end

  if #bad_rows > 0 then
    add("")
    add("Validation errors:")
    for i = 1, math.min(#bad_rows, 5) do
      for _, err in ipairs(bad_rows[i].errors) do
        add(err)
      end
    end
    if #bad_rows > 5 then
      add(string.format("  ... and %d more row(s) with errors", #bad_rows - 5))
    end
  end

  return lines, orange_rows
end

function M.show_preview(table_info, total_rows, valid_count, bad_rows,
    col_map, unmatched_import, unmatched_table, parsed_cols, parsed_rows, callback)
  local max_preview_cols = 6
  local content, orange_rows = build_preview_lines(table_info, total_rows, valid_count, bad_rows,
    col_map, unmatched_import, unmatched_table, parsed_cols, parsed_rows, max_preview_cols)

  local content_width = 0
  for _, l in ipairs(content) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(l))
  end
  local min_width = 60
  local text_area = math.max(content_width, min_width)
  width = math.min(text_area + 4, math.floor(vim.o.columns * 0.8))

  local lines = content
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.6))

  local right_title = " [P]roceed  [A]bort "
  if #bad_rows > 0 then
    right_title = " [P]roceed  [S]kip bad  [A]bort "
  end
  local left_title = " Import Preview "
  local interior = width - 2
  local left_w = vim.fn.strdisplaywidth(left_title)
  local right_w = vim.fn.strdisplaywidth(right_title)
  local middle_w = interior - left_w - right_w
  local title
  if middle_w >= 1 then
    title = left_title .. string.rep("─", middle_w) .. right_title
  else
    title = " Import Preview "
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win_opts = {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height, style = "minimal",
    border = "rounded", title = title, title_pos = "left",
  }
  local ok, win = pcall(vim.api.nvim_open_win, buf, true, win_opts)
  if not ok then
    win_opts.title = nil
    win = vim.api.nvim_open_win(buf, true, win_opts)
  end

  vim.wo[win].cursorline = false
  vim.wo[win].cursorcolumn = false

  local ns = vim.api.nvim_create_namespace("poste_import_preview")

  local parsed_li = 2
  local parsed_text = lines[parsed_li + 1]
  if parsed_text then
    local s1, e1 = parsed_text:find("%d+", 9)
    local s2, e2 = parsed_text:find("%d+", e1 + 1)
    local s3, e3 = parsed_text:find("%d+", e2 + 1)
    if s1 then vim.api.nvim_buf_add_highlight(buf, ns, "Number", parsed_li, s1 - 1, e1) end
    if s2 then vim.api.nvim_buf_add_highlight(buf, ns, "String", parsed_li, s2 - 1, e2) end
    if s3 then vim.api.nvim_buf_add_highlight(buf, ns, "DiagnosticError", parsed_li, s3 - 1, e3) end
  end

  for _, li in ipairs(orange_rows) do
    vim.api.nvim_buf_add_highlight(buf, ns, "DiagnosticWarn", li - 1, 0, -1)
  end

  local closed = false
  local function close()
    if closed then return end
    closed = true
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local sopts = { buffer = buf, noremap = true, silent = true, nowait = true }
  vim.keymap.set("n", "q", close, sopts)
  vim.keymap.set("n", "<Esc>", close, sopts)
  vim.keymap.set("n", "a", function() close(); callback(nil) end, sopts)
  vim.keymap.set("n", "A", function() close(); callback(nil) end, sopts)
  vim.keymap.set("n", "p", function() close(); callback("proceed") end, sopts)
  vim.keymap.set("n", "P", function() close(); callback("proceed") end, sopts)
  if #bad_rows > 0 then
    vim.keymap.set("n", "s", function() close(); callback("skip") end, sopts)
    vim.keymap.set("n", "S", function() close(); callback("skip") end, sopts)
  end
end

return M
