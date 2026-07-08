local state = require("poste.state")
local format = require("poste.http.format")
local buffer = require("poste.http.buffer")

local uv = vim.uv or vim.loop
local M = {}
local verbose_timer = nil

local function stop_verbose_timer()
  if verbose_timer then
    verbose_timer:stop()
    verbose_timer:close()
    verbose_timer = nil
  end
end

local function start_verbose_timer()
  stop_verbose_timer()
  verbose_timer = uv.new_timer()
  verbose_timer:start(200, 200, vim.schedule_wrap(function()
    if not state.pending_request or state.last_response then
      stop_verbose_timer()
      return
    end
    if state.current_view ~= "verbose" then return end
    local buf = buffer.get_buf()
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
    local lines = format.format_view("verbose", nil, { pending_request = state.pending_request })
    lines = buffer.sanitize_lines(lines)
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    format.apply_view_highlights(buf, "verbose", lines, nil)
  end))
end

local function render_view(view, lines, filetype)
  lines = buffer.sanitize_lines(lines)
  buffer.render_buffer(lines, filetype)
  buffer.update_winbar(view)

  if filetype == "json" then
    local json = require("poste.http.json")
    local buf = buffer.get_buf()
    json.setup_buffer(buf)
  end

  local buf = buffer.get_buf()
  if buf then
    format.apply_view_highlights(buf, view, lines, state.last_response)
  end
end

function M.show_view(view)
  state.current_view = view

  if view ~= "verbose" then
    stop_verbose_timer()
  end

  -- Pending request (no response yet)
  if not state.last_response and state.pending_request then
    if view == "verbose" then
      local lines, filetype = format.format_view("verbose", nil, { pending_request = state.pending_request })
      render_view(view, lines, filetype)
      start_verbose_timer()
    else
      buffer.update_winbar(view)
    end
    return
  end

  if not state.last_response then return end

  -- Response available
  stop_verbose_timer()

  -- Fast path: use pre-rendered buffer for multi-response
  local idx = state.response_index
  local rb = idx and buffer.get_response_buffer_for_idx(idx, view)
  if rb and buffer.get_response_win() then
    local win = buffer.get_response_win()
    vim.api.nvim_win_set_buf(win, rb)
    buffer.update_winbar(view)
    return
  end

  local opts = {
    assertion_results = state.last_assertion_results,
    script_logs = state.last_script_logs,
  }
  local lines, filetype = format.format_view(view, state.last_response, opts)

  render_view(view, lines, filetype)

  if view == "body" then
    local buf = buffer.get_buf()
    local r = state.last_response
    if buf and r and r.metadata and format.is_image_content_type(r.metadata.file_content_type) then
      local cursor_line = vim.api.nvim_buf_line_count(buf) - format.inline_image_padding_lines() + 1
      format.render_response_image(buf, r, cursor_line)
    end
  end
end

buffer.on_show_view = M.show_view

return M