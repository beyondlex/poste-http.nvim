local _ = require("poste-http.state")
local request_vars = require("poste-http.http.request_vars")
local ts_query = require("poste-http.http.ts_query")
local text = require("poste-http.ui.text")
local semantics = require("poste-http.ui.semantics")
-- ui/render is aliased: this module has its own local render() below.
local ui_render = require("poste-http.ui.render")
local float = require("poste-http.ui.float")

local M = {}

local function use_ts()
  return require("poste-http.http.ts_query").feature_enabled("outline")
end

local active = nil
local hl_ns = vim.api.nvim_create_namespace("poste_outline")

local function ellipsis(s, max)
  return text.truncate(s, max)
end

-----------------------------------------------------------------------------
-- Parse request blocks
-----------------------------------------------------------------------------

local function extract_method_url(buf, start_line, total_lines)
  local lines = vim.api.nvim_buf_get_lines(buf, start_line, math.min(start_line + 20, total_lines), false)
  local in_pre = false
  for _, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.-)%s*$") or line
    if trimmed:match("^<%s*{") then
      in_pre = true
    elseif in_pre then
      if trimmed:match("%%}") then in_pre = false end
    elseif trimmed == "" or trimmed:match("^@%S") or trimmed:match("^#") or trimmed:match("^<<") then  -- luacheck: ignore 542
    else
      local run_target = trimmed:match("^[Rr][Uu][Nn]%s+(%S+)")
      if run_target then
        return "RUN", run_target
      end
      local method = trimmed:match("^(%u+)%s")
      if method then
        local url = trimmed:match("^%u+%s+(.+)")
        local path = url and (
          url:match("://[^/]*(.*)")
          or url:match("}}(.*)")
          or url:match("^(/.*)")
        ) or nil
        if path then path = path:gsub("%?.*", "") end
        return method, (path and path ~= "" and path or nil)
      end
      return nil, nil
    end
  end
  return nil, nil
end

