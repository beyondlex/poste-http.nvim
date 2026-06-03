--- Symbol outline: fuzzy picker showing all HTTP requests in the current file.
--- Direct buffer parsing — no LSP needed for HTTP's simple structure.
---
--- Two-window layout (like Telescope):
---   ┌─ Prompt (insert mode) ──────────┐
---   │ > query                         │
---   ├─ Results ───────────────────────┤
---   │ [POST] Login  (L3)              │
---   │ [GET] Verify  (L29)             │
---   ╰─────────────────────────────────╯
---
--- Prompt stays focused in insert mode.  Ctrl+n/p (or Ctrl+j/k)
--- move the selection highlight in the results window.
--- Enter jumps to the selected request, Esc closes.

local M = {}

---------------------------------------------------------------------------
-- Fuzzy matching
---------------------------------------------------------------------------

--- Case-insensitive subsequence match with scoring.
--- @param text string
--- @param query string
--- @return boolean matched
--- @return number score (higher = better match)
local function fuzzy_match(text, query)
  if #query == 0 then return true, 0 end

  local lower_text = text:lower()
  local lower_query = query:lower()
  local qi = 1
  local score = 0
  local last_match_pos = 0

  for ti = 1, #lower_text do
    if qi <= #lower_query and lower_text:byte(ti) == lower_query:byte(qi) then
      if last_match_pos == ti - 1 then score = score + 1 end  -- consecutive
      if ti == 1 then score = score + 1 end                    -- start of text
      last_match_pos = ti
      qi = qi + 1
    end
  end

  return qi > #lower_query, score
end

---------------------------------------------------------------------------
-- Parse requests from buffer
---------------------------------------------------------------------------

