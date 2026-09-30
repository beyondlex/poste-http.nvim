--- Image preview for response buffers.
---
--- Supports image.nvim, snacks.image, Kitty protocol, and external viewer fallback.
--- Extracted from the former format.lua god module.
---
--- URL download/caching and content-type tables live in http/image_cache.lua
--- (2026-08-30 review U6); they are re-exported here so the format.lua facade
--- and existing callers keep one import path. Preview flows call
--- M.download_image_url dynamically, so tests can still stub it on this module.
local M = {}
local float = require("poste-http.ui.float")
local image_cache = require("poste-http.http.image_cache")
local notify = require("poste-http.ui.notify").notify

local image_preview_state = {
  image = nil,
  snacks_placement = nil,
  float_win = nil,
  float_buf = nil,
}
local INLINE_IMAGE_PADDING_LINES = 2

local meta_ns = nil
local meta_hl_defined = false

local function meta_namespace()
  if not meta_ns then
    meta_ns = vim.api.nvim_create_namespace("poste_image_meta")
  end
  return meta_ns
end

--- Gray highlight for the meta lines below a floating image preview.
local function ensure_meta_highlight()
  if meta_hl_defined then return end
  meta_hl_defined = true
  pcall(vim.api.nvim_set_hl, 0, "PosteImageMeta", { fg = "#9e9e9e", default = true })
end

-- Re-exports from image_cache (content-type tables, download + disk cache).
M.is_image_content_type = image_cache.is_image_content_type
M.guess_image_content_type = image_cache.guess_image_content_type
M.cache_path_for_url = image_cache.cache_path_for_url
M.download_image_url = image_cache.download_image_url
M.cached_image_path = image_cache.cached_image_path
M.download_image_url_async = image_cache.download_image_url_async

--- Detect terminal support for Kitty graphics protocol.
function M.supports_kitty_protocol()
  if vim.env.KITTY_WINDOW_ID then return true end
  if (vim.env.TERM or ""):match("kitty") then return true end
  if vim.env.TERM_PROGRAM == "WezTerm" then return true end
  return false
end

--- Open an image file in the system viewer (macOS `open` / Linux `xdg-open`).
function M.open_image_external(file_path)
  if not file_path or vim.fn.filereadable(file_path) ~= 1 then
    notify("Image file not found: " .. tostring(file_path), vim.log.levels.WARN)
    return
  end
  local opener = vim.fn.has("mac") == 1 and "open" or "xdg-open"
  vim.fn.jobstart({ opener, file_path }, { detach = true })
  notify(string.format("Opening image: %s", file_path), vim.log.levels.INFO)
end

function M.close_image_preview()
  -- Close floating image preview window
  if image_preview_state.float_win then
    local win = image_preview_state.float_win
    image_preview_state.float_win = nil
    image_preview_state.float_buf = nil
    pcall(function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end)
  end
  if image_preview_state.snacks_placement then
    local p = image_preview_state.snacks_placement
    image_preview_state.snacks_placement = nil
    pcall(function()
      if type(p.close) == "function" then
        p:close()
      end
    end)
  end
  if image_preview_state.image then
    local img = image_preview_state.image
    image_preview_state.image = nil
    pcall(function()
      if type(img) == "table" then
        if type(img.clear) == "function" then
          img:clear()
        elseif type(img.delete) == "function" then
          img:delete()
        end
      end
    end)
  end
end

local function try_snacks_image(buf, file_path, cursor_line)
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" then
    return false
  end
  if type(snacks.image) ~= "table" or type(snacks.image.supports) ~= "function" then
    return false
  end
  if not snacks.image.supports(file_path) then
    return false
  end
  local win = vim.fn.bufwinid(buf)
  if win < 0 then return false end

  local pos_row = (cursor_line or 1)

  M.close_image_preview()

  local placement_ok, placement = pcall(snacks.image.placement.new, buf, file_path, {
    pos = { pos_row, 0 },
    inline = true,
    conceal = false,
  })
  if not placement_ok then
    notify("snacks.image preview failed: " .. tostring(placement), vim.log.levels.WARN)
    return false
  end
  if not placement then
    return false
  end

  image_preview_state.snacks_placement = placement
  vim.schedule(function()
    vim.defer_fn(function()
      if placement.img and placement.img:failed() then
        notify("snacks.image async load failed for: " .. file_path, vim.log.levels.WARN)
      end
    end, 2000)
  end)
  return true
