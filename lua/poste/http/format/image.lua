--- Image preview for response buffers.
---
--- Supports image.nvim, snacks.image, Kitty protocol, and external viewer fallback.
--- Extracted from the former format.lua god module.
local M = {}

local image_preview_state = {
  image = nil,
  snacks_placement = nil,
}
local INLINE_IMAGE_PADDING_LINES = 2

--- Image content type detection.
local image_content_types = {
  ["image/png"] = true,
  ["image/jpeg"] = true,
  ["image/gif"] = true,
  ["image/webp"] = true,
  ["image/svg+xml"] = true,
  ["image/avif"] = true,
  ["image/bmp"] = true,
  ["image/tiff"] = true,
  ["image/x-icon"] = true,
  ["image/vnd.microsoft.icon"] = true,
}

function M.is_image_content_type(content_type)
  if not content_type then return false end
  local mime = content_type:match("^([^;]+)") or content_type
  return image_content_types[mime] == true
end

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
    vim.notify("Image file not found: " .. tostring(file_path), vim.log.levels.WARN, { title = "Poste" })
    return
  end
  local opener = vim.fn.has("mac") == 1 and "open" or "xdg-open"
  vim.fn.jobstart({ opener, file_path }, { detach = true })
  vim.notify(string.format("Opening image: %s", file_path), vim.log.levels.INFO, { title = "Poste" })
end

function M.close_image_preview()
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
  if not placement_ok or not placement then
    return false
  end

  image_preview_state.snacks_placement = placement
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

return M