-- Tests for the Poste HTTP history list rendering.
--
-- The list line is built by a pure function (history.format_list_line)
-- so the layout can be locked down without a floating window. Extmark
-- placement is driven by the column offsets it returns.

local history = require("poste-http.http.history")
local state = require("poste-http.state")

local function entry(name, opts)
  opts = opts or {}
  return {
    name = name,
    time = opts.time or os.time({ year = 2026, month = 8, day = 7, hour = 7, min = 26, sec = 0 }),
    response = {
      latency_ms = opts.latency_ms,
      status = opts.status or 200,
      metadata = { method = opts.method or "GET" },
    },
  }
end

describe("history.format_list_line", function()
  it("formats POST with name, elapsed and timestamp like the requested layout", function()
    local line, info = history.format_list_line(entry("RegisterUser", {
      method = "POST",
      latency_ms = 12,
    }), 53)
    assert.equals(
      "POST    RegisterUser      200 12.00 ms   " .. os.date("%H:%M:%S", entry("RegisterUser").time) .. ".000",
      line
    )
    assert.equals("PosteMethodPOST", info.method_hl)
    assert.equals(0, info.method_col)
    assert.equals(4, info.method_end)
    assert.equals(8 + 18, info.status_col)
    assert.equals("200", info.status)
    assert.equals("PosteStatus2xx", info.status_hl)
    assert.equals(8 + 18 + 4, info.elapsed_col)
    assert.equals(8 + 18 + 4 + 9 + 2, info.ts_col)
  end)

  it("shows status before elapsed", function()
    local line = history.format_list_line(entry("GetUser", { latency_ms = 9.23 }), 53)
    assert.matches("^GET%s+GetUser%s+200%s+9%.23 ms%s+%d%d:%d%d:%d%d%.%d%d%d$", line)
  end)

  it("keeps three-digit elapsed values aligned", function()
    local line, info = history.format_list_line(entry("GetProfile", { status = 404, latency_ms = 123 }), 53)
    assert.matches("^GET%s+GetProfile%s+404%s+123%.00 ms%s+%d%d:%d%d:%d%d%.%d%d%d$", line)
    assert.equals("PosteStatus4xx", info.status_hl)
  end)

  it("colors status codes by class like the verbose view", function()
    local _, info = history.format_list_line(entry("Ok", { status = 200, latency_ms = 5 }), 53)
    assert.equals("PosteStatus2xx", info.status_hl)

    _, info = history.format_list_line(entry("Moved", { status = 301, latency_ms = 5 }), 53)
    assert.equals("PosteStatus3xx", info.status_hl)

    _, info = history.format_list_line(entry("Broken", { status = 503, latency_ms = 5 }), 53)
    assert.equals("PosteStatus5xx", info.status_hl)
  end)

  it("shows '-' for failed requests with status 0", function()
    local line, info = history.format_list_line(entry("Failed", { method = "", status = 0, latency_ms = 0 }), 53)
    assert.matches("^%-%s+Failed%s+%-%s+0%.00 ms%s+%d%d:%d%d:%d%d%.%d%d%d$", line)
    assert.equals("-", info.status)
    assert.equals("Comment", info.status_hl)
  end)

  it("formats elapsed above one second as seconds", function()
    local line = history.format_list_line(entry("Slow", { latency_ms = 1200 }), 53)
    assert.matches("1%.20 s", line)
  end)

  it("shows '-' when latency is missing", function()
    local line = history.format_list_line(entry("NoLatency", { latency_ms = nil }), 53)
    assert.matches("%-%s+%d%d:%d%d:%d%d%.%d%d%d$", line)
  end)

  it("shows milliseconds from time_usec, truncated to three digits", function()
    local e = entry("Ms", { latency_ms = 5 })
    e.time_usec = 231999
    local line = history.format_list_line(e, 53)
    assert.matches("%.231$", line)
  end)

  it("maps SCRIPT to the script highlight group", function()
    local _, info = history.format_list_line(entry("Run", { method = "SCRIPT", latency_ms = 5 }), 53)
    assert.equals("SCRIPT", info.method)
    assert.equals("PosteMethodScript", info.method_hl)
  end)

  it("maps unknown methods to PosteMethodOther", function()
    local _, info = history.format_list_line(entry("Custom", { method = "FOO", latency_ms = 5 }), 53)
    assert.equals("PosteMethodOther", info.method_hl)
  end)

  it("shows '-' for entries without a method", function()
    local line, info = history.format_list_line(entry("Failed", { method = "", latency_ms = 0 }), 53)
    assert.matches("^%-%s+Failed%s+200", line)
    assert.equals("-", info.method)
    assert.equals("PosteMethodOther", info.method_hl)
  end)

  it("falls back to the response metadata method when entry.method is absent", function()
    local e = entry("Direct", { latency_ms = 5 })
    e.method = nil
    local _, info = history.format_list_line(e, 18)
    assert.equals("GET", info.method)
    assert.equals("PosteMethodGET", info.method_hl)
  end)

  it("truncates long names with an ellipsis", function()
    local line = history.format_list_line(entry("ThisNameIsWayTooLongForTheList", { latency_ms = 5 }), 53)
    assert.equals("ThisNameIsWayTo...", line:sub(9, 9 + 17))
  end)
end)

