local state = require("poste-http.state")
local format = require("poste-http.http.format")
local buffer = require("poste-http.http.buffer")
local columns = require("poste-http.ui.columns")
local semantics = require("poste-http.ui.semantics")
local render = require("poste-http.ui.render")
local winbar = require("poste-http.ui.winbar")
local float = require("poste-http.ui.float")
local keymaps = require("poste-http.ui.keymaps")

local M = {}

local list_buf = nil
local list_win = nil
-- method (8) + name (18) + status (3) + gap (1) + elapsed (9) + gap (2) + ts (12, HH:MM:SS.mmm).
local list_width = 53
local detail_buf = nil
local detail_win = nil
local current_index = nil
local DEFAULT_DETAIL_VIEW = "verbose"
local detail_view = DEFAULT_DETAIL_VIEW
local hiding = false
local list_ns = vim.api.nvim_create_namespace("poste_history_list")

local MAX_BODY_SAVE = 100 * 1024

local METHOD_WIDTH = 8
local STATUS_WIDTH = 3
local ELAPSED_WIDTH = 9
-- method (8) | name (stretch) | status (3) | gap (1) | elapsed (9) | gap (2) | timestamp (natural).
-- Name and status sit flush against method (no gaps), matching the classic list layout.
local LIST_COLS = {
  { width = METHOD_WIDTH, ellipsis = false },
  { flex = true, lead = 0 },
  { width = STATUS_WIDTH, lead = 0 },
  { lead = 1, width = ELAPSED_WIDTH },
  { lead = 2 },
}

local function truncate_response(response)
  if not response or type(response) ~= "table" then return response end
  local r = vim.deepcopy(response)
  if r.body and type(r.body) == "string" and #r.body > MAX_BODY_SAVE then
    r.body = r.body:sub(1, MAX_BODY_SAVE) .. "\n... [truncated " .. #r.body .. " bytes]"
  end
  return r
end

local function now()
  if vim.uv and vim.uv.gettimeofday then
    local sec, usec = vim.uv.gettimeofday()
    if sec then return sec, usec or 0 end
  end
  return os.time(), 0
end

local function history_file()
  return state.config.history_file or (vim.fn.stdpath("data") .. "/poste-http/history.json")
end

--- Write the full history to disk (synchronous, small bounded payload:
--- http_history_max entries with bodies truncated to MAX_BODY_SAVE).
local function persist()
  if not state.config.persist_history then return end
  local ok, payload = pcall(vim.json.encode, state.http_history)
  if not ok or not payload then return end
  local file = history_file()
  local ok_dir, _ = pcall(vim.fn.mkdir, vim.fn.fnamemodify(file, ":h"), "p")
  if not ok_dir then return end
  local fd, err = io.open(file, "w")
  if not fd then
    if state.log then state.log("WARN", "history persist failed: " .. tostring(err)) end
    return
  end
  fd:write(payload)
  fd:close()
end

--- Load persisted history at startup (idempotent).
function M.load()
  if not state.config.persist_history then return end
  local file = history_file()
  if vim.fn.filereadable(file) == 0 then return end
  local fd = io.open(file, "r")
  if not fd then return end
  local content = fd:read("*a")
  fd:close()
  if not content or content == "" then return end
  local ok, entries = pcall(vim.json.decode, content)
  if not ok or type(entries) ~= "table" then
    if state.log then state.log("WARN", "history load failed: invalid JSON in " .. file) end
    return
  end
  local loaded = {}
  local max_id = 0
  for _, e in ipairs(entries) do
    if e and type(e) == "table" and e.id then
      table.insert(loaded, e)
      if e.id > max_id then max_id = e.id end
    end
  end
  if #loaded > 0 then
    state.http_history = loaded
    local max = state.config.http_history_max or state.http_history_max
    if #state.http_history > max then
      for _ = 1, #state.http_history - max do
        table.remove(state.http_history)
      end
    end
    state.http_history_id_counter = max_id
  end
end

function M.add_entry(name, response, assertion_results, script_logs, source_file)
  state.http_history_id_counter = state.http_history_id_counter + 1
  local sec, usec = now()
  local entry = {
    id = state.http_history_id_counter,
    name = name,
    time = sec,
    time_usec = usec,
    source_file = source_file or "",
    response = truncate_response(response),
    assertion_results = assertion_results and vim.deepcopy(assertion_results) or nil,
    script_logs = script_logs and vim.deepcopy(script_logs) or nil,
  }
  table.insert(state.http_history, 1, entry)
  local max = state.config.http_history_max or state.http_history_max
  if #state.http_history > max then
    table.remove(state.http_history)
  end
  persist()
