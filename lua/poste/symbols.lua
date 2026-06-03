--- Symbol outline: fuzzy picker showing all HTTP requests in the current file.
--- Direct buffer parsing — no LSP needed for HTTP's simple structure.

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
      -- Consecutive matches score higher
      if last_match_pos == ti - 1 then
        score = score + 1
      end
      -- Match at start of text scores higher
      if ti == 1 then
        score = score + 1
      end
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

        if next_line:match("^%s*$") then
          skip = true
        end

        if not skip and next_line:match("^%s*<%s*{%%") then
          in_pre_script = true
          skip = true
        end
        if not skip and in_pre_script then
          if next_line:match("%%}") then
            in_pre_script = false
          end
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

--- Filter requests by fuzzy query, sorted by score.
--- @param requests table[] All requests
--- @param query string Search query
--- @return table[] Filtered and sorted requests
local function search_requests(requests, query)
  if query == "" then
    local result = {}
    for _, req in ipairs(requests) do
      table.insert(result, req)
    end
    return result
  end

  local scored = {}
  for _, req in ipairs(requests) do
    local method_prefix = req.method and ("[" .. req.method .. "] ") or ""
    local search_text = method_prefix .. req.name
    local matched, score = fuzzy_match(search_text, query)
    if matched then
      table.insert(scored, { req = req, score = score })
    end
  end

  table.sort(scored, function(a, b) return a.score > b.score end)

  local result = {}
  for _, item in ipairs(scored) do
    table.insert(result, item.req)
  end
  return result
end

---------------------------------------------------------------------------
-- Format
---------------------------------------------------------------------------

--- Format a request entry for display.
--- @param entry table Request entry { name, method, line }
--- @return string Formatted line
local function format_entry(entry)
  local method_str = entry.method and ("[" .. entry.method .. "] ") or ""
  return string.format("  %s%s  (L%d)", method_str, entry.name, entry.line)
end

---------------------------------------------------------------------------
-- Fuzzy picker UI
---------------------------------------------------------------------------

--- Show symbol outline as a fuzzy picker floating window.
function M.show_symbols()
  local source_buf = vim.api.nvim_get_current_buf()
  local requests = collect_requests(source_buf)

  if #requests == 0 then
    vim.notify("No requests found in this file", vim.log.levels.INFO)
    return
  end

  local state = {
    query = "",
    filtered = requests,
    source_buf = source_buf,
  }

  -----------------------------------------------------------------------
  -- Render functions
  -----------------------------------------------------------------------

  local function render_results(buf)
    local lines = {}
    for _, req in ipairs(state.filtered) do
      table.insert(lines, format_entry(req))
    end
    if #lines == 0 then
      table.insert(lines, "  No matches")
    end
    vim.api.nvim_buf_set_lines(buf, 2, -1, false, lines)
    return lines
  end

  local function apply_highlights(buf, lines)
    vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
    for i, line in ipairs(lines) do
      local cs = line:find("%[")
      local ce = line:find("%]")
      if cs and ce then
        vim.api.nvim_buf_add_highlight(buf, -1, "PosteSymbolMethod", i + 1, cs - 1, ce)
      end
      local ls = line:find("%(L%d+%)")
      if ls then
        vim.api.nvim_buf_add_highlight(buf, -1, "Comment", i + 1, ls - 1, -1)
      end
    end
  end

  local function update(buf)
    state.filtered = search_requests(requests, state.query)
    local lines = render_results(buf)
    apply_highlights(buf, lines)
  end

  -----------------------------------------------------------------------
  -- Create buffer and window
  -----------------------------------------------------------------------

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "poste_symbols"

  -- Initial render
  local result_lines = {}
  for _, req in ipairs(requests) do
    table.insert(result_lines, format_entry(req))
  end

  local max_width = 40
  for _, l in ipairs(result_lines) do
    max_width = math.max(max_width, #l + 2)
  end
  local width = math.min(max_width, vim.o.columns - 4)
  local separator = string.rep("─", width)

  -- Line 1: prompt, Line 2: separator, Line 3+: results
  local all_lines = { "> ", separator }
  for _, l in ipairs(result_lines) do
    table.insert(all_lines, l)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)

  local total_height = 2 + #result_lines
  local height = math.min(total_height, vim.o.lines - 6)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " Requests ",
    title_pos = "center",
  })

  -- Highlight the separator line
  vim.api.nvim_buf_add_highlight(buf, -1, "Comment", 1, 0, -1)

  -- Highlight methods and line numbers in initial results
  apply_highlights(buf, result_lines)

  -- Enter insert mode at prompt
  vim.api.nvim_win_set_cursor(win, { 1, 2 })
  vim.cmd("startinsert")

  -----------------------------------------------------------------------
  -- Live filtering on text change
  -----------------------------------------------------------------------

  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = buf,
    callback = function()
      -- Protect separator line
      local sep = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
      if sep ~= separator then
        vim.api.nvim_buf_set_lines(buf, 1, 2, false, { separator })
      end
      -- Extract query from prompt
      local line1 = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
      state.query = line1:sub(3)  -- skip "> " prefix
      update(buf)
    end,
  })

  -----------------------------------------------------------------------
  -- Auto mode switch: insert on prompt, normal on results
  -----------------------------------------------------------------------

  vim.api.nvim_create_autocmd("CursorMovedI", {
    buffer = buf,
    callback = function()
      local row = vim.api.nvim_win_get_cursor(win)[1]
      if row > 1 and vim.fn.mode() == "i" then
        vim.schedule(function()
          vim.cmd("noautocmd stopinsert")
        end)
      end
    end,
  })

  -----------------------------------------------------------------------
  -- Keymaps (work in both modes via vim.cmd)
  -----------------------------------------------------------------------

  local function nav(delta)
    return function()
      local row = vim.api.nvim_win_get_cursor(win)[1]
      local max_row = vim.api.nvim_buf_line_count(buf)

      if delta > 0 then
        -- Moving down
        if row < 2 then
          row = 3  -- skip separator
        else
          row = row + 1
        end
      else
        -- Moving up
        if row > 2 then
          row = row - 1
        else
          row = 1  -- back to prompt
        end
      end

      -- Skip separator
      if row == 2 then
        row = delta > 0 and 3 or 1
      end

      -- Clamp to valid range
      row = math.max(1, math.min(row, max_row))
      vim.api.nvim_win_set_cursor(win, { row, 0 })
    end
  end

  local function jump()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    if row <= 2 then return end  -- on prompt or separator

    local idx = row - 2  -- line 3 = index 1
    if idx >= 1 and idx <= #state.filtered then
      local req = state.filtered[idx]
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_win_set_cursor(0, { req.line, 0 })
      vim.cmd("normal! zz")
    end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- Navigation: Ctrl+j / Ctrl+k work in any mode
  vim.keymap.set({ "n", "i" }, "<C-j>", nav(1), { buffer = buf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-k>", nav(-1), { buffer = buf, nowait = true, silent = true })

  -- Also j/k in normal mode
  vim.keymap.set("n", "j", nav(1), { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "k", nav(-1), { buffer = buf, nowait = true, silent = true })

  -- Actions
  vim.keymap.set({ "n", "i" }, "<CR>", jump, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<Esc>", close, { buffer = buf, nowait = true, silent = true })

  -- Auto-close on buffer leave
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = close,
  })
end

return M
