local M = {}

local ns = vim.api.nvim_create_namespace("poste_http_boundary")
local _prev_buf = nil
local _disabled = false

local function clear_all(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

local function apply_range(buf, start, stop)
  clear_all(_prev_buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    _prev_buf = nil
    return
  end
  clear_all(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count == 0 then
    _prev_buf = nil
    return
  end
  -- Clamp to valid 0-based range
  start = math.max(0, math.min(start, line_count - 1))
  stop  = math.max(0, math.min(stop,  line_count - 1))
  for line = start, stop do
    local text
    if start == stop then text = "──"
    elseif line == start then text = "─┐"
    elseif line == stop then  text = "─┘"
    else text = " │"
    end
    vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
      virt_text = {{text, "PosteHttpBoundaryBorder"}},
      virt_text_pos = "right_align",
      priority = 100,
    })
  end
  _prev_buf = buf
end

--- Find the request block for a given cursor position.
--- Delegates to cache.lua block index for O(1) lookup.
local function find_block(buf, cursor)
  local cache = require("poste.http.cache")
  local block = cache.get_block_at_line(buf, cursor)
  if not block then return nil, nil end
  local stop_line = block.last_content_line or block.end_line
  return block.start_line, stop_line
end

local function update(buf, cursor)
  if _disabled then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local total = vim.api.nvim_buf_line_count(buf)
  if total == 0 then return end
  local start, stop = find_block(buf, cursor)
  if not start then clear_all(_prev_buf); _prev_buf = nil; return end
  apply_range(buf, start - 1, stop - 1)
end

function M.refresh(buf, cursor)
  if _disabled then return end
  update(buf, cursor)
end

function M.clear(buf)
  clear_all(buf)
  _prev_buf = nil
end

function M.toggle()
  _disabled = not _disabled
  if _disabled then
    M.clear(vim.api.nvim_get_current_buf())
    vim.notify("HTTP boundary highlight: OFF", vim.log.levels.INFO, { title = "Poste" })
  else
    M.refresh(vim.api.nvim_get_current_buf(), vim.fn.line("."))
    vim.notify("HTTP boundary highlight: ON", vim.log.levels.INFO, { title = "Poste" })
  end
end

vim.api.nvim_create_user_command("PosteHttpBoundary", function()
  require("poste.http.boundary_indicator").toggle()
end, { desc = "Toggle HTTP request block boundary highlight" })

return M