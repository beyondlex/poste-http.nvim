--- Response buffer/window management and winbar tab indicators.
local state = require("poste-http.state")
local format = require("poste-http.http.format")
local winbar = require("poste-http.ui.winbar")
local render = require("poste-http.ui.render")
local keymaps = require("poste-http.ui.keymaps")

local M = {}

local response_buffer = nil
local response_window = nil
local response_cleanup_group = nil
local response_keymaps_set = false
local response_buffers = {}  -- view → { idx → buf_nr }
local setup_keymaps  -- forward declaration

-- Callback for tab-switching keymaps; set by init.lua after show_view is defined.
M.on_show_view = nil

--- Open a popup preview for the current image response; falls back to the
--- system viewer when the popup cannot be created.
---@return boolean true when the current response is an image
function M.preview_response_image()
  local r = state.last_response
  if not r or not r.metadata or not r.metadata.file_path then return false end
  local ct = r.metadata.file_content_type or r.content_type
  if not format.is_image_content_type(ct) then return false end
  if format.render_image_float(r.metadata.file_path, ct) then return true end
  format.open_image_external(r.metadata.file_path)
  return true
end

-- Tab metadata: id → { name, section, action (for keymap lookup) }
local TAB_META = {
  body        = { name = "Body",     section = "http_response", action = "view_body" },
  request     = { name = "Rqst",     section = "http_response", action = "view_request" },
  verbose     = { name = "Verb",     section = "http_response", action = "view_verbose" },
  assertions  = { name = "Asserts",  section = "http_response", action = "view_assertions" },
  messages    = { name = "Msgs",     section = "http_response", action = "view_messages" },
  script_logs = { name = "Script",   section = "http_response", action = "view_script_logs" },
  errors      = { name = "Error",    section = "http_response", action = "view_errors" },
}

--- Build a tab label with key hint, e.g. "Body [B]" or "Verb [Tab]".
local function tab_label(tab_id)
  local meta = TAB_META[tab_id]
  if not meta then return tab_id end
  local key = state.format_keymap(meta.section, meta.action)
  if key ~= "" then
    return meta.name .. " [" .. key .. "]"
  end
  return meta.name
end

--- Get list of active tabs based on current state
local function get_active_tabs()
  local body_label = tab_label("body")
  if state._json.is_filtered and state._json.query then
    body_label = tab_label("body") .. " | jq: " .. state._json.query
  end
  local tabs = {
    { id = "body", label = body_label },
  }
  -- Only show Rqst tab when request has a body
  local r = state.last_response
  if state.last_responses and #state.last_responses > 0 then
    local idx = state.response_index or 1
    r = state.last_responses[idx] and state.last_responses[idx].response
  end
  if r and r.metadata and r.metadata.request_body and r.metadata.request_body ~= "" then
    table.insert(tabs, { id = "request", label = tab_label("request") })
  end
  -- Messages tab for WebSocket frame transcripts
  if r and r.metadata and r.metadata.frames then
    table.insert(tabs, { id = "messages", label = tab_label("messages") })
  end
  table.insert(tabs, { id = "verbose", label = tab_label("verbose") })
  -- Show Error tab when errors were collected. When the request never sent
  -- (pre-request error), there is no response to inspect, so show only the
  -- Error tab to avoid a dead Body/Verb tab.
  if state.last_errors and #state.last_errors > 0 then
    if not state.last_response then
      return { { id = "errors", label = tab_label("errors") } }
    end
    table.insert(tabs, { id = "errors", label = tab_label("errors") })
  end
  -- Only show Asserts tab when assertions were actually run
  if state.last_assertion_results and state.last_assertion_results.tests
      and #state.last_assertion_results.tests > 0 then
    table.insert(tabs, { id = "assertions", label = tab_label("assertions") })
  end
  -- Show Script tab when pre/post scripts produced output
  if state.last_script_logs and #state.last_script_logs > 0 then
    table.insert(tabs, { id = "script_logs", label = tab_label("script_logs") })
  end
  return tabs
end

