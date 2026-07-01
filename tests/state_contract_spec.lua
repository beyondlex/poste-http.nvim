-- Contract tests for poste.state — the shared mutable state module.
--
-- These tests lock down the current behavior of every state field so that
-- refactoring (event bus, type safety, etc.) does not introduce regressions.
--
-- IMPORTANT: These are NOT "good design" tests.  They simply capture what
-- the code currently does so we can safely change *how* it works.

local state = require("poste.state")

---------------------------------------------------------------------------
-- Configuration defaults
---------------------------------------------------------------------------

describe("state.config defaults", function()
  it("default_env is 'dev'", function()
    assert.equals("dev", state.config.default_env)
  end)

  it("split_direction is 'vertical'", function()
    assert.equals("vertical", state.config.split_direction)
  end)

  it("split_size is 80", function()
    assert.equals(80, state.config.split_size)
  end)

  it("sql_formatters has defaults in order", function()
    assert.is_table(state.config.sql_formatters)
    assert.equals("sqlfluff", state.config.sql_formatters[1])
  end)

  it("highlights is an empty table", function()
    assert.is_table(state.config.highlights)
    assert.equals(0, vim.tbl_count(state.config.highlights))
  end)
end)

---------------------------------------------------------------------------
-- Cross-cutting mutable state
---------------------------------------------------------------------------

describe("state mutable fields", function()
  before_each(function()
    -- Reset to safe defaults before each test
    state.current_env = "dev"
    state.last_response = nil
    state.last_assertion_results = nil
    state.last_script_logs = nil
    state.last_request = nil
    state.pending_request = nil
    state.current_view = "body"
  end)

  it("current_env defaults to config.default_env", function()
    assert.equals(state.config.default_env, "dev")
  end)

  it("last_response is nil after clear", function()
    state.last_response = { status = 200 }
    assert.is_not_nil(state.last_response)
    state.last_response = nil
    assert.is_nil(state.last_response)
  end)

  it("last_assertion_results stores test summary", function()
    local results = { passed = 3, failed = 1, total = 4 }
    state.last_assertion_results = results
    assert.equals(4, state.last_assertion_results.total)
    assert.equals(3, state.last_assertion_results.passed)
  end)

  it("last_script_logs stores log lines", function()
    state.last_script_logs = { "line1", "line2" }
    assert.equals(2, #state.last_script_logs)
    assert.equals("line1", state.last_script_logs[1])
  end)

  it("last_request stores { buf, line }", function()
    state.last_request = { buf = 1, line = 42 }
    assert.equals(1, state.last_request.buf)
    assert.equals(42, state.last_request.line)
  end)

  it("pending_request stores in-flight request info", function()
    state.pending_request = { method = "GET", url = "http://example.com", headers_str = "", body = "", env = "dev" }
    assert.equals("GET", state.pending_request.method)
  end)

  it("current_view defaults to 'body'", function()
    assert.equals("body", state.current_view)
  end)

  it("current_view can be changed", function()
    state.current_view = "headers"
    assert.equals("headers", state.current_view)
  end)
end)

---------------------------------------------------------------------------
-- http_history
---------------------------------------------------------------------------

describe("state.http_history", function()
  before_each(function()
    state.http_history = {}
    state.http_history_id_counter = 0
  end)

  it("starts empty", function()
    assert.is_table(state.http_history)
    assert.equals(0, #state.http_history)
  end)

  it("accepts entries", function()
    state.http_history_id_counter = state.http_history_id_counter + 1
    table.insert(state.http_history, { id = state.http_history_id_counter, method = "GET", url = "/test" })
    assert.equals(1, #state.http_history)
    assert.equals("GET", state.http_history[1].method)
  end)
end)

---------------------------------------------------------------------------
-- SQL-specific state
---------------------------------------------------------------------------

describe("state.sql state", function()
  before_each(function()
    state.sql.context.connection = nil
    state.sql.context.database = nil
    state.sql.last_dataset = nil
    state.sql.cell = { row = 1, col = 1 }
  end)

  it("sql.context defaults are nil", function()
    assert.is_nil(state.sql.context.connection)
    assert.is_nil(state.sql.context.database)
  end)

  it("sql.cell defaults to row=1, col=1", function()
    assert.equals(1, state.sql.cell.row)
    assert.equals(1, state.sql.cell.col)
  end)

  it("sql.cell can be updated", function()
    state.sql.cell.row = 5
    state.sql.cell.col = 3
    assert.equals(5, state.sql.cell.row)
    assert.equals(3, state.sql.cell.col)
  end)
end)

---------------------------------------------------------------------------
-- Keymap helpers
---------------------------------------------------------------------------

describe("state.get_keymap()", function()
  it("returns default when action not configured", function()
    local key = state.get_keymap("http_source", "nonexistent_action", "<CR>")
    assert.equals("<CR>", key)
  end)

  it("returns nil when key is set to false (disabled)", function()
    local orig = state.config.keymaps.http_source.run
    state.config.keymaps.http_source.run = false
    local key = state.get_keymap("http_source", "run", "<CR>")
    assert.is_nil(key)
    state.config.keymaps.http_source.run = orig
  end)

  it("returns configured key", function()
    local key = state.get_keymap("http_source", "run", "<CR>")
    assert.is_not_nil(key)
  end)
end)

---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------

describe("state.log()", function()
  it("does not crash with nil log_file", function()
    local orig = state.config.log_file
    state.config.log_file = nil
    state.log("INFO", "test message")  -- should not error
    state.config.log_file = orig
  end)

  it("does not crash with empty log_file", function()
    local orig = state.config.log_file
    state.config.log_file = ""
    state.log("INFO", "test message")  -- should not error
    state.config.log_file = orig
  end)
end)

---------------------------------------------------------------------------
-- _json state
---------------------------------------------------------------------------

describe("state._json state", function()
  before_each(function()
    state._json.original_lines = nil
    state._json.query = nil
    state._json.is_filtered = false
    state._json.pretty_mode = true
  end)

  it("defaults are correct", function()
    assert.is_nil(state._json.original_lines)
    assert.is_nil(state._json.query)
    assert.is_false(state._json.is_filtered)
    assert.is_true(state._json.pretty_mode)
  end)
end)

---------------------------------------------------------------------------
-- Script variables
---------------------------------------------------------------------------

describe("state script variables", function()
  before_each(function()
    state.global_vars = {}
    state.script_variables = {}
  end)

  it("global_vars starts empty", function()
    assert.is_table(state.global_vars)
    assert.equals(0, vim.tbl_count(state.global_vars))
  end)

  it("script_variables starts empty", function()
    assert.is_table(state.script_variables)
    assert.equals(0, vim.tbl_count(state.script_variables))
  end)
end)
