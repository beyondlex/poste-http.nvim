--- Edge case tests for SQL completion context detection.
---
--- These tests capture the CURRENT behavior, including known bugs and
--- limitations of the heuristic-based approach. When we upgrade to a
--- proper tokenizer/AST-based approach, these tests will catch regressions
--- AND document what improved.
---
--- Naming convention:
---   <behavior> — <condition>
---   "BUG:" prefix = known incorrect behavior we want to fix
---   "CURRENT:" prefix = correct behavior of current implementation

local sql_comp = require("poste.sql.completion")
local detect_context = sql_comp._test.detect_lua_context
local extract_from_tables = sql_comp._test.extract_from_tables
local resolve_current_context = sql_comp._test.resolve_current_context
local conn_key = sql_comp._test.conn_key

----------------------------------------------------------------------
-- Helper to create a mock buffer for extract_from_tables tests
----------------------------------------------------------------------
local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

----------------------------------------------------------------------
-- 1. DML clause-level context detection
----------------------------------------------------------------------
describe("detect_context — DML clauses", function()
  it("UPDATE<space> → table context", function()
    assert.equals("table", detect_context("UPDATE "))
  end)

  it("UPDATE users SET<space> → column context", function()
    assert.equals("column", detect_context("UPDATE users SET "))
  end)

  it("DELETE FROM<space> → table context", function()
    assert.equals("table", detect_context("DELETE FROM "))
  end)

  it("INSERT INTO<space> → table context", function()
    assert.equals("table", detect_context("INSERT INTO "))
  end)

  it("SELECT<space> → column context", function()
    -- "SELECT" is in COLUMN_CTX → suggests columns
    assert.equals("column", detect_context("SELECT "))
  end)

  it("ON after JOIN<space> → column context", function()
    local ctx = detect_context("SELECT * FROM users u JOIN posts ON ")
    assert.equals("column", ctx)
  end)

  it("HAVING<space> → column context", function()
    local ctx = detect_context("SELECT * FROM users GROUP BY id HAVING ")
    assert.equals("column", ctx)
  end)

  it("ORDER BY<space> → column context (via 'by')", function()
    assert.equals("column", detect_context("SELECT * FROM users ORDER BY "))
  end)

  it("GROUP BY<space> → column context (via 'by')", function()
    assert.equals("column", detect_context("SELECT * FROM users GROUP BY "))
  end)

  it("comma after column → column context", function()
    assert.equals("column", detect_context("SELECT id, name, "))
  end)

  it("comma with prefix → column context", function()
    assert.equals("column", detect_context("SELECT id, na"))
  end)

  it("CURRENT: WHERE col = <space> → keyword (operator not in word tokens)", function()
    -- Operators like = > < are in COLUMN_CTX but are NOT matched by gmatch("[%w_]+")
    -- so they're never checked. check_word_idx resolves to "id" → not in COLUMN_CTX
    assert.equals("keyword", detect_context("SELECT * FROM users WHERE id = "))
  end)

  it("CURRENT: WHERE col > <space> → keyword", function()
    assert.equals("keyword", detect_context("SELECT * FROM users WHERE id > "))
  end)

  it("CURRENT: WHERE id = 1 AND <space> → column (AND is a word)", function()
    -- AND is in COLUMN_CTX and IS matched by %w+
    assert.equals("column", detect_context("SELECT * FROM users WHERE id = 1 AND "))
  end)

  it("NOT<space> → column context", function()
    -- "not" is in COLUMN_CTX → column context (debatable correctness)
    assert.equals("column", detect_context("SELECT * FROM users WHERE id IS NOT "))
  end)
end)