function M.update_winbar(active)
  if not response_window or not vim.api.nvim_win_is_valid(response_window) then
    return
  end

  local parts = {}

  -- Multi-response index: [1/3] GetIP
  if state.last_responses and #state.last_responses > 0 then
    local idx = state.response_index or 1
    local name = (state.last_responses[idx] and state.last_responses[idx].name) or ""
    local label = string.format("[%d/%d] %s", idx, #state.last_responses, winbar.escape(name))
    table.insert(parts, "%#TabLineFill# " .. label .. " %*")
  end

  table.insert(parts, winbar.render_tabs(get_active_tabs(), active))

  vim.wo[response_window].winbar = table.concat(parts)
end

--- Get the response window (nil if not open or invalid).
function M.get_response_win()
  if response_window and vim.api.nvim_win_is_valid(response_window) then
    return response_window
  end
  return nil
end

--- Check if a pre-rendered buffer exists for the given index and view.
function M.get_response_buffer_for_idx(idx, view)
  view = view or "body"
  local bufs = response_buffers[view]
  if not bufs then return nil end
  local buf = bufs[idx]
  if buf and vim.api.nvim_buf_is_valid(buf) then return buf end
  return nil
end

--- Reset multi-response state. Call before rendering a new request to avoid stale buffers.
function M.reset_multi_response()
  for _, bufs in pairs(response_buffers) do
    for _, buf in pairs(bufs) do
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  response_buffers = {}
  state.last_responses = nil
  state.response_index = nil
end

--- Pre-render all multi-responses into scratch buffers for instant switching.
function M.prepare_multi_responses(responses)

  local views = { "body", "request", "verbose" }

  for _, view in ipairs(views) do
    response_buffers[view] = {}
  end

  for idx, entry in ipairs(responses) do
    local r = entry.response
    for _, view in ipairs(views) do
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = "nofile"
      local ok, lines, ft = pcall(format.format_view, view, r, {})
      if not ok then
        lines = { "(error formatting)" }
        ft = "text"
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.sanitize_lines(lines))
      vim.bo[buf].filetype = ft or "text"

      -- JSON setup for body view
      if view == "body" and ft == "json" then
        local json = require("poste-http.http.json")
        json.setup_buffer(buf)
      end

      -- Apply view-specific extmarks (same as render_view does in view.lua)
      format.apply_view_highlights(buf, view, lines, r)

      setup_keymaps(buf)
      response_buffers[view][idx] = buf
    end
  end
end

--- Navigate to the next/previous response in multi-response mode.
--- direction: 1 = next, -1 = previous
function M.navigate_response(direction)
  if not state.last_responses or #state.last_responses <= 1 then return end
  local idx = (state.response_index or 1) + direction
  if idx < 1 then idx = #state.last_responses
  elseif idx > #state.last_responses then idx = 1 end
  state.response_index = idx
  state.last_response = state.last_responses[idx].response
  state._json.original_lines = nil
  state._json.query = nil
  state._json.is_filtered = false

  -- Preserve current tab when switching responses
  local cur_view = state.current_view or "body"
  local view_bufs = response_buffers[cur_view]
  local buf = view_bufs and view_bufs[idx]
  if buf and vim.api.nvim_buf_is_valid(buf) and response_window and vim.api.nvim_win_is_valid(response_window) then
    vim.api.nvim_win_set_buf(response_window, buf)
    pcall(vim.api.nvim_win_set_cursor, response_window, { 1, 0 })
    M.update_winbar(cur_view)
    return
  end

  -- Fallback: full render (view without pre-rendered buffer, e.g. assertions)
  if M.on_show_view then
    M.on_show_view(cur_view)
  end
end

--- Cycle to the next/previous tab. direction: 1 = forward, -1 = backward
function M.cycle_tab(direction)
  if not M.on_show_view then return end
  direction = direction or 1
  local next_id = winbar.cycle(get_active_tabs(), state.current_view, direction)
  if next_id then
    M.on_show_view(next_id)
  end
end

---------------------------------------------------------------------------
-- Buffer management
---------------------------------------------------------------------------

