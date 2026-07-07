-- Tests for USE statement context resolution across blocks
vim.opt.runtimepath:prepend(".")

local out = {}
local function log(s) table.insert(out, s) end
local pass, fail = 0, 0
local function check(label, got, expected)
  if got == expected then log("PASS: " .. label); pass = pass + 1
  else log(string.format("FAIL: %s  got=%s  expected=%s", label, tostring(got), tostring(expected))); fail = fail + 1 end
end

local context = require("poste.sql.context")

local function make_buf(lines, cursor)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { cursor, 0 })
  return buf
end

log("=== resolve_context USE across blocks ===")

do -- USE in prior block carries over to next block
  local lines = {
    "-- @connection my-blog",
    "-- @database blog",
    "",
    "### Switch DB",
    "USE inventory;",
    "",
    "### Query",
    "select * from warehouse;",
  }
  make_buf(lines, 8)  -- cursor on warehouse query
  local ctx = context.resolve_context()
  check("USE in prior block → database=inventory", ctx.database, "inventory")
  check("connection unchanged",                     ctx.connection, "my-blog")
end

do -- no USE → uses @database
  local lines = {
    "-- @connection my-blog",
    "-- @database blog",
    "",
    "### Query",
    "select * from authors;",
  }
  make_buf(lines, 5)
  local ctx = context.resolve_context()
  check("no USE → database=blog", ctx.database, "blog")
end

do -- USE after cursor has no effect
  local lines = {
    "-- @connection my-blog",
    "-- @database blog",
    "",
    "### Query",
    "select * from authors;",
    "",
    "### Switch",
    "USE inventory;",
  }
  make_buf(lines, 5)  -- cursor BEFORE the USE block
  local ctx = context.resolve_context()
  check("USE after cursor ignored → database=blog", ctx.database, "blog")
end

do -- last USE wins when multiple exist
  local lines = {
    "-- @connection my-blog",
    "-- @database blog",
    "",
    "### first",
    "USE inventory;",
    "",
    "### second",
    "USE analytics;",
    "",
    "### query",
    "select * from events;",
  }
  make_buf(lines, 11)
  local ctx = context.resolve_context()
  check("last USE wins → database=analytics", ctx.database, "analytics")
end

log(string.format("\n=== RESULT: %d passed, %d failed ===", pass, fail))
vim.fn.writefile(out, "/tmp/poste_context_diag.txt")
vim.cmd("qa!")
