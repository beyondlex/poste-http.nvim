local state = require("poste.state")
local request_vars = require("poste.http.request_vars")

local M = {}

local active = nil  -- { src_buf, src_win, out_buf, out_win, augroup, items }
local hl_ns = vim.api.nvim_create_namespace("poste_outline")

-----------------------------------------------------------------------------
-- Parse request blocks
-----------------------------------------------------------------------------

local function extract_method_url(buf, start_line, total_lines)
  local lines = vim.api.nvim_buf_get_lines(buf, start_line, math.min(start_line + 20, total_lines), false)
  local in_pre = false
  for _, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.-)%s*$") or line
    if trimmed == "" then
      -- skip empty
    elseif trimmed:match("^<%s*{%%") then
      in_pre = true
    elseif in_pre then
      if trimmed:match("%%}") then in_pre = false end
    elseif trimmed:match("^@%w") then
      -- var def
    elseif trimmed:match("^#") then
      -- comment
    else
      local method = trimmed:match("^(%u+)%s")
      if method then
        local url = trimmed:match("^%u+%s+(.+)")
        local path = url and (
          url:match("://[^/]*(.*)")
          or url:match("}}(.*)")
          or url:match("^(/.*)")
        ) or nil
        return method, (path and path ~= "" and path or nil)
      end
      return nil, nil
    end
  end
  return nil, nil
end

local function collect_items(buf)
  local requests = request_vars.collect_requests(buf)
  local total = vim.api.nvim_buf_line_count(buf)
  local items = {}
  for _, req in ipairs(requests) do
    local method, url_path = extract_method_url(buf, req.start_line, total)
    table.insert(items, {
      name = req.name,
      line = req.start_line,
      method = method,
      url_path = url_path,
    })
  end
  return items
end

-----------------------------------------------------------------------------
-- Rendering
-----------------------------------------------------------------------------

local function method_hl(method)
  if not method then return "PosteMethodOther" end
  local m = method:upper()
  if m == "GET" then return "PosteMethodGET"
  elseif m == "POST" then return "PosteMethodPOST"
  elseif m == "PUT" then return "PosteMethodPUT"
  elseif m == "DELETE" then return "PosteMethodDELETE"
  elseif m == "PATCH" then return "PosteMethodPATCH"
  elseif m == "HEAD" then return "PosteMethodHEAD"
  else return "PosteMethodOther" end
end

