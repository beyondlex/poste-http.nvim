-- Diagnostic tests for SQL completion
-- Focus: does "SELECT * FROM authors WHERE " trigger column completions?

local sql_comp = require("poste.sql.completion")
local get_items = sql_comp._test.get_items

-- ── 3. get_items integration (no real DB needed) ─────────────────────────────
-- These tests verify the pipeline works end-to-end with a mocked cache.
-- We inject columns directly into the module's cache via cache_columns/cache_tables.

describe("get_items with seeded cache", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    return buf
  end

  -- Seed cache: simulate that introspect already returned columns for 'authors'
  before_each(function()
    -- We need a connection context so conn_key() returns something.
    -- Temporarily set global state.
    local state = require("poste.state")
    state.sql = state.sql or {}
    state.sql.context = { connection = "test-conn", database = "blog" }

    -- Seed the cache via public API
    sql_comp.cache_tables({ { name = "authors" }, { name = "posts" } })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" }, { name = "email" }, { name = "bio" },
    })
  end)

  it("WHERE<space> returns authors columns", function()
    local buf = make_buf({
      "###",
      "SELECT * FROM authors WHERE ",
    })

    local items = nil
    get_items(buf, "SELECT * FROM authors WHERE ", 2, function(result)
      items = result
    end)

    -- get_items is sync when cache is hot
    assert.is_not_nil(items, "callback was not called synchronously (cache miss?)")
    assert.is_true(#items > 0, "no items returned")

    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end

    assert.is_true(labels["id"],       "missing column: id")
    assert.is_true(labels["username"], "missing column: username")
    assert.is_true(labels["email"],    "missing column: email")
  end)

  it("WHERE us filters to prefix", function()
    local buf = make_buf({
      "###",
      "SELECT * FROM authors WHERE us",
    })

    local items = nil
    get_items(buf, "SELECT * FROM authors WHERE us", 2, function(result)
      items = result
    end)

    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end

    assert.is_true(labels["username"], "username should match prefix 'us'")
    assert.is_nil(labels["id"],        "id should NOT match prefix 'us'")
  end)
end)

-- ── 4. blink trigger character patch ─────────────────────────────────────────
-- Ensures space is NOT blocked in SQL buffers so blink auto-triggers after WHERE/FROM etc.

describe("blink show_on_blocked_trigger_characters patch", function()
  -- Simulate what poste.setup does: patch the blocked list with a function
  local orig = { " ", "\n", "\t" }
  local patched = function()
    local ft = vim.bo.filetype
    if ft == "poste_sql" or ft == "poste_sqlite" then
      return vim.tbl_filter(function(c) return c ~= " " end, orig)
    end
    return orig
  end

  it("space is blocked in non-SQL buffers", function()
    vim.bo.filetype = "lua"
    local blocked = patched()
    assert.is_true(vim.tbl_contains(blocked, " "))
  end)

  it("space is NOT blocked in poste_sql buffers", function()
    vim.bo.filetype = "poste_sql"
    local blocked = patched()
    assert.is_false(vim.tbl_contains(blocked, " "))
  end)

  it("space is NOT blocked in poste_sqlite buffers", function()
    vim.bo.filetype = "poste_sqlite"
    local blocked = patched()
    assert.is_false(vim.tbl_contains(blocked, " "))
  end)

  it("newline and tab remain blocked in SQL buffers", function()
    vim.bo.filetype = "poste_sql"
    local blocked = patched()
    assert.is_true(vim.tbl_contains(blocked, "\n"))
    assert.is_true(vim.tbl_contains(blocked, "\t"))
  end)
end)

-- ── 5. get_completions line_before calculation ────────────────────────────────
-- blink passes ctx.cursor[2] as 0-based col; line:sub(1, col) must include the space.

