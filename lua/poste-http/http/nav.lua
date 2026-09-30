local state = require("poste-http.state")
local context_detector = require("poste-http.http.context_detector")
local data = require("poste-http.http.data")
local lua_docs = require("poste-http.http.lua_docs")
local import = require("poste-http.http.import")
local nav_ts = require("poste-http.http.nav.ts")
local nav_text = require("poste-http.http.nav.text")
local util = require("poste-http.util")
local notify = require("poste-http.ui.notify").notify

local M = {}

local function use_ts()
  return require("poste-http.http.ts_query").enabled_for(
    vim.api.nvim_get_current_buf(), "nav")
end

function M.show_script_api_doc()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local col_1idx = cursor[2] + 1
  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""

  local ctx = context_detector.detect_script_context(buf, line_num, col_1idx)
  if not ctx then return false end

  local ctx_key = ctx == "pre_script" and "pre" or "post"
  local docs = data.script_api_docs[ctx_key]
  if not docs then return false end

  local start = col_1idx
  while start > 1 do
    local ch = line_text:sub(start - 1, start - 1)
    if ch:match("[%w_]") or ch == "." then start = start - 1 else break end
  end

  local finish = col_1idx
  while finish < #line_text do
    local ch = line_text:sub(finish + 1, finish + 1)
    if ch:match("[%w_]") or ch == "." then finish = finish + 1 else break end
  end

  local identifier = start <= finish and line_text:sub(start, finish) or nil
  if not identifier then return false end

  if lua_docs.is_lua_identifier(identifier) then
    lua_docs.show_doc(buf, line_num, col_1idx, identifier)
    return true
  end

  local entry = nil
  local rel = col_1idx - start + 1
  local seg_start = 1
  local prefix_parts = {}

  for segment in identifier:gmatch("[^%.]+") do
    local seg_end = seg_start + #segment - 1
    table.insert(prefix_parts, segment)
    if rel >= seg_start and rel <= seg_end then
      local lookup_path = table.concat(prefix_parts, ".")
      entry = docs[lookup_path]
      while not entry and lookup_path:find("%.") do
        lookup_path = lookup_path:match("^(.+)%.[^%.]+$")
        entry = docs[lookup_path]
      end
      break
    end
    seg_start = seg_end + 2
  end
  if not entry then
    local cword = vim.fn.expand("<cword>")
    if cword and cword ~= "" then entry = docs[cword] end
  end
  if not entry then
    lua_docs.show_doc(buf, line_num, col_1idx, identifier)
    return true
  end

  local lines = {}
  table.insert(lines, "```lua")
  table.insert(lines, entry.sig)
  table.insert(lines, "```")
  table.insert(lines, "")
  table.insert(lines, entry.desc)

  local title = ctx == "pre_script" and " Pre-script API " or " Post-script API "
  local _, _, reused = util.open_doc_preview(lines, {
    title = title,
    track_key = "api:" .. identifier,
  })
  if reused then return true end

  return true
end

function M.jump_next()
  local line = vim.fn.line(".")
  local total = vim.fn.line("$")
  for i = line + 1, total do
    local text = vim.fn.getline(i)
    if text:match("^%s*###") then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  notify("No more requests", vim.log.levels.INFO)
end

function M.jump_prev()
  local line = vim.fn.line(".")
  for i = line - 1, 1, -1 do
    local text = vim.fn.getline(i)
    if text:match("^%s*###") then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  notify("No previous requests", vim.log.levels.INFO)
end

function M.show_var_value()
  if M.show_script_api_doc() then return end

  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local col = cursor[2] + 1
  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""

  local var_name = nil
  local s, e = line_text:find("{{(.-)}}")
  while s do
    if col >= s and col <= e then
      var_name = line_text:sub(s + 2, e - 2):gsub("^%s+", ""):gsub("%s+$", "")
      break
    end
    s, e = line_text:find("{{(.-)}}", e + 1)
  end

  if not var_name then
    notify("Not on a {{variable}} reference", vim.log.levels.WARN)
    return
  end

  local buf_path = vim.api.nvim_buf_get_name(buf)
  local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local full_content = table.concat(buf_lines, "\n")
  local buf_dir = buf_path ~= "" and vim.fn.fnamemodify(buf_path, ":h") or vim.fn.getcwd()
  local resolved_content = import.resolve_lua_imports(full_content, buf_dir)
  local resolved_lines = vim.split(resolved_content, "\n", { plain = true })
  local cache = require("poste-http.http.cache")
  local block_start, block_end = cache.find_request_block_bounds(buf, line_num)
  local vars = require("poste-http.http.vars")
  local resolver = vars.build_resolver_from_state({
    buf = buf,
    lines = resolved_lines,
    file_path = buf_path,
    block_start = block_start,
    block_end = block_end,
    env_name = state.current_env,
  })
  local value = resolver:resolve(var_name)
  if value == nil then
    value = import.resolve_lua_keypath(var_name, full_content, buf_dir)
  end
  local resolved = value or "(unresolved)"

  local title = " " .. var_name .. " "
  local lines = {}
  if resolved:find("\n") or resolved:find("`") then
    table.insert(lines, "```")
    table.insert(lines, resolved)
    table.insert(lines, "```")
  else
    table.insert(lines, "`" .. resolved .. "`")
  end

  local _, _, reused = util.open_doc_preview(lines, {
    title = title,
    track_key = tostring(buf) .. ":" .. var_name,
  })
  if reused then return end
end

function M.goto_definition()
  if use_ts() then
    nav_ts.goto_definition()
  else
    nav_text.goto_definition()
  end
end

function M.goto_references()
  if use_ts() then
    nav_ts.goto_references()
  else
    nav_text.goto_references()
  end
end

return M