----------------------------------------------------------------------
-- 2. IN / BETWEEN / LIKE / IS clauses (current gaps)
----------------------------------------------------------------------
describe("detect_context — IN / BETWEEN / LIKE / IS", function()
  it("BEFORE FIX: WHERE col IN<space> → keyword", function()
    -- IN is not in COLUMN_CTX or TABLE_CTX → keyword context
    -- After IN the user wants a value list or subquery, not a column name
    assert.equals("keyword", detect_context("SELECT * FROM users WHERE id IN "))
  end)

  it("BEFORE FIX: WHERE col BETWEEN<space> → keyword", function()
    assert.equals("keyword", detect_context("SELECT * FROM users WHERE id BETWEEN "))
  end)

  it("BEFORE FIX: WHERE col LIKE<space> → keyword", function()
    assert.equals("keyword", detect_context("SELECT * FROM users WHERE name LIKE "))
  end)

  it("BEFORE FIX: WHERE col IS<space> → keyword", function()
    -- IS is not in any context table → keyword
    assert.equals("keyword", detect_context("SELECT * FROM users WHERE status IS "))
  end)

  it("BEFORE FIX: WHERE col NOT IN<space> → keyword", function()
    -- "not" is in COLUMN_CTX so "WHERE col NOT " → column
    -- But "WHERE col NOT IN " → last words are "NOT IN" → ends with alnum
    -- check_word_idx = #words - 1 = 2nd-to-last. Words: {SELECT, FROM, users, WHERE, id, NOT, IN}
    -- check_word_idx = 6 (IN) → wait, it depends on whether "IN " ends with space
    -- "SELECT * FROM users WHERE id NOT IN " → ends with space
    -- Actually wait, "IN " ends with space, so line_before:match("[%w_]+$") returns nil
    -- check_word_idx = #words = 7 → keyword = "IN" (lowered) → not in TABLE_CTX or COLUMN_CTX
    assert.equals("keyword", detect_context("SELECT * FROM users WHERE id NOT IN "))
  end)

  it("BEFORE FIX: WHERE col NOT LIKE<space> → keyword", function()
    assert.equals("keyword", detect_context("SELECT * FROM users WHERE id NOT LIKE "))
  end)
end)

----------------------------------------------------------------------
-- 3. DDL clause detection
----------------------------------------------------------------------
describe("detect_context — DDL clauses", function()
  it("CREATE TABLE<space> → table context", function()
    assert.equals("table", detect_context("CREATE TABLE "))
  end)

  it("ALTER TABLE<space> → table context", function()
    assert.equals("table", detect_context("ALTER TABLE "))
  end)

  it("DROP TABLE<space> → table context", function()
    assert.equals("table", detect_context("DROP TABLE "))
  end)

  it("TRUNCATE TABLE<space> → table context", function()
    assert.equals("table", detect_context("TRUNCATE TABLE "))
  end)

  it("CREATE TABLE name ( → keyword context (column def follows)", function()
    assert.equals("keyword", detect_context("CREATE TABLE users ("))
  end)

  it("BEFORE FIX: ALTER TABLE name ADD COLUMN<space> → keyword (not in COLUMN_CTX)", function()
    -- "column" is NOT in COLUMN_CTX, so it falls through to "keyword"
    assert.equals("keyword", detect_context("ALTER TABLE users ADD COLUMN "))
  end)
end)

