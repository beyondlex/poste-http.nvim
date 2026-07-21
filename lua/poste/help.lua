--- Poste keymap help — dynamically reads configured keymaps and shows with descriptions.
local state = require("poste.state")

local M = {}

-- Description map: section → action → description
local DESCRIPTIONS = {
  http_source = {
    run = "Execute request under cursor",
    run_hsplit = "Execute request, horizontal split",
    jump_next = "Jump to next request block",
    jump_prev = "Jump to previous request block",
    goto_definition = "Go to variable definition",
    goto_references = "Show variable references",
    quickfix_next = "Next quickfix item",
    quickfix_prev = "Previous quickfix item",
    paste_curl = "Paste clipboard as cURL request",
    copy_as_curl = "Copy request as cURL command",
    toggle_outline = "Toggle outline window",
    pick_env = "Pick environment",
    show_var_value = "Show variable value / response chain",
    show_history = "Open request history",
    help = "Show this help window",
  },
  http_response = {
    close = "Close response window",
    rerun = "Re-run request",
    view_body = "View response body",
    view_verbose = "View verbose output",
    view_assertions = "View assertion results",
    view_script_logs = "View pre/post script logs",
    next_tab = "Next response tab",
    prev_tab = "Previous response tab",
    image_preview = "Render image inline or open externally",
  },
  http_history = {
    close = "Close history window",
    delete_entry = "Delete current history entry",
    focus_detail = "Focus detail pane",
  },
}

local SECTION_TITLES = {
  http_source = "HTTP Request Buffer",
  http_response = "HTTP Response Buffer",
  http_history = "HTTP Request History",
}

function M.open()
  local lines = {}
  local width = 50

  for _, section in ipairs({ "http_source", "http_response", "http_history" }) do
    local title = SECTION_TITLES[section] or section
    local km = state.config.keymaps[section] or {}
    local desc = DESCRIPTIONS[section] or {}

    table.insert(lines, "")
    table.insert(lines, "  " .. title)
    table.insert(lines, "  " .. string.rep("─", 46))

    local actions = {}
    for action, _ in pairs(km) do
      table.insert(actions, action)
    end
    table.sort(actions)

    for _, action in ipairs(actions) do
      local key = state.get_keymap(section, action)
      if key and key ~= false then
        local key_display = state.format_key_string(key)
        local description = desc[action] or ""
        local line = string.format("  %-12s  %s", key_display, description)
        table.insert(lines, line)
        width = math.max(width, #line + 2)
      end
    end
  end

  -- Dynamic close hint: collect all configured close keys
  local close_keys = {}
  local function collect_close(section, action)
    local k = state.get_keymap(section, action)
    if k then close_keys[state.format_key_string(k)] = true end
  end
  collect_close("http_response", "close")
  collect_close("http_history", "close")
  local close_parts = {}
  for k in pairs(close_keys) do
    table.insert(close_parts, k)
  end
  table.sort(close_parts, function(a, b) return #a < #b end)
  local close_text = #close_parts > 0 and table.concat(close_parts, " / ") or "q"
  table.insert(lines, "  " .. close_text .. "  close")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "poste_help"

  local height = math.min(#lines, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 2, col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height,
    style = "minimal",
    border = "rounded",
    title = " Poste Keymaps ",
    title_pos = "center",
  })

  vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = buf, nowait = true })

  -- Highlight section titles
  local ns = vim.api.nvim_create_namespace("poste_help")
  for i, line in ipairs(lines) do
    if line:find("^  %u%a") then -- section title line (two+ char word, not single-letter key)
      vim.api.nvim_buf_add_highlight(buf, ns, "Title", i - 1, 2, -1)
    elseif line:find("^  ─") then -- separator
      vim.api.nvim_buf_add_highlight(buf, ns, "Comment", i - 1, 2, -1)
    else
      -- Highlight the key name (first non-space word)
      local key_s, key_e = line:find("%S+", 3)
      if key_s then
        vim.api.nvim_buf_add_highlight(buf, ns, "Special", i - 1, key_s - 1, key_e)
      end
    end
  end
end

return M