end

function M.delete_entry(id)
  for i, entry in ipairs(state.http_history) do
    if entry.id == id then
      table.remove(state.http_history, i)
      persist()
      return
    end
  end
end

local function format_timestamp(time, usec)
  if not time then return "" end
  local ms = usec and math.floor(usec / 1000) or 0
  return string.format("%s.%03d", os.date("%H:%M:%S", time), ms)
end

local function entry_method(entry)
  if not entry then return "" end
  local m = entry.method
  if (m == nil or m == "") and entry.response and entry.response.metadata then
    m = entry.response.metadata.method
  end
  if type(m) ~= "string" then return "" end
  return vim.trim(m):upper()
end

local function format_elapsed(ms)
  if type(ms) ~= "number" then return "-" end
  if ms >= 1000 then
    return string.format("%.2f s", ms / 1000)
  end
  return string.format("%.2f ms", ms)
end

--- Build the five display cells for one history entry (method, name, status,
--- elapsed, timestamp). Also returns the raw status for highlight mapping.
local function build_row(entry)
  local status = entry.response and entry.response.status
  local method = entry_method(entry)
  if method == "" then method = "-" end
  local status_text = (tonumber(status) or 0) > 0 and tostring(status) or "-"
  return {
    method,
    entry.name or "",
    status_text,
    format_elapsed(entry.response and entry.response.latency_ms),
    format_timestamp(entry.time, entry.time_usec),
  }, status
end

--- Attach highlight groups and byte ranges to the rendered cells of one row.
local function entry_info(cells, status)
  return {
    method = cells[1].text,
    method_hl = semantics.method_hl(cells[1].text),
    method_col = cells[1].col,
    method_end = cells[1].end_col,
    status = cells[3].text,
    status_hl = semantics.status_hl(status),
    status_col = cells[3].col,
    status_end = cells[3].end_col,
    elapsed_col = cells[4].col,
    elapsed_end = cells[4].end_col,
    ts_col = cells[5].col,
  }
end

--- Build the display line for one history entry.
--- Returns the line text plus column metadata used for extmark highlighting.
--- `width` is the total list width (defaults to the current list window width).
local function format_list_line(entry, width)
  local row, status = build_row(entry)
  local lines, cells = columns.render({ row }, LIST_COLS, { width = width or list_width })
  return lines[1], entry_info(cells[1], status)
end

local function get_active_tabs()
  local entry = state.http_history[current_index]
  if not entry then return {} end
  local body_label = "Body [" .. state.format_keymap("http_response", "view_body") .. "]"
  if entry._jq and entry._jq.query then
    body_label = "Body [" .. state.format_keymap("http_response", "view_body") .. "] | jq: " .. entry._jq.query
  end
  local tabs = {
    { id = "body", label = body_label },
  }
  local r = entry.response
  if r and r.metadata and r.metadata.request_body and r.metadata.request_body ~= "" then
    table.insert(tabs, { id = "request", label = "Rqst [" .. state.format_keymap("http_response", "view_request") .. "]" })
  end
  table.insert(tabs, { id = "verbose", label = "Verb [" .. state.format_keymap("http_response", "view_verbose") .. "]" })
  if entry.assertion_results then
    table.insert(tabs, { id = "assertions", label = "Asserts [" .. state.format_keymap("http_response", "view_assertions") .. "]" })
  end
  if entry.script_logs and #entry.script_logs > 0 then
    table.insert(tabs, { id = "script_logs", label = "Script [" .. state.format_keymap("http_response", "view_script_logs") .. "]" })
  end
  return tabs
end

local function update_winbar()
  if not detail_win or not vim.api.nvim_win_is_valid(detail_win) then return end
  vim.wo[detail_win].winbar = winbar.render_tabs(get_active_tabs(), detail_view)
end

local _detail_cursor = {}  -- { [entry_id] = { [view_name] = { row, col }, ... }, ... }

