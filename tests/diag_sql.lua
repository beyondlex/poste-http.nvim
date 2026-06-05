-- Standalone diagnostic: run with
--   nvim --headless -u NONE -l tests/diag_sql.lua
-- Writes results to /tmp/poste_sql_diag.txt

vim.opt.runtimepath:prepend(".")

local out = {}
local function log(s) table.insert(out, s) end

local ok, sql_comp = pcall(require, "poste.sql.completion")
if not ok then
  log("FAIL: could not load sql.completion: " .. tostring(sql_comp))
  vim.fn.writefile(out, "/tmp/poste_sql_diag.txt")
  os.exit(1)
end

local detect_context    = sql_comp._test.detect_context
local extract_from_tables = sql_comp._test.extract_from_tables
local get_items         = sql_comp._test.get_items

local pass, fail = 0, 0
local function check(label, got, expected)
  if got == expected then
    log("PASS: " .. label)
    pass = pass + 1
  else
    log(string.format("FAIL: %s  got=%s  expected=%s", label, tostring(got), tostring(expected)))
    fail = fail + 1
  end
end

-- ── 1. detect_context ────────────────────────────────────────────────────────
log("\n=== detect_context ===")
check("WHERE<space>",        detect_context("SELECT * FROM authors WHERE "),          "column")
check("WHERE<space>partial", detect_context("SELECT * FROM authors WHERE us"),        "column")
check("FROM<space>",         detect_context("SELECT * FROM "),                         "table")
check("AND<space>",          detect_context("... WHERE id=1 AND "),                   "column")
check("bare SEL",            detect_context("SEL"),                                   "keyword")
do
  local ctx, extra = detect_context("SELECT authors.")
  check("dot_column ctx",   ctx,   "dot_column")
  check("dot_column extra", extra, "authors")
end

-- ── 2. extract_from_tables ───────────────────────────────────────────────────
log("\n=== extract_from_tables ===")
local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

do
  local buf = make_buf({ "###", "SELECT * FROM authors WHERE " })
  local tbls = extract_from_tables(buf, 2)
  check("finds authors", vim.tbl_contains(tbls, "authors"), true)
end

do
  local buf = make_buf({
    "###", "SELECT * FROM other;",
    "###", "SELECT * FROM authors WHERE ",
  })
  local tbls = extract_from_tables(buf, 4)
  check("authors in block",    vim.tbl_contains(tbls, "authors"),     true)
  check("other NOT in block",  vim.tbl_contains(tbls, "other"),       false)
end

-- ── 3. get_items with seeded cache ───────────────────────────────────────────
log("\n=== get_items (seeded cache) ===")

-- Seed state so conn_key() resolves
local state = require("poste.state")
state.sql = { context = { connection = "test-conn", database = "blog" } }

sql_comp.cache_tables({ { name = "authors" }, { name = "posts" } })
sql_comp.cache_columns("authors", {
  { name = "id" }, { name = "username" }, { name = "email" }, { name = "bio" },
})

do
  local buf = make_buf({ "###", "SELECT * FROM authors WHERE " })
  local items = nil
  get_items(buf, "SELECT * FROM authors WHERE ", 2, function(r) items = r end)

  if items == nil then
    log("FAIL: callback not called (async? cache miss?)")
    fail = fail + 1
  else
    log("items count: " .. #items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    check("column: id",       labels["id"],       true)
    check("column: username", labels["username"],  true)
    check("column: email",    labels["email"],     true)
  end
end

do
  -- Prefix filter
  local buf = make_buf({ "###", "SELECT * FROM authors WHERE us" })
  local items = nil
  get_items(buf, "SELECT * FROM authors WHERE us", 2, function(r) items = r end)
  if items then
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    check("prefix 'us' → username",  labels["username"], true)
    check("prefix 'us' → no id",     labels["id"],       nil)
  else
    log("FAIL: prefix filter callback not called")
    fail = fail + 1
  end
end

-- ── Summary ──────────────────────────────────────────────────────────────────
log(string.format("\n=== RESULT: %d passed, %d failed ===", pass, fail))

-- ── 4. Alias resolution ───────────────────────────────────────────────────────
log("\n=== alias resolution ===")

do
  local buf = make_buf({ "###", "SELECT * FROM authors s LEFT JOIN posts p ON p." })
  local tbls, alias_map = extract_from_tables(buf, 2)
  check("alias s → authors", alias_map["s"], "authors")
  check("alias p → posts",   alias_map["p"], "posts")
end

do
  local buf = make_buf({ "###", "SELECT * FROM authors WHERE " })
  local _, alias_map = extract_from_tables(buf, 2)
  check("no alias: authors → authors", alias_map["authors"], "authors")
end

-- dot_column resolves alias
state.sql = { context = { connection = "test-conn", database = "blog" } }
sql_comp.cache_tables({ { name = "authors" }, { name = "posts" } })
sql_comp.cache_columns("posts", {
  { name = "id" }, { name = "title" }, { name = "author_id" },
})

do
  local buf = make_buf({ "###", "SELECT * FROM authors s LEFT JOIN posts p ON p." })
  vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
  vim.api.nvim_set_current_buf(buf)
  local items = nil
  get_items(buf, "SELECT * FROM authors s LEFT JOIN posts p ON p.", 2, function(r) items = r end)
  if items == nil then
    log("FAIL: alias dot_column callback not called"); fail = fail + 1
  else
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    check("p. → posts.id",       labels["id"],        true)
    check("p. → posts.title",    labels["title"],      true)
    check("p. → posts.author_id",labels["author_id"],  true)
  end
end

do
  local buf = make_buf({ "###", "SELECT * FROM authors s LEFT JOIN posts p ON p.ti" })
  vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
  vim.api.nvim_set_current_buf(buf)
  local items = nil
  get_items(buf, "SELECT * FROM authors s LEFT JOIN posts p ON p.ti", 2, function(r) items = r end)
  if items then
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    check("p.ti → title",  labels["title"], true)
    check("p.ti → no id",  labels["id"],    nil)
  else
    log("FAIL: prefix filter callback not called"); fail = fail + 1
  end
end

log(string.format("\n=== RESULT: %d passed, %d failed ===", pass, fail))

vim.fn.writefile(out, "/tmp/poste_sql_diag.txt")
vim.cmd("qa!")