describe("history list window navigation", function()
  -- Full verbose-view-renderable entries (render_detail formats entry.response
  -- through format_verbose on every j/k/gg/G).
  local function nav_entry(name, url)
    local e = entry(name, { latency_ms = 5 })
    e.id = "id-" .. name
    e.time_usec = 0
    e.response.url = url
    e.response.status_text = "200 " .. name
    e.response.headers = {}
    e.response.body = "body of " .. name
    e.response.content_type = "text/plain"
    e.response.protocol = "HTTP/1.1"
    return e
  end

  local saved_history

  before_each(function()
    saved_history = state.http_history
    state.http_history = {
      nav_entry("One", "http://one.example.com/"),
      nav_entry("Two", "http://two.example.com/"),
      nav_entry("Three", "http://three.example.com/"),
    }
  end)

  after_each(function()
    state.http_history = saved_history
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end)

  local function feed(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
    vim.wait(80)
  end

  local function list_cursor()
    return vim.api.nvim_win_get_cursor(0)[1]
  end

  local function detail_first_line()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        local buf = vim.api.nvim_win_get_buf(w)
        if vim.bo[buf].filetype ~= "poste_history_list" then
          return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
        end
      end
    end
  end

  it("gg then j lands on the second entry, not the stale baseline", function()
    history.show()
    feed("j")
    feed("gg")
    feed("j")
    assert.equals(2, list_cursor())
  end)

  it("gg syncs the detail pane to the first entry", function()
    history.show()
    feed("j")
    feed("gg")
    assert.matches("one%.example", detail_first_line())
  end)

  it("G then k lands on the second-to-last entry", function()
    history.show()
    feed("G")
    feed("k")
    assert.equals(2, list_cursor())
  end)

  it("j wraps from the last entry back to the first", function()
    history.show()
    feed("G")
    feed("j")
    assert.equals(1, list_cursor())
  end)
end)

describe("history.apply_jq_filter", function()
  local history2 = require("poste-http.http.history")
  local notify_calls
  local orig_notify

  before_each(function()
    notify_calls = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level)
      notify_calls[#notify_calls + 1] = { msg = msg, level = level }
    end
  end)

  after_each(function()
    vim.notify = orig_notify
  end)

  local function make_pane(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  it("a jq failure keeps the pane and the entry untouched, and notifies", function()
    local pane = make_pane({ "original body line" })
    local e = { name = "GetUser", response = { body = '{"a":1}' } }
    history2._run_jq = function()
      return false, ""
    end
    local applied = history2.apply_jq_filter(e, ".bad[", pane)
    history2._run_jq = nil
    assert.is_false(applied)
    assert.is_nil(e._jq and e._jq.is_filtered, "entry not marked filtered")
    assert.same({ "original body line" }, vim.api.nvim_buf_get_lines(pane, 0, -1, false))
    assert.equals(1, #notify_calls)
    assert.equals(vim.log.levels.ERROR, notify_calls[1].level)
    assert.truthy(notify_calls[1].msg:match("jq error"))
  end)

  it("a successful jq filter updates the pane and records the query", function()
    local pane = make_pane({ "original body line" })
    local e = { name = "GetUser", response = { body = '{"a":1}' } }
    history2._run_jq = function()
      return true, '{"a":1}\n'
    end
    local applied = history2.apply_jq_filter(e, ".a", pane)
    history2._run_jq = nil
    assert.is_true(applied)
    assert.is_true(e._jq.is_filtered)
    assert.equals(".a", e._jq.query)
    assert.truthy(vim.api.nvim_buf_get_lines(pane, 0, -1, false)[1]:match('"a"'))
    assert.equals(0, #notify_calls)
  end)
end)
