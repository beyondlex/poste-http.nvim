-- Tests for the unified notification primitive (poste-http.ui.notify).
--
-- Every user-facing message goes through this module: it owns the plugin
-- title, sentence capitalization, length capping and the mirror into the
-- state.log sink. Call sites never call vim.notify directly — the guardrail
-- grep in tests/run.sh fails on any vim.notify outside ui/notify.lua.

local notify_mod = require("poste-http.ui.notify")
local state = require("poste-http.state")

describe("poste-http.ui.notify", function()
  local captured
  local orig_notify

  before_each(function()
    captured = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level, opts)
      table.insert(captured, { msg = msg, level = level, opts = opts })
    end
  end)

  after_each(function()
    vim.notify = orig_notify
  end)

  it("delegates to vim.notify with the default plugin title", function()
    notify_mod.notify("Request finished", vim.log.levels.INFO)
    assert.equals(1, #captured)
    assert.equals("Request finished", captured[1].msg)
    assert.equals(vim.log.levels.INFO, captured[1].level)
    assert.equals("Poste HTTP", captured[1].opts.title)
  end)

  it("defaults to INFO when no level is given", function()
    notify_mod.notify("just a status")
    assert.equals(1, #captured)
    assert.equals(vim.log.levels.INFO, captured[1].level)
  end)

  it("honors an opts.title override", function()
    notify_mod.notify("scoped", vim.log.levels.WARN, { title = "Import OpenAPI" })
    assert.equals("Import OpenAPI", captured[1].opts.title)
  end)

  it("keeps the message verbatim — call sites own sentence style", function()
    -- Auto-capitalization would mangle leading tool names ("jq error")
    -- and {{var}} placeholders, so the wrapper never rewrites the text.
    notify_mod.notify("jq error: unexpected token", vim.log.levels.ERROR)
    assert.equals("jq error: unexpected token", captured[1].msg)
  end)

  it("leaves messages that do not start with a lowercase letter alone", function()
    notify_mod.notify("{{var}} is unresolved", vim.log.levels.WARN)
    assert.equals("{{var}} is unresolved", captured[1].msg)
    notify_mod.notify("3 entries cleared", vim.log.levels.INFO)
    assert.equals("3 entries cleared", captured[2].msg)
  end)

  it("drops NUL bytes that would corrupt downstream string handling", function()
    notify_mod.notify("has\0a nul", vim.log.levels.WARN)
    assert.equals("hasa nul", captured[1].msg)
  end)

  it("truncates very long messages to a bounded display width", function()
    notify_mod.notify(string.rep("a", 500), vim.log.levels.WARN)
    assert.is_true(vim.fn.strdisplaywidth(captured[1].msg) <= 200,
      "message must stay within the 200-column budget, got "
      .. vim.fn.strdisplaywidth(captured[1].msg))
    assert.truthy(captured[1].msg:find("…$"))
  end)

  it("mirrors the message into the state log sink", function()
    local tmp = vim.fn.tempname()
    local orig_log_file = state.config.log_file
    state.config.log_file = tmp
    notify_mod.notify("Log mirror check", vim.log.levels.WARN)
    state.config.log_file = orig_log_file
    local f = io.open(tmp, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(tmp)
    assert.truthy(content:find("Log mirror check", 1, true), "message must reach the log file")
    assert.truthy(content:find("%[WARN%]"), "level must be written as a name, not a number")
  end)
end)
