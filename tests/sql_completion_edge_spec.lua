--- Edge case tests for SQL completion.
--- Lua heuristic (detect_context / extract_from_tables) removed in P3.
--- Remaining tests cover non-heuristic paths like resolve_current_context.

local sql_comp = require("poste.sql.completion")
local resolve_current_context = sql_comp._test.resolve_current_context
local conn_key = sql_comp._test.conn_key

----------------------------------------------------------------------
-- Helper
----------------------------------------------------------------------
local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

----------------------------------------------------------------------
-- resolve_current_context / conn_key edge cases
----------------------------------------------------------------------
describe("resolve_current_context / conn_key", function()
  before_each(function()
    local state = require("poste.state")
    state.sql = state.sql or {}
  end)

  it("nil conn_key when no connection in buffer or state", function()
    local buf = make_buf({"###", "SELECT * FROM users"})
    vim.api.nvim_set_current_buf(buf)
    local state = require("poste.state")
    state.sql.context = nil
    assert.is_nil(conn_key())
  end)

  it("conn_key from state.sql.context", function()
    local state = require("poste.state")
    state.sql.context = { connection = "pg-dev", database = "blog" }
    assert.equals("pg-dev/blog", conn_key())
  end)

  it("conn_key works without database", function()
    local state = require("poste.state")
    state.sql.context = { connection = "pg-dev", database = nil }
    assert.equals("pg-dev/", conn_key())
  end)

  it("resolve_context reads @connection from buffer header", function()
    local buf = make_buf({
      "-- @connection pg-ecommerce",
      "###",
      "SELECT * FROM users WHERE ",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 3, 1 })
    local ctx = resolve_current_context()
    assert.equals("pg-ecommerce", ctx.connection)
  end)

  it("resolve_context reads @database from buffer header", function()
    local buf = make_buf({
      "-- @connection pg-ecommerce",
      "-- @database analytics",
      "###",
      "SELECT * FROM users WHERE ",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 4, 1 })
    local ctx = resolve_current_context()
    assert.equals("pg-ecommerce", ctx.connection)
    assert.equals("analytics", ctx.database)
  end)
end)