local function render()
  if not active or not vim.api.nvim_buf_is_valid(active.out_buf) then return end
  local items = collect_items(active.src_buf)

  local lines = {}
  for _, item in ipairs(items) do
    local method = item.method or "--"
    local label = method .. "  " .. item.name
    if item.url_path then
      label = label .. "  " .. item.url_path
    end
    table.insert(lines, label)
  end

  vim.bo[active.out_buf].modifiable = true
  vim.api.nvim_buf_set_lines(active.out_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(active.out_buf, hl_ns, 0, -1)

  for i, item in ipairs(items) do
    local m = item.method or "--"
    local m_end = #m + 1
    vim.api.nvim_buf_add_highlight(active.out_buf, hl_ns, method_hl(item.method), i - 1, 0, m_end)
    vim.api.nvim_buf_add_highlight(active.out_buf, hl_ns, "PosteRequestName", i - 1, m_end + 2, m_end + 2 + #item.name)
  end

  vim.bo[active.out_buf].modifiable = false
  active.items = items
end

-----------------------------------------------------------------------------
-- Highlight current request
-----------------------------------------------------------------------------

local function find_current_item(items, cursor_line)
  local best = nil
  for _, item in ipairs(items) do
    if item.line <= cursor_line then
      best = item
    else
      break
    end
  end
  return best
end

local function highlight_current()
  if not active or not vim.api.nvim_buf_is_valid(active.out_buf) then return end
  local items = active.items or {}
  if #items == 0 then return end

  local cursor_line = vim.api.nvim_win_get_cursor(active.src_win)
  if not cursor_line then return end

  local current = find_current_item(items, cursor_line[1])
  local data_win = active.out_win

  -- Clear previous extmarks
  vim.api.nvim_buf_clear_namespace(active.out_buf, hl_ns, 0, -1)

  -- Re-apply method+name highlights, then highlight current line
  for i, item in ipairs(items) do
    local m = item.method or "--"
    local m_end = #m + 1
    vim.api.nvim_buf_add_highlight(active.out_buf, hl_ns, method_hl(item.method), i - 1, 0, m_end)
    vim.api.nvim_buf_add_highlight(active.out_buf, hl_ns, "PosteRequestName", i - 1, m_end + 2, m_end + 2 + #item.name)

    if current and item.line == current.line then
      vim.api.nvim_buf_add_highlight(active.out_buf, hl_ns, "PosteSymbolCurrent", i - 1, 0, -1)
    end
  end

  -- Scroll outline to keep current item visible
  if current then
    local target_line = nil
    for i, item in ipairs(items) do
      if item.line == current.line then target_line = i break end
    end
    if target_line then
      local win_lines = vim.api.nvim_win_get_height(data_win)
      local cur_top = vim.fn.line("w0", data_win)
      if target_line < cur_top or target_line >= cur_top + win_lines - 1 then
        vim.api.nvim_win_set_cursor(data_win, { target_line, 0 })
      end
    end
  end

  -- Re-mark modifiable state
  vim.bo[active.out_buf].modifiable = false
end

-----------------------------------------------------------------------------
-- Jump to request from outline
-----------------------------------------------------------------------------

local function jump_to_request()
  if not active then return end
  local items = active.items or {}
  local cursor = vim.api.nvim_win_get_cursor(0)
  local idx = cursor[1]
  local item = items[idx]
  if not item then return end

  if vim.api.nvim_buf_is_valid(active.src_buf) and vim.api.nvim_win_is_valid(active.src_win) then
    vim.api.nvim_set_current_win(active.src_win)
    vim.api.nvim_win_set_cursor(active.src_win, { item.line, 0 })
    vim.cmd("normal! zz")
  end
end

-----------------------------------------------------------------------------
-- Public API
-----------------------------------------------------------------------------

function M.toggle()
  if active then
    M.close()
  else
    M.open()
  end
end

function M.open()
  if active then M.close() end

  local src_buf = vim.api.nvim_get_current_buf()
  local src_win = vim.api.nvim_get_current_win()
  local ft = vim.bo[src_buf].filetype
  if ft ~= "poste_http" then
    vim.notify("Poste outline: only available for .http files", vim.log.levels.WARN)
    return
  end

  local out_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(out_buf, "poste://outline")
  vim.bo[out_buf].buftype = "nofile"
  vim.bo[out_buf].bufhidden = "wipe"
  vim.bo[out_buf].filetype = "poste_outline"
  vim.bo[out_buf].modifiable = true

  local out_win = vim.api.nvim_open_win(out_buf, false, {
    split = "right",
    win = src_win,
  })
  vim.api.nvim_win_set_width(out_win, 40)
  vim.wo[out_win].winfixwidth = true
  vim.wo[out_win].number = false
  vim.wo[out_win].relativenumber = false
  vim.wo[out_win].signcolumn = "no"
  vim.wo[out_win].foldenable = false

  -- Keymaps for outline buffer
  vim.keymap.set("n", "<CR>", jump_to_request, { buffer = out_buf, noremap = true, silent = true })
  vim.keymap.set("n", "q", M.close, { buffer = out_buf, noremap = true, silent = true })

  active = {
    src_buf = src_buf,
    src_win = src_win,
    out_buf = out_buf,
    out_win = out_win,
    augroup = vim.api.nvim_create_augroup("PosteOutline_" .. src_buf, { clear = true }),
  }

  -- Autocommands
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = active.augroup,
    buffer = src_buf,
    callback = function()
      if not active then return end
      render()
      highlight_current()
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = active.augroup,
    buffer = src_buf,
    callback = highlight_current,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = active.augroup,
    buffer = src_buf,
    callback = function()
      if active then M.close() end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = active.augroup,
    buffer = out_buf,
    callback = function()
      if active then active = nil end
    end,
  })

  -- Initialize items for jump lookups
  active.items = {}

  render()
  highlight_current()
end

function M.close()
  if not active then return end

  pcall(vim.api.nvim_del_augroup_by_id, active.augroup)
  if vim.api.nvim_win_is_valid(active.out_win) then
    pcall(vim.api.nvim_win_close, active.out_win, true)
  end
  if vim.api.nvim_buf_is_valid(active.out_buf) then
    pcall(vim.api.nvim_buf_delete, active.out_buf, { force = true })
  end

  active = nil
end

return M