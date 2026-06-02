--- Floating window selector with fuzzy search.
--- Calls on_select(selected_item) when user makes a selection.
--- selected_item is nil if user cancelled.
local M = {}

function M.select(items, prompt_text, on_select)
  if #items == 0 then
    vim.schedule(function() on_select(nil) end)
    return
  end

  if #items <= 10 then
    -- Short list: use input() which accepts both index numbers and text values
    local choices_str = {}
    for idx, item in ipairs(items) do
      table.insert(choices_str, string.format("  %d. %s", idx, item))
    end
    local display = prompt_text .. "\n" .. table.concat(choices_str, "\n") .. "\n"
    vim.schedule(function()
      local ok, raw = pcall(vim.fn.input, { prompt = display .. "> ", default = "" })
      if not ok or not raw or raw == "" then
        on_select(nil)
        return
      end
      -- Try as numeric index first
      local num = tonumber(raw)
      if num and num >= 1 and num <= #items then
        on_select(items[num])
        return
      end
      -- Fall back to case-insensitive text match
      local lower_raw = raw:lower()
      for _, item in ipairs(items) do
        if item:lower() == lower_raw then
          on_select(item)
          return
        end
      end
      -- No match
      on_select(nil)
    end)
    return
  end

  -- Long list: use floating window with fuzzy search
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "filetype", "PosteSelect")

  -- Calculate window size
  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(20, #items + 2)  -- +2 for search line and border
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Create floating window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = prompt_text,
    title_pos = "center",
  })

  -- State
  local filtered = vim.deepcopy(items)
  local selected_idx = 1
  local search_text = ""
  local resolved = false

  -- Helper to resolve selection
  local function resolve(result)
    if resolved then return end
    resolved = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.schedule(function() on_select(result) end)
  end

  -- Render function
  local function render()
    local lines = { "\239\132\133 " .. search_text }
    for idx, item in ipairs(filtered) do
      local prefix = (idx == selected_idx) and "▶ " or "  "
      table.insert(lines, prefix .. item)
    end
    -- Pad with empty lines to maintain height
    while #lines < height do
      table.insert(lines, "")
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    -- Highlight selected line
    vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
    if selected_idx > 0 and selected_idx <= #filtered then
      vim.api.nvim_buf_add_highlight(buf, -1, "Visual", selected_idx, 0, -1)
    end
  end

  -- Filter items based on search text
  local function filter_items()
    if search_text == "" then
      filtered = vim.deepcopy(items)
      selected_idx = 1
    else
      filtered = {}
      local lower_search = search_text:lower()
      local exact_idx = nil
      for _, item in ipairs(items) do
        if item:lower():find(lower_search, 1, true) then
          table.insert(filtered, item)
          -- Check for exact match (case-insensitive)
          if item:lower() == lower_search and not exact_idx then
            exact_idx = #filtered
          end
        end
      end
      selected_idx = exact_idx or 1
    end
    render()
  end

  -- Keymaps
  local function map_key(mode, key, action)
    vim.keymap.set(mode, key, action, { buffer = buf, nowait = true })
  end

  -- Navigation
  map_key("n", "j", function()
    selected_idx = math.min(selected_idx + 1, #filtered)
    render()
  end)
  map_key("n", "k", function()
    selected_idx = math.max(selected_idx - 1, 1)
    render()
  end)
  map_key("n", "<Down>", function()
    selected_idx = math.min(selected_idx + 1, #filtered)
    render()
  end)
  map_key("n", "<Up>", function()
    selected_idx = math.max(selected_idx - 1, 1)
    render()
  end)

  -- Selection
  map_key("n", "<CR>", function()
    if #filtered > 0 then
      resolve(filtered[selected_idx])
    else
      resolve(nil)
    end
  end)
  map_key("n", "<Esc>", function()
    resolve(nil)
  end)
  map_key("n", "q", function()
    resolve(nil)
  end)

  -- Search input
  map_key("n", "i", function()
    vim.cmd("startinsert!")
  end)
  map_key("n", "a", function()
    vim.cmd("startinsert!")
  end)

  -- Insert mode mappings
  map_key("i", "<CR>", function()
    vim.cmd("stopinsert")
    if #filtered > 0 then
      resolve(filtered[selected_idx])
    else
      resolve(nil)
    end
  end)
  map_key("i", "<Esc>", function()
    vim.cmd("stopinsert")
    resolve(nil)
  end)
  map_key("i", "<Down>", function()
    selected_idx = math.min(selected_idx + 1, #filtered)
    render()
  end)
  map_key("i", "<Up>", function()
    selected_idx = math.max(selected_idx - 1, 1)
    render()
  end)

  -- Real-time filtering on text change (TextChangedI for insert mode)
  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = buf,
    callback = function()
      if resolved then return end
      local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
      local first_line = lines[1] or ""
      -- Extract search text after prefix
      local new_search = first_line:match("^\239\132\133 (.*)$") or ""
      if new_search ~= search_text then
        search_text = new_search
        filter_items()
      end
    end,
  })

  -- Initial render
  render()
  vim.cmd("startinsert!")
end

return M