local function get_response_buffer()
  if response_buffer and vim.api.nvim_buf_is_valid(response_buffer) then
    return response_buffer
  end

  response_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = response_buffer })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = response_buffer })
  vim.api.nvim_set_option_value("swapfile", false, { buf = response_buffer })
  vim.api.nvim_set_option_value("modifiable", false, { buf = response_buffer })
  vim.api.nvim_buf_set_name(response_buffer, "poste://response")
  -- Disable treesitter if no markdown parser is installed.
  -- Assertions and script_logs views still use "markdown" filetype, and
  -- without a parser treesitter will crash on those views.
  local has_md_parser = pcall(function()
    return vim.treesitter.language.require_lang("markdown")
  end)
  if not has_md_parser then
    pcall(vim.api.nvim_buf_set_var, response_buffer, "ts_highlight", false)
    pcall(vim.treesitter.stop, response_buffer)
  end

  return response_buffer
end

local function setup_response_cleanup_autocmds()
  if not response_window or not vim.api.nvim_win_is_valid(response_window) then
    return
  end

  if response_cleanup_group then
    pcall(vim.api.nvim_del_augroup_by_id, response_cleanup_group)
    response_cleanup_group = nil
  end

  response_cleanup_group = vim.api.nvim_create_augroup("poste_http_response_cleanup", { clear = true })
  local win_id = response_window
  local buf_id = response_buffer

  vim.api.nvim_create_autocmd("WinClosed", {
    group = response_cleanup_group,
    pattern = tostring(win_id),
    callback = function()
      format.close_image_preview()
    end,
  })

  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = response_cleanup_group,
    buffer = buf_id,
    callback = function()
      format.close_image_preview()
    end,
  })

  if buf_id and vim.api.nvim_buf_is_valid(buf_id) then
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = response_cleanup_group,
      buffer = buf_id,
      callback = function()
        format.close_image_preview()
      end,
    })
  end
end

