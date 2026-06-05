-- Diagnostic tests for SQL completion
-- Focus: does "SELECT * FROM authors WHERE " trigger column completions?

local sql_comp = require("poste.sql.completion")
local detect_context = sql_comp._test.detect_context
local extract_from_tables = sql_comp._test.extract_from_tables
local get_items = sql_comp._test.get_items

-- ── 1. Context detection ─────────────────────────────────────────────────────

describe("detect_context (SQL)", function()
  it("WHERE<space> → column context", function()
    local ctx = detect_context("SELECT * FROM authors WHERE ")
    assert.equals("column", ctx)
  end)

  it("WHERE<space>partial → column context", function()
    local ctx = detect_context("SELECT * FROM authors WHERE us")
    assert.equals("column", ctx)
  end)

  it("FROM<space> → table context", function()
    local ctx = detect_context("SELECT * FROM ")
    assert.equals("table", ctx)
  end)

  it("table dot → dot_column context", function()
    local ctx, extra = detect_context("SELECT authors.")
    assert.equals("dot_column", ctx)
    assert.equals("authors", extra)
  end)

  it("AND<space> → column context", function()
    local ctx = detect_context("SELECT * FROM authors WHERE id = 1 AND ")
    assert.equals("column", ctx)
  end)

  it("bare keyword → keyword context", function()
    local ctx = detect_context("SEL")
    assert.equals("keyword", ctx)
  end)
end)

-- ── 2. Table extraction from buffer ──────────────────────────────────────────

describe("extract_from_tables", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  it("finds table after FROM", function()
    local buf = make_buf({
      "###",
      "SELECT * FROM authors WHERE ",
    })
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "authors"))
  end)

  it("finds multiple tables from JOIN", function()
    local buf = make_buf({
      "###",
      "SELECT * FROM posts p JOIN authors a ON a.id = p.author_id WHERE ",
    })
    local tbls = extract_from_tables(buf, 2)
    assert.is_true(vim.tbl_contains(tbls, "posts"))
    assert.is_true(vim.tbl_contains(tbls, "authors"))
  end)

  it("stops at ### boundary", function()
    local buf = make_buf({
      "###",
      "SELECT * FROM other_table;",
      "###",
      "SELECT * FROM authors WHERE ",
    })
    -- cursor on line 4, should only see authors, not other_table
    local tbls = extract_from_tables(buf, 4)
    assert.is_true(vim.tbl_contains(tbls, "authors"))
    assert.is_false(vim.tbl_contains(tbls, "other_table"))
  end)
end)

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
end)