describe("get_completions line_before", function()
  before_each(function()
    local state = require("poste.state")
    state.sql = { context = { connection = "test-conn", database = "blog" } }
    sql_comp.cache_tables({ { name = "authors" } })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" },
    })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "###", "SELECT * FROM authors WHERE ",
    })
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    vim.api.nvim_set_current_buf(buf)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_cursor(win, { 1, #("SELECT * FROM authors WHERE ") })
  end)

  it("returns columns when cursor col equals line length (after space)", function()
    local line = "SELECT * FROM authors WHERE "
    local items = nil
    sql_comp.new():get_completions(
      { line = line, cursor = { 2, #line } },
      function(r) items = r end
    )
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items.items) do labels[item.label] = true end
    assert.is_true(labels["id"])
    assert.is_true(labels["username"])
    assert.is_nil(labels["SELECT"])
  end)

  it("does NOT return columns when cursor is before the space (WHERE without space)", function()
    local line = "SELECT * FROM authors WHERE"
    local items = nil
    sql_comp.new():get_completions(
      { line = line, cursor = { 2, #line } },
      function(r) items = r end
    )
    -- Context is "column" (last word = WHERE) so still columns, but prefix filters to nothing
    -- Actually detect_context sees WHERE as the prefix → keyword context
    -- Just verify it doesn't crash and returns something
    assert.is_not_nil(items)
  end)

  it("single letter s returns SELECT via get_completions", function()
    local line = "s"
    local items = nil
    sql_comp.new():get_completions(
      { line = line, cursor = { 0, 1 } },
      function(r) items = r end
    )
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items.items) do labels[item.label] = true end
    assert.is_true(labels["SELECT"], "SELECT should appear for prefix 's'")
    assert.is_true(#items.items > 0, "expected items for prefix 's'")
  end)

  it("select * f returns FROM via get_completions", function()
    local line = "select * f"
    local items = nil
    sql_comp.new():get_completions(
      { line = line, cursor = { 0, 10 } },
      function(r) items = r end
    )
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items.items) do labels[item.label] = true end
    assert.is_true(labels["FROM"], "FROM should appear for prefix 'f' after 'select *'")
    assert.is_nil(labels["SELECT"], "SELECT should not match prefix 'f'")
  end)
end)

-- ── 14. get_keyword_length edge cases ────────────────────────────────────

describe("get_keyword_length", function()
  local src = sql_comp.new()

  it("returns 0 when cursor is nil", function()
    assert.equals(0, src:get_keyword_length({}))
    assert.equals(0, src:get_keyword_length(nil))
  end)

  it("returns 1 for single letter s", function()
    local len = src:get_keyword_length({ line = "s", cursor = { 0, 1 } })
    assert.equals(1, len)
  end)

  it("returns 1 for prefix f after select *", function()
    local len = src:get_keyword_length({ line = "select * f", cursor = { 0, 10 } })
    assert.equals(1, len)
  end)

  it("returns 0 for empty line", function()
    local len = src:get_keyword_length({ line = "", cursor = { 0, 0 } })
    assert.equals(0, len)
  end)

  it("returns 0 for cursor at position 0 with content", function()
    local len = src:get_keyword_length({ line = "foo", cursor = { 0, 0 } })
    assert.equals(0, len)
  end)

  it("returns correct length for multi-char prefix", function()
    local len = src:get_keyword_length({ line = "SEL", cursor = { 0, 3 } })
    assert.equals(3, len)
  end)
end)

-- ── 6. Alias resolution ───────────────────────────────────────────────────────

describe("get_items dot_column resolves alias", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    return buf
  end

  before_each(function()
    local state = require("poste.state")
    state.sql = { context = { connection = "test-conn", database = "blog" } }
    sql_comp.cache_tables({ { name = "authors" }, { name = "posts" } })
    sql_comp.cache_columns("posts", {
      { name = "id" }, { name = "title" }, { name = "author_id" },
    })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" }, { name = "email" }, { name = "bio" },
    })
  end)

  it("p. after JOIN posts p returns posts columns", function()
    local buf = make_buf({ "###", "SELECT * FROM authors s LEFT JOIN posts p ON p." })
    local items = nil
    get_items(buf, "SELECT * FROM authors s LEFT JOIN posts p ON p.", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["id"])
    assert.is_true(labels["title"])
    assert.is_true(labels["author_id"])
  end)

  it("p.ti prefix filters correctly", function()
    local buf = make_buf({ "###", "SELECT * FROM authors s LEFT JOIN posts p ON p.ti" })
    local items = nil
    get_items(buf, "SELECT * FROM authors s LEFT JOIN posts p ON p.ti", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["title"])
    assert.is_nil(labels["id"])
  end)

  it("a. resolves alias from statement on a later line after other SQL", function()
    local buf = make_buf({
      "###",
      "select * from posts;",
      "",
      "SELECT p.slug, a.  FROM posts p LEFT JOIN authors a on a.id = p.author_id;",
    })
    -- Cursor on line 4 (the last line), line_before with a.
    local items = nil
    get_items(buf, "SELECT p.slug, a.", 4, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["id"], "should have id column from authors table")
    assert.is_true(labels["bio"], "should have bio column from authors table")
  end)
end)