--- (Re-)apply response buffer keymaps.
--- Called on every render to ensure they stay active even after buffer reuse or ftplugin reload.
setup_keymaps = function(buf)
  keymaps.register_all(buf, "http_response", {
    { action = "close", default = "q", handler = function()
      format.close_image_preview()
      if response_window and vim.api.nvim_win_is_valid(response_window) then
        vim.api.nvim_win_close(response_window, true)
        response_window = nil
      end
    end },
    { action = "view_body", default = "B", handler = function() if M.on_show_view then M.on_show_view("body") end end },
    { action = "view_request", default = "R", handler = function() if M.on_show_view then M.on_show_view("request") end end },
    { action = "view_messages", default = "M", handler = function() if M.on_show_view then M.on_show_view("messages") end end },
    { action = "view_verbose", default = "E", handler = function() if M.on_show_view then M.on_show_view("verbose") end end },
    { action = "view_assertions", default = "A", handler = function() if M.on_show_view then M.on_show_view("assertions") end end },
    { action = "view_errors", default = "X", handler = function() if M.on_show_view then M.on_show_view("errors") end end },
    { action = "view_script_logs", default = "S", handler = function() if M.on_show_view then M.on_show_view("script_logs") end end },
    { action = "next_tab", default = "<Tab>", handler = function() M.cycle_tab(1) end },
    { action = "prev_tab", default = "<S-Tab>", handler = function() M.cycle_tab(-1) end },
    { action = "rerun", default = "r", handler = function()
      local last = state.last_request
      if not last then
        vim.notify("No request to re-run", vim.log.levels.WARN)
        return
      end
      if not vim.api.nvim_buf_is_valid(last.buf) then
        vim.notify("Source buffer no longer exists", vim.log.levels.WARN)
        return
      end
      local win = vim.fn.bufwinid(last.buf)
      if win < 0 then
        vim.notify("Source buffer not visible in any window", vim.log.levels.WARN)
        return
      end
      local response_win = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_win(win)
      pcall(vim.api.nvim_win_set_cursor, win, { last.line, 0 })
      -- Clear last_response so the UI updates even if the same request returns quickly
      state.set_response(nil)
      require("poste-http").run_request()
      if vim.api.nvim_win_is_valid(response_win) then
        vim.api.nvim_set_current_win(response_win)
      end
    end },
    -- Ask the AI about the shown response/errors (needs poste-ai.nvim)
    { action = "ask_ai", default = "a", handler = function()
      require("poste-http.ai").ask_view()
    end },
    -- Multi-response navigation
    { action = "next_response", default = "]", handler = function() M.navigate_response(1) end },
    { action = "prev_response", default = "[", handler = function() M.navigate_response(-1) end },
    -- JSON filter prompt (<leader>j) — interactive float with completion dropdown
    { action = "json_filter", default = "<leader>j", handler = function()
      local bufnr = vim.api.nvim_get_current_buf()
      if vim.bo[bufnr].filetype ~= "json" then return end
      require("poste-http.http.json").start_interactive_input()
    end },
    -- JSON restore original (<leader>jc)
    { action = "json_restore", default = "<leader>jc", handler = function()
      local bufnr = vim.api.nvim_get_current_buf()
      if vim.bo[bufnr].filetype ~= "json" then return end
      require("poste-http.http.json").restore_original()
    end },
  }, { nowait = true })

  -- gd on "Open file:" (binary) or "File:" (large text) lines: open the file
  vim.keymap.set("n", "gd", function()
    local bufnr = vim.api.nvim_get_current_buf()
    if bufnr ~= buf then return end
    local cur_line = vim.api.nvim_get_current_line()
    if not (cur_line:match("^  Open") or cur_line:match("^  File:")) then return end
    local file_path = state.last_response and state.last_response.metadata and state.last_response.metadata.file_path
    if not file_path then return end
    local opener = vim.fn.has("mac") == 1 and "open" or "xdg-open"
    vim.fn.jobstart({ opener, file_path }, { detach = true })
    vim.notify(string.format("Opening: %s", file_path), vim.log.levels.INFO, { title = "Poste" })
  end, { buffer = buf, noremap = true, silent = true })

  -- K on image/URL preview: image responses and image URLs in JSON/text open a
  -- popup preview that can be closed with <Esc> or q.
  keymaps.register(buf, "http_response", "image_preview", "K", function()
    local bufnr = vim.api.nvim_get_current_buf()
    if bufnr ~= buf then return end
    local r = state.last_response

    -- Popup preview when the response itself is an image
    if r and format.is_image_content_type(r.metadata and (r.metadata.file_content_type or r.content_type)) then
      M.preview_response_image()
      return
    end

    -- Fallback: URL under cursor → show in floating window
    if state.current_view == "body" then
      local url = format.get_url_under_cursor()
      if url then
        vim.defer_fn(function()
          format.preview_image_url_float(url)
        end, 50)
      end
    end
  end, { nowait = true })
end

function M.get_buf()
  if response_buffer and vim.api.nvim_buf_is_valid(response_buffer) then
    return response_buffer
  end
  return nil
end

--- Split lines containing embedded newlines into separate entries.
--- nvim_buf_set_lines rejects strings with \\n inside them.
function M.sanitize_lines(lines)
  local out = {}
  for _, line in ipairs(lines) do
    if line:find("[\n\r]") then
      local normalized = (line:gsub("\r\n", "\n")):gsub("\r", "\n")
      local parts = vim.split(normalized, "\n", { plain = true })
      for _, part in ipairs(parts) do
        table.insert(out, part)
      end
    else
      table.insert(out, line)
    end
  end
  return out
end

local resize_group = nil

-- Minimum sizes that keep a split usable. The response window is never
-- rebalanced below these, and the other side of the split is guaranteed the
-- source minimum so the http file window never disappears.
local MIN_RESPONSE_WIDTH = 30
local MIN_SOURCE_WIDTH = 40
local MIN_RESPONSE_HEIGHT = 8
local MIN_SOURCE_HEIGHT = 8

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

