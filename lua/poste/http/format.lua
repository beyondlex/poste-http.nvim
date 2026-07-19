--- Response formatters: body, headers, verbose views + filetype detection.
---
--- This module is now a thin facade that dispatches to sub-modules:
---   - format/body.lua       — HTTP response body formatting, JSON pretty-print, Redis body
---   - format/verbose.lua    — Verbose response rendering + highlights
---   - format/image.lua      — Image preview (image.nvim, snacks, Kitty, external)
---   - format/multipart.lua  — Multipart body parsing & display
---
--- NOTE: New code should require the sub-modules directly. The re-exports
--- here are maintained for backward compatibility.
local state = require("poste.state")

local body_mod = require("poste.http.format.body")
local verbose_mod = require("poste.http.format.verbose")
local image_mod = require("poste.http.format.image")
local multipart_mod = require("poste.http.format.multipart")
local redis_mod = require("poste.redis")

local M = {}

-- Namespaces
local file_link_ns = vim.api.nvim_create_namespace("poste_file_link")
local request_ns = vim.api.nvim_create_namespace("poste_request")

---------------------------------------------------------------------------
-- Content-type → filetype mapping (for treesitter syntax highlighting)
---------------------------------------------------------------------------
local content_type_map = {
  ["application/json"] = "json",
  ["application/ld+json"] = "json",
  ["application/vnd.api+json"] = "json",
  ["text/html"] = "html",
  ["application/xhtml+xml"] = "html",
  ["text/xml"] = "xml",
  ["application/xml"] = "xml",
  ["application/rss+xml"] = "xml",
  ["application/atom+xml"] = "xml",
  ["text/javascript"] = "javascript",
  ["application/javascript"] = "javascript",
  ["text/css"] = "css",
  ["text/markdown"] = "markdown",
  ["text/yaml"] = "yaml",
  ["application/x-yaml"] = "yaml",
  ["text/plain"] = "text",
}

function M.detect_filetype(content_type)
  if not content_type or content_type == "" then
    return "text"
  end
  local mime = content_type:match("^([^;]+)") or content_type
  mime = vim.trim(mime):lower()
  return content_type_map[mime] or "text"
end

---------------------------------------------------------------------------
-- Image preview (re-exported from format/image.lua)
---------------------------------------------------------------------------
function M.is_image_content_type(content_type)
  return image_mod.is_image_content_type(content_type)
end
function M.supports_kitty_protocol()
  return image_mod.supports_kitty_protocol()
end
function M.open_image_external(file_path)
  return image_mod.open_image_external(file_path)
end
function M.close_image_preview()
  return image_mod.close_image_preview()
end
function M.has_image_nvim()
  return image_mod.has_image_nvim()
end
function M.has_snacks_image()
  return image_mod.has_snacks_image()
end
function M.inline_image_padding_lines()
  return image_mod.inline_image_padding_lines()
end
function M.render_image_preview(buf, file_path, content_type, cursor_line)
  return image_mod.render_image_preview(buf, file_path, content_type, cursor_line)
end
function M.render_response_image(buf, r, cursor_line)
  return image_mod.render_response_image(buf, r, cursor_line)
end

---------------------------------------------------------------------------
-- Body formatting (re-exported from format/body.lua)
---------------------------------------------------------------------------
function M.pretty_body(body, content_type)
  return body_mod.pretty_body(body, content_type)
end
function M.format_body(r)
  return body_mod.format_body(r)
end
function M.clean_response_cache(max_age_minutes)
  return body_mod.clean_response_cache(max_age_minutes)
end

---------------------------------------------------------------------------
-- Verbose view (re-exported from format/verbose.lua)
---------------------------------------------------------------------------
function M.format_verbose(r, pending)
  return verbose_mod.format_verbose(r, pending)
end
function M.format_request_payload(r)
  return verbose_mod.format_request_payload(r)
end
function M.apply_verbose_highlights(buf, lines, r)
  return verbose_mod.apply_verbose_highlights(buf, lines, r)
end

---------------------------------------------------------------------------
-- Multipart helpers (re-exported from format/multipart.lua)
---------------------------------------------------------------------------
M.condense_multipart_body = multipart_mod.condense_multipart_body

