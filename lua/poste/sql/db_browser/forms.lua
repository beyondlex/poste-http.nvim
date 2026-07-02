--- Data-driven form UI for DB Browser operations (Modify Column, New Table, etc.)
--- M.open(title, fields, on_submit) renders a floating form window.
--- fields: { { label, key, value, kind }, ... }  kind = "text" | "bool"
local M = {}

local state = require("poste.state")

local ns_form = vim.api.nvim_create_namespace("poste_db_form")

-- Form visual highlight groups — applied at load and on ColorScheme change
local function setup_hl()
  vim.api.nvim_set_hl(0, "PosteFormBorder",    { fg = 0x7aa2f7, bold = true })
  vim.api.nvim_set_hl(0, "PosteFormTitle",     { fg = 0xe0af68, bold = true })
  vim.api.nvim_set_hl(0, "PosteFormSubmit",    { fg = 0x98c379, bold = true })
  vim.api.nvim_set_hl(0, "PosteFormCancel",    { fg = 0x5c6370 })
  state.apply_highlight_overrides({
    "PosteFormBorder", "PosteFormTitle", "PosteFormSubmit", "PosteFormCancel",
  })
end
setup_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = setup_hl })

--- Convert a field value to a displayable string.
--- nil/vim.NULL → "(not set)" virtual text
--- empty string → "''"
--- bool → ✓/✗
local function to_display(f)
  if f.kind == "bool" then
    return f.value and "✓" or "✗"
  end
  local v = f.value
  if v == nil or v == vim.NULL or type(v) == "userdata" then return "(not set)" end
  if v == "" then return "''" end
  return tostring(v)
end

--- Render form lines into a buffer. Returns { lines, field_rows } where
--- field_rows[i] = line number of field i (1-indexed within buffer).
local function render_form(buf, title, fields, current_idx)
  local label_dw = 4
  for _, f in ipairs(fields) do
    label_dw = math.max(label_dw, vim.fn.strdisplaywidth(f.label))
  end

  local content_width = label_dw + 4 + 24  -- "  Label: " + value area
  local title_dw = vim.fn.strdisplaywidth(title)
  -- Top border: "┌ " (2) + title + " " (1) + pad + "┐" (1) = title_dw + 4 + pad
  -- So pad = width - title_dw - 4
  local width = math.max(title_dw + 6, content_width)

  local lines = {}
  local field_rows = {}

  local top_pad = width - title_dw - 4
  if top_pad < 0 then top_pad = 0 end
  table.insert(lines, "┌ " .. title .. " " .. string.rep("─", top_pad) .. "┐")
  table.insert(lines, "")

  for i, f in ipairs(fields) do
    local pad = label_dw - vim.fn.strdisplaywidth(f.label)
    local display_val = to_display(f)
    local line = "  " .. f.label .. ": " .. string.rep(" ", pad) .. display_val
    table.insert(lines, line)
    field_rows[i] = #lines
  end

  table.insert(lines, "")
  local submit_row = #lines + 1
  local btn_text = "  [q Cancel]  [s Submit]"
  local btn_dw = vim.fn.strdisplaywidth(btn_text)
  local right_pad = width - btn_dw
  if right_pad < 0 then right_pad = 0 end
  table.insert(lines, string.rep(" ", right_pad) .. btn_text)

  table.insert(lines, "  j/k:move  Enter:edit  Space:toggle  s:submit  q:close")
  local hints_row = #lines

  table.insert(lines, "└" .. string.rep("─", width - 2) .. "┘")  -- -2 for └ and ┘

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Highlight current field
  vim.api.nvim_buf_clear_namespace(buf, ns_form, 0, -1)
  if field_rows[current_idx] then
    vim.api.nvim_buf_add_highlight(buf, ns_form, "Visual",
      field_rows[current_idx] - 1, 0, -1)
  end
  -- Hints row in subtle color
  vim.api.nvim_buf_add_highlight(buf, ns_form, "Comment", hints_row - 1, 0, -1)
  -- Submit / Cancel buttons with distinct colors — Cancel left, Submit right
  vim.api.nvim_buf_add_highlight(buf, ns_form, "PosteFormCancel", submit_row - 1, right_pad + 2, right_pad + 12)
  vim.api.nvim_buf_add_highlight(buf, ns_form, "PosteFormSubmit", submit_row - 1, right_pad + 14, right_pad + 24)
  -- Top border + title
  vim.api.nvim_buf_add_highlight(buf, ns_form, "PosteFormBorder", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, ns_form, "PosteFormTitle", 0, 4, 4 + #title)
  -- Bottom border
  local last_line = #lines - 1
  vim.api.nvim_buf_add_highlight(buf, ns_form, "PosteFormBorder", last_line, 0, -1)
  -- Virtual text for unset defaults
  for i, f in ipairs(fields) do
    if f.kind == "text" and (f.value == nil or f.value == vim.NULL or type(f.value) == "userdata") and field_rows[i] then
      local line_nr = field_rows[i] - 1
      local line_text = vim.api.nvim_buf_get_lines(buf, line_nr, line_nr + 1, false)[1] or ""
      local s, e = line_text:find("(not set)", 1, true)
      if s then
        vim.api.nvim_buf_add_highlight(buf, ns_form, "Comment", line_nr, s - 1, e)
      end
    end
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
    local label_dw = 4
    for _, f in ipairs(fields) do
      label_dw = math.max(label_dw, vim.fn.strdisplaywidth(f.label))
    end
    local content_width = label_dw + 4 + 24
    local title_dw = vim.fn.strdisplaywidth(title)
    local width = math.max(title_dw + 6, content_width)
    local height = #fields + 6  -- borders + padding + submit + hints
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

  -- Auto-close on blur
  local au_group = vim.api.nvim_create_augroup("PosteFormClose", { clear = true })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = au_group,
    buffer = form_buf,
    callback = close,
  })

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
    local v = f.value
    local current_val = (v == nil or v == vim.NULL or type(v) == "userdata") and "" or tostring(v)

    -- For type fields, enable dialect-specific completion via blink.cmp.
    local completion = require("poste.sql.db_browser.completion")
    if f.key == "col_type" then
      completion.enable_for_next_input()
    end

    vim.ui.input({
      prompt = f.label .. ": ",
      default = current_val,
    }, function(input)
      completion.cleanup()
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
      for i, field_row in ipairs(field_rows) do
        if field_row == cursor[1] then
          current_idx = i
          break
        end
      end
      edit_current()
    end
  end, opts)
  vim.keymap.set("n", "s", function()
    close()
    vim.schedule(function() on_submit(fields) end)
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
