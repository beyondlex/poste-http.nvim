local M = {}
local ns = vim.api.nvim_create_namespace("poste_insert_hint")

local _debounce_timer = nil
local DEBOUNCE_MS = 150

local function dbg(msg)
  if vim.g.poste_insert_hint_debug then
    vim.notify("[insert_hint] " .. msg, vim.log.levels.INFO, { title = "Poste Insert Hint" })
  end
end

function M.clear()
  local ok, bufnr = pcall(vim.api.nvim_get_current_buf)
  if ok then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  end
end

function M.update()
  local ok, bufnr = pcall(vim.api.nvim_get_current_buf)
  if not ok then return end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  dbg("update called, bufnr=" .. bufnr)

  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_row = cursor[1]
  local cursor_col = cursor[2]

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, cursor_row, false)
  dbg("lines count=" .. #lines .. " cursor_row=" .. cursor_row .. " cursor_col=" .. cursor_col)

  local block_start = 1
  for i = #lines, 1, -1 do
    if (lines[i] or ""):match("^###") then block_start = i; break end
  end
  dbg("block_start=" .. block_start .. " first line=" .. (lines[1] or "nil"))

  local text_segments = {}
  for i = block_start, #lines do
    local clean = (lines[i - block_start + 1] or ""):gsub("%-%-.*", "")
    text_segments[#text_segments + 1] = clean
  end
  local full_text = table.concat(text_segments, "\n")

  local text_offset = 0
  for i = block_start, cursor_row - 1 do
    local clean = (lines[i - block_start + 1] or ""):gsub("%-%-.*", "")
    text_offset = text_offset + #clean + 1
  end
  text_offset = text_offset + cursor_col
  dbg("full_text: " .. full_text:sub(1, 200):gsub("\n", "\\n"))

  local s, e = nil, nil
  local search_pos = 1
  while true do
    local ns2, ne = full_text:find("[Ii][Nn][Ss][Ee][Rr][Tt]%s+[Ii][Nn][Tt][Oo]%s+[%w_]+%s*%(", search_pos)
    if not ns2 or ns2 > text_offset then break end
    s, e = ns2, ne
    search_pos = ne + 1
  end
  if not s then dbg("no INSERT INTO before cursor"); return end
  dbg("INSERT INTO found, col_list_paren at pos " .. e)

  local paren_open = e
  local depth = 1
  local col_list_end = paren_open
  for i = paren_open + 1, #full_text do
    local ch = full_text:sub(i, i)
    if ch == "(" then depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
      if depth == 0 then col_list_end = i; break end
    end
  end
  if col_list_end == paren_open then dbg("no closing paren for column list"); return end

  local cols = {}
  for c in full_text:sub(paren_open + 1, col_list_end - 1):gmatch("([%w_]+)") do
    cols[#cols + 1] = c
  end
  if #cols == 0 then dbg("no columns found"); return end
  dbg("columns: " .. table.concat(cols, ", "))

  local v_start = full_text:find("[Vv][Aa][Ll][Uu][Ee][Ss]%s*%(", col_list_end)
  if not v_start then dbg("no VALUES found"); return end
  dbg("VALUES found at " .. v_start)

  local v_paren = full_text:find("%(", v_start)
  if not v_paren then dbg("no VALUES paren"); return end
  dbg("v_paren=" .. v_paren .. " text_offset=" .. text_offset)

  depth = 1
  local v_close = nil
  for i = v_paren + 1, #full_text do
    local ch = full_text:sub(i, i)
    if ch == "(" then depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
      if depth == 0 then v_close = i; break end
    end
  end

  if text_offset < v_paren then dbg("cursor before VALUES paren"); return end
  if v_close and text_offset > v_close then dbg("cursor after VALUES paren close"); return end
  dbg("cursor inside VALUES parens")

  local vals_prefix = full_text:sub(v_paren + 1, text_offset)
  dbg("vals_prefix='" .. vals_prefix .. "'")
  local value_idx = 0
  local in_str = false
  local str_char = nil
  depth = 0
  for i = 1, #vals_prefix do
    local ch = vals_prefix:sub(i, i)
    local prev = i > 1 and vals_prefix:sub(i - 1, i - 1) or ""
    if in_str then
      if ch == str_char and prev ~= "\\" then in_str = false end
    elseif ch == "'" or ch == '"' then
      in_str = true; str_char = ch
    elseif ch == "(" then depth = depth + 1
    elseif ch == ")" then depth = depth - 1
    elseif ch == "," and depth == 0 then value_idx = value_idx + 1
    end
  end
  dbg("value_idx=" .. value_idx .. " target_idx=" .. (value_idx + 1))

  local target_idx = value_idx + 1
  if target_idx > #cols then dbg("target_idx " .. target_idx .. " > " .. #cols); return end
  local target_col = cols[target_idx]
  dbg("target: col#" .. target_idx .. " = " .. target_col)

  local function to_buf_pos(byte_off)
    local acc = 0
    for i = block_start, #lines do
      local clean = (lines[i - block_start + 1] or ""):gsub("%-%-.*", "")
      local line_len = #clean
      if byte_off <= acc + line_len then
        return i - 1, byte_off - acc
      end
      acc = acc + line_len + 1
    end
    return nil, nil
  end

  local start_row, start_col = to_buf_pos(paren_open + 1)
  local end_row, end_col = to_buf_pos(col_list_end)
  dbg("search area: rows " .. tostring(start_row) .. "-" .. tostring(end_row) .. " cols " .. tostring(start_col) .. "-" .. tostring(end_col))
  if not start_row then dbg("start_row nil"); return end

  for row = start_row, end_row or start_row do
    local line_text = lines[row + 1] or ""
    local search_from, search_to
    if row == start_row then search_from = start_col else search_from = 1 end
    if end_row and row == end_row then search_to = end_col else search_to = #line_text end

    local segment = line_text:sub(search_from, search_to)
    dbg("searching in row " .. row .. " [" .. search_from .. "," .. search_to .. "]: '" .. segment .. "'")
    local col_pos = segment:find(vim.pesc(target_col))
    if col_pos then
      local before = col_pos > 1 and segment:sub(col_pos - 1, col_pos - 1) or ""
      local after = col_pos + #target_col <= #segment and segment:sub(col_pos + #target_col, col_pos + #target_col) or ""
      dbg("found at col_pos=" .. col_pos .. " before='" .. before .. "' after='" .. after .. "'")
      if (before:match("[%s_,(]") or before == "") and (after:match("[%s_,)]") or after == "") then
        local buf_col = search_from + col_pos - 2
        dbg("PLACING extmark row=" .. row .. " col=" .. buf_col)
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, buf_col, {
          end_col = buf_col + #target_col,
          hl_group = "PosteInsertHint",
          priority = 200,
        })
        return
      end
    end
  end
  dbg("column not found in search area")
end

function M.setup()
  local group = vim.api.nvim_create_augroup("poste_insert_hint", { clear = true })
  local function debounced_update()
    if _debounce_timer then
      _debounce_timer:stop()
      _debounce_timer:close()
    end
    _debounce_timer = vim.defer_fn(function()
      _debounce_timer = nil
      M.update()
    end, DEBOUNCE_MS)
  end
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    pattern = { "*.sql", "*.sqlite" },
    callback = debounced_update,
  })
  vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
    group = group,
    pattern = { "*.sql", "*.sqlite" },
    callback = M.update,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    pattern = { "*.sql", "*.sqlite" },
    callback = M.clear,
  })
end

return M