--- Scan buffer and collect all ### request blocks.
--- @param bufnr number Buffer handle
--- @return table[] List of { name = string, method = string|nil, line = number }
local function collect_requests(bufnr)
  local requests = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for i, line in ipairs(lines) do
    local name = line:match("^%s*###%s+(.+)$")
    if name then
      local method = nil
      local in_pre_script = false

      for j = i + 1, math.min(i + 20, #lines) do
        local next_line = lines[j]
        local skip = false

        if next_line:match("^%s*$") then skip = true end
        if not skip and next_line:match("^%s*<%s*{%%") then
          in_pre_script = true
          skip = true
        end
        if not skip and in_pre_script then
          if next_line:match("%%}") then in_pre_script = false end
          skip = true
        end
        if not skip and next_line:match("^%s*@%w") then skip = true end
        if not skip and next_line:match("^%s*#") then skip = true end

        if not skip then
          method = next_line:match("^%s*(%u+)%s")
          break
        end
      end

      table.insert(requests, { name = name, method = method, line = i })
    end
  end

  return requests
end

---------------------------------------------------------------------------
-- Search and filter
---------------------------------------------------------------------------

--- Filter requests by fuzzy query, sorted by score descending.
local function search_requests(requests, query)
  if query == "" then
    local result = {}
    for _, req in ipairs(requests) do table.insert(result, req) end
    return result
  end

  local scored = {}
  for _, req in ipairs(requests) do
    local search_text = (req.method and ("[" .. req.method .. "] ") or "") .. req.name
    local matched, score = fuzzy_match(search_text, query)
    if matched then table.insert(scored, { req = req, score = score }) end
  end
  table.sort(scored, function(a, b) return a.score > b.score end)

  local result = {}
  for _, item in ipairs(scored) do table.insert(result, item.req) end
  return result
end

---------------------------------------------------------------------------
-- Format
---------------------------------------------------------------------------

local function format_entry(entry)
  local method_str = entry.method and ("[" .. entry.method .. "] ") or ""
  return string.format(" %s%s  (L%d)", method_str, entry.name, entry.line)
end

---------------------------------------------------------------------------
-- Fuzzy picker UI (two-window layout)
---------------------------------------------------------------------------

function M.show_symbols()
  local source_buf = vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  local requests = collect_requests(source_buf)

  if #requests == 0 then
    vim.notify("No requests found in this file", vim.log.levels.INFO)
    return
  end

  -- State
  local state = {
    query = "",
    filtered = requests,
    selected = 1,
    alive = true,
  }

  -----------------------------------------------------------------------
  -- Create prompt buffer (top, insert mode)
  -----------------------------------------------------------------------
  local prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[prompt_buf].buftype = "nofile"
  vim.bo[prompt_buf].bufhidden = "wipe"
  vim.bo[prompt_buf].filetype = "poste_picker_prompt"  -- not in blink.cmp per_filetype
  vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "> " })

  -----------------------------------------------------------------------
  -- Create results buffer (bottom, normal mode)
  -----------------------------------------------------------------------
  local results_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[results_buf].buftype = "nofile"
  vim.bo[results_buf].bufhidden = "wipe"
  vim.bo[results_buf].modifiable = false
  vim.bo[results_buf].filetype = "poste_picker_results"

  local hl_ns = vim.api.nvim_create_namespace("poste_symbol_picker")

  -----------------------------------------------------------------------
  -- Render
  -----------------------------------------------------------------------
  local function render()
    local lines = {}
    for _, req in ipairs(state.filtered) do
      table.insert(lines, format_entry(req))
    end
    if #lines == 0 then
      table.insert(lines, "  No matches")
    end

    vim.bo[results_buf].modifiable = true
    vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)
    vim.bo[results_buf].modifiable = false

    -- Highlights
    vim.api.nvim_buf_clear_namespace(results_buf, hl_ns, 0, -1)
    for i, line in ipairs(lines) do
      local cs = line:find("%[")
      local ce = line:find("%]")
      if cs and ce then
        vim.api.nvim_buf_add_highlight(results_buf, hl_ns, "PosteSymbolMethod", i - 1, cs - 1, ce)
      end
      local ls = line:find("%(L%d+%)")
      if ls then
        vim.api.nvim_buf_add_highlight(results_buf, hl_ns, "Comment", i - 1, ls - 1, -1)
      end
    end

    -- Selection highlight (whole line)
    if state.selected >= 1 and state.selected <= #state.filtered then
      vim.api.nvim_buf_set_extmark(results_buf, hl_ns, state.selected - 1, 0, {
        line_hl_group = "PosteSymbolSelected",
      })
    end
  end

  -----------------------------------------------------------------------
  -- Calculate dimensions
  -----------------------------------------------------------------------
  local max_width = 40
  for _, req in ipairs(requests) do
    max_width = math.max(max_width, #format_entry(req) + 2)
  end
  local width = math.min(max_width, vim.o.columns - 4)
  local max_results = math.min(#requests, vim.o.lines - 8)
  local results_height = math.max(1, max_results)
  local total_height = 1 + results_height  -- prompt + results, no separator

  local start_row = math.floor((vim.o.lines - total_height) / 2)
  local start_col = math.floor((vim.o.columns - width) / 2)

  -----------------------------------------------------------------------
  -- Open prompt window (top, rounded border, no bottom)
  -----------------------------------------------------------------------
  local prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = start_row,
    col = start_col,
    style = "minimal",
    border = { "╭", "─", "┬", "│", "│", "│", "╰", "╯" },
    title = " Requests ",
    title_pos = "center",
  })
  vim.wo[prompt_win].winbar = ""

  -----------------------------------------------------------------------
  -- Open results window (bottom, connected border)
  -----------------------------------------------------------------------
  local results_win = vim.api.nvim_open_win(results_buf, false, {
    relative = "editor",
    width = width,
    height = results_height,
    row = start_row + 1,
    col = start_col,
    style = "minimal",
    border = { "├", "─", "╮", "│", "╯", "─", "╰", "│" },
  })
  vim.wo[results_win].cursorline = false
  vim.wo[results_win].winhl = "Normal:Normal"

  -----------------------------------------------------------------------
  -- Initial render + enter insert mode
  -----------------------------------------------------------------------
  render()
  vim.api.nvim_win_set_cursor(prompt_win, { 1, 2 })
  vim.cmd("startinsert!")

  -----------------------------------------------------------------------
  -- Cleanup helper
  -----------------------------------------------------------------------
  local function close_picker()
    if not state.alive then return end
    state.alive = false
    if vim.api.nvim_win_is_valid(prompt_win) then
      vim.api.nvim_win_close(prompt_win, true)
    end
    if vim.api.nvim_win_is_valid(results_win) then
      vim.api.nvim_win_close(results_win, true)
    end
  end

  -----------------------------------------------------------------------
  -- Prompt input → live filter
  -----------------------------------------------------------------------
  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = prompt_buf,
    callback = function()
      if not state.alive then return end
      local line = vim.api.nvim_buf_get_lines(prompt_buf, 0, 1, false)[1] or ""
      state.query = line:sub(3)  -- skip "> "
      state.filtered = search_requests(requests, state.query)
      state.selected = 1
      render()
    end,
  })

  -----------------------------------------------------------------------
  -- Keep cursor after "> " prefix
  -----------------------------------------------------------------------
  vim.api.nvim_create_autocmd("CursorMovedI", {
    buffer = prompt_buf,
    callback = function()
      if not state.alive then return end
      local col = vim.api.nvim_win_get_cursor(prompt_win)[2]
      if col < 2 then
        vim.api.nvim_win_set_cursor(prompt_win, { 1, 2 })
      end
    end,
  })

  -----------------------------------------------------------------------
  -- Navigation: move selection in results window
  -----------------------------------------------------------------------
  local function move_selection(delta)
    local n = #state.filtered
    if n == 0 then return end
    state.selected = state.selected + delta
    if state.selected < 1 then state.selected = n end
    if state.selected > n then state.selected = 1 end
    render()
    -- Scroll results window to keep selection visible
    if vim.api.nvim_win_is_valid(results_win) then
      vim.api.nvim_win_set_cursor(results_win, { state.selected, 0 })
    end
  end

  -----------------------------------------------------------------------
  -- Jump to selected request
  -----------------------------------------------------------------------
  local function jump()
    if not state.alive then return end
    local req = state.filtered[state.selected]
    close_picker()
    if req then
      vim.api.nvim_set_current_win(source_win)
      vim.api.nvim_win_set_cursor(source_win, { req.line, 0 })
      vim.cmd("normal! zz")
    end
  end

  -----------------------------------------------------------------------
  -- Prompt window keymaps (insert mode)
  -----------------------------------------------------------------------
  local pmap = { buffer = prompt_buf, nowait = true, silent = true }

  vim.keymap.set("i", "<C-n>", function() move_selection(1) end, pmap)
  vim.keymap.set("i", "<C-p>", function() move_selection(-1) end, pmap)
  vim.keymap.set("i", "<C-j>", function() move_selection(1) end, pmap)
  vim.keymap.set("i", "<C-k>", function() move_selection(-1) end, pmap)
  vim.keymap.set("i", "<Down>", function() move_selection(1) end, pmap)
  vim.keymap.set("i", "<Up>", function() move_selection(-1) end, pmap)
  vim.keymap.set("i", "<CR>", jump, pmap)
  vim.keymap.set("i", "<Esc>", close_picker, pmap)

  -----------------------------------------------------------------------
  -- Results window keymaps (normal mode, if user clicks into it)
  -----------------------------------------------------------------------
  local rmap = { buffer = results_buf, nowait = true, silent = true }

  vim.keymap.set("n", "j", function() move_selection(1) end, rmap)
  vim.keymap.set("n", "k", function() move_selection(-1) end, rmap)
  vim.keymap.set("n", "<C-n>", function() move_selection(1) end, rmap)
  vim.keymap.set("n", "<C-p>", function() move_selection(-1) end, rmap)
  vim.keymap.set("n", "<C-j>", function() move_selection(1) end, rmap)
  vim.keymap.set("n", "<C-k>", function() move_selection(-1) end, rmap)
  vim.keymap.set("n", "<Down>", function() move_selection(1) end, rmap)
  vim.keymap.set("n", "<Up>", function() move_selection(-1) end, rmap)
  vim.keymap.set("n", "gg", function() state.selected = 1; render() end, rmap)
  vim.keymap.set("n", "G", function() state.selected = #state.filtered; render() end, rmap)
  vim.keymap.set("n", "<CR>", jump, rmap)
  vim.keymap.set("n", "q", close_picker, rmap)
  vim.keymap.set("n", "<Esc>", close_picker, rmap)

  -----------------------------------------------------------------------
  -- Auto-close when leaving either window
  -----------------------------------------------------------------------
  vim.api.nvim_create_autocmd("WinLeave", {
    callback = function()
      if not state.alive then return end
      -- Defer to let keymaps fire first
      vim.schedule(function()
        if not state.alive then return end
        local cur = vim.api.nvim_get_current_win()
        if cur ~= prompt_win and cur ~= results_win then
          close_picker()
        end
      end)
    end,
  })
end

return M
