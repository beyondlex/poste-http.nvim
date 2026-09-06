local uv = vim.uv or vim.loop
local C = require("poste-http.constants")
local M = {}
local ns = vim.api.nvim_create_namespace(C.INDICATOR_NS_NAME)
local _extmarks = {}  -- buf -> { line_0 = extmark_id, ... } (payload on the separator line)
local spinners = {}   -- buf -> { line_0 = { timer, gen }, ... }
local spinner_frames = C.SPINNER_FRAMES
local sign_group = "poste_indicator_sg"

-- status icons live in the sign column (freed by the boundary bg), so they
-- never overlap request text even when the method/URL line is long
local function define_signs()
  for i, frame in ipairs(spinner_frames) do
    pcall(vim.fn.sign_define, "PosteSpin" .. i, { text = frame .. " ", texthl = "PosteSpinner" })
  end
  pcall(vim.fn.sign_define, "PosteIndicatorSuccess", { text = "✓ ", texthl = "PosteSuccess" })
  pcall(vim.fn.sign_define, "PosteIndicatorError",   { text = "✘ ", texthl = "PosteError" })
end
define_signs()

local function place_sign(buf, line_0, name)
  vim.fn.sign_unplace(sign_group, { buffer = buf, lnum = line_0 + 1 })
  vim.fn.sign_place(0, sign_group, name, buf, { lnum = line_0 + 1 })
end

local function unplace_sign(buf, line_0)
  vim.fn.sign_unplace(sign_group, { buffer = buf, lnum = line_0 + 1 })
end

local function stop_timer(buf, line_0)
  if not spinners[buf] then return end
  local s = spinners[buf][line_0]
  if not s then return end
  s.timer:stop()
  s.timer:close()
  spinners[buf][line_0] = nil
end

local function stop_all_timers(buf)
  if not spinners[buf] then return end
  for _, s in pairs(spinners[buf]) do
    s.timer:stop()
    s.timer:close()
  end
  spinners[buf] = nil
end

function M.clear_all(buf)
  -- 0 = current-buffer sentinel; sign_unplace rejects 0 (E158), so resolve
  -- before the guard (0 is truthy and nvim_buf_is_valid(0) is true).
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if _extmarks[buf] then _extmarks[buf] = {} end
  stop_all_timers(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.fn.sign_unplace(sign_group, { buffer = buf })
end

function M.clear_other_requests(buf, line_0)
  -- single-flight execution policy: wiping everything is equivalent (the
  -- caller places the current line's indicator right afterwards)
  M.clear_all(buf)
end

local function format_latency(latency_ms)
  if latency_ms >= 1000 then
    return string.format("%.2f s", latency_ms / 1000)
  end
  return string.format("%.2f ms", latency_ms)
end

local function build_assertion_text(assertion_results)
  if not assertion_results or not assertion_results.total or assertion_results.total == 0 then
    return nil
  end
  if assertion_results.failed and assertion_results.failed > 0 then
    return { text = string.format("  ✘ %d/%d tests", assertion_results.failed, assertion_results.total), hl = "PosteError" }
  end
  return { text = string.format("  ✓ %d/%d tests", assertion_results.passed, assertion_results.total), hl = "PosteSuccess" }
end

local function build_virt_text(latency_ms, assertion_results)
  local virt_text = {}
  if latency_ms and latency_ms > 0 then
    table.insert(virt_text, { format_latency(latency_ms), "PosteLatency" })
  end
  local assert_item = build_assertion_text(assertion_results)
  if assert_item then
    table.insert(virt_text, { assert_item.text, assert_item.hl })
  end
  return virt_text
end

--- Payload (latency / assertion results) is right-aligned on the request's
--- `###` separator line — short by construction, so it never overlaps the
--- method/URL even for long URLs. Falls back to the request line itself.
local function separator_line(buf, line_0)
  local ok, cache = pcall(require, "poste-http.http.cache")
  if not ok then return line_0 end
  local ok_b, block = pcall(cache.get_block_at_line, buf, line_0 + 1)
  if ok_b and block and block.start_line then
    return block.start_line - 1
  end
  return line_0
end

local function set_payload_extmark(buf, line_0, virt_text)
  local sep = separator_line(buf, line_0)
  vim.api.nvim_buf_clear_namespace(buf, ns, sep, sep + 1)
  if virt_text and #virt_text > 0 then
    local id = vim.api.nvim_buf_set_extmark(buf, ns, sep, 0, {
      virt_text = virt_text,
      virt_text_pos = "right_align",
      hl_mode = "combine",
    })
    if not _extmarks[buf] then _extmarks[buf] = {} end
    _extmarks[buf][line_0] = id
  end
end

function M.set_indicator(buf, line_0, status, latency_ms, assertion_results)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if not line_0 then return end
  if not _extmarks[buf] then _extmarks[buf] = {} end

  if status == "running" then
    stop_timer(buf, line_0)
    place_sign(buf, line_0, "PosteSpin1")
    -- A re-run must not keep showing the previous run's latency/verdict.
    set_payload_extmark(buf, line_0, nil)
    local frame = 1
    local timer = uv.new_timer()
    if not spinners[buf] then spinners[buf] = {} end
    spinners[buf][line_0] = { timer = timer }
    local function update_spinner()
      if not spinners[buf] or not spinners[buf][line_0] then return end
      if not vim.api.nvim_buf_is_valid(buf) then return end
      frame = (frame % #spinner_frames) + 1
      place_sign(buf, line_0, "PosteSpin" .. frame)
    end
    timer:start(C.SPINNER_INTERVAL_MS, C.SPINNER_INTERVAL_MS, vim.schedule_wrap(update_spinner))
  elseif status == "success" then
    stop_timer(buf, line_0)
    unplace_sign(buf, line_0)
    place_sign(buf, line_0, "PosteIndicatorSuccess")
    set_payload_extmark(buf, line_0, build_virt_text(latency_ms, assertion_results))
  elseif status == "error" then
    stop_timer(buf, line_0)
    unplace_sign(buf, line_0)
    place_sign(buf, line_0, "PosteIndicatorError")
    set_payload_extmark(buf, line_0, build_virt_text(latency_ms, assertion_results))
  end
end

local _indicator_augroup = vim.api.nvim_create_augroup("PosteHttpIndicators", { clear = true })
vim.api.nvim_create_autocmd("BufDelete", {
  group = _indicator_augroup,
  callback = function(ev)
    local buf = ev.buf
    if _extmarks[buf] then _extmarks[buf] = nil end
    if spinners[buf] then
      for _, s in pairs(spinners[buf]) do
        s.timer:stop()
        s.timer:close()
      end
      spinners[buf] = nil
    end
  end,
})

return M