local function render_detail()
  if not detail_buf or not vim.api.nvim_buf_is_valid(detail_buf) then return end

  -- Save cursor for the current entry+view before re-rendering
  local entry = state.http_history[current_index]
  if entry and detail_win and vim.api.nvim_win_is_valid(detail_win) then
    local pos = vim.api.nvim_win_get_cursor(detail_win)
    _detail_cursor[entry.id] = _detail_cursor[entry.id] or {}
    _detail_cursor[entry.id][detail_view] = pos
  end

  entry = state.http_history[current_index]
  if not entry then
    render.set_lines(detail_buf, { "(no history)" }, { filetype = "text" })
    update_winbar()
    return
  end

  local r = entry.response
  local jq_lines = nil
  if detail_view == "body" and entry._jq and entry._jq.is_filtered then
    jq_lines = entry._jq.lines
  end

  local opts = {
    pending_request = nil,
    assertion_results = entry.assertion_results,
    script_logs = entry.script_logs,
    jq_lines = jq_lines,
  }
  local lines, filetype = format.format_view(detail_view, r, opts)

  lines = buffer.sanitize_lines(lines)

  render.set_lines(detail_buf, lines, { filetype = filetype or "text" })

  local saved = _detail_cursor[entry.id] and _detail_cursor[entry.id][detail_view]
  if saved then
    local max_line = vim.api.nvim_buf_line_count(detail_buf)
    if saved[1] <= max_line then
      pcall(vim.api.nvim_win_set_cursor, detail_win, saved)
    else
      pcall(vim.api.nvim_win_set_cursor, detail_win, { max_line, 0 })
    end
  else
    pcall(vim.api.nvim_win_set_cursor, detail_win, { 1, 0 })
  end
  update_winbar()

  if filetype == "json" then
    if detail_win and vim.api.nvim_win_is_valid(detail_win) then
      vim.wo[detail_win].foldmethod = "indent"
      vim.wo[detail_win].foldlevel = 99
      vim.wo[detail_win].foldcolumn = "0"
    end
  end

  format.apply_view_highlights(detail_buf, detail_view, lines, r)
end

--- Run jq and report failure the way json.apply_filter does: vim.fn.system
--- only captures stdout, so a bad query exits non-zero with empty output —
--- treating that as success silently wiped the detail pane.
--- Exposed for specs (vim.v.shell_error cannot be forced in headless runs).
function M._run_jq(query, body)
  local ok, output = pcall(vim.fn.system, { "jq", query, "-r" }, body)
  if ok and vim.v.shell_error == 0 then
    return true, output
  end
  return false, output
end

--- Apply a jq query to one history entry's response body and render the
--- result into the detail pane buffer. The <leader>j keymap resolves the
--- current entry; specs call this directly with a stub entry.
--- Returns true when the filter was applied.
function M.apply_jq_filter(entry, query, pane_buf)
  if not entry or not entry.response or not entry.response.body then return false end

  if not entry._jq then entry._jq = {} end
  if not entry._jq.original_lines then
    entry._jq.original_lines = vim.api.nvim_buf_get_lines(pane_buf, 0, -1, false)
  end

  local result
  if vim.fn.executable("jq") == 1 then
    local ok, output = M._run_jq(query, entry.response.body)
    if not ok then
      vim.notify("jq error: " .. (output or "unknown"), vim.log.levels.ERROR)
      return false
    end
    result = format.pretty_body(output, "application/json")
  else
    local json = require("poste-http.http.json")
    result = json._jsonpath_query(entry.response.body, query)
  end

  if not result then return false end

  local lines = vim.split(result, "\n")
  entry._jq.query = query
  entry._jq.is_filtered = true
  entry._jq.lines = lines

  render.set_lines(pane_buf, buffer.sanitize_lines(lines))

  if detail_win and vim.api.nvim_win_is_valid(detail_win) then
    vim.wo[detail_win].foldmethod = "indent"
    vim.wo[detail_win].foldlevel = 99
    vim.wo[detail_win].foldcolumn = "0"
  end

  update_winbar()
  return true
end

local function history_jq_filter(query)
  M.apply_jq_filter(state.http_history[current_index], query, detail_buf)
end

local function history_jq_restore()
  local entry = state.http_history[current_index]
  if not entry or not entry._jq or not entry._jq.original_lines then return end

  render.set_lines(detail_buf, buffer.sanitize_lines(entry._jq.original_lines))

  entry._jq = nil

  local ft = "text"
  if entry.response and entry.response.content_type then
    ft = format.detect_filetype(entry.response.content_type)
  end
  vim.bo[detail_buf].filetype = ft
  update_winbar()
end