----------------------------------------------------------------------
-- 4. extract_from_tables — DML form edge cases
----------------------------------------------------------------------
describe("extract_from_tables — DML forms", function()
  it("UPDATE table name", function()
    local buf = make_buf({"###", "UPDATE users SET name = 'foo' WHERE "})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "users"))
  end)

  it("DELETE FROM table", function()
    local buf = make_buf({"###", "DELETE FROM sessions WHERE "})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "sessions"))
  end)

  it("INSERT INTO table", function()
    local buf = make_buf({"###", "INSERT INTO audit_log (user_id, action) VALUES "})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "audit_log"))
  end)

  it("multiple JOINs without aliases", function()
    local buf = make_buf({"###",
      "SELECT * FROM orders " ..
      "JOIN customers ON orders.customer_id = customers.id " ..
      "JOIN products ON orders.product_id = products.id WHERE "
    })
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "orders"))
    assert.is_true(vim.tbl_contains(tbls, "customers"))
    assert.is_true(vim.tbl_contains(tbls, "products"))
  end)

  it("CROSS JOIN", function()
    local buf = make_buf({"###", "SELECT * FROM users CROSS JOIN roles WHERE "})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "users"))
    assert.is_true(vim.tbl_contains(tbls, "roles"))
  end)

  it("CROSS JOIN with alias", function()
    local buf = make_buf({"###", "SELECT * FROM users u CROSS JOIN roles r WHERE "})
    local _, alias_map = extract_from_tables(buf, 2)
    assert.equals("users", alias_map["u"])
    assert.equals("roles", alias_map["r"])
  end)

  it("two SELECTs in same ### block both extracted", function()
    local buf = make_buf({"###", "SELECT * FROM users; SELECT * FROM orders WHERE "})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "users"))
    assert.is_true(vim.tbl_contains(tbls, "orders"))
  end)
end)

----------------------------------------------------------------------
-- 5. Schema/database-qualified table names (current limitations)
----------------------------------------------------------------------
describe("extract_from_tables — schema qualifiers (BEFORE FIX)", function()
  -- BUG: regex only matches %w+ after FROM/JOIN/UPDATE/INTO
  -- "public.users" → only matches "public", not "users"

  it("BUG: schema.table extracts only the schema name", function()
    local buf = make_buf({"###", "SELECT * FROM public.users WHERE "})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "public"),
      "schema name 'public' is extracted")
    assert.is_false(vim.tbl_contains(tbls, "users"),
      "BUG: 'users' is not extracted; only first word after FROM is")
  end)

  it("BUG: db.schema.table extracts only db name", function()
    local buf = make_buf({"###", "SELECT * FROM mydb.public.users WHERE "})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "mydb"))
    assert.is_false(vim.tbl_contains(tbls, "users"),
      "BUG: table part lost in db.schema.table")
  end)
end)

----------------------------------------------------------------------
-- 6. Subquery table leakage (current limitations)
----------------------------------------------------------------------
describe("extract_from_tables — subquery awareness (BEFORE FIX)", function()
  -- BUG: no paren depth tracking → inner tables leak to outer scope

  it("BUG: tables from subquery-FROM leak to outer scope", function()
    local buf = make_buf({"###",
      "SELECT * FROM (SELECT * FROM items) AS sub WHERE "})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "items"),
      "BUG: 'items' from subquery should NOT be in outer table list")
    assert.is_false(vim.tbl_contains(tbls, "sub"),
      "subquery alias 'sub' is also NOT captured (regex limitation)")
  end)

  it("BUG: tables from deeply nested subquery leak", function()
    local buf = make_buf({"###",
      "SELECT * FROM (SELECT * FROM (SELECT * FROM deep) AS mid) AS outer WHERE "})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "deep"),
      "BUG: table from 2-level nested subquery leaks")
  end)

  it("BUG: JOIN inside subquery leaks tables", function()
    local buf = make_buf({"###",
      "SELECT * FROM (SELECT * FROM a JOIN b ON a.id=b.id) AS sub WHERE "})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "a"),
      "BUG: inner_a from subquery JOIN leaks")
    assert.is_true(vim.tbl_contains(tbls, "b"),
      "BUG: inner_b from subquery JOIN leaks")
  end)

  it("cursor inside subquery WHERE gets tables from both scopes", function()
    local buf = make_buf({"###",
      "SELECT * FROM users WHERE id IN (SELECT user_id FROM secret WHERE "})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "users"))
    assert.is_true(vim.tbl_contains(tbls, "secret"))
  end)
end)

