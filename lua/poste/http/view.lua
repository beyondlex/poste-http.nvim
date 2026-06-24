local state = require("poste.state")
local format = require("poste.http.format")
local assertions = require("poste.http.assertions")
local scripts = require("poste.http.scripts")
local buffer = require("poste.http.buffer")

local M = {}

function M.show_view(view)
  state.current_view = view
  if not state.last_response then return end

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
    lines = format.format_verbose(state.last_response)
    filetype = "markdown"
  elseif view == "assertions" then
    lines = assertions.format_assertions(state.last_assertion_results)
    filetype = "markdown"
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
      filetype = "markdown"
    else
      filetype = format.detect_filetype(ct)
    end
  else
    lines = { "Unknown view: " .. view }
    filetype = "text"
  end

  buffer.render_buffer(lines, filetype)
  buffer.update_winbar(view)

  if filetype == "json" then
    local json = require("poste.http.json")
    local buf = buffer.get_buf()
    json.setup_buffer(buf)
  end

  if view == "body" and (not state.last_response.body or state.last_response.body == "") then
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

  if view == "verbose" and state.last_response.status then
    local buf = buffer.get_buf()
    if buf then
      local sc = state.last_response.status
      local hl_group
      if sc < 300 then hl_group = "PosteStatus2xx"
      elseif sc < 400 then hl_group = "PosteStatus3xx"
      elseif sc < 500 then hl_group = "PosteStatus4xx"
      else hl_group = "PosteStatus5xx"
      end
      local ns = vim.api.nvim_create_namespace("poste_status_code")
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      for i, line in ipairs(lines) do
        local status_start, status_end = line:find("%*%*.-%*%*")
        if status_start then
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, status_start - 1, {
            end_col = status_end,
            hl_group = hl_group,
            priority = 200,
          })
          break
        end
      end
    end
  end
end

buffer.on_show_view = M.show_view

return M