--- Compute a rebalance target size for the response window.
local function target_size(total, ratio, min_self, min_other)
  local halves = math.floor(total / 2)
  local lower = math.min(min_self, halves)
  local upper = math.max(lower, total - math.min(min_other, halves))
  return clamp(math.floor(total * ratio + 0.5), lower, upper)
end

--- Approximate the number of window text rows available to horizontal splits.
local function available_rows()
  local rows = vim.o.lines - (vim.o.cmdheight or 1)
  if vim.o.showtabline and vim.o.showtabline >= 1 then
    rows = rows - 1
  end
  if vim.o.laststatus and vim.o.laststatus >= 2 then
    rows = rows - 1
  end
  return math.max(1, rows)
end

--- Rebalance the response split after the whole window was resized (terminal
--- maximize/restore). Neovim's default layout can squeeze one side down to a
--- sliver so it is effectively invisible; here we only step in when a side is
--- below the usable minimum, restoring the configured proportion.
function M.rebalance_on_resize()
  if not response_window or not vim.api.nvim_win_is_valid(response_window) then
    return
  end
  local ratio = state.config.result_window_ratio
  if not ratio or not (ratio > 0 and ratio < 1) then
    ratio = 0.5
  end

  -- A side-by-side split (vertical) has width < columns; a stacked split
  -- (horizontal) spans the full width.
  if vim.api.nvim_win_get_width(response_window) < vim.o.columns then
    local total = vim.o.columns
    local cur = vim.api.nvim_win_get_width(response_window)
    if cur >= MIN_RESPONSE_WIDTH and total - cur >= MIN_SOURCE_WIDTH then
      return
    end
    local target = target_size(total, ratio, MIN_RESPONSE_WIDTH, MIN_SOURCE_WIDTH)
    if target ~= cur then
      pcall(vim.api.nvim_win_set_width, response_window, target)
    end
  else
    local total = available_rows()
    local cur = vim.api.nvim_win_get_height(response_window)
    if cur >= MIN_RESPONSE_HEIGHT and total - cur >= MIN_SOURCE_HEIGHT then
      return
    end
    local target = target_size(total, ratio, MIN_RESPONSE_HEIGHT, MIN_SOURCE_HEIGHT)
    if target ~= cur then
      pcall(vim.api.nvim_win_set_height, response_window, target)
    end
  end
end

-- Register the VimResized handler once (idempotent across re-renders).
local function setup_response_resize_autocmd()
  if resize_group then return end
  resize_group = vim.api.nvim_create_augroup("poste_http_response_resize", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = resize_group,
    callback = function() M.rebalance_on_resize() end,
  })
end

--- Ensure the response split is open and display the given lines
function M.render_buffer(lines, filetype)
  format.close_image_preview()
  format.cleanup_url_preview()
  local buf = get_response_buffer()

  -- Write lines (ui/render toggles modifiable around the write)
  render.set_lines(buf, M.sanitize_lines(lines))

  -- Set filetype for treesitter highlighting (skip if same to avoid reattach)
  local new_ft = filetype or "text"
  if vim.bo[buf].filetype ~= new_ft then
    vim.bo[buf].filetype = new_ft
    response_keymaps_set = false
  end

  -- Re-apply keymaps AFTER filetype change so ftplugin keymaps don't win
  if not response_keymaps_set then
    setup_keymaps(buf)
    response_keymaps_set = true
  end

  -- Open split window if not already open
  if not response_window or not vim.api.nvim_win_is_valid(response_window) then
    local saved_win = vim.api.nvim_get_current_win()
    local dir = state._split_override or state.config.split_direction
    state._split_override = nil
    local cmd = dir == "vertical" and "vsplit" or "split"
    vim.cmd(cmd)
    response_window = vim.api.nvim_get_current_win()
    response_keymaps_set = false
    vim.api.nvim_set_current_win(saved_win)
    setup_response_cleanup_autocmds()
    setup_response_resize_autocmd()
  end

  vim.api.nvim_win_set_buf(response_window, buf)

  -- Move cursor to top
  pcall(vim.api.nvim_win_set_cursor, response_window, { 1, 0 })
end

return M