----------------------------------------------------------------------
-- 7. CTE (WITH clause) handling (current limitations)
----------------------------------------------------------------------
describe("extract_from_tables — CTE (BEFORE FIX)", function()
  -- BUG: CTE definitions are scanned the same way as the outer query
  -- Tables referenced inside CTE definitions leak to the outer scope

  it("BUG: CTE inner tables leak", function()
    local buf = make_buf({"###",
      "WITH active AS (SELECT * FROM users WHERE active=1) " ..
      "SELECT * FROM active WHERE "})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "users"),
      "BUG: 'users' from CTE definition leaks to outer table list")
    assert.is_true(vim.tbl_contains(tbls, "active"),
      "CTE name is correctly found")
  end)

  it("BUG: multi-CTE: all inner tables leak", function()
    local buf = make_buf({"###",
      "WITH " ..
      "recent AS (SELECT * FROM recent_posts WHERE created_at > NOW()), " ..
      "popular AS (SELECT * FROM popular_posts WHERE views > 100) " ..
      "SELECT * FROM recent JOIN popular ON recent.id = popular.id WHERE "})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "recent_posts"),
      "BUG: recent_posts from CTE def leaks")
    assert.is_true(vim.tbl_contains(tbls, "popular_posts"),
      "BUG: popular_posts from CTE def leaks")
  end)
end)

----------------------------------------------------------------------
-- 8. Dot-notation edge cases
----------------------------------------------------------------------
describe("detect_context — dot-notation", function()
  it("table.col → dot_column", function()
    local ctx, extra = detect_context("users.")
    assert.equals("dot_column", ctx)
    assert.equals("users", extra)
  end)

  it("schema.table.col → dot_column (loses schema qualifier)", function()
    local ctx, extra = detect_context("public.users.")
    -- CURRENT: regex finds 'users' as the last word before '.', loses 'public.'
    assert.equals("dot_column", ctx)
    assert.equals("users", extra)
  end)

  it("two-level qualifier → dot_column loses db+schema", function()
    local ctx, extra = detect_context("mydb.public.users.")
    assert.equals("dot_column", ctx)
    assert.equals("users", extra)
  end)

  it("alias prefix → dot_column with alias", function()
    local ctx, extra = detect_context("u.na")
    assert.equals("dot_column", ctx)
    assert.equals("u", extra)
  end)

  it("multiple dots yields last segment", function()
    local ctx, extra = detect_context("a.b.c.d.")
    assert.equals("dot_column", ctx)
    assert.equals("d", extra)
  end)

  it("dot at line start → keyword", function()
    assert.equals("keyword", detect_context("."))
  end)

  it("dot after operator → keyword", function()
    assert.equals("keyword", detect_context("1 + ."))
  end)
end)

----------------------------------------------------------------------
-- 9. @connection and USE directive edge cases
----------------------------------------------------------------------
describe("detect_context — directive edge cases", function()
  it("@connection<eol> → keyword (needs trailing space)", function()
    -- The regex `@connection%s+%S*$` requires at least one space after @connection
    -- Without the space, it falls through to word-based detection
    assert.equals("keyword", detect_context("@connection"))
  end)

  it("@connection with leading ws → connection context", function()
    assert.equals("connection", detect_context("  @connection "))
  end)

  it("@connection prefix → connection context", function()
    assert.equals("connection", detect_context("@connection dev-"))
  end)

  it("--@connection → connection context", function()
    assert.equals("connection", detect_context("--@connection "))
  end)

  it("USE<eol> → keyword (no space after USE)", function()
    assert.equals("keyword", detect_context("USE"))
  end)

  it("USE<space> → database context", function()
    assert.equals("database", detect_context("USE "))
  end)

  it("USE prefix → database context", function()
    assert.equals("database", detect_context("USE my_"))
  end)

  it("lowercase use → database context", function()
    assert.equals("database", detect_context("use "))
  end)

  it("USE `db → database context with backtick", function()
    assert.equals("database", detect_context("USE `my"))
  end)
end)