end

local function try_image_nvim(buf, file_path, cursor_line)
  local ok, image = pcall(require, "image")
  if not ok or type(image) ~= "table" or type(image.from_file) ~= "function" then
    return false
  end

  local win = vim.fn.bufwinid(buf)
  if win < 0 then
    return false
  end

  local restore_cursor = nil
  if cursor_line and vim.api.nvim_win_is_valid(win) then
    restore_cursor = vim.api.nvim_win_get_cursor(win)
    local line_count = vim.api.nvim_buf_line_count(buf)
    local target_line = math.max(1, math.min(cursor_line, math.max(1, line_count)))
    pcall(vim.api.nvim_win_set_cursor, win, { target_line, 0 })
  end

  local opts = {
    buffer = buf,
    window = win,
    with_virtual_padding = true,
    inline = true,
    id = "poste_image_preview",
    overlap = 0,
    x = 0,
    y = cursor_line and math.max(cursor_line - 1, 0) or 0,
  }

  local image_obj
  local from_ok, from_err = pcall(function()
    image_obj = image.from_file(file_path, opts)
  end)
  if not from_ok or not image_obj then
    if restore_cursor then
      pcall(vim.api.nvim_win_set_cursor, win, restore_cursor)
    end
    return false, from_err
  end

  M.close_image_preview()
  image_preview_state.image = image_obj

  if type(image_obj) == "table" then
    if type(image_obj.render) == "function" then
      local render_ok = pcall(function() image_obj:render() end)
      if render_ok then
        if restore_cursor then
          pcall(vim.api.nvim_win_set_cursor, win, restore_cursor)
        end
        return true
      end
    end
    if type(image_obj.show) == "function" then
      local show_ok = pcall(function() image_obj:show() end)
      if show_ok then
        if restore_cursor then
          pcall(vim.api.nvim_win_set_cursor, win, restore_cursor)
        end
        return true
      end
    end
  end

  image_preview_state.image = nil
  if type(image.render) == "function" then
    local render_ok = pcall(function()
      image.render(image_obj)
    end)
    if render_ok then
      if restore_cursor then
        pcall(vim.api.nvim_win_set_cursor, win, restore_cursor)
      end
      return true
    end
  end

  if restore_cursor then
    pcall(vim.api.nvim_win_set_cursor, win, restore_cursor)
  end

  return false
end

function M.has_image_nvim()
  local ok, image = pcall(require, "image")
  return ok and type(image) == "table" and type(image.from_file) == "function"
end

function M.has_snacks_image()
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" then return false end
  if type(snacks.image) ~= "table" or type(snacks.image.supports) ~= "function" then return false end
  return snacks.image.supports_terminal()
end

function M.inline_image_padding_lines()
  return INLINE_IMAGE_PADDING_LINES
end

--- Render image inline in the current response buffer/window.
function M.render_image_preview(buf, file_path, content_type, cursor_line)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  if not file_path or vim.fn.filereadable(file_path) ~= 1 then return false end
  if not M.is_image_content_type(content_type) then return false end

  -- snacks supports SVG via imagemagick conversion, try it first
  if try_snacks_image(buf, file_path, cursor_line) then
    return true
  end

  -- image.nvim doesn't support SVG, skip those
  if content_type and content_type:match("^image/svg%+xml") then return false end
  if try_image_nvim(buf, file_path, cursor_line) then
    return true
  end
  return false
end

function M.render_response_image(buf, r, cursor_line)
  if not r or not r.metadata then return false end
  local file_path = r.metadata.file_path
  local content_type = r.metadata.file_content_type or r.content_type
  return M.render_image_preview(buf, file_path, content_type, cursor_line)
end

--- Get the URL under the cursor position.
--- Returns the URL string or nil.
function M.get_url_under_cursor()
  local line = vim.fn.getline(".")
  local col = vim.fn.col(".") - 1
  local url_pattern = "https?://[^\"'%s>%)%]]+"
  local urls = {}
  for u in line:gmatch(url_pattern) do
    table.insert(urls, u)
  end
  for _, u in ipairs(urls) do
    local start_idx, end_idx = line:find(u, 1, true)
    if start_idx and col >= start_idx - 1 and col < end_idx then
      return u
    end
  end
  local expanded = vim.fn.expand("<cfile>")
  if expanded then
    expanded = expanded:match("^https?://[^\"'%s>%,%)%]]+")
  end
  if expanded then
    return expanded
  end
  return nil