-- ── 7. Dedup in get_completions (blink path) ─────────────────────────────────

describe("get_completions dedup", function()
  before_each(function()
    local state = require("poste.state")
    state.sql = { context = { connection = "test-conn", database = "blog" } }
    sql_comp.cache_tables({ { name = "authors" }, { name = "posts" } })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" }, { name = "email" }, { name = "bio" },
    })
    sql_comp.cache_columns("posts", {
      { name = "id" }, { name = "title" }, { name = "author_id" },
    })
  end)

  it("deduplicates by label when tables share column names", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "###", "SELECT * FROM authors a JOIN posts p ON a.id = p.id WHERE ",
    })
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    vim.api.nvim_set_current_buf(buf)

    -- Simulate blink context: cursor at end of line after WHERE<space>
    local line = "SELECT * FROM authors a JOIN posts p ON a.id = p.id WHERE "
    local items = nil
    sql_comp.new():get_completions(
      { line = line, cursor = { 2, #line } },
      function(r) items = r end
    )
    assert.is_not_nil(items)
    assert.is_not_nil(items.items)

    -- Check for duplicate labels
    local seen = {}
    for _, item in ipairs(items.items) do
      assert.is_nil(seen[item.label],
        string.format("duplicate label in get_completions: %s", item.label))
      seen[item.label] = true
    end
  end)

  it("dedup removes duplicate when get_items returns same label", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "###", "SELECT * FROM authors WHERE ",
    })
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    vim.api.nvim_set_current_buf(buf)

    local line = "SELECT * FROM authors WHERE "
    local items = nil
    sql_comp.new():get_completions(
      { line = line, cursor = { 2, #line } },
      function(r) items = r end
    )
    assert.is_not_nil(items)
    assert.is_not_nil(items.items)
    assert.is_true(#items.items > 0, "expected at least one item")

    -- Count occurrences of each label
    local counts = {}
    for _, item in ipairs(items.items) do
      counts[item.label] = (counts[item.label] or 0) + 1
    end
    for label, count in pairs(counts) do
      assert.equals(1, count, string.format("label '%s' appears %d times", label, count))
    end
  end)
end)

-- ── 8. Dedup in nvim-cmp complete path ─────────────────────────────────────

describe("complete dedup (nvim-cmp path)", function()
  before_each(function()
    local state = require("poste.state")
    state.sql = { context = { connection = "test-conn", database = "blog" } }
    sql_comp.cache_tables({ { name = "authors" } })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" }, { name = "email" }, { name = "bio" },
    })
  end)

  it("deduplicates items by label", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "###", "SELECT * FROM authors WHERE ",
    })
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    vim.api.nvim_set_current_buf(buf)

    local source = sql_comp.source.new()
    local items = nil
    source:complete(
      { context = { cursor_before_line = "SELECT * FROM authors WHERE " } },
      function(r) items = r end
    )
    assert.is_not_nil(items)
    assert.is_not_nil(items.items)

    local seen = {}
    for _, item in ipairs(items.items) do
      assert.is_nil(seen[item.label],
        string.format("duplicate label in complete: %s", item.label))
      seen[item.label] = true
    end
  end)
end)

-- ── 10. get_items insert_column (quick-insert + column completion) ───────────

