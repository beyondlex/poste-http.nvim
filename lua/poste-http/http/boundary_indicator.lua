local state = require("poste-http.state")

local M = {}

local _prev_buf = nil
local _disabled = false
local _boundary_augroup = nil
local ns = vim.api.nvim_create_namespace("poste_boundary")

local function clear_all(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  _prev_buf = nil
end

--- Paint the request block as a full-width rectangle: one extmark per row
--- with hl_eol, so the background reaches the window edge on every screen
--- row (auto-wrapped lines included). This replaces the old sign-column
--- border, freeing the sign column for the execution status indicator.
local function paint_background(buf, start, stop)
  for line = start, stop do
    vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
      end_row = line + 1,
      end_col = 0,
      hl_group = "PosteHttpBoundary",
      hl_eol = true,
      hl_mode = "combine",
    })
  end
end

--- Only the number column of each line — the text keeps the parser's own
--- colours (poste-db.nvim's boundary_style="gutter" parity).
local function paint_gutter(buf, start, stop)
  for line = start, stop do
    vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
      number_hl_group = "PosteHttpBoundaryGutter",
    })
  end
end

local function apply_range(buf, start, stop)
  if _prev_buf and _prev_buf ~= buf then
    clear_all(_prev_buf)
  end
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count == 0 then return end
  start = math.max(0, math.min(start, line_count - 1))
  stop  = math.max(0, math.min(stop,  line_count - 1))
  if state.config.boundary_style == "gutter" then
    paint_gutter(buf, start, stop)
  else
    paint_background(buf, start, stop)
  end
  _prev_buf = buf
end

local function find_block(buf, cursor)
  local cache = require("poste-http.http.cache")
  local block = cache.get_semantic_block_at_line(buf, cursor)
  if block and block.line and block.end_line then
    return block.line, block.last_content_line or block.end_line
  end
  block = cache.get_block_at_line(buf, cursor)
  if not block then return nil, nil end
  local stop_line = block.last_content_line or block.end_line
  return block.start_line, stop_line
end

local function update(buf, cursor)
  if _disabled then return end
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local total = vim.api.nvim_buf_line_count(buf)
  if total == 0 then return end
  local start, stop = find_block(buf, cursor)
  if not start then clear_all(_prev_buf); return end
  apply_range(buf, start - 1, stop - 1)
end

function M.refresh(buf, cursor)
  if _disabled then return end
  update(buf, cursor)
end

function M.clear(buf)
  clear_all(buf)
end

function M.toggle()
  _disabled = not _disabled
  if _disabled then
    -- The painted extmarks may live in ANOTHER buffer (the last one the
    -- cursor moved in) — clearing only the current buffer used to leave
    -- that stale rectangle behind, still visible after coming back.
    M.clear(_prev_buf)
    M.clear(vim.api.nvim_get_current_buf())
    if _boundary_augroup then
      pcall(vim.api.nvim_del_augroup_by_id, _boundary_augroup)
      _boundary_augroup = nil
    end
    vim.notify("HTTP boundary highlight: OFF", vim.log.levels.INFO, { title = "Poste" })
  else
    _boundary_augroup = vim.api.nvim_create_augroup("PosteHttpBoundary", { clear = true })
    -- The toggle is GLOBAL (one command, one notification): every
    -- .http buffer follows the cursor, not just the one that happened to
    -- be focused when the command ran (the old buffer=0 binding silently
    -- dropped tracking on the next buffer). The cache's block scan keys on
    -- `###` lines, which any markdown file carries — so the filetype gate
    -- lives here, not in the scan.
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
      group = _boundary_augroup,
      callback = function(ev)
        if vim.bo[ev.buf].filetype ~= "poste_http" then
          return
        end
        M.refresh(ev.buf, vim.fn.line("."))
      end,
    })
    M.refresh(vim.api.nvim_get_current_buf(), vim.fn.line("."))
    vim.notify("HTTP boundary highlight: ON", vim.log.levels.INFO, { title = "Poste" })
  end
end

vim.api.nvim_create_user_command("PosteHttpBoundary", function()
  require("poste-http.http.boundary_indicator").toggle()
end, { desc = "Toggle HTTP request block boundary highlight" })

return M