local function render_list()
  if not list_buf or not vim.api.nvim_buf_is_valid(list_buf) then return end
  vim.api.nvim_buf_clear_namespace(list_buf, list_ns, 0, -1)

  local lines = { "(no history)" }
  local line_info = {}

  if #state.http_history > 0 then
    local rows = {}
    local statuses = {}
    for i, entry in ipairs(state.http_history) do
      rows[i], statuses[i] = build_row(entry)
    end
    local rendered, cells = columns.render(rows, LIST_COLS, { width = list_width })
    lines = rendered
    for i = 1, #rows do
      line_info[i] = entry_info(cells[i], statuses[i])
    end
  end

  render.set_lines(list_buf, lines, { filetype = "poste_history_list" })

  -- Colored method, elapsed, and gray timestamp via extmarks
  for i, line in ipairs(lines) do
    local info = line_info[i]
    if info then
      vim.api.nvim_buf_set_extmark(list_buf, list_ns, i - 1, info.method_col, {
        end_col = info.method_end,
        hl_group = info.method_hl,
        priority = 100,
      })
      vim.api.nvim_buf_set_extmark(list_buf, list_ns, i - 1, info.status_col, {
        end_col = info.status_end,
        hl_group = info.status_hl,
        priority = 100,
      })
      vim.api.nvim_buf_set_extmark(list_buf, list_ns, i - 1, info.elapsed_col, {
        end_col = info.elapsed_end,
        hl_group = "PosteLatency",
        priority = 100,
      })
      if info.ts_col <= #line then
        vim.api.nvim_buf_set_extmark(list_buf, list_ns, i - 1, info.ts_col, {
          end_col = #line,
          hl_group = "Comment",
          priority = 100,
        })
      end
    end
  end

  if current_index == nil and #state.http_history > 0 then
    current_index = 1
  end

  if current_index and current_index <= #state.http_history then
    pcall(vim.api.nvim_win_set_cursor, list_win, { current_index, 0 })
  end
end

local function hide()
  if hiding then return end
  hiding = true
  if list_win and vim.api.nvim_win_is_valid(list_win) then
    pcall(vim.api.nvim_win_close, list_win, true)
  end
  if detail_win and vim.api.nvim_win_is_valid(detail_win) then
    pcall(vim.api.nvim_win_close, detail_win, true)
  end
  list_buf = nil
  list_win = nil
  detail_buf = nil
  detail_win = nil
  current_index = nil
  detail_view = DEFAULT_DETAIL_VIEW
  hiding = false
end

local function navigate_list(direction)
  if #state.http_history == 0 then return end
  -- The real cursor is authoritative: native motions (gg, G, <C-d>, ...) move
  -- it without touching current_index. Resync first so j/k are anchored to
  -- where the cursor actually is, not a stale baseline (history ghost-cursor
  -- bug: gg/G then j/k landed one line past the visual position).
  local pos = vim.api.nvim_win_get_cursor(list_win)
  if pos and pos[1] and pos[1] >= 1 and pos[1] <= #state.http_history then
    current_index = pos[1]
  end
  if current_index == nil then
    current_index = direction > 0 and 1 or #state.http_history
  else
    current_index = current_index + direction
    if current_index < 1 then current_index = #state.http_history
    elseif current_index > #state.http_history then current_index = 1 end
  end
  pcall(vim.api.nvim_win_set_cursor, list_win, { current_index, 0 })
  render_detail()
end

--- Jump the list cursor to a history index (gg / G): syncs current_index,
--- the buffer cursor, and the detail pane in one step.
local function jump_to(index)
  if #state.http_history == 0 then return end
  if index < 1 then index = 1
  elseif index > #state.http_history then index = #state.http_history end
  current_index = index
  pcall(vim.api.nvim_win_set_cursor, list_win, { current_index, 0 })
  render_detail()
end

local function delete_at_cursor()
  if #state.http_history == 0 or not current_index then return end
  local entry = state.http_history[current_index]
  M.delete_entry(entry.id)
  if current_index > #state.http_history then
    current_index = #state.http_history
  end
  render_list()
  render_detail()
end

local function switch_tab(tab_id)
  detail_view = tab_id
  render_detail()
end

local function cycle_tab(direction)
  detail_view = winbar.cycle(get_active_tabs(), detail_view, direction) or detail_view
  render_detail()
end

local function focus_detail()
  if detail_win and vim.api.nvim_win_is_valid(detail_win) then
    vim.api.nvim_set_current_win(detail_win)
  end
end

local function wincmd_list()
  if list_win and vim.api.nvim_win_is_valid(list_win) then
    vim.api.nvim_set_current_win(list_win)
  end
end

local function wincmd_detail()
  if detail_win and vim.api.nvim_win_is_valid(detail_win) then
    vim.api.nvim_set_current_win(detail_win)
  end
end