---------------------------------------------------------------------------
-- Request highlights
---------------------------------------------------------------------------
function M.apply_request_highlights(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, request_ns, 0, -1)
  for i, line in ipairs(lines) do
    local row = i - 1
    if line:match("^[^*#][^:]*:%s") then
      local colon = line:find(":", 3)
      if not colon then break end
      if colon then
        vim.api.nvim_buf_set_extmark(buf, request_ns, row, 0, {
          end_row = row, end_col = colon + 1,
          hl_group = "PosteRequestKey", priority = 100,
        })
        local val_start = colon + 2
        if val_start <= #line then
          vim.api.nvim_buf_set_extmark(buf, request_ns, row, val_start - 1, {
            end_row = row, end_col = #line,
            hl_group = "PosteRequestValue", priority = 100,
          })
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- File link highlights
---------------------------------------------------------------------------
function M.apply_file_link_highlight(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, file_link_ns, 0, -1)
  for i, line in ipairs(lines) do
    local prefix
    if line:match("^  Open file:%s+") then
      prefix = line:match("^  Open file:%s+")
    elseif line:match("^  File:%s+") then
      prefix = line:match("^  File:%s+")
    end
    if prefix then
      local col = #prefix
      if col < #line then
        local row = i - 1
        vim.api.nvim_buf_set_extmark(buf, file_link_ns, row, col, {
          end_row = row, end_col = #line,
          hl_group = "PosteFileLink",
          priority = 150,
        })
        return
      end
    end
  end
end

---------------------------------------------------------------------------
-- Redis highlights
---------------------------------------------------------------------------
-- Redis highlights (delegated to poste.redis module)
function M.apply_redis_highlights(buf, lines, rtype)
  return redis_mod.apply_highlights(buf, lines, rtype)
end

---------------------------------------------------------------------------
-- Content-Type helpers
---------------------------------------------------------------------------
function M.get_request_content_type(r)
  local req_headers = r.metadata and r.metadata.request_headers
  if not req_headers then return "" end
  for l in req_headers:gmatch("[^\r\n]+") do
    local k, v = l:match("^([^:]+):%s*(.+)$")
    if k and k:lower() == "content-type" then return v end
  end
  return ""
end

---------------------------------------------------------------------------
-- View dispatch
---------------------------------------------------------------------------
function M.format_view(view, r, opts)
  opts = opts or {}
  if view == "body" then
    if opts.jq_lines then
      return opts.jq_lines, "json"
    elseif not r or not r.body or r.body == "" then
      return { "(no response body)" }, "text"
    else
      return M.format_body(r), M.detect_filetype(r.content_type)
    end
  elseif view == "verbose" then
    return M.format_verbose(r, opts.pending_request), "text"
  elseif view == "assertions" then
    local ass = require("poste.http.assertions")
    return ass.format_assertions(opts.assertion_results), "poste_assertions"
  elseif view == "script_logs" then
    local scr = require("poste.http.scripts")
    return scr.format_script_logs(opts.script_logs), "markdown"
  elseif view == "request" then
    local lines = M.format_request_payload(r)
    local ct = M.get_request_content_type(r)
    local ft = (ct == "" or ct:lower():find("multipart/form%-data")) and "text" or M.detect_filetype(ct)
    return lines, ft
  end
  return { "Unknown view: " .. view }, "text"
end

function M.apply_view_highlights(buf, view, lines, r)
  if view == "body" and (not r or not r.body or r.body == "") then
    if lines[1] then
      local ns = vim.api.nvim_create_namespace("poste_response_hint")
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
        end_col = #lines[1],
        hl_group = "Comment",
      })
    end
  end

  if (view == "body" or view == "verbose") and r and r.metadata and r.metadata.file_path then
    M.apply_file_link_highlight(buf, lines)
  end

  if view == "verbose" then
    pcall(vim.treesitter.stop, buf)
    M.apply_verbose_highlights(buf, lines, r)
  end

  if view == "request" then
    M.apply_request_highlights(buf, lines)
  end

  if view == "assertions" then
    pcall(vim.treesitter.stop, buf)
    local ass = require("poste.http.assertions")
    ass.apply_highlights(buf, lines)
  end
end

return M
