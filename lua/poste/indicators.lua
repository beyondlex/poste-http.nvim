--- Request line detection and status indicators (sign column + eol latency/assertions).
local uv = vim.uv or vim.loop

local M = {}

local sign_group = "poste_sg_4a7f"
local indicator_ns = vim.api.nvim_create_namespace("poste_indicator")
local indicator_marks = {}  -- buf -> { line_0 -> sign_id }
local spinner_timer = nil
local spinner_gen = 0  -- generation counter to invalidate stale spinner callbacks

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Define sign column symbols
pcall(vim.fn.sign_define, "PosteSpinnerSign", { text = spinner_frames[1], texthl = "PosteSpinner" })
pcall(vim.fn.sign_define, "PosteSuccessSign", { text = "✓", texthl = "PosteSuccess" })
pcall(vim.fn.sign_define, "PosteErrorSign", { text = "✘", texthl = "PosteError" })

---------------------------------------------------------------------------
-- Request block extraction
---------------------------------------------------------------------------

--- Extract the full request block from the buffer at the given line.
--- Returns { request_line = "GET ...", headers = { { "Key", "Value" }, ... } }.
function M.extract_request_block(buf, start_line)
  -- Walk backward to find ### separator
  local header_line = nil
  for i = start_line, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      header_line = i
      break
    end
  end
  if not header_line then return { request_line = "", headers = {} } end

  local total = vim.api.nvim_buf_line_count(buf)
  local request_line = nil
  local headers = {}

  for i = header_line + 1, total do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then break end  -- next block

    -- Skip comments (lines starting with # or --)
    if text:match("^%s*#") or text:match("^%s*%-%-") then
      -- skip
    elseif not request_line and text:match("%S") then
      -- First non-empty non-comment line is the request line
      request_line = text
    elseif request_line then
      -- After request line: headers until empty line, then body
      if text:match("^%s*$") then
        break  -- empty line = end of headers
      end
      local key, val = text:match("^([^:]+):%s*(.*)")
      if key then
        table.insert(headers, { vim.trim(key), vim.trim(val) })
      end
    end
  end

  return { request_line = request_line or "", headers = headers }
end

--- Find the request definition line: walk backward from `start_line` to
--- find the ### separator, then return the first non-empty, non-comment
--- line after it (the GET/POST/SET/etc line).
--- Skips pre-request script blocks (< {% ... %} and < ./script.lua) and
--- variable definitions (@var = value).
--- Returns (line_number_0indexed, nil) or (nil, nil) if not found.
function M.find_request_line(buf, start_line)
  -- Walk backward to find ### separator
  local header_line = nil
  for i = start_line, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      header_line = i
      break
    end
  end

  if not header_line then return nil end

  local total = vim.api.nvim_buf_line_count(buf)

  -- Find next ### and last content line of this block
  local next_sep = total + 1
  for i = header_line + 1, total do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      next_sep = i
      break
    end
  end

  -- If cursor is on a separator line between blocks, don't attach to either
  local last_content = nil
  for i = next_sep - 1, header_line, -1 do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    local trimmed = vim.trim(text)
    if trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^%-%-") then
      last_content = i
      break
    end
  end
  if start_line > (last_content or header_line) and start_line < next_sep then
    return nil
  end

  local in_prescript = false

  for i = header_line + 1, total do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    local trimmed = vim.trim(text)

    if text:match("^%s*###") then break end  -- next block

    -- Skip pre-request script blocks
    if in_prescript then
      if trimmed == "%}" then
        in_prescript = false
      end
    elseif trimmed:match("^<%s*{%%") and not trimmed:match("%%}$") then
      -- Multi-line pre-script start: < {% (no closing %})
      in_prescript = true
    elseif trimmed:match("^<%s*{%%.*%%}$") then
      -- Single-line pre-script: < {% code %}
      -- skip
    elseif trimmed:match("^<%s*%.?%.") and trimmed:match("%.lua%s*$") then
      -- External script: < ./path.lua
      -- skip
    elseif trimmed:match("^@%S+%s*[= ]") then
      -- Variable definition: @var = value
      -- skip
    elseif trimmed == "" or trimmed:match("^#") or trimmed:match("^%-%-") then
      -- Empty line, comment
      -- skip
    else
      -- This is the actual request line
      return i - 1  -- 0-indexed for extmark
    end
  end

  return nil
end

--- Find the request block boundaries for a given cursor line.
--- Returns (start_line, end_line) as 1-indexed inclusive ranges.
--- A request block starts at ### and ends before the next ### or EOF.
function M.find_request_block_bounds(buf, cursor_line)
  local total = vim.api.nvim_buf_line_count(buf)

  -- Walk backward to find ###
  local start_line = nil
  for i = cursor_line, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      start_line = i
      break
    end
  end

  if not start_line then return nil, nil end

  -- Walk forward to find end of block (next ### or EOF)
  local end_line = total
  for i = start_line + 1, total do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      end_line = i - 1
      break
    end
  end

  -- If cursor is on a separator line between blocks, return no bounds
  local last_content = nil
  for i = end_line, start_line, -1 do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    local trimmed = vim.trim(text)
    if trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^%-%-") then
      last_content = i
      break
    end
  end
  if cursor_line > (last_content or start_line) then
    return nil, nil
  end

  return start_line, end_line
end

---------------------------------------------------------------------------
-- Status indicator (sign column + eol latency/assertions)
---------------------------------------------------------------------------

local function stop_timer()
  spinner_gen = spinner_gen + 1
  if spinner_timer then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end
end

--- Clear all indicators for a buffer (called before each execution).
function M.clear_all(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if indicator_marks[buf] then
    for line_0, sign_id in pairs(indicator_marks[buf]) do
      pcall(vim.fn.sign_unplace, sign_group, { id = sign_id })
    end
    indicator_marks[buf] = {}
  end
  vim.api.nvim_buf_clear_namespace(buf, indicator_ns, 0, -1)
  stop_timer()
end

--- Clear indicators for all lines except the current one.
function M.clear_other_requests(buf, line_0)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if not indicator_marks[buf] then return end
  for other_line_0, sign_id in pairs(indicator_marks[buf]) do
    if other_line_0 ~= line_0 then
      pcall(vim.fn.sign_unplace, sign_group, { id = sign_id })
      indicator_marks[buf][other_line_0] = nil
      vim.api.nvim_buf_clear_namespace(buf, indicator_ns, other_line_0, other_line_0 + 1)
    end
  end
end

--- Replace a sign on a line by its tracked ID, or place a new one if none.
--- Ensures the sign is defined before placing.
--- Returns the sign_id.
local function place_or_replace_sign(buf, line_0, old_sign_id, sign_name)
  local lnum = line_0 + 1
  -- Define sign first (idempotent)
  local sign_configs = {
    PosteSpinnerSign = { text = spinner_frames[1], texthl = "PosteSpinner" },
    PosteSuccessSign = { text = "✓", texthl = "PosteSuccess" },
    PosteErrorSign   = { text = "✘", texthl = "PosteError" },
  }
  pcall(vim.fn.sign_define, sign_name, sign_configs[sign_name])

  if old_sign_id then
    -- Use vim.cmd with :sign place to replace in-place
    vim.cmd(string.format("sign place %d line=%d name=%s group=%s buffer=%d",
      old_sign_id, lnum, sign_name, sign_group, buf))
    return old_sign_id
  else
    return vim.fn.sign_place(0, sign_group, sign_name, buf, { lnum = lnum })
  end
end

--- Place or update indicator (sign column + eol latency/assertions).
--- status: "running" | "success" | "error"
--- latency_ms: optional, shown after ✓ on success
function M.set_indicator(buf, line_0, status, latency_ms, assertion_results)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if not line_0 then return end

  -- Invalidate any in-flight spinner callbacks
  spinner_gen = spinner_gen + 1
  local my_gen = spinner_gen

  if not indicator_marks[buf] then indicator_marks[buf] = {} end

  if status == "running" then
    stop_timer()

    -- Place or replace spinner sign
    local old_id = indicator_marks[buf][line_0]
    local sign_id = place_or_replace_sign(buf, line_0, old_id, "PosteSpinnerSign")
    if sign_id and sign_id > 0 then
      indicator_marks[buf][line_0] = sign_id
    end

    local frame = 1
    local function update_spinner()
      if my_gen ~= spinner_gen then return end
      if not vim.api.nvim_buf_is_valid(buf) then return end
      vim.fn.sign_define("PosteSpinnerSign", { text = spinner_frames[frame], texthl = "PosteSpinner" })
      frame = (frame % #spinner_frames) + 1
    end

    spinner_timer = uv.new_timer()
    spinner_timer:start(100, 100, vim.schedule_wrap(update_spinner))

  elseif status == "success" then
    stop_timer()

    local old_id = indicator_marks[buf][line_0]
    local sign_id = place_or_replace_sign(buf, line_0, old_id, "PosteSuccessSign")

    -- Clear stale eol virt_text, then create latency/assertion eol text
    vim.api.nvim_buf_clear_namespace(buf, indicator_ns, line_0, line_0 + 1)

    local virt_text = {}
    if latency_ms and latency_ms > 0 then
      local latency_text
      if latency_ms >= 1000 then
        latency_text = string.format("%.2f s", latency_ms / 1000)
      else
        latency_text = string.format("%.2f ms", latency_ms)
      end
      table.insert(virt_text, { latency_text, "PosteLatency" })
    end
    if assertion_results and assertion_results.total > 0 then
      if assertion_results.failed > 0 then
        table.insert(virt_text, {
          string.format("  ✘ %d/%d tests", assertion_results.failed, assertion_results.total),
          "PosteError",
        })
      else
        table.insert(virt_text, {
          string.format("  ✓ %d/%d tests", assertion_results.passed, assertion_results.total),
          "PosteSuccess",
        })
      end
    end
    if #virt_text > 0 then
      vim.api.nvim_buf_set_extmark(buf, indicator_ns, line_0, 0, {
        virt_text = virt_text,
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
    end

  elseif status == "error" then
    stop_timer()

    local old_id = indicator_marks[buf][line_0]
    local sign_id = place_or_replace_sign(buf, line_0, old_id, "PosteErrorSign")
    if sign_id and sign_id > 0 then
      indicator_marks[buf][line_0] = sign_id
    end
    vim.api.nvim_buf_clear_namespace(buf, indicator_ns, line_0, line_0 + 1)

    -- Create error latency/assertion eol text
    local virt_text = {}
    if latency_ms and latency_ms > 0 then
      local latency_text
      if latency_ms >= 1000 then
        latency_text = string.format("%.2f s", latency_ms / 1000)
      else
        latency_text = string.format("%.2f ms", latency_ms)
      end
      table.insert(virt_text, { latency_text, "PosteLatency" })
    end
    if assertion_results and assertion_results.total > 0 then
      if assertion_results.failed > 0 then
        table.insert(virt_text, {
          string.format("  ✘ %d/%d tests", assertion_results.failed, assertion_results.total),
          "PosteError",
        })
      else
        table.insert(virt_text, {
          string.format("  ✓ %d/%d tests", assertion_results.passed, assertion_results.total),
          "PosteSuccess",
        })
      end
    end
    if #virt_text > 0 then
      vim.api.nvim_buf_set_extmark(buf, indicator_ns, line_0, 0, {
        virt_text = virt_text,
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
    end
  end
end

return M
