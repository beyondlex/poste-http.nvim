--- Response buffer/window management and winbar tab indicators.
local state = require("poste.state")
local format = require("poste.format")

local M = {}

local response_buffer = nil
local response_window = nil

-- Callback for tab-switching keymaps; set by init.lua after show_view is defined.
M.on_show_view = nil

---------------------------------------------------------------------------
-- Winbar (tab indicators)
---------------------------------------------------------------------------

function M.update_winbar(active)
  if not response_window or not vim.api.nvim_win_is_valid(response_window) then
    return
  end

  local tabs = {
    { id = "body",    label = "Body [B]" },
    { id = "headers", label = "Headers [H]" },
    { id = "verbose", label = "Verbose [V]" },
  }
  -- Only show Asserts tab when assertions were run
  if state.last_assertion_results then
    table.insert(tabs, { id = "assertions", label = "Asserts [A]" })
  end

  local parts = {}
  for _, tab in ipairs(tabs) do
    if tab.id == active then
      table.insert(parts, "%#TabLineSel# " .. tab.label .. " %*")
    else
      table.insert(parts, "%#TabLine# " .. tab.label .. " %*")
    end
  end

  vim.wo[response_window].winbar = table.concat(parts)
end

---------------------------------------------------------------------------
-- Buffer management
---------------------------------------------------------------------------

local function get_response_buffer()
  if response_buffer and vim.api.nvim_buf_is_valid(response_buffer) then
    return response_buffer
  end

  response_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = response_buffer })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = response_buffer })
  vim.api.nvim_set_option_value("swapfile", false, { buf = response_buffer })
  vim.api.nvim_set_option_value("modifiable", false, { buf = response_buffer })
  vim.api.nvim_buf_set_name(response_buffer, "poste://response")

  local opts = { buffer = response_buffer, noremap = true, silent = true }

  -- Close window
  vim.keymap.set("n", "q", function()
    if response_window and vim.api.nvim_win_is_valid(response_window) then
      vim.api.nvim_win_close(response_window, true)
      response_window = nil
    end
  end, opts)

  -- Tab switching keymaps — delegate to on_show_view callback
  vim.keymap.set("n", "B", function() if M.on_show_view then M.on_show_view("body") end end, opts)
  vim.keymap.set("n", "H", function() if M.on_show_view then M.on_show_view("headers") end end, opts)
  vim.keymap.set("n", "V", function() if M.on_show_view then M.on_show_view("verbose") end end, opts)
  vim.keymap.set("n", "A", function() if M.on_show_view then M.on_show_view("assertions") end end, opts)

  return response_buffer
end

--- Ensure the response split is open and display the given lines
function M.render_buffer(lines, filetype)
  local buf = get_response_buffer()

  -- Make buffer modifiable, write lines, lock again
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Set filetype for treesitter highlighting
  vim.bo[buf].filetype = filetype or "text"

  -- Apply Redis-specific extmark highlights if this is a Redis response
  if state.last_response and state.last_response.protocol == "redis" and state.current_view == "body" then
    local ok, data = pcall(vim.json.decode, state.last_response.body)
    if ok and data and data.type then
      format.apply_redis_highlights(buf, lines, data.type)
    end
  end

  -- Open split window if not already open
  if not response_window or not vim.api.nvim_win_is_valid(response_window) then
    local saved_win = vim.api.nvim_get_current_win()
    local cmd = state.config.split_direction == "vertical" and "vsplit" or "split"
    vim.cmd(cmd)
    response_window = vim.api.nvim_get_current_win()

    if state.config.split_direction == "vertical" then
      vim.api.nvim_win_set_width(response_window, state.config.split_size)
    else
      vim.api.nvim_win_set_height(response_window, state.config.split_size)
    end

    vim.api.nvim_set_current_win(saved_win)
  end

  vim.api.nvim_win_set_buf(response_window, buf)

  -- Move cursor to top
  pcall(vim.api.nvim_win_set_cursor, response_window, { 1, 0 })
end

return M
