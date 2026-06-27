--- Response buffer/window management and winbar tab indicators.
local state = require("poste.state")
local format = require("poste.http.format")

local M = {}

local response_buffer = nil
local response_window = nil

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
  -- Only disable treesitter for the response buffer if the markdown parser
  -- isn't installed. Response views use "markdown" filetype for their
  -- formatting (bold status codes, section headers), but the content is
  -- curl logs/assertion output — not real markdown. If there's no parser,
  -- treesitter will crash trying to parse it, so we disable it preemptively.
  -- Users with a markdown parser installed get treesitter highlighting.
  local has_md_parser = pcall(function()
    return vim.treesitter.language.require_lang("markdown")
  end)
  if not has_md_parser then
    pcall(vim.api.nvim_buf_set_var, response_buffer, "ts_highlight", false)
    pcall(vim.treesitter.stop, response_buffer)
  end

  local opts = { buffer = response_buffer, noremap = true, silent = true }

  -- Close window
  local k = state.get_keymap("http_response", "close", "q")
  if k then
    vim.keymap.set("n", k, function()
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
      local buf = vim.api.nvim_get_current_buf()
      if vim.bo[buf].filetype ~= "json" then return end
      require("poste.http.json").start_interactive_input()
    end, opts)
  end

  -- JSON restore original (<leader>jc)
  k = state.get_keymap("http_response", "json_restore", "<leader>jc")
  if k then
    vim.keymap.set("n", k, function()
      local buf = vim.api.nvim_get_current_buf()
      if vim.bo[buf].filetype ~= "json" then return end
      require("poste.http.json").restore_original()
    end, opts)
  end

  return response_buffer
end

function M.get_buf()
  if response_buffer and vim.api.nvim_buf_is_valid(response_buffer) then
    return response_buffer
  end
  return nil
end

--- Ensure the response split is open and display the given lines
function M.render_buffer(lines, filetype)
  local buf = get_response_buffer()

  -- Make buffer modifiable, write lines, lock again
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Set filetype for treesitter highlighting
  vim.bo[buf].filetype = filetype or "text"

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
  end

  vim.api.nvim_win_set_buf(response_window, buf)

  -- Move cursor to top
  pcall(vim.api.nvim_win_set_cursor, response_window, { 1, 0 })
end

return M
