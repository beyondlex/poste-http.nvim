local ts_query = require("poste-http.http.ts_query")

local M = {}

local function select_node(type_name)
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]

  local node = ts_query.node_at_point(buf, row, col)
  if not node then return end

  local target = ts_query.parent_of_type(node, type_name)
  if not target then return end

  local sr, sc, er, ec = target:range()
  vim.api.nvim_feedkeys(
    vim.keycode(string.format("%dG%d|%dG%d|", sr + 1, sc, er + 1, ec)),
    "n", false
  )
end

function M.select_request_block()
  select_node("request_block")
end

function M.select_headers()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]

  local node = ts_query.node_at_point(buf, row, col)
  if not node then return end

  local request_block = ts_query.parent_of_type(node, "request_block")
  if not request_block then return end

  local sr, _, er, _ = request_block:range()
  local headers = ts_query.query_nodes_in_range(buf, [[
    (header) @hdr
  ]], sr, er)

  if #headers == 0 then return end

  local first = headers[1].captures[1].node
  local last = headers[#headers].captures[1].node
  local hs, hsc, _, _ = first:range()
  local _, _, ls, lc = last:range()

  vim.api.nvim_feedkeys(
    vim.keycode(string.format("%dG%d|%dG%d|", hs + 1, hsc, ls + 1, lc)),
    "n", false
  )
end

function M.select_body()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]

  local node = ts_query.node_at_point(buf, row, col)
  if not node then return end

  local body = ts_query.parent_of_type(node, "json_body", "multipart_boundary",
    "multipart_form_data", "form_body", "file_upload")
  if not body then return end

  local sr, sc, er, ec = body:range()
  vim.api.nvim_feedkeys(
    vim.keycode(string.format("%dG%d|%dG%d|", sr + 1, sc, er + 1, ec)),
    "n", false
  )
end

function M.select_script()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]

  local node = ts_query.node_at_point(buf, row, col)
  if not node then return end

  local script = ts_query.parent_of_type(node, "pre_script", "post_script")
  if not script then return end

  local sr, sc, er, ec = script:range()
  vim.api.nvim_feedkeys(
    vim.keycode(string.format("%dG%d|%dG%d|", sr + 1, sc, er + 1, ec)),
    "n", false
  )
end

return M