local function collect_file_scope_vars(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local items = {}
  for i, line in ipairs(lines) do
    if line:match("^###") then break end
    local name, val = line:match("^%s*@(%w+)%s*[= ](.*)")
    if name then
      table.insert(items, {
        name = "@" .. name,
        line = i,
        method = "@",
        url_path = vim.trim(val),
      })
    else
      local bare = line:match("^%s*@(%w+)%s*$")
      if bare then
        table.insert(items, {
          name = "@" .. bare,
          line = i,
          method = "@",
          url_path = nil,
        })
      end
    end
  end
  return items
end

local function ts_collect_file_scope_vars(buf)
  local seps = ts_query.query_nodes(buf, [[
    (separator) @sep
  ]])
  local first_sep_line = nil
  if #seps > 0 then
    for _, cap in ipairs(seps[1].captures) do
      if cap.name == "sep" then
        first_sep_line = cap.node:start()
      end
    end
  end

  local results = ts_query.query_nodes(buf, [[
    (variable_definition
      (var_name) @name
      (var_value) @val)
  ]])
  local items = {}

  for _, match in ipairs(results) do
    local name_node = nil
    local name, val = "", ""
    for _, cap in ipairs(match.captures) do
      if cap.name == "name" then name_node = cap.node; name = ts_query.node_text(cap.node) end
      if cap.name == "val" then val = ts_query.node_text(cap.node) end
    end
    if name_node then
      local sr = name_node:start()
      if first_sep_line and sr >= first_sep_line then break end
      table.insert(items, {
        name = "@" .. name,
        line = sr + 1,
        method = "@",
        url_path = vim.trim(val),
      })
    end
  end

  return items
end

local function ts_collect_items(buf)
  local items = ts_collect_file_scope_vars(buf)

  local results = ts_query.query_nodes(buf, [[
    (request_block
      (separator)
      (request_name) @name)
  ]])

  for _, match in ipairs(results) do
    local name_node = nil
    for _, cap in ipairs(match.captures) do
      if cap.name == "name" then name_node = cap.node end
    end
    if name_node then
      local sr = name_node:start()
      local name = vim.trim(ts_query.node_text(name_node))

      local method = "--"
      local url_path = nil

      local block_node = ts_query.parent_of_type(name_node, "request_block")
      if block_node then
        local br, _, _, _ = block_node:range()

        local run_nodes = ts_query.query_nodes_in_range(buf, [[
          (run_directive) @run
        ]], br, br + 3)
        if #run_nodes > 0 then
          local run_node = run_nodes[1].captures[1].node
          local target_child = run_node:child_by_field_name("target")
          local target = target_child and ts_query.node_text(target_child) or ""
          method = "RUN"
          url_path = target
        else
          local line_nodes = ts_query.query_nodes_in_range(buf, [[
            (request_line) @line
          ]], br, br + 20)
          -- First request_line wins: the block's own line defines the row.
          local ln = line_nodes[1]
          if ln then
            local line_node = ln.captures[1].node
            local method_node = line_node:named_child(0)
            if method_node then
              method = ts_query.node_text(method_node):upper()
              local url_node = line_node:named_child(1)
              if url_node then
                local url = ts_query.node_text(url_node)
                url_path = url:match("://[^/]*(.*)")
                  or url:match("}}(.*)")
                  or url:match("^(/.*)")
                  or nil
                if url_path then url_path = url_path:gsub("%?.*", "") end
              end
            end
          end
        end
      end

      table.insert(items, {
        name = name,
        line = sr + 1,
        method = method,
        url_path = url_path,
      })
    end
  end

  return items
end

local function collect_items(buf)
  local items
  if use_ts() then
    items = ts_collect_items(buf)
  else
    items = collect_file_scope_vars(buf)
    local requests = request_vars.collect_requests(buf)
    local total = vim.api.nvim_buf_line_count(buf)
    for _, req in ipairs(requests) do
      local method, url_path = extract_method_url(buf, req.start_line, total)
      table.insert(items, {
        name = req.name,
        line = req.start_line,
        method = method,
        url_path = url_path,
      })
    end
  end
  for _, item in ipairs(items) do
    if item.method and item.method:lower() == "run" then
      item.method = "RUN"
    end
  end
  return items
end

-----------------------------------------------------------------------------
-- Rendering
-----------------------------------------------------------------------------

local function method_hl(method)
  if method == "@" then return "PreProc" end
  return semantics.method_hl(method)
end

local function build_label(item, max_method_width)
  local win_width = active and vim.api.nvim_win_get_width(active.out_win) or 40
  local method = item.method or "--"

  if method == "@" then
    item._name_start = 1
    local path_display = item.url_path and ellipsis(item.url_path, win_width - 2) or ""
    local val = path_display ~= "" and (" " .. path_display) or ""
    return "@" .. item.name:sub(2) .. val
  end

  -- Pad method to fixed column width for alignment
  local method_padded = method .. string.rep(" ", max_method_width - #method)
  local remaining = win_width - max_method_width - 2
  local name_max = math.max(4, math.min(16, math.floor(remaining * 0.35)))
  local path_max = math.max(3, remaining - name_max - 1)

  local path_display = item.url_path and ellipsis(item.url_path, path_max) or ""
  local name_display = "-" .. ellipsis(item.name, name_max - 1)

  if path_display == "" then
    item._name_start = max_method_width + 2
    return method_padded .. "  " .. name_display
  end
  item._name_start = max_method_width + #path_display + 3
  return method_padded .. "  " .. path_display .. " " .. name_display
end

local function render()
  if not active or not vim.api.nvim_buf_is_valid(active.out_buf) then return end
  local items = collect_items(active.src_buf)

  -- Compute fixed method column width for alignment
  local max_method_width = 0
  for _, item in ipairs(items) do
    local m = (item.method or "--"):len()
    if m > max_method_width then max_method_width = m end
  end
  max_method_width = math.min(max_method_width, 8)

  local lines = {}
  for _, item in ipairs(items) do
    table.insert(lines, build_label(item, max_method_width))
  end

  ui_render.set_lines(active.out_buf, lines)
  vim.api.nvim_buf_clear_namespace(active.out_buf, hl_ns, 0, -1)

  for i, item in ipairs(items) do
    local m_end = max_method_width + 1
    vim.api.nvim_buf_add_highlight(active.out_buf, hl_ns, method_hl(item.method), i - 1, 0, m_end)
    if item._name_start then
      vim.api.nvim_buf_add_highlight(active.out_buf, hl_ns, "Comment", i - 1, item._name_start - 1, -1)
    end
  end

  active.items = items
  active.max_method_width = max_method_width
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
  local max_method_width = active.max_method_width or 4

  vim.api.nvim_buf_clear_namespace(active.out_buf, hl_ns, 0, -1)

  for i, item in ipairs(items) do
    local m_end = max_method_width + 1
    vim.api.nvim_buf_add_highlight(active.out_buf, hl_ns, method_hl(item.method), i - 1, 0, m_end)
    if item._name_start then
      vim.api.nvim_buf_add_highlight(active.out_buf, hl_ns, "Comment", i - 1, item._name_start - 1, -1)
    end

    if current and item.line == current.line then
      vim.api.nvim_buf_add_highlight(active.out_buf, hl_ns, "PosteSymbolCurrent", i - 1, 0, -1)
    end
  end

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

  local width = math.min(80, math.max(45, math.floor(vim.o.columns * 0.4)))
  local height = math.min(20, vim.o.lines - 4)

  local ok, out_win = pcall(function()
    local _, w = float.open({
      buf = out_buf,
      width = width,
      height = height,
      border = "rounded",
      close_keys = {},
      win_opts = { zindex = 50 },
    })
    return w
  end)
  if not ok or not out_win then
    pcall(vim.api.nvim_buf_delete, out_buf, { force = true })
    return
  end
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
  local outline_debounce
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = active.augroup,
    buffer = src_buf,
    callback = function()
      if not active then return end
      if outline_debounce then outline_debounce:stop() end
      outline_debounce = vim.defer_fn(function()
        render()
        highlight_current()
      end, 150)
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

  -- Place outline cursor on the current request, not the first line
  local items = active.items or {}
  if #items > 0 then
    local cursor_line = vim.api.nvim_win_get_cursor(active.src_win)
    if cursor_line then
      local current = find_current_item(items, cursor_line[1])
      if current then
        for i, item in ipairs(items) do
          if item.line == current.line then
            vim.api.nvim_win_set_cursor(active.out_win, { i, 0 })
            break
          end
        end
      end
    end
  end
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