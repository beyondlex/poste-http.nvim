--- Item selector with automatic picker detection.
--- Priority: telescope → fzf-lua → mini.pick → snacks → built-in float → vim.ui.select.
--- All branches call on_select(item) on pick, on_select(nil) on cancel.
--- Supports optional preview: select(items, prompt, on_select, preview_data)
local M = {}

---------------------------------------------------------------------------
-- External picker integrations
---------------------------------------------------------------------------

local function pick_telescope(items, prompt, on_select, preview_data)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  local resolved = false  -- luacheck: ignore 231

  -- When preview_data is available, use a custom previewer
  local previewer
  if preview_data then
    previewer = previewers.new_buffer_previewer({
      title = "Preview",
      define_preview = function(self, entry)
        local idx = entry.index
        local data = preview_data[idx]
        if data and data.lines then
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, data.lines)
          if data.filetype then
            vim.bo[self.state.bufnr].filetype = data.filetype
          end
          -- Highlight the matching line
          if data.highlight_line then
            vim.api.nvim_buf_add_highlight(self.state.bufnr, -1, "Visual",
              data.highlight_line - 1, 0, -1)
          end
        end
      end,
    })
  end

  -- Build entries with index for preview lookup
  local entries = {}
  for i, item in ipairs(items) do
    table.insert(entries, { value = item, display = item, ordinal = item, index = i })
  end

  local picker_opts = {
    prompt_title = prompt,
    finder = finders.new_table({
      results = entries,
      entry_maker = function(entry)
        return {
          value = entry.value,
          display = entry.display,
          ordinal = entry.ordinal,
          index = entry.index,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(_, map)
      map({ "i", "n" }, "<CR>", function(bufnr)
        local sel = state.get_selected_entry()
        actions.close(bufnr)
        resolved = true
        on_select(sel and sel.value or nil)
      end)
      return true
    end,
  }

  if previewer then
    picker_opts.previewer = previewer
  end

  pickers.new({}, picker_opts):find()
end

local function pick_fzf(items, prompt, on_select, preview_data)
  local fzf = require("fzf-lua")
  local fzf_opts = {
    prompt = (prompt or "Select") .. "> ",
    actions = {
      ["default"] = function(sel)
        on_select(sel and sel[1] or nil)
      end,
    },
  }

  -- Add preview for fzf-lua
  if preview_data then
    fzf_opts.preview = function(args)
      local idx = tonumber(args[1] and args[1]:match("^L(%d+):"))
      if idx and preview_data[idx] then
        return table.concat(preview_data[idx].lines, "\n")
      end
      return ""
    end
  end

  fzf.fzf_exec(items, fzf_opts)
end

local function pick_mini(items, prompt, on_select)
  local pick = require("mini.pick")
  local result = pick.start({
    items = items,
    source = { name = prompt or "Select" },
  })
  on_select(result)
end

local function pick_snacks(items, prompt, on_select)
  local snacks = require("snacks.picker")
  snacks({
    title = prompt,
    items = items,
    format = "text",
    confirm = function(picker, item)
      picker:close()
      on_select(item and item.text or nil)
    end,
  })
end

--- Detect the best available picker plugin.
--- Returns the picker function or nil if none found.
local function detect_picker()
  local candidates = {
    { mod = "telescope.pickers", fn = pick_telescope },
    { mod = "fzf-lua",           fn = pick_fzf },
    { mod = "mini.pick",         fn = pick_mini },
    { mod = "snacks.picker",     fn = pick_snacks },
  }
  for _, c in ipairs(candidates) do
    if pcall(require, c.mod) then
      return c.fn
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Built-in floating window fallback (with fuzzy search + preview)
---------------------------------------------------------------------------

local function pick_float(items, prompt_text, on_select, preview_data)
  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(list_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(list_buf, "filetype", "PosteSelect")

  local preview_buf = nil
  if preview_data then
    preview_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(preview_buf, "bufhidden", "wipe")
  end

  local width = math.min(80, vim.o.columns - 4)
  local total_height = math.min(24, #items + 2)
  if preview_data then
    total_height = math.min(30, vim.o.lines - 6)
  end
  local list_height = preview_data and math.floor(total_height * 0.4) or total_height
  local preview_height = preview_data and (total_height - list_height - 1) or 0

  local row = math.floor((vim.o.lines - total_height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- List window (top)
  local list_win = vim.api.nvim_open_win(list_buf, true, {
    relative = "editor",
    width = width,
    height = list_height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = prompt_text,
    title_pos = "center",
  })

  -- Preview window (bottom)
  local preview_win = nil
  if preview_data then
    preview_win = vim.api.nvim_open_win(preview_buf, false, {
      relative = "editor",
      width = width,
      height = preview_height,
      row = row + list_height + 2,  -- +2 for border
      col = col,
      style = "minimal",
      border = "rounded",
      title = "Preview",
      title_pos = "center",
    })
    vim.api.nvim_set_option_value("wrap", true, { win = preview_win })
  end

  local filtered = vim.deepcopy(items)
  local filtered_indices = {}  -- original indices for preview lookup
  for i = 1, #items do
    table.insert(filtered_indices, i)
  end
  local selected_idx = 1
  local search_text = ""
  local resolved = false

  local function resolve(result)
    if resolved then return end
    resolved = true
    if vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_win_close(list_win, true)
    end
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_close(preview_win, true)
    end
    vim.schedule(function() pcall(on_select, result) end)
  end

  local function update_preview()
    if not preview_data or not preview_buf then return end
    local orig_idx = filtered_indices[selected_idx]
    if orig_idx and preview_data[orig_idx] then
      local data = preview_data[orig_idx]
      vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, data.lines)
      if data.filetype then
        vim.bo[preview_buf].filetype = data.filetype
      end
      -- Highlight the matching line
      if data.highlight_line then
        vim.api.nvim_buf_clear_namespace(preview_buf, -1, 0, -1)
        vim.api.nvim_buf_add_highlight(preview_buf, -1, "Visual",
          data.highlight_line - 1, 0, -1)
        -- Scroll preview to show highlighted line
        if preview_win and vim.api.nvim_win_is_valid(preview_win) then
          pcall(vim.api.nvim_win_set_cursor, preview_win, {data.highlight_line, 0})
        end
      end
    end
  end

  local function render()
    local lines = { "\239\134\133 " .. search_text }
    for idx, item in ipairs(filtered) do
      local prefix = (idx == selected_idx) and "▶ " or "  "
      table.insert(lines, prefix .. item)
    end
    while #lines < list_height do table.insert(lines, "") end
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)

    vim.api.nvim_buf_clear_namespace(list_buf, -1, 0, -1)
    if selected_idx > 0 and selected_idx <= #filtered then
      vim.api.nvim_buf_add_highlight(list_buf, -1, "Visual", selected_idx, 0, -1)
    end

    update_preview()
  end

  local function filter_items()
    if search_text == "" then
      filtered = vim.deepcopy(items)
      filtered_indices = {}
      for i = 1, #items do
        table.insert(filtered_indices, i)
      end
      selected_idx = 1
    else
      filtered = {}
      filtered_indices = {}
      local lower_search = search_text:lower()
      local exact_idx = nil
      for i, item in ipairs(items) do
        if item:lower():find(lower_search, 1, true) then
          table.insert(filtered, item)
          table.insert(filtered_indices, i)
          if item:lower() == lower_search and not exact_idx then
            exact_idx = #filtered
          end
        end
      end
      selected_idx = exact_idx or 1
    end
    render()
  end

  local function map(mode, key, action)
    vim.keymap.set(mode, key, action, { buffer = list_buf, nowait = true })
  end

  map("n", "j",      function() selected_idx = math.min(selected_idx + 1, #filtered); render() end)
  map("n", "k",      function() selected_idx = math.max(selected_idx - 1, 1);         render() end)
  map("n", "<Down>", function() selected_idx = math.min(selected_idx + 1, #filtered); render() end)
  map("n", "<Up>",   function() selected_idx = math.max(selected_idx - 1, 1);         render() end)

  map("n", "<CR>", function() resolve(#filtered > 0 and filtered[selected_idx] or nil) end)
  map("n", "<Esc>", function() resolve(nil) end)
  map("n", "q",     function() resolve(nil) end)

  map("n", "i", function() vim.cmd("startinsert!") end)
  map("n", "a", function() vim.cmd("startinsert!") end)

  map("i", "<CR>",   function() vim.cmd("stopinsert"); resolve(#filtered > 0 and filtered[selected_idx] or nil) end)
  map("i", "<Esc>",  function() vim.cmd("stopinsert"); resolve(nil) end)
  map("i", "<Down>", function() selected_idx = math.min(selected_idx + 1, #filtered); render() end)
  map("i", "<Up>",   function() selected_idx = math.max(selected_idx - 1, 1);         render() end)

  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = list_buf,
    callback = function()
      if resolved then return end
      local lines = vim.api.nvim_buf_get_lines(list_buf, 0, 1, false)
      local first_line = lines[1] or ""
      local new_search = first_line:match("^\239\134\133 (.*)$") or ""
      if new_search ~= search_text then
        search_text = new_search
        filter_items()
      end
    end,
  })

  render()
  vim.cmd("startinsert!")
end

---------------------------------------------------------------------------
-- Last-resort: vim.ui.select (works even without a GUI)
---------------------------------------------------------------------------

local function pick_vimui(items, prompt, on_select)
  vim.ui.select(items, { prompt = prompt }, function(choice)
    on_select(choice)
  end)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Show a picker for `items` and call `on_select(selected_item)` (nil if cancelled).
--- @param items string[] List of display strings
--- @param prompt string Title for the picker
--- @param on_select function Callback with selected item (nil if cancelled)
--- @param preview_data table[]|nil Optional: list of {lines, filetype, highlight_line} per item
function M.select(items, prompt, on_select, preview_data)
  if #items == 0 then
    vim.schedule(function() pcall(on_select, nil) end)
    return
  end

  -- 1. Try external picker (telescope, fzf-lua, mini.pick, snacks)
  local picker = detect_picker()
  if picker then
    local ok, err = pcall(picker, items, prompt, on_select, preview_data)
    if ok then return end
    -- Picker failed at runtime; fall through to built-in
    require("poste.state").log("WARN", "picker failed, falling back: " .. tostring(err))
  end

  -- 2. Built-in floating window (with preview support)
  local ok, err = pcall(pick_float, items, prompt, on_select, preview_data)
  if ok then return end

  -- 3. Ultimate fallback: vim.ui.select
  require("poste.state").log("WARN", "float picker failed, using vim.ui.select: " .. tostring(err))
  pick_vimui(items, prompt, on_select)
end

return M