----------------------------------------------------------------------
-- 10. Comment-awareness gaps
----------------------------------------------------------------------
describe("detect_context — comment handling (BEFORE FIX)", function()
  -- BUG: detect_context has no comment awareness. It scans all text including
  -- comments as if they were SQL code, so keywords inside comments trigger
  -- their corresponding contexts.

  it("BUG: -- FROM<space> → table context (should be keyword)", function()
    assert.equals("table", detect_context("-- FROM "),
      "BUG: 'FROM' inside comment triggers table context")
  end)

  it("BUG: -- WHERE<space> → column context (should be keyword)", function()
    assert.equals("column", detect_context("-- WHERE "),
      "BUG: 'WHERE' inside comment triggers column context")
  end)

  it("BUG: /* FROM */ → table context", function()
    assert.equals("table", detect_context("/* FROM */ "),
      "BUG: 'FROM' inside block comment triggers table context")
  end)

  it("non-comment line with WHERE → correct column context", function()
    -- Sanity check: regular WHERE outside comment works
    assert.equals("column", detect_context("SELECT * FROM users WHERE "))
  end)
end)

----------------------------------------------------------------------
-- 11. String-awareness gaps
----------------------------------------------------------------------
describe("detect_context — string literal handling (BEFORE FIX)", function()
  -- BUG: detect_context has no string awareness. Keywords inside string
  -- literals may trigger wrong contexts.

  it("BUG: string 'WHERE ' at end triggers column context", function()
    -- "FROM " is the last meaningful word → table context
    -- But the string contains 'WHERE ' which doesn't matter because
    -- it's not the last word. This case is correct by accident.
    assert.equals("table", detect_context("SELECT 'problem WHERE ' FROM "))
  end)

  it("'FRO' inside string → keyword context (no false match)", function()
    -- "FRO" doesn't match any context word
    assert.equals("keyword", detect_context("SELECT 'FROM the ' "))
  end)
end)

----------------------------------------------------------------------
-- 12. resolve_current_context / conn_key edge cases
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

----------------------------------------------------------------------
-- 13. INSERT INTO column completion edge cases
----------------------------------------------------------------------
describe("detect_context — INSERT INTO edge cases", function()
  it("INSERT INTO tbl ( → insert_column", function()
    local ctx, extra = detect_context("INSERT INTO users (")
    assert.equals("insert_column", ctx)
    assert.equals("users", extra)
  end)

  it("INSERT INTO tbl (closed paren → not insert_column", function()
    assert.is_not.equals("insert_column", detect_context("INSERT INTO users (id, name)"))
  end)

  it("INSERT INTO<space> → keyword (last word 'users' not a context keyword)", function()
    -- Current code checks the LAST word "users" (since line ends with space).
    -- "users" is not in TABLE_CTX or COLUMN_CTX → returns keyword.
    assert.equals("keyword", detect_context("INSERT INTO users "))
  end)

  it("INSERT INTO tbl (prefix → insert_column with prefix", function()
    local ctx, extra = detect_context("INSERT INTO users (i")
    assert.equals("insert_column", ctx)
    assert.equals("users", extra)
  end)

  it("insert into tbl (lowercase → insert_column", function()
    local ctx, extra = detect_context("   insert into posts (")
    assert.equals("insert_column", ctx)
    assert.equals("posts", extra)
  end)

  it("non-ASCII table names return keyword (Lua %w doesn't match Unicode)", function()
    -- Lua's %w pattern only matches ASCII [a-zA-Z0-9_], not CJK characters.
    -- So "用户表" is not captured, and "into" becomes the last checked word → table.
    local ctx = detect_context("INSERT INTO 用户表 (")
    assert.equals("table", ctx)
  end)
end)