end

--- Download and preview an image URL.
--- Fresh cache hits render synchronously; otherwise the "Downloading..."
--- notification is truthful because the fetch runs via jobstart and the
--- render happens from its completion callback.
---@param buf number
---@param url string
---@param cursor_line number
---@return boolean  render happened (cache hit) or the fetch was started
function M.preview_image_url(buf, url, cursor_line)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  if not url or not url:match("^https?://") then return false end
  local ct = M.guess_image_content_type(url)
  if not ct then return false end

  M.cleanup_url_preview()

  local cached = M.cached_image_path(url)
  if cached then
    return M.render_image_preview(buf, cached, ct, cursor_line)
  end

  notify("Downloading image...", vim.log.levels.INFO)
  return M.download_image_url_async(url, function(file_path, content_type)
    if not file_path then
      notify("Failed to download image from URL", vim.log.levels.WARN)
      return
    end
    M.render_image_preview(buf, file_path, content_type or ct, cursor_line)
  end)
end

--- Download and preview an image URL in a floating window.
--- Async like preview_image_url; the popup opens from the completion callback
--- and can be closed with Esc.
---@param url string
---@return boolean  render happened (cache hit) or the fetch was started
function M.preview_image_url_float(url)
  if not url or not url:match("^https?://") then return false end
  local ct = M.guess_image_content_type(url)
  if not ct then return false end

  M.close_image_preview()

  local cached = M.cached_image_path(url)
  if cached then
    return M.render_image_float(cached, ct)
  end

  notify("Downloading image...", vim.log.levels.INFO)
  return M.download_image_url_async(url, function(file_path, content_type)
    if not file_path then
      notify("Failed to download image from URL", vim.log.levels.WARN)
      return
    end
    M.render_image_float(file_path, content_type or ct)
  end)
end

--- Try to render image in floating window using snacks.image.
--- @param start_row number 1-based row to anchor the header bottom; snacks
--- requires pos[1] <= buf line count, so the header must leave a real line there.
local function try_snacks_image_float(buf, win, file_path, start_row, img_width, img_height)
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" then return false end
  if type(snacks.image) ~= "table" or type(snacks.image.supports) ~= "function" then
    return false
  end
  if not snacks.image.supports(file_path) then return false end

  local placement_ok, placement = pcall(snacks.image.placement.new, buf, file_path, {
    inline = true,
    conceal = false,
    pos = { start_row or 1, 0 },
    width = img_width,
    height = img_height,
  })
  if not placement_ok or not placement then
    return false
  end

  image_preview_state.snacks_placement = placement
  return true
end

--- Try to render image in floating window using image.nvim.
local function try_image_nvim_float(buf, win, file_path, start_row, img_width, img_height)
  local ok, image = pcall(require, "image")
  if not ok or type(image) ~= "table" or type(image.from_file) ~= "function" then
    return false
  end

  local image_obj
  local from_ok = pcall(function()
    image_obj = image.from_file(file_path, {
      buffer = buf,
      window = win,
      with_virtual_padding = true,
      inline = true,
      id = "poste_image_float_preview",
      y = start_row or 0,
      width = img_width,
      height = img_height,
    })
  end)
  if not from_ok or not image_obj then return false end

  image_preview_state.image = image_obj

  if type(image_obj.render) == "function" then
    local render_ok = pcall(function() image_obj:render() end)
    if render_ok then return true end
  end
  if type(image_obj.show) == "function" then
    local show_ok = pcall(function() image_obj:show() end)
    if show_ok then return true end
  end

  image_preview_state.image = nil
  return false
end

--- Build the meta lines rendered below a floating image preview (gray text).
local function build_meta_lines(meta)
  local summary = {}
  if meta.format then table.insert(summary, meta.format) end
  if meta.width and meta.height then
    table.insert(summary, string.format("%d*%d", meta.width, meta.height))
  end
  if meta.size_human then table.insert(summary, meta.size_human) end

  local lines = { " " }
  table.insert(lines,  " " .. table.concat(summary, "  ") )
  if meta.exif then
    if meta.exif.Make then
      local model = meta.exif.Model and (" " .. meta.exif.Model) or ""
      table.insert(lines, " Camera: " .. meta.exif.Make .. model)
    end
    if meta.exif.DateTime then
      table.insert(lines, " Taken:  " .. meta.exif.DateTime)
    end
    if meta.exif.Orientation and meta.exif.Orientation ~= 1 then
      local labels = { [3] = "Rotate 180", [6] = "Rotate 90 CW", [8] = "Rotate 270 CW" }
      table.insert(lines, " Orient: " .. (labels[meta.exif.Orientation] or tostring(meta.exif.Orientation)))
    end
  end
  return lines
