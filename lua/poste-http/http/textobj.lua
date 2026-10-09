--- Text objects over the poste_http tree: request block, headers, body,
--- script. The module shipped dead for months (nothing mapped it) and its
--- selects never worked anyway: the grammar's request_block node is ONLY
--- the `### Name` line — the old lookups walked up from a request-line node
--- to a request_block that can never be its ancestor. buffer_setup.lua now
--- maps the M.select_* handlers in visual/operator-pending mode (config
--- keymap section "http_source", actions textobj_block/headers/body/script)
--- and buffer-local <Plug> aliases exist for explicit mappings.
---
--- Selection feeds `line|col` motions in VISUAL mode: move the cursor to
--- the range end, `o`-swap so the old anchor becomes the cursor, then move
--- to the range start — the selection then covers exactly the range
--- regardless of where the visual anchor was. Operator-pending mode is
--- deliberately NOT mapped: an operator consumes exactly ONE motion and our
--- range is a two-motion walk, which vim cannot express as an operator
--- target (the fed keys would complete the operator after its first line).
--- The pure range computation lives in block_rows so specs test it without
--- keymap machinery.
local ts_query = require("poste-http.http.ts_query")

local M = {}

--- The range (0-based rows, end EXCLUSIVE row) of the request block that
--- contains row: from its ### separator to the line before the next
--- separator (or the last non-blank line). Trailing blank lines are trimmed
--- so `daR` does not eat the spacing before the next block. nil when no
--- separator sits at or above the row.
--- @return integer|nil, integer|nil
function M.block_rows(buf, row)
  local seps = ts_query.query_nodes(buf, [[
    (separator) @sep
  ]])
  local rows = {}
  for _, match in ipairs(seps) do
    for _, cap in ipairs(match.captures) do
      if cap.name == "sep" then
        rows[#rows + 1] = cap.node:start()
      end
    end
  end
  table.sort(rows)

  local start_row = nil
  for _, r in ipairs(rows) do
    if r <= row then
      start_row = r
    end
  end
  if not start_row then return nil end

  local next_sep = nil
  for _, r in ipairs(rows) do
    if r > start_row then
      next_sep = r
      break
    end
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  local end_row = (next_sep and (next_sep - 1)) or (line_count - 1)
  while end_row > start_row do
    local line = vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1]
    if line and vim.trim(line) ~= "" then break end
    end_row = end_row - 1
  end
  return start_row, end_row
end

--- Feed the motions that select (sr,sc)..(er,ec) from any visual anchor:
--- jump to the range END, `o`-swap anchor/cursor, jump to the range START —
--- the selection then covers exactly the range no matter where V anchored.
--- The `|` motion takes a 1-based column, tree-sitter cols are 0-based
--- bytes: the start needs sc + 1; the end stays ec — moving TO 1-based col
--- ec puts the cursor ON the node's last byte, which is where a visual
--- selection must end.
local function feed_range(sr, sc, er, ec)
  vim.api.nvim_feedkeys(
    vim.keycode(string.format("%dG%d|o%dG%d|", er + 1, ec, sr + 1, sc + 1)),
    "n", false
  )
end

--- The whole request block: separator line through the last non-blank line
--- before the next separator.
function M.select_request_block()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local sr, er = M.block_rows(buf, cursor[1] - 1)
  if not sr then return end
  local end_line = vim.api.nvim_buf_get_lines(buf, er, er + 1, false)[1] or ""
  feed_range(sr, 0, er, #end_line)
end

--- The header section: from the first header's first byte to the last
--- header's last byte within the cursor's block (the tree has no node
--- spanning them, so the range composes the first/last (header) captures).
function M.select_headers()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local sr, er = M.block_rows(buf, cursor[1] - 1)
  if not sr then return end

  local headers = ts_query.query_nodes_in_range(buf, [[
    (header) @hdr
  ]], sr, er)
  if #headers == 0 then return end

  local hs, hsc = headers[1].captures[1].node:range()
  local _, _, ls, lc = headers[#headers].captures[1].node:range()
  feed_range(hs, hsc, ls, lc)
end

--- The body: JSON / multipart / form / file upload — whichever node wraps
--- the cursor.
function M.select_body()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local node = ts_query.node_at_point(buf, cursor[1] - 1, cursor[2])
  if not node then return end
  local target = ts_query.parent_of_type(node, "json_body", "multipart_boundary",
    "multipart_form_data", "form_body", "file_upload")
  if not target then return end
  local sr, sc, er, ec = target:range()
  feed_range(sr, sc, er, ec)
end

--- The script block the cursor is inside (pre- or post-script).
function M.select_script()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local node = ts_query.node_at_point(buf, cursor[1] - 1, cursor[2])
  if not node then return end
  local target = ts_query.parent_of_type(node, "pre_script", "post_script")
  if not target then return end
  local sr, sc, er, ec = target:range()
  feed_range(sr, sc, er, ec)
end

return M
