-- Tests for semicolon-based statement extraction (no ### required)
vim.opt.runtimepath:prepend(".")

local out = {}
local function log(s) table.insert(out, s) end
local pass, fail = 0, 0
local function check(label, got, expected)
  if got == expected then log("PASS: " .. label); pass = pass + 1
  else log(string.format("FAIL: %s\n  got=     %s\n  expected=%s", label, tostring(got), tostring(expected))); fail = fail + 1 end
end

-- Access the internal function via a small shim (reload with rtp)
local sql_init = require("poste.sql.init")
-- extract_stmt_at_cursor is local; expose via _test
local t = sql_init._test

log("=== extract_stmt_at_cursor ===")

do -- single statement, cursor on query line
  local lines = {
    "-- @connection my-blog",
    "-- @database blog",
    "",
    "SELECT * FROM authors WHERE id = 1;",
  }
  local content, adj_line = t.extract_stmt_at_cursor(lines, 4)
  check("contains ###", content:find("###") ~= nil, true)
  check("contains the query", content:find("SELECT %* FROM authors") ~= nil, true)
  check("contains directive", content:find("@connection") ~= nil, true)
  -- adjusted line should point inside the ### block (> directive count + 1)
  check("adjusted line > 0", adj_line > 0, true)
end

do -- cursor on second statement of two
  local lines = {
    "-- @connection my-blog",
    "SELECT * FROM authors;",
    "",
    "SELECT * FROM posts;",
  }
  local content, _ = t.extract_stmt_at_cursor(lines, 4)
  check("only posts query", content:find("FROM posts") ~= nil, true)
  -- should NOT include the authors query (it's in a different statement)
  check("no authors query", content:find("FROM authors") == nil, true)
end

do -- multi-line statement
  local lines = {
    "-- @connection my-blog",
    "SELECT p.title,",
    "       a.username AS author",
    "FROM posts p",
    "JOIN authors a ON a.id = p.author_id;",
  }
  local content, _ = t.extract_stmt_at_cursor(lines, 3)
  check("multi-line: contains SELECT", content:find("SELECT") ~= nil, true)
  check("multi-line: contains JOIN",   content:find("JOIN") ~= nil, true)
  check("multi-line: has ###",         content:find("###") ~= nil, true)
end

log(string.format("\n=== RESULT: %d passed, %d failed ===", pass, fail))
vim.fn.writefile(out, "/tmp/poste_stmt_diag.txt")
vim.cmd("qa!")