end

--- Pick a float window size that hugs the image while fitting on screen.
--- The image sits at the top; `meta_rows` extra rows are reserved below it.
--- Also returns the image render area (cells) for the backend renderers.
local function calc_float_size(meta, meta_rows)
  meta_rows = meta_rows or 0
  local max_w = math.max(20, vim.o.columns - 2)
  local max_h = math.max(4, vim.o.lines - 2)
  local img_cols, img_rows = 80, math.max(1, max_h - meta_rows - 2)
  if meta.width and meta.height and meta.width > 0 and meta.height > 0 then
    local cols = math.max(1, meta.width / 9)
    local rows = math.max(1, meta.height / 18)
    local avail_h = math.max(1, max_h - meta_rows - 2)
    local scale = math.min(max_w / cols, avail_h / rows, 1)
    img_cols = math.max(1, math.floor(cols * scale))
    img_rows = math.max(1, math.floor(rows * scale))
  end
  local width = math.max(20, math.min(img_cols, max_w))
  local height = math.min(1 + img_rows + meta_rows, max_h)
  return width, height, img_cols, img_rows
end

--- Render an image file in a floating window.
--- The image fills the top; meta info (format, dimensions, size, JPEG EXIF)
--- is shown below it in gray. Tries snacks.image first, then image.nvim, then
--- fallback to file info. Closable with <Esc> or q.
---@param file_path string
---@param content_type string
---@return boolean
function M.render_image_float(file_path, content_type)
  if not file_path or vim.fn.filereadable(file_path) ~= 1 then return false end
  if not M.is_image_content_type(content_type) then return false end

  local image_meta = require("poste-http.http.format.image_meta")
  local meta = image_meta.read_image_meta(file_path, content_type)
  local meta_lines = build_meta_lines(meta)
  local width, height, img_cols, img_rows = calc_float_size(meta, #meta_lines)

  -- Floating window: row 0 is a blank anchor below which the image renders;
  -- meta text follows. modifiable stays open for the external-viewer fallback
  -- that appends file info below.
  -- q/<Esc> close via on_close → close_image_preview (also covers :q/<C-w>c
  -- through the WinClosed autocmd inside ui/float).
  local lines = { "" }
  for _, l in ipairs(meta_lines) do
    table.insert(lines, l)
  end

  local title_parts = { "Preview" }
  if meta.format then table.insert(title_parts, meta.format) end
  if meta.width and meta.height then
    table.insert(title_parts, string.format("%d*%d", meta.width, meta.height))
  end
  if meta.size_human then table.insert(title_parts, meta.size_human) end

  local buf, win = float.open({
    lines = lines,
    width = width,
    height = height,
    title = " " .. table.concat(title_parts, "  ") .. " ",
    modifiable = true,
    on_close = function() M.close_image_preview() end,
  })
  if not win then return false end

  image_preview_state.float_win = win
  image_preview_state.float_buf = buf

  -- Gray meta lines below the image
  ensure_meta_highlight()
  for i = 1, #meta_lines do
    vim.api.nvim_buf_set_extmark(buf, meta_namespace(), i, 0, {
      hl_group = "PosteImageMeta",
      end_row = i + 1,
      end_col = 0,
    })
  end

  -- Try snacks.image first (image anchored on the blank row 0)
  if try_snacks_image_float(buf, win, file_path, 1, img_cols, img_rows) then
    return true
  end

  -- Try image.nvim (draw below the meta lines so it never covers them)
  if try_image_nvim_float(buf, win, file_path, #lines, img_cols, img_rows) then
    return true
  end

  -- Fallback: show file info in the buffer
  local extras = {
    "File: " .. file_path,
    "Type: " .. (content_type or "unknown"),
  }
  vim.api.nvim_buf_set_lines(buf, #lines, -1, false, extras)
  vim.bo[buf].modifiable = false
  return true
end

--- Clean up temp files created for URL preview.
function M.cleanup_url_preview()
  image_cache.cleanup_temp_files()
end

return M
