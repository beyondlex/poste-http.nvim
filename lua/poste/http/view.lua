local state = require("poste.state")
local format = require("poste.http.format")
local assertions = require("poste.http.assertions")
local scripts = require("poste.http.scripts")
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
    -- Only update if we're still waiting and the verbose tab is active
    if not state.pending_request or state.last_response then
      stop_verbose_timer()
      return
    end
    if state.current_view ~= "verbose" then return end
    local buf = buffer.get_buf()
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
    local lines = format.format_verbose(nil, state.pending_request)
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    -- Re-apply verbose highlights (r=nil for pending)
    format.apply_verbose_highlights(buf, lines, nil)
  end))
end

local function render_view(view, lines, filetype)
  buffer.render_buffer(lines, filetype)
  buffer.update_winbar(view)

  if filetype == "json" then
    local json = require("poste.http.json")
    local buf = buffer.get_buf()
    json.setup_buffer(buf)
  end

  if view == "body" and state.last_response and (not state.last_response.body or state.last_response.body == "") then
    local buf = buffer.get_buf()
    if buf then
      local ns = vim.api.nvim_create_namespace("poste_response_hint")
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
        end_col = #lines[1],
        hl_group = "Comment",
      })
    end
  end

  -- Binary file link highlight (blue, underlined)
  if (view == "body" or view == "verbose") and state.last_response and state.last_response.metadata and state.last_response.metadata.file_path then
    local buf = buffer.get_buf()
    if buf then
      format.apply_file_link_highlight(buf, lines)
    end
  end

  if view == "verbose" then
    local buf = buffer.get_buf()
    if buf then
      pcall(vim.treesitter.stop, buf)
      format.apply_verbose_highlights(buf, lines, state.last_response)
    end
  end

  if view == "request" then
    local buf = buffer.get_buf()
    if buf then
      format.apply_request_highlights(buf, lines)
    end
  end

  if view == "assertions" then
    local buf = buffer.get_buf()
    if buf then
      pcall(vim.treesitter.stop, buf)
      assertions.apply_highlights(buf, lines)
    end
  end
end

function M.show_view(view)
  state.current_view = view

  -- Stop any running verbose timer when switching away from verbose
  if view ~= "verbose" then
    stop_verbose_timer()
  end

  -- --- Pending request (no response yet) ---
  if not state.last_response and state.pending_request then
    if view == "verbose" then
      local lines = format.format_verbose(nil, state.pending_request)
      local filetype = "text"
      render_view(view, lines, filetype)
      start_verbose_timer()
    else
      -- Non-verbose pending views: show nothing yet (window stays open with previous content)
      -- but ensure winbar is updated
      buffer.update_winbar(view)
    end
    return
  end

  if not state.last_response then return end

  -- --- Response available: show full data ---
  stop_verbose_timer()

  local lines, filetype
  if view == "body" then
    if not state.last_response.body or state.last_response.body == "" then
      lines = { "(no response body)" }
      filetype = "text"
    else
      lines = format.format_body(state.last_response)
      filetype = format.detect_filetype(state.last_response.content_type)
    end
  elseif view == "verbose" then
    lines = format.format_verbose(state.last_response, nil)
    filetype = "text"
  elseif view == "assertions" then
    lines = assertions.format_assertions(state.last_assertion_results)
    filetype = "poste_assertions"
  elseif view == "script_logs" then
    lines = scripts.format_script_logs(state.last_script_logs)
    filetype = "markdown"
  elseif view == "request" then
    lines = format.format_request_payload(state.last_response)
    local r = state.last_response
    local ct = ""
    local req_headers = r.metadata and r.metadata.request_headers
    if req_headers then
      for l in req_headers:gmatch("[^\r\n]+") do
        local k, v = l:match("^([^:]+):%s*(.+)$")
        if k and k:lower() == "content-type" then ct = v end
      end
    end
    if ct:lower():find("multipart/form%-data") then
      filetype = "text"
    else
      filetype = format.detect_filetype(ct)
    end
  else
    lines = { "Unknown view: " .. view }
    filetype = "text"
  end

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
