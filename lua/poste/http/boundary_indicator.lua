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

local function find_block(lines, cursor)
  local start = nil
  for i = cursor, 1, -1 do
    if (lines[i] or ""):match("^###") then
      start = i
      break
    end
  end
  if not start then return nil, nil end

  local next_sep = #lines + 1
  for i = cursor + 1, #lines do
    if (lines[i] or ""):match("^###") then
      next_sep = i
      break
    end
  end

  local stop = nil
  for i = next_sep - 1, start, -1 do
    local trimmed = (lines[i] or ""):match("^%s*(.-)%s*$")
    if trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^%-%-") then
      stop = i
      break
    end
  end
  if not stop then stop = start end

  return start, stop
end

local function update(buf, cursor)
  if _disabled then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local total = vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, total, false)
  local start, stop = find_block(lines, cursor)
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