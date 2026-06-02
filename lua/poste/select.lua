--- Item selector with automatic picker detection.
--- Priority: telescope → fzf-lua → mini.pick → snacks → built-in float → vim.ui.select.
--- All branches call on_select(item) on pick, on_select(nil) on cancel.
local M = {}

---------------------------------------------------------------------------
-- External picker integrations
---------------------------------------------------------------------------

local function pick_telescope(items, prompt, on_select)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local state = require("telescope.actions.state")

  local resolved = false
  local function resolve(item)
    if resolved then return end
    resolved = true
    actions.close(require("telescope.actions.state").get_current_picker(prompt and prompt:gsub(" ", "_") or "poste_select").prompt_bufnr)
    on_select(item)
  end

  pickers.new({}, {
    prompt_title = prompt,
    finder = finders.new_table { results = items },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(_, map)
      map({ "i", "n" }, "<CR>", function(bufnr)
        local sel = state.get_selected_entry()
        -- Close picker first, then invoke callback
        actions.close(bufnr)
        resolved = true
        on_select(sel and sel[1] or nil)
      end)
      return true
    end,
  }):find()
end

local function pick_fzf(items, prompt, on_select)
  local fzf = require("fzf-lua")
  fzf.fzf_exec(items, {
    prompt = (prompt or "Select") .. "> ",
    actions = {
      ["default"] = function(sel)
        on_select(sel and sel[1] or nil)
      end,
    },
  })
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
-- Built-in floating window fallback (with fuzzy search)
---------------------------------------------------------------------------

local function pick_float(items, prompt_text, on_select)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "filetype", "PosteSelect")

  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(20, #items + 2)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

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

  local filtered = vim.deepcopy(items)
  local selected_idx = 1
  local search_text = ""
  local resolved = false

  local function resolve(result)
    if resolved then return end
    resolved = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.schedule(function() on_select(result) end)
  end

  local function render()
    local lines = { "\239\132\133 " .. search_text }
    for idx, item in ipairs(filtered) do
      local prefix = (idx == selected_idx) and "▶ " or "  "
      table.insert(lines, prefix .. item)
    end
    while #lines < height do table.insert(lines, "") end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
    if selected_idx > 0 and selected_idx <= #filtered then
      vim.api.nvim_buf_add_highlight(buf, -1, "Visual", selected_idx, 0, -1)
    end
  end

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
    vim.keymap.set(mode, key, action, { buffer = buf, nowait = true })
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
    buffer = buf,
    callback = function()
      if resolved then return end
      local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
      local first_line = lines[1] or ""
      local new_search = first_line:match("^\239\132\133 (.*)$") or ""
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
function M.select(items, prompt, on_select)
  if #items == 0 then
    vim.schedule(function() on_select(nil) end)
    return
  end

  -- 1. Try external picker (telescope, fzf-lua, mini.pick, snacks)
  local picker = detect_picker()
  if picker then
    local ok, err = pcall(picker, items, prompt, on_select)
    if ok then return end
    -- Picker failed at runtime; fall through to built-in
    require("poste.state").log("WARN", "picker failed, falling back: " .. tostring(err))
  end

  -- 2. Built-in floating window
  local ok, err = pcall(pick_float, items, prompt, on_select)
  if ok then return end

  -- 3. Ultimate fallback: vim.ui.select
  require("poste.state").log("WARN", "float picker failed, using vim.ui.select: " .. tostring(err))
  pick_vimui(items, prompt, on_select)
end

return M