----------------------------------------------------------------------
-- 14. Unhandled keyword contexts (for new architecture)
----------------------------------------------------------------------
describe("detect_context — unhandled SQL constructs", function()
  it("PARTITION BY → column ('by' is in COLUMN_CTX, works by accident)", function()
    -- "by" is in COLUMN_CTX via ORDER BY, so PARTITION BY also triggers column
    assert.equals("column", detect_context("SELECT ROW_NUMBER() OVER (PARTITION BY "))
  end)

  it("THEN inside CASE → keyword", function()
    assert.equals("keyword", detect_context("SELECT CASE WHEN id > 10 THEN "))
  end)

  it("ELSE inside CASE → keyword", function()
    assert.equals("keyword", detect_context("SELECT CASE WHEN id > 10 THEN 'big' ELSE "))
  end)

  it("VALUES ( → keyword", function()
    assert.equals("keyword", detect_context("INSERT INTO users (id, name) VALUES ("))
  end)
end)

----------------------------------------------------------------------
-- 15. Null-safe and edge inputs
----------------------------------------------------------------------
describe("detect_context — edge inputs", function()
  it("empty string → keyword", function()
    assert.equals("keyword", detect_context(""))
  end)

  it("whitespace only → keyword", function()
    assert.equals("keyword", detect_context("   "))
  end)

  it("special characters → keyword", function()
    assert.equals("keyword", detect_context("*&^%"))
  end)

  it("numbers only → keyword", function()
    assert.equals("keyword", detect_context("12345"))
  end)

  it("newline embedded → works (line_before is current line only)", function()
    -- detect_context receives only the text before cursor on the current line
    -- Multi-line content is handled by the caller
    assert.equals("column", detect_context("WHERE "))
  end)
end)

----------------------------------------------------------------------
-- 16. String literal containing semicolons in extract_from_tables
----------------------------------------------------------------------
describe("extract_from_tables — with string/comment content", function()
  it("string containing FROM does not create false table (FROM%' → no match)", function()
    -- "%FROM%" → the '%' before 'FROM' makes it not match FROM\s+%w+ pattern
    -- because % is not whitespace
    local buf = make_buf({"###",
      "SELECT * FROM users WHERE bio LIKE '%FROM%' " ..
      "AND name = 'FROM here'"
    })
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "users"))
    -- BUG: "FROM here" in the string matches FROM\s+here → "here" is extracted
    assert.is_true(vim.tbl_contains(tbls, "here"),
      "BUG: 'here' after 'FROM' in string is incorrectly extracted as a table")
  end)

  it("comment containing FROM is stripped safely", function()
    -- Lines starting with -- are removed before text concatenation
    local buf = make_buf({"###", "SELECT * FROM users WHERE id = 1 -- FROM orders"})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "users"))
    assert.is_false(vim.tbl_contains(tbls, "orders"),
      "'orders' after FROM in comment is stripped")
  end)
end)

----------------------------------------------------------------------
-- 17. Alias edge cases
----------------------------------------------------------------------
describe("extract_from_tables — alias edge cases", function()
  it("FULL OUTER JOIN with alias", function()
    local buf = make_buf({"###",
      "SELECT * FROM users u FULL OUTER JOIN orders o ON u.id = o.user_id WHERE "})
    local _, alias_map = extract_from_tables(buf, 2)
    assert.equals("users", alias_map["u"])
    assert.equals("orders", alias_map["o"])
  end)

  it("RIGHT JOIN with alias", function()
    local buf = make_buf({"###",
      "SELECT * FROM users u RIGHT JOIN orders o ON u.id = o.user_id WHERE "})
    local _, alias_map = extract_from_tables(buf, 2)
    assert.equals("users", alias_map["u"])
    assert.equals("orders", alias_map["o"])
  end)

  it("NATURAL JOIN (no ON clause)", function()
    local buf = make_buf({"###",
      "SELECT * FROM users NATURAL JOIN orders WHERE "})
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "users"))
    assert.is_true(vim.tbl_contains(tbls, "orders"))
  end)
end)