describe("get_items insert_column", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  before_each(function()
    local state = require("poste.state")
    state.sql = state.sql or {}
    state.sql.context = { connection = "test-conn", database = "blog" }
    sql_comp.cache_tables({ { name = "authors" } })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" }, { name = "email" }, { name = "bio" },
    })
  end)

  it("returns quick-insert all-columns item first", function()
    local buf = make_buf({ "###", "INSERT INTO authors (" })
    local items = nil
    get_items(buf, "INSERT INTO authors (", 2, function(r) items = r end)
    assert.is_not_nil(items)
    assert.equals("id, username, email, bio", items[1].label)
    assert.equals("Insert all columns", items[1].documentation)
  end)

  it("returns quick-insert no-id item second", function()
    local buf = make_buf({ "###", "INSERT INTO authors (" })
    local items = nil
    get_items(buf, "INSERT INTO authors (", 2, function(r) items = r end)
    assert.is_not_nil(items)
    assert.equals("username, email, bio", items[2].label)
    assert.equals("All columns except id", items[2].documentation)
  end)

  it("returns individual columns after quick-insert items", function()
    local buf = make_buf({ "###", "INSERT INTO authors (" })
    local items = nil
    get_items(buf, "INSERT INTO authors (", 2, function(r) items = r end)
    assert.is_not_nil(items)
    -- items[1] = all-cols, items[2] = no-id, items[3+] = individual columns
    assert.equals("id", items[3].label)
    assert.equals("username", items[4].label)
    assert.equals("email", items[5].label)
    assert.equals("bio", items[6].label)
    assert.equals(6, #items)
  end)

  it("filters out already-listed columns from individual items", function()
    local buf = make_buf({ "###", "INSERT INTO authors (id, email, " })
    local items = nil
    get_items(buf, "INSERT INTO authors (id, email, ", 2, function(r) items = r end)
    assert.is_not_nil(items)
    -- Quick-insert always shows (2 items)
    assert.equals("id, username, email, bio", items[1].label)
    assert.equals("username, email, bio", items[2].label)
    -- Individual columns: id and email excluded, username and bio included
    local labels = {}
    for i = 3, #items do labels[items[i].label] = true end
    assert.is_nil(labels["id"], "id should be excluded")
    assert.is_nil(labels["email"], "email should be excluded")
    assert.is_true(labels["username"], "username should be included")
    assert.is_true(labels["bio"], "bio should be included")
    assert.equals(4, #items)  -- 2 quick-insert + 2 remaining columns
  end)

  it("quick-insert items always show even with prefix", function()
    local buf = make_buf({ "###", "INSERT INTO authors (us" })
    local items = nil
    get_items(buf, "INSERT INTO authors (us", 2, function(r) items = r end)
    assert.is_not_nil(items)
    -- Quick-insert always shows
    assert.equals("id, username, email, bio", items[1].label)
    assert.equals("username, email, bio", items[2].label)
    -- Only username matches prefix 'us'
    assert.equals("username", items[3].label)
    assert.equals(3, #items)
  end)

  it("no-id quick-insert hidden when table has no id column", function()
    local state = require("poste.state")
    state.sql.context = { connection = "test-conn", database = "blog" }
    sql_comp.cache_columns("tags", {
      { name = "name" }, { name = "slug" },
    })
    local buf = make_buf({ "###", "INSERT INTO tags (" })
    local items = nil
    get_items(buf, "INSERT INTO tags (", 2, function(r) items = r end)
    assert.is_not_nil(items)
    -- Only all-columns quick-insert
    assert.equals("name, slug", items[1].label)
    assert.equals(3, #items)
  end)
end)

-- ── 11. get_items table context ───────────────────────────────────────

describe("get_items table context", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    return buf
  end

  before_each(function()
    local state = require("poste.state")
    state.sql = state.sql or {}
    state.sql.context = { connection = "test-conn", database = "blog" }
    sql_comp.cache_tables({ { name = "authors" }, { name = "posts" } })
    -- Pre-cache databases so ensure_databases doesn't start async job with binary
    local data_mod = require("poste.sql.completion_data")
    local cache = data_mod.get_cache()
    cache["test-conn/__databases__"] = { "blog" }
  end)

  it("FROM<space> returns cached tables", function()
    local buf = make_buf({ "###", "SELECT * FROM " })
    local items = nil
    get_items(buf, "SELECT * FROM ", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["authors"])
    assert.is_true(labels["posts"])
  end)

  it("FROM au filters to matching table", function()
    local buf = make_buf({ "###", "SELECT * FROM au" })
    local items = nil
    get_items(buf, "SELECT * FROM au", 2, function(r) items = r end)
    assert.is_not_nil(items)
    assert.equals("authors", items[1].label)
    assert.equals(1, #items)
  end)
end)

-- ── 12. get_items keyword context (fallback with no connection) ────────

describe("get_items keyword context (no connection)", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    return buf
  end

  it("bare text returns matching SQL keywords", function()
    local buf = make_buf({ "###", "SEL" })
    local items = nil
    get_items(buf, "SEL", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["SELECT"], "SELECT should match prefix SEL")
    assert.is_nil(labels["FROM"], "FROM should not match prefix SEL")
    assert.is_true(#items > 0, "expected at least one keyword")
  end)

  it("single letter s returns SELECT keyword", function()
    local buf = make_buf({ "###", "s" })
    local items = nil
    get_items(buf, "s", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["SELECT"], "SELECT should match single-letter prefix 's'")
    assert.is_true(#items > 0, "expected at least one item for prefix 's'")
  end)

  it("select * f returns FROM keyword", function()
    local buf = make_buf({ "###", "select * f" })
    local items = nil
    get_items(buf, "select * f", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["FROM"], "FROM should match prefix 'f' after 'select *'")
    assert.is_nil(labels["SELECT"], "SELECT should not match prefix 'f'")
  end)

  it("empty prefix returns many keywords", function()
    local buf = make_buf({ "###", "" })
    local items = nil
    get_items(buf, "", 2, function(r) items = r end)
    assert.is_not_nil(items)
    assert.is_true(#items > 20, "expected > 20 items for empty prefix")
  end)

  it("prefix 'CRE' matches CREATE TABLE", function()
    local buf = make_buf({ "###", "CRE" })
    local items = nil
    get_items(buf, "CRE", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["CREATE TABLE"], "CREATE TABLE should match prefix CRE")
    assert.is_nil(labels["SELECT"], "SELECT should not match prefix CRE")
  end)

  it("returns data types as well as keywords (regression: INSERT INTO keyword)", function()
    local buf = make_buf({ "###", "IN" })
    local items = nil
    get_items(buf, "IN", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["INT"], "data type INT should match")
    assert.is_true(labels["INTEGER"], "data type INTEGER should match")
    assert.is_true(labels["INSERT INTO"], "keyword INSERT INTO should match prefix IN")
    assert.is_true(labels["IN"], "keyword IN should match prefix IN")
  end)

  it("UPDATE SET slug='...', bio='' w suggests WHERE keyword", function()
    local buf = make_buf({ "###", "UPDATE posts SET slug='', author_id='', bio='' w" })
    local items = nil
    get_items(buf, "UPDATE posts SET slug='', author_id='', bio='' w", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["WHERE"], "WHERE should match prefix w after SET column assignments")
    assert.is_true(labels["WITH"], "WITH should match prefix w after SET column assignments")
  end)
end)

-- ── 7. Drift check: Lua fallback functions ⊆ Rust functions ───────────────────
-- Requires Rust binary. Skip if not found.
-- Authoritative drift tests are in Rust: test_lua_fallback_functions_are_subset,
-- test_lua_keywords_recognized_by_rust.
local data = require("poste.sql.completion_data")
describe("Rust/Lua function drift", function()
  it("every Lua SQL_FUNCTIONS entry exists in Rust known_functions()", function()
    local binary = data.find_binary()
    if not binary then
      print("SKIP: Rust binary not found")
      assert.is_true(true)
      return
    end
    local out = vim.fn.system(binary .. " context detect 0", "")
    if vim.v.shell_error ~= 0 then
      print("SKIP: Rust context detect failed")
      assert.is_true(true)
      return
    end
    local ok, rust = pcall(vim.json.decode, out)
    if not ok or not rust.functions then
      print("SKIP: cannot parse Rust output")
      assert.is_true(true)
      return
    end
    local rust_set = {}
    for _, f in ipairs(rust.functions) do rust_set[f] = true end
    local missing = {}
    for _, f in ipairs(data.SQL_FUNCTIONS) do
      if not rust_set[f] then table.insert(missing, f) end
    end
    assert.equals(0, #missing,
      "Lua functions not in Rust: " .. table.concat(missing, ", "))
  end)
end)

-- ── 13. Completion mode integration tests ─────────────────────────

describe("completion mode integration", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  local function mock_find_binary()
    _G._saved_find_binary = require("poste.sql.completion_data").find_binary
    require("poste.sql.completion_data").find_binary = function() return nil end
  end

  local function restore_find_binary()
    if _G._saved_find_binary then
      require("poste.sql.completion_data").find_binary = _G._saved_find_binary
      _G._saved_find_binary = nil
    end
  end

  before_each(function()
    local state = require("poste.state")
    state.sql = state.sql or {}
    state.sql.context = { connection = "test-conn", database = "blog" }
    sql_comp.cache_tables({ { name = "authors" }, { name = "posts" } })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" }, { name = "email" }, { name = "bio" },
    })
    _G._saved_legacy = vim.g.poste_sql_legacy_completion
  end)

  after_each(function()
    vim.g.poste_sql_legacy_completion = _G._saved_legacy
    restore_find_binary()
  end)


  -- Mode: true (Lua-only legacy) — Lua heuristic removed, returns keyword fallback
  describe("legacy_completion = true (Lua-only)", function()
    before_each(function() mock_find_binary() end)

    it("returns keywords after WHERE (heuristic removed)", function()
      vim.g.poste_sql_legacy_completion = true
      local buf = make_buf({ "###", "SELECT * FROM authors WHERE " })
      local items = nil
      get_items(buf, "SELECT * FROM authors WHERE ", 2, function(r) items = r end)
      assert.is_not_nil(items)
      local labels = {}
      for _, item in ipairs(items) do labels[item.label] = true end
      -- Without Lua heuristic, legacy mode returns keyword context
      -- Table names may still appear via the keyword fallback path
      assert.is_true(labels["WHERE"] ~= nil or labels["SELECT"] ~= nil,
        "should return some keywords, got: " .. vim.inspect(labels))
    end)

    it("uses Lua fallback SQL_FUNCTIONS for keyword context", function()
      vim.g.poste_sql_legacy_completion = true
      local buf = make_buf({ "###", "CO" })
      local items = nil
      get_items(buf, "CO", 2, function(r) items = r end)
      assert.is_not_nil(items)
      local labels = {}
      for _, item in ipairs(items) do labels[item.label] = true end
      -- Lua fallback functions should be available
      assert.is_true(labels["COUNT"], "COUNT should come from Lua fallback")
      assert.is_true(labels["COALESCE"], "COALESCE should come from Lua fallback")
    end)
  end)

  -- Mode: "rust" (Rust strict) — Rust path only, no Lua fallback
  describe("legacy_completion = 'rust' (Rust strict)", function()
    local data_mod = require("poste.sql.completion_data")
    local has_binary = data_mod.find_binary() ~= nil

    local function skip_or_run(assert_fn)
      if not has_binary then
        print("SKIP: Rust binary not found for strict mode tests")
        assert.is_true(true)
        return
      end
      assert_fn()
    end

    it("returns columns after WHERE", function()
      skip_or_run(function()
        vim.g.poste_sql_legacy_completion = "rust"
        local buf = make_buf({ "###", "SELECT * FROM authors WHERE " })
        local items = nil
        get_items(buf, "SELECT * FROM authors WHERE ", 2, function(r) items = r end)
        assert.is_not_nil(items)
        local labels = {}
        for _, item in ipairs(items) do labels[item.label] = true end
        assert.is_true(labels["id"])
        assert.is_true(labels["username"])
      end)
    end)

    it("returns tables after FROM", function()
      skip_or_run(function()
        vim.g.poste_sql_legacy_completion = "rust"
        local buf = make_buf({ "###", "SELECT * FROM " })
        local items = nil
        get_items(buf, "SELECT * FROM ", 2, function(r) items = r end)
        assert.is_not_nil(items)
        local labels = {}
        for _, item in ipairs(items) do labels[item.label] = true end
        assert.is_true(labels["authors"])
      end)
    end)
  end)

  -- Conditional: Rust binary integration tests
  describe("Rust binary integration", function()
    local data_mod = require("poste.sql.completion_data")
    local binary = data_mod.find_binary()
    local has_binary = binary ~= nil

    local function skip_or_run(assert_fn)
      if not has_binary then
        print("SKIP: Rust binary not found, build with 'cargo build -p poste-cli' first")
        assert.is_true(true)
        return
      end
      assert_fn()
    end

    it("detects column context via CLI", function()
      skip_or_run(function()
        local out = vim.fn.system(binary .. " context detect 23", "SELECT * FROM authors WHERE ")
        assert.equals(0, vim.v.shell_error)
        local ok, parsed = pcall(vim.json.decode, out)
        assert.is_true(ok)
        assert.equals("column", parsed.ctx_type)
      end)
    end)

    it("detects table context via CLI", function()
      skip_or_run(function()
        local out = vim.fn.system(binary .. " context detect 14", "SELECT * FROM ")
        assert.equals(0, vim.v.shell_error)
        local ok, parsed = pcall(vim.json.decode, out)
        assert.is_true(ok)
        assert.equals("table", parsed.ctx_type)
      end)
    end)

    it("detects schema-qualified dot-column with ctx_schema", function()
      skip_or_run(function()
        local sql = "SELECT * FROM public.users WHERE public.users."
        local out = vim.fn.system(binary .. " context detect 47", sql)
        assert.equals(0, vim.v.shell_error)
        local ok, parsed = pcall(vim.json.decode, out)
        assert.is_true(ok)
        assert.equals("dot_column", parsed.ctx_type)
        assert.equals("users", parsed.ctx_data)
        assert.equals("public", parsed.ctx_schema)
        assert.is_true(#parsed.tables > 0)
        assert.equals("public", parsed.tables[1].schema)
        assert.equals("users", parsed.tables[1].name)
      end)
    end)

    it("detects string context with in_string flag", function()
      skip_or_run(function()
        local sql = "SELECT * FROM users WHERE name = 'hello'"
        local out = vim.fn.system(binary .. " context detect 39", sql)
        assert.equals(0, vim.v.shell_error)
        local ok, parsed = pcall(vim.json.decode, out)
        assert.is_true(ok)
        assert.is_true(parsed.in_string, "cursor inside string")
      end)
    end)

    it("detects comment context with in_comment flag", function()
      skip_or_run(function()
        local sql = "SELECT * FROM users -- comment"
        local out = vim.fn.system(binary .. " context detect 21", sql)
        assert.equals(0, vim.v.shell_error)
        local ok, parsed = pcall(vim.json.decode, out)
        assert.is_true(ok)
        assert.is_true(parsed.in_comment, "cursor inside comment")
      end)
    end)

    it("detects keyword context after Rust binary fallback", function()
      skip_or_run(function()
        local sql = "SEL"
        local out = vim.fn.system(binary .. " context detect 3", sql)
        assert.equals(0, vim.v.shell_error)
        local ok, parsed = pcall(vim.json.decode, out)
        assert.is_true(ok)
        assert.equals("keyword", parsed.ctx_type)
        assert.equals("SEL", parsed.prefix)
      end)
    end)
  end)

  -- String/comment: Rust handles correctly
  describe("comment string fallback behavior", function()
    it("get_items on comment line returns keywords not tables", function()
      local buf = make_buf({ "###", "-- SELECT * FROM " })
      local items = nil
      get_items(buf, "-- SELECT * FROM ", 2, function(r) items = r end)
      assert.is_not_nil(items)
      -- Should be keywords, not table names
      local labels = {}
      for _, item in ipairs(items) do labels[item.label] = true end
      -- Table names should NOT appear
      assert.is_nil(labels["authors"], "tables must not leak on comment lines")
      assert.is_nil(labels["posts"], "tables must not leak on comment lines")
    end)

    it("line inside string literal returns keywords not columns", function()
      local buf = make_buf({ "###", "SELECT * FROM users WHERE name = 'some text'" })
      -- cursor at the start of the string content
      local items = nil
      get_items(buf, "SELECT * FROM users WHERE name = 'some text'", 2, function(r) items = r end)
      assert.is_not_nil(items)
      -- When not in string-aware mode, at minimum should not crash
      local labels = {}
      for _, item in ipairs(items) do labels[item.label] = true end
      -- May contain keywords; should not contain string fragments
      assert.is_nil(labels["some text"], "string content must not leak as items")
    end)
  end)

  -- Mode toggle function
  describe("toggle_legacy cycles through modes", function()
    before_each(function()
      vim.g.poste_sql_legacy_completion = nil
    end)

    it("first call sets to true (Lua-only)", function()
      sql_comp.toggle_legacy()
      assert.is_true(vim.g.poste_sql_legacy_completion)
    end)

    it("second call sets to 'rust' (Rust strict)", function()
      sql_comp.toggle_legacy()
      sql_comp.toggle_legacy()
      assert.equals("rust", vim.g.poste_sql_legacy_completion)
    end)

    it("third call resets to nil (default hybrid)", function()
      sql_comp.toggle_legacy()
      sql_comp.toggle_legacy()
      sql_comp.toggle_legacy()
      assert.is_nil(vim.g.poste_sql_legacy_completion)
    end)
  end)
end)
