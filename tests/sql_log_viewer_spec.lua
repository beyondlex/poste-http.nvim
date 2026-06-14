--- Tests for SQL execution log viewer.
local log = require("poste.sql.log_viewer")

describe("log viewer _format_time", function()
  it("formats as MM-DD HH:mm:ss", function()
    assert.equals("06-13 10:30:00", log._format_time("2026-06-13T10:30:00"))
  end)

  it("formats another timestamp", function()
    assert.equals("12-25 14:05:22", log._format_time("2025-12-25T14:05:22"))
  end)

  it("handles nil", function()
    assert.equals("??-?? ??:??:??", log._format_time(nil))
  end)

  it("handles non-ISO string", function()
    assert.equals("raw-time", log._format_time("raw-time"))
  end)
end)

describe("log viewer _preview_sql", function()
  it("returns empty string for nil", function()
    assert.equals("", log._preview_sql(nil, 50))
  end)

  it("returns SQL unchanged when under max length", function()
    assert.equals("SELECT 1", log._preview_sql("SELECT 1", 50))
  end)

  it("truncates with ellipsis when over max length", function()
    local long = string.rep("x", 100)
    local result = log._preview_sql(long, 10)
    -- "…" is 3 bytes in UTF-8
    assert.equals(12, #result)
    assert.equals("…", result:sub(-3))
  end)

  it("shows first line with ellipsis for multi-line SQL", function()
    assert.equals("a…", log._preview_sql("a\nb", 50))
  end)
end)

describe("log viewer _filter_matches", function()
  it("matches everything when filter is empty", function()
    assert.is_true(log._filter_matches({ table = "posts" }))
  end)

  it("matches by table name", function()
    log._set_filter_text("posts")
    assert.is_true(log._filter_matches({ table = "posts" }))
    assert.is_false(log._filter_matches({ table = "users" }))
    log._set_filter_text("")
  end)

  it("matches by status", function()
    log._set_filter_text("error")
    assert.is_true(log._filter_matches({ status = "error" }))
    assert.is_false(log._filter_matches({ status = "success" }))
    log._set_filter_text("")
  end)

  it("matches by connection", function()
    log._set_filter_text("pg-ecommerce")
    assert.is_true(log._filter_matches({ connection = "pg-ecommerce" }))
    log._set_filter_text("")
  end)

  it("matches by sql content", function()
    log._set_filter_text("DELETE")
    assert.is_true(log._filter_matches({ sql = "DELETE FROM posts" }))
    assert.is_false(log._filter_matches({ sql = "SELECT * FROM posts" }))
    log._set_filter_text("")
  end)
end)

describe("log viewer _count_detail_lines", function()
  it("counts minimal entry with just meta line", function()
    local entry = { connection = "c1", sql = "SELECT 1" }
    assert.equals(3, log._count_detail_lines(entry))
  end)

  it("counts entry with edit_summary", function()
    local entry = { connection = "c1", sql = "SELECT 1", edit_summary = { updates = 1 } }
    assert.equals(4, log._count_detail_lines(entry))
  end)

  it("counts entry with error", function()
    local entry = { connection = "c1", sql = "SELECT 1", error = "syntax error" }
    assert.equals(4, log._count_detail_lines(entry))
  end)

  it("counts multi-line SQL", function()
    local entry = { connection = "c1", sql = "line1\nline2\nline3" }
    assert.equals(5, log._count_detail_lines(entry))
  end)

  it("counts entry without connection (no meta line)", function()
    local entry = { sql = "SELECT 1" }
    assert.equals(2, log._count_detail_lines(entry))
  end)
end)

describe("log viewer _get_entry_at_line", function()
  before_each(function()
    log._set_entries({
      { table = "posts", connection = "c1", status = "success", sql = "SELECT 1" },
      { table = "users", connection = "c1", status = "error",   sql = "SELECT 2" },
      { table = "tags",  connection = "c2", status = "success", sql = "SELECT 3" },
    })
  end)

  it("returns nil for line 0", function()
    assert.is_nil(log._get_entry_at_line(0))
  end)

  it("returns entry 1 at line 1 (first data row)", function()
    assert.equals(1, log._get_entry_at_line(1))
  end)

  it("returns entry 2 at line 2", function()
    assert.equals(2, log._get_entry_at_line(2))
  end)

  it("returns entry 3 at line 3", function()
    assert.equals(3, log._get_entry_at_line(3))
  end)

  it("returns nil past last entry", function()
    assert.is_nil(log._get_entry_at_line(10))
  end)

  it("returns same entry when on detail lines (expanded)", function()
    log._set_entries({
      { table = "posts", connection = "c1", status = "success", sql = "SELECT 1" },
    })
    log._set_expanded(1, true)
    assert.equals(1, log._get_entry_at_line(2))
    assert.equals(1, log._get_entry_at_line(3))
  end)
end)

describe("log viewer _clean_sql", function()
  it("returns empty string for nil", function()
    assert.equals("", log._clean_sql(nil))
  end)

  it("keeps plain SQL unchanged", function()
    assert.equals("SELECT 1", log._clean_sql("SELECT 1"))
  end)

  it("strips -- @connection directive", function()
    local result = log._clean_sql("-- @connection my-blog\nSELECT 1")
    assert.equals("SELECT 1", result)
  end)

  it("strips -- @database directive", function()
    local result = log._clean_sql("-- @connection my-blog\n-- @database blog\nSELECT 1")
    assert.equals("SELECT 1", result)
  end)

  it("strips ### block markers", function()
    local result = log._clean_sql("-- @connection c\n\n###\nSELECT 1")
    assert.equals("SELECT 1", result)
  end)

  it("preserves multiple SQL statements", function()
    local result = log._clean_sql("-- @connection c\nSELECT 1;\nSELECT 2")
    assert.equals("SELECT 1;\nSELECT 2", result)
  end)

  it("strips leading newline from buffer extraction", function()
    local result = log._clean_sql("\nSELECT * FROM posts")
    assert.equals("SELECT * FROM posts", result)
  end)

  it("strips leading blank line before ###", function()
    local result = log._clean_sql("-- @connection c\n-- @database d\n\n###\nSELECT 1")
    assert.equals("SELECT 1", result)
  end)
end)

describe("log viewer _guess_table", function()
  it("extracts from SELECT", function()
    assert.equals("posts", log._guess_table("SELECT * FROM posts"))
  end)

  it("extracts from SELECT with schema", function()
    assert.equals("posts", log._guess_table("SELECT id, name FROM public.posts"))
  end)

  it("extracts from UPDATE", function()
    assert.equals("users", log._guess_table("UPDATE users SET name = 'x'"))
  end)

  it("extracts from JOIN", function()
    assert.equals("comments", log._guess_table("SELECT * FROM posts JOIN comments ON ..."))
  end)

  it("extracts from INSERT INTO", function()
    assert.equals("logs", log._guess_table("INSERT INTO logs (msg) VALUES ('hello')"))
  end)

  it("extracts from DELETE FROM", function()
    assert.equals("sessions", log._guess_table("DELETE FROM sessions WHERE expires < NOW()"))
  end)

  it("returns nil for no table reference", function()
    assert.is_nil(log._guess_table("BEGIN"))
  end)

  it("handles nil input", function()
    assert.is_nil(log._guess_table(nil))
  end)
end)

describe("log viewer _entry_table", function()
  it("uses entry.table when set", function()
    assert.equals("posts", log._entry_table({ table = "posts", sql = "SELECT 1" }))
  end)

  it("falls back to entry.table_name", function()
    assert.equals("users", log._entry_table({ table_name = "users", sql = "SELECT 1" }))
  end)

  it("guesses from SQL when no table field", function()
    assert.equals("posts", log._entry_table({ sql = "SELECT * FROM posts" }))
  end)

  it("returns nil when nothing matches", function()
    assert.is_nil(log._entry_table({ sql = "BEGIN" }))
  end)
end)