local function setup_detail_keymaps()
  keymaps.register_all(detail_buf, "http_response", {
    { action = "close", default = "q", handler = hide },
    { action = "view_body", default = "B", handler = function() switch_tab("body") end },
    { action = "view_request", default = "R", handler = function() switch_tab("request") end },
    { action = "view_verbose", default = "E", handler = function() switch_tab("verbose") end },
    { action = "view_assertions", default = "A", handler = function() switch_tab("assertions") end },
    { action = "view_script_logs", default = "S", handler = function() switch_tab("script_logs") end },
    { action = "next_tab", default = "<Tab>", handler = function() cycle_tab(1) end },
    { action = "prev_tab", default = "<S-Tab>", handler = function() cycle_tab(-1) end },
    { action = "json_filter", default = "<leader>j", handler = function()
      if vim.bo[detail_buf].filetype ~= "json" then return end
      local entry = state.http_history[current_index]
      if not entry then return end
      local saved_response = state.last_response
      state.last_response = entry.response
      local json = require("poste-http.http.json")
      local paths = json.get_key_paths()
      state.last_response = saved_response
      if #paths > 0 then
        vim.ui.select(paths, {
          prompt = "jq filter",
          format_item = function(item) return item end,
        }, function(choice)
          if choice then history_jq_filter(choice) end
        end)
      else
        local hist_entry = state.http_history[current_index]
        local default_q = (hist_entry and hist_entry._jq and hist_entry._jq.query) or ""
        vim.ui.input({ prompt = "jq> ", default = default_q }, function(q)
          if q and q ~= "" then history_jq_filter(q) end
        end)
      end
    end },
    { action = "json_restore", default = "<leader>jc", handler = history_jq_restore },
  })

  vim.keymap.set("n", "<C-h>", wincmd_list, { buffer = detail_buf, noremap = true, silent = true, nowait = true })
end

local function setup_list_keymaps()
  keymaps.register_all(list_buf, "http_history", {
    { action = "close", default = "q", handler = hide },
    { action = "delete_entry", default = "dd", handler = delete_at_cursor },
    { action = "focus_detail", default = "<CR>", handler = focus_detail },
  })

  vim.keymap.set("n", "j", function() navigate_list(1) end, { buffer = list_buf, noremap = true, silent = true })
  vim.keymap.set("n", "k", function() navigate_list(-1) end, { buffer = list_buf, noremap = true, silent = true })
  vim.keymap.set("n", "gg", function()
    local c = vim.v.count
    jump_to(c > 0 and c or 1)
  end, { buffer = list_buf, noremap = true, silent = true })
  vim.keymap.set("n", "G", function()
    local c = vim.v.count
    jump_to(c > 0 and c or #state.http_history)
  end, { buffer = list_buf, noremap = true, silent = true })
  vim.keymap.set("n", "<C-l>", wincmd_detail, { buffer = list_buf, noremap = true, silent = true, nowait = true })

  vim.api.nvim_buf_attach(list_buf, false, {
    on_detach = function()
      hide()
    end,
  })
end

function M.show()

  if list_win and vim.api.nvim_win_is_valid(list_win) then
    pcall(vim.api.nvim_set_current_win, list_win)
    return
  end

  local editor_width = vim.o.columns
  local editor_height = vim.o.lines
  local total_width = math.floor(editor_width * 0.92)
  local total_height = math.floor(editor_height * 0.88)
  local top = math.floor((editor_height - total_height) / 2)
  local left = math.floor((editor_width - total_width) / 2)
  list_width = 53
  local gap = 1

  -- close_keys = {}: the list/detail keymaps below own "q" (hide closes both
  -- windows), so the float primitive must not map its own close keys.
  list_buf, list_win = float.open({
    width = list_width,
    height = total_height,
    row = top,
    col = left,
    border = "single",
    title = " Poste HTTP History ",
    cursorline = true,
    close_keys = {},
  })
  if not list_win then return end

  local detail_width = total_width - list_width - gap - 1
  detail_buf, detail_win = float.open({
    width = detail_width,
    height = total_height,
    row = top,
    col = left + list_width + gap,
    border = "single",
    focus = false,
    close_keys = {},
  })
  if not detail_win then
    hide()
    return
  end

  current_index = nil
  detail_view = DEFAULT_DETAIL_VIEW

  setup_list_keymaps()
  setup_detail_keymaps()

  render_list()
  render_detail()

  pcall(vim.api.nvim_set_current_win, list_win)
end

--- Build the history list line for an entry (pure, window-free).
--- @param entry table
--- @param width number  Available display width
--- @return string, table  rendered line, { status_hl, method, doc_id }
function M.format_list_line(entry, width)
  return format_list_line(entry, width)
end

return M
