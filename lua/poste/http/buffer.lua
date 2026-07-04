--- Response buffer/window management and winbar tab indicators.
local state = require("poste.state")
local format = require("poste.http.format")

local M = {}

local response_buffer = nil
local response_window = nil
local response_cleanup_group = nil

-- Callback for tab-switching keymaps; set by init.lua after show_view is defined.
M.on_show_view = nil

-- Tab metadata: id → { name, section, action (for keymap lookup) }
local TAB_META = {
  body        = { name = "Body",     section = "http_response", action = "view_body" },
  request     = { name = "Rqst",     section = "http_response", action = "view_request" },
  verbose     = { name = "Verb",     section = "http_response", action = "view_verbose" },
  assertions  = { name = "Asserts",  section = "http_response", action = "view_assertions" },
  script_logs = { name = "Script",   section = "http_response", action = "view_script_logs" },
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
    { id = "body",    label = body_label },
    { id = "request", label = tab_label("request") },
    { id = "verbose", label = tab_label("verbose") },
  }
  -- Only show Asserts tab when assertions were run
  if state.last_assertion_results then
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

  local tabs = get_active_tabs()
  local parts = {}

  -- Multi-response index: [1/3] GetIP
  if state.last_responses and #state.last_responses > 0 then
    local idx = state.response_index or 1
    local name = (state.last_responses[idx] and state.last_responses[idx].name) or ""
    local label = string.format("[%d/%d] %s", idx, #state.last_responses, name)
    table.insert(parts, "%#TabLineFill# " .. label .. " %*")
  end

  for _, tab in ipairs(tabs) do
    if tab.id == active then
      table.insert(parts, "%#TabLineSel# " .. tab.label .. " %*")
    else
      table.insert(parts, "%#TabLine# " .. tab.label .. " %*")
    end
  end

  vim.wo[response_window].winbar = table.concat(parts)
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
  if state.current_view and M.on_show_view then
    M.on_show_view(state.current_view)
  end
end

--- Cycle to the next/previous tab. direction: 1 = forward, -1 = backward
function M.cycle_tab(direction)
  if not M.on_show_view then return end
  local tabs = get_active_tabs()
  if #tabs == 0 then return end
  direction = direction or 1

  -- Find current tab index
  local current_idx = 1
  for i, tab in ipairs(tabs) do
    if tab.id == state.current_view then
      current_idx = i
      break
    end
  end

  -- Move to next/previous tab (wrap around)
  local next_idx = ((current_idx - 1 + direction) % #tabs) + 1
  M.on_show_view(tabs[next_idx].id)
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
local function setup_keymaps(buf)
  local opts = { buffer = buf, noremap = true, silent = true }

  -- Close window
  local k = state.get_keymap("http_response", "close", "q")
  if k then
    vim.keymap.set("n", k, function()
      format.close_image_preview()
      if response_window and vim.api.nvim_win_is_valid(response_window) then
        vim.api.nvim_win_close(response_window, true)
        response_window = nil
      end
    end, opts)
  end

  -- Tab switching keymaps — delegate to on_show_view callback
  k = state.get_keymap("http_response", "view_body", "B")
  if k then
    vim.keymap.set("n", k, function() if M.on_show_view then M.on_show_view("body") end end, opts)
  end
  k = state.get_keymap("http_response", "view_request", "R")
  if k then
    vim.keymap.set("n", k, function() if M.on_show_view then M.on_show_view("request") end end, opts)
  end
  k = state.get_keymap("http_response", "view_verbose", "E")
  if k then
    vim.keymap.set("n", k, function() if M.on_show_view then M.on_show_view("verbose") end end, opts)
  end
  k = state.get_keymap("http_response", "view_assertions", "A")
  if k then
    vim.keymap.set("n", k, function() if M.on_show_view then M.on_show_view("assertions") end end, opts)
  end
  k = state.get_keymap("http_response", "view_script_logs", "S")
  if k then
    vim.keymap.set("n", k, function() if M.on_show_view then M.on_show_view("script_logs") end end, opts)
  end
  k = state.get_keymap("http_response", "next_tab", "<Tab>")
  if k then
    vim.keymap.set("n", k, function() M.cycle_tab(1) end, opts)
  end
  k = state.get_keymap("http_response", "prev_tab", "<S-Tab>")
  if k then
    vim.keymap.set("n", k, function() M.cycle_tab(-1) end, opts)
  end

  -- Re-run current request
  k = state.get_keymap("http_response", "rerun", "r")
  if k then
    vim.keymap.set("n", k, function()
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
      vim.api.nvim_set_current_win(win)
      pcall(vim.api.nvim_win_set_cursor, win, { last.line, 0 })
      -- Clear last_response so the UI updates even if the same request returns quickly
      state.last_response = nil
      require("poste").run_request()
    end, opts)
  end

  -- Multi-response navigation
  k = state.get_keymap("http_response", "next_response", "]")
  if k then
    vim.keymap.set("n", k, function() M.navigate_response(1) end, opts)
  end
  k = state.get_keymap("http_response", "prev_response", "[")
  if k then
    vim.keymap.set("n", k, function() M.navigate_response(-1) end, opts)
  end

  -- JSON filter prompt (<leader>j) — interactive float with completion dropdown
  k = state.get_keymap("http_response", "json_filter", "<leader>j")
  if k then
    vim.keymap.set("n", k, function()
      local bufnr = vim.api.nvim_get_current_buf()
      if vim.bo[bufnr].filetype ~= "json" then return end
      require("poste.http.json").start_interactive_input()
    end, opts)
  end

  -- JSON restore original (<leader>jc)
  k = state.get_keymap("http_response", "json_restore", "<leader>jc")
  if k then
    vim.keymap.set("n", k, function()
      local bufnr = vim.api.nvim_get_current_buf()
      if vim.bo[bufnr].filetype ~= "json" then return end
      require("poste.http.json").restore_original()
    end, opts)
  end

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

  -- K on image response: try inline render in Body, otherwise open system viewer
  k = state.get_keymap("http_response", "image_preview", "K")
  if k then
    vim.keymap.set("n", k, function()
      local bufnr = vim.api.nvim_get_current_buf()
      if bufnr ~= buf then return end
      local r = state.last_response
      if not r or not r.metadata or not r.metadata.file_path then return end
      if not format.is_image_content_type(r.metadata.file_content_type) then return end
      local ok = false
      if state.current_view == "body" then
        if format.has_image_nvim() and not r.metadata.file_content_type:match("^image/svg%+xml") then
          local cursor_line = vim.api.nvim_buf_line_count(buf) - format.inline_image_padding_lines() + 1
          ok = format.render_response_image(buf, r, cursor_line)
        end
      end
      if not ok then
        format.open_image_external(r.metadata.file_path)
      end
    end, opts)
  end
end

function M.get_buf()
  if response_buffer and vim.api.nvim_buf_is_valid(response_buffer) then
    return response_buffer
  end
  return nil
end

--- Ensure the response split is open and display the given lines
function M.render_buffer(lines, filetype)
  format.close_image_preview()
  local buf = get_response_buffer()

  -- Make buffer modifiable, write lines, lock again
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Set filetype for treesitter highlighting
  vim.bo[buf].filetype = filetype or "text"

  -- Re-apply keymaps AFTER filetype change so ftplugin keymaps don't win
  setup_keymaps(buf)

  -- Apply Redis-specific extmark highlights if this is a Redis response
  if state.last_response and state.last_response.protocol == "redis" and state.current_view == "body" then
    local ok, data = pcall(vim.json.decode, state.last_response.body)
    if ok and data and data.type then
      format.apply_redis_highlights(buf, lines, data.type)
    end
  end

  -- Open split window if not already open
  if not response_window or not vim.api.nvim_win_is_valid(response_window) then
    local saved_win = vim.api.nvim_get_current_win()
    local cmd = state.config.split_direction == "vertical" and "vsplit" or "split"
    vim.cmd(cmd)
    response_window = vim.api.nvim_get_current_win()

    if state.config.split_direction == "vertical" then
      vim.api.nvim_win_set_width(response_window, state.config.split_size)
    else
      vim.api.nvim_win_set_height(response_window, state.config.split_size)
    end

    vim.api.nvim_set_current_win(saved_win)
    setup_response_cleanup_autocmds()
  end

  vim.api.nvim_win_set_buf(response_window, buf)

  -- Move cursor to top
  pcall(vim.api.nvim_win_set_cursor, response_window, { 1, 0 })
end

return M
