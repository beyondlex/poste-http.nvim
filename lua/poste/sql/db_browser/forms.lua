--- Data-driven form UI for DB Browser operations (Modify Column, New Table, etc.)
--- M.open(title, fields, on_submit) renders a floating form window.
--- fields: { { label, key, value, kind }, ... }  kind = "text" | "bool"
local M = {}

local ns_form = vim.api.nvim_create_namespace("poste_db_form")

--- Find max display width across labels and values.
local function max_field_width(fields)
  local w = 0
  for _, f in ipairs(fields) do
    w = math.max(w, #f.label)
    if f.kind == "text" then
      w = math.max(w, #(tostring(f.value or "")))
    end
  end
  return w
end

--- Render form lines into a buffer. Returns { lines, field_rows } where
--- field_rows[i] = line number of field i (1-indexed within buffer).
local function render_form(buf, title, fields, current_idx)
  local label_width = 0
  for _, f in ipairs(fields) do
    label_width = math.max(label_width, #f.label)
  end
  label_width = math.max(label_width, 4)

  local content_width = label_width + 4 + 20  -- "  Label: " + value area
  local width = math.max(#title + 4, content_width)

  local lines = {}
  local field_rows = {}

  table.insert(lines, "┌ " .. title .. " " .. string.rep("─", width - #title - 2) .. "┐")
  table.insert(lines, "")
  local header_end = #lines

  for i, f in ipairs(fields) do
    local pad = label_width - #f.label
    local display_val
    if f.kind == "bool" then
      display_val = f.value and "✓" or "✗"
    else
      display_val = f.value or ""
    end
    local line = "  " .. f.label .. ": " .. string.rep(" ", pad) .. display_val
    table.insert(lines, line)
    field_rows[i] = #lines
  end

  table.insert(lines, "")
  local submit_row = #lines + 1
  table.insert(lines, "  [<CR> Submit]  [q Cancel]")

  table.insert(lines, "")
  table.insert(lines, "└" .. string.rep("─", width) .. "┘")

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Highlight current field
  vim.api.nvim_buf_clear_namespace(buf, ns_form, 0, -1)
  if field_rows[current_idx] then
    vim.api.nvim_buf_add_highlight(buf, ns_form, "Visual",
      field_rows[current_idx] - 1, 0, -1)
  end

  return field_rows, submit_row
end

--- Open a form floating window.
--- @param title    string    Window title
--- @param fields   table[]   { label, key, value, kind }
--- @param on_submit fun(fields: table[])  Called with updated fields on submit
function M.open(title, fields, on_submit)
  if not fields or #fields == 0 then return end

  local current_idx = 1

  local function calc_size()
    local label_width = 0
    for _, f in ipairs(fields) do
      label_width = math.max(label_width, #f.label)
    end
    label_width = math.max(label_width, 4)
    local content_width = label_width + 4 + 20
    local width = math.max(#title + 4, content_width)
    local height = #fields + 6  -- borders + padding + submit row
    return width, height
  end

  local width, height = calc_size()
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  if row < 0 then row = 0 end
  if col < 0 then col = 0 end

  local form_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[form_buf].modifiable = true

  local win_opts = {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "none",
  }
  local ok, form_win = pcall(vim.api.nvim_open_win, form_buf, true, win_opts)
  if not ok then return end

  vim.wo[form_win].cursorline = false
  vim.wo[form_win].winhl = "Normal:NormalFloat"

  local field_rows = {}
  local submit_row = 0
  local closed = false

  local function refresh()
    field_rows, submit_row = render_form(form_buf, title, fields, current_idx)
    -- Position cursor on current field
    local target_row = field_rows[current_idx] or submit_row
    if target_row > 0 then
      pcall(vim.api.nvim_win_set_cursor, form_win, { target_row, 3 })
    end
  end

  local function close()
    if closed then return end
    closed = true
    if form_win and vim.api.nvim_win_is_valid(form_win) then
      vim.api.nvim_win_close(form_win, true)
    end
  end

  local function move_cursor(delta)
    local new_idx = current_idx + delta
    if new_idx < 1 or new_idx > #fields then return end
    current_idx = new_idx
    refresh()
  end

  local function edit_current()
    local f = fields[current_idx]
    if not f then return end

    if f.kind == "bool" then
      f.value = not f.value
      refresh()
      return
    end

    -- Text field: open vim.ui.input
    local current_val = tostring(f.value or "")
    vim.ui.input({
      prompt = f.label .. ": ",
      default = current_val,
    }, function(input)
      if closed then return end
      if input ~= nil then
        f.value = input
      end
      if form_win and vim.api.nvim_win_is_valid(form_win) then
        vim.api.nvim_set_current_win(form_win)
      end
      refresh()
    end)
  end

  refresh()

  local opts = { buffer = form_buf, noremap = true, silent = true, nowait = true }

  vim.keymap.set("n", "j", function() move_cursor(1) end, opts)
  vim.keymap.set("n", "k", function() move_cursor(-1) end, opts)
  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(form_win)
    if cursor[1] == submit_row then
      close()
      vim.schedule(function() on_submit(fields) end)
    else
      for i, row in ipairs(field_rows) do
        if row == cursor[1] then
          current_idx = i
          break
        end
      end
      edit_current()
    end
  end, opts)
  vim.keymap.set("n", "<Space>", function()
    local f = fields[current_idx]
    if f and f.kind == "bool" then
      f.value = not f.value
      refresh()
    end
  end, opts)
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
end

return M
