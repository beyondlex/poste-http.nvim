--- Tests for SQL dataset editor: value conversion, validation, edit state, DML generation.
--- Covers UT1-UT11 from dataset-ui-edit-impl.md §5.

local editor = require("poste.sql.editor")
local edit_commit = require("poste.sql.edit_commit")

---------------------------------------------------------------------------
-- UT1: parse_value — various input → value conversions
---------------------------------------------------------------------------
describe("parse_value", function()
  it("empty input on non-nil old_val → vim.NIL (NULL)", function()
    local result = editor.parse_value("", "hello")
    assert.equals(vim.NIL, result)
  end)

  it("empty input on nil old_val → nil (no change)", function()
    local result = editor.parse_value("", nil)
    assert.is_nil(result)
  end)

  it("'' (two single quotes) → empty string", function()
    local result = editor.parse_value("''", "old")
    assert.equals("", result)
  end)

  it("(NULL) → vim.NIL", function()
    local result = editor.parse_value("(NULL)", "old")
    assert.equals(vim.NIL, result)
  end)

  it("NULL → vim.NIL", function()
    local result = editor.parse_value("NULL", "old")
    assert.equals(vim.NIL, result)
  end)

  it("pure number '42' → number 42", function()
    local result = editor.parse_value("42", "old")
    assert.equals(42, result)
    assert.equals("number", type(result))
  end)

  it("negative number '-3.14' → number -3.14", function()
    local result = editor.parse_value("-3.14", "old")
    assert.equals(-3.14, result)
  end)

  it("'0' → number 0", function()
    local result = editor.parse_value("0", "old")
    assert.equals(0, result)
  end)

  it("'true' → boolean true", function()
    local result = editor.parse_value("true", "old")
    assert.is_true(result)
  end)

  it("'false' → boolean false", function()
    local result = editor.parse_value("false", "old")
    assert.is_false(result)
  end)

  it("plain string → string", function()
    local result = editor.parse_value("hello world", "old")
    assert.equals("hello world", result)
  end)

  it("string with spaces → string", function()
    local result = editor.parse_value("  spaced  ", "old")
    assert.equals("  spaced  ", result)
  end)
end)

---------------------------------------------------------------------------
-- UT2: validate_value — type interception
---------------------------------------------------------------------------
describe("validate_value", function()
  local function col(ctype)
    return { ctype = ctype }
  end

  describe("integer types", function()
    it("accepts valid integer", function()
      local ok, err = editor.validate_value(42, col("integer"))
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("accepts integer string parsed to number", function()
      local ok, err = editor.validate_value(42, col("int"))
      assert.is_true(ok)
    end)

    it("accepts bigint", function()
      local ok = editor.validate_value(9999999, col("bigint"))
      assert.is_true(ok)
    end)

    it("accepts smallint", function()
      local ok = editor.validate_value(1, col("smallint"))
      assert.is_true(ok)
    end)

    it("rejects float for integer", function()
      local ok, err = editor.validate_value(3.14, col("integer"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)

    it("rejects string for integer", function()
      local ok, err = editor.validate_value("abc", col("integer"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)
  end)

  describe("numeric/float types", function()
    it("accepts float for numeric", function()
      local ok = editor.validate_value(3.14, col("numeric"))
      assert.is_true(ok)
    end)

    it("accepts integer for float", function()
      local ok = editor.validate_value(42, col("float"))
      assert.is_true(ok)
    end)

    it("accepts decimal", function()
      local ok = editor.validate_value(99.99, col("decimal"))
      assert.is_true(ok)
    end)

    it("accepts real", function()
      local ok = editor.validate_value(1.0, col("real"))
      assert.is_true(ok)
    end)

    it("rejects string for numeric", function()
      local ok, err = editor.validate_value("abc", col("numeric"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)
  end)

  describe("boolean types", function()
    it("accepts true", function()
      local ok = editor.validate_value(true, col("boolean"))
      assert.is_true(ok)
    end)

    it("accepts false", function()
      local ok = editor.validate_value(false, col("bool"))
      assert.is_true(ok)
    end)

    it("accepts number 1 as boolean", function()
      local ok = editor.validate_value(1, col("boolean"))
      assert.is_true(ok)
    end)

    it("accepts number 0 as boolean", function()
      local ok = editor.validate_value(0, col("boolean"))
      assert.is_true(ok)
    end)

    it("rejects string 'maybe' for boolean", function()
      local ok, err = editor.validate_value("maybe", col("boolean"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)

    it("rejects number 2 for boolean", function()
      local ok, err = editor.validate_value(2, col("boolean"))
      assert.is_false(ok)
    end)
  end)

  describe("date/timestamp types", function()
    it("accepts ISO date string", function()
      local ok = editor.validate_value("2026-06-13", col("date"))
      assert.is_true(ok)
    end)

    it("accepts ISO datetime string", function()
      local ok = editor.validate_value("2026-06-13T10:30:00", col("timestamp"))
      assert.is_true(ok)
    end)

    it("accepts timestamptz", function()
      local ok = editor.validate_value("2026-06-13T10:30:00+08:00", col("timestamptz"))
      assert.is_true(ok)
    end)

    it("rejects invalid date", function()
      local ok, err = editor.validate_value("notadate", col("date"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)

    it("rejects random string for timestamp", function()
      local ok, err = editor.validate_value("hello", col("timestamp"))
      assert.is_false(ok)
    end)
  end)

  describe("json/jsonb types", function()
    it("accepts valid JSON object", function()
      local val = { a = 1 }
      local ok = editor.validate_value(val, col("json"))
      assert.is_true(ok)
    end)

    it("accepts valid JSON array", function()
      local val = { 1, 2, 3 }
      local ok = editor.validate_value(val, col("jsonb"))
      assert.is_true(ok)
    end)

    it("accepts string for json (passthrough)", function()
      local ok = editor.validate_value('{"a":1}', col("json"))
      assert.is_true(ok)
    end)

    it("rejects number for json", function()
      local ok, err = editor.validate_value(42, col("json"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)
  end)

  describe("uuid type", function()
    it("accepts valid UUID", function()
      local ok = editor.validate_value("550e8400-e29b-41d4-a716-446655440000", col("uuid"))
      assert.is_true(ok)
    end)

    it("rejects invalid UUID", function()
      local ok, err = editor.validate_value("bad", col("uuid"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)

    it("rejects short UUID", function()
      local ok = editor.validate_value("550e8400-e29b-41d4", col("uuid"))
      assert.is_false(ok)
    end)
  end)

  describe("text/varchar/char types", function()
    it("accepts any string for text", function()
      local ok = editor.validate_value("anything goes", col("text"))
      assert.is_true(ok)
    end)

    it("accepts any string for varchar", function()
      local ok = editor.validate_value("hello", col("varchar"))
      assert.is_true(ok)
    end)

    it("accepts any string for char", function()
      local ok = editor.validate_value("x", col("char"))
      assert.is_true(ok)
    end)

    it("accepts empty string", function()
      local ok = editor.validate_value("", col("text"))
      assert.is_true(ok)
    end)
  end)

  describe("NULL values", function()
    it("NULL is always valid", function()
      local ok = editor.validate_value(vim.NIL, col("integer"))
      assert.is_true(ok)
    end)

    it("nil is always valid", function()
      local ok = editor.validate_value(nil, col("uuid"))
      assert.is_true(ok)
    end)
  end)
end)

---------------------------------------------------------------------------
-- UT3: is_editable_field — binary/geometry/etc skip
---------------------------------------------------------------------------
describe("is_editable_field", function()
  it("allows text", function()
    assert.is_true(editor.is_editable_field({ ctype = "text" }))
  end)

  it("allows varchar", function()
    assert.is_true(editor.is_editable_field({ ctype = "varchar" }))
  end)

  it("allows integer", function()
    assert.is_true(editor.is_editable_field({ ctype = "integer" }))
  end)

  it("allows boolean", function()
    assert.is_true(editor.is_editable_field({ ctype = "boolean" }))
  end)

  it("allows json/jsonb", function()
    assert.is_true(editor.is_editable_field({ ctype = "jsonb" }))
  end)

  it("allows uuid", function()
    assert.is_true(editor.is_editable_field({ ctype = "uuid" }))
  end)

  it("allows date/timestamp", function()
    assert.is_true(editor.is_editable_field({ ctype = "timestamp" }))
  end)

  it("blocks binary", function()
    assert.is_false(editor.is_editable_field({ ctype = "binary" }))
  end)

  it("blocks bytea", function()
    assert.is_false(editor.is_editable_field({ ctype = "bytea" }))
  end)

  it("blocks blob", function()
    assert.is_false(editor.is_editable_field({ ctype = "blob" }))
  end)

  it("blocks varbinary", function()
    assert.is_false(editor.is_editable_field({ ctype = "varbinary" }))
  end)

  it("blocks geometry", function()
    assert.is_false(editor.is_editable_field({ ctype = "geometry" }))
  end)

  it("blocks geography", function()
    assert.is_false(editor.is_editable_field({ ctype = "geography" }))
  end)

  it("blocks point", function()
    assert.is_false(editor.is_editable_field({ ctype = "point" }))
  end)

  it("blocks polygon", function()
    assert.is_false(editor.is_editable_field({ ctype = "polygon" }))
  end)

  it("blocks linestring", function()
    assert.is_false(editor.is_editable_field({ ctype = "linestring" }))
  end)

  it("blocks inet", function()
    assert.is_false(editor.is_editable_field({ ctype = "inet" }))
  end)

  it("blocks cidr", function()
    assert.is_false(editor.is_editable_field({ ctype = "cidr" }))
  end)

  it("blocks macaddr", function()
    assert.is_false(editor.is_editable_field({ ctype = "macaddr" }))
  end)

  it("blocks bit", function()
    assert.is_false(editor.is_editable_field({ ctype = "bit" }))
  end)

  it("blocks varbit", function()
    assert.is_false(editor.is_editable_field({ ctype = "varbit" }))
  end)

  it("blocks interval", function()
    assert.is_false(editor.is_editable_field({ ctype = "interval" }))
  end)

  it("blocks tsvector", function()
    assert.is_false(editor.is_editable_field({ ctype = "tsvector" }))
  end)

  it("blocks tsquery", function()
    assert.is_false(editor.is_editable_field({ ctype = "tsquery" }))
  end)

  it("blocks user_defined type", function()
    assert.is_false(editor.is_editable_field({ ctype = "my_type", user_defined = true }))
  end)

  it("allows numeric", function()
    assert.is_true(editor.is_editable_field({ ctype = "numeric" }))
  end)

  it("allows float", function()
    assert.is_true(editor.is_editable_field({ ctype = "float" }))
  end)
end)

---------------------------------------------------------------------------
-- UT4: edit_state tracking — modified/deleted/added
---------------------------------------------------------------------------
describe("edit_state tracking", function()
  local es

  before_each(function()
    es = editor.create_edit_state()
  end)

  describe("track_cell_edit", function()
    it("marks dirty on first edit", function()
      assert.is_false(es.dirty)
      editor.track_cell_edit(es, "1:2", 2, "old", "new")
      assert.is_true(es.dirty)
    end)

    it("records cell modification", function()
      editor.track_cell_edit(es, "1:2", 2, "old", "new")
      assert.is_not_nil(es.modified_cells["1:2"])
      assert.equals(2, es.modified_cells["1:2"].col)
      assert.equals("old", es.modified_cells["1:2"].old_val)
      assert.equals("new", es.modified_cells["1:2"].new_val)
    end)

    it("tracks multiple different cells", function()
      editor.track_cell_edit(es, "1:1", 1, "a", "b")
      editor.track_cell_edit(es, "1:2", 2, "c", "d")
      assert.is_not_nil(es.modified_cells["1:1"])
      assert.is_not_nil(es.modified_cells["1:2"])
    end)

    it("overwrites same cell edit", function()
      editor.track_cell_edit(es, "1:2", 2, "old", "new1")
      editor.track_cell_edit(es, "1:2", 2, "old", "new2")
      assert.equals("new2", es.modified_cells["1:2"].new_val)
      assert.equals("old", es.modified_cells["1:2"].old_val)
    end)

    it("restores to original removes from modified_cells", function()
      editor.track_cell_edit(es, "1:2", 2, "old", "new")
      editor.track_cell_edit(es, "1:2", 2, "old", "old")
      assert.is_nil(es.modified_cells["1:2"])
      assert.is_false(es.dirty)
    end)
  end)

  describe("track_row_delete", function()
    it("marks deleted row", function()
      editor.track_row_delete(es, 3)
      assert.is_true(es.deleted_rows[3])
      assert.is_true(es.dirty)
    end)

    it("removes modified_cells for deleted row", function()
      editor.track_cell_edit(es, "3:2", 2, "old", "new")
      editor.track_row_delete(es, 3)
      assert.is_nil(es.modified_cells["3:2"])
      assert.is_true(es.deleted_rows[3])
    end)
  end)

  describe("track_row_add", function()
    it("adds a new row", function()
      editor.track_row_add(es, { "a", "b", "c" })
      assert.equals(1, #es.added_rows)
      assert.same({ "a", "b", "c" }, es.added_rows[1].data)
      assert.is_true(es.dirty)
    end)

    it("tracks multiple added rows", function()
      editor.track_row_add(es, { "a" })
      editor.track_row_add(es, { "b" })
      assert.equals(2, #es.added_rows)
    end)
  end)

  describe("has_pending_changes", function()
    it("returns false initially", function()
      assert.is_false(editor.has_pending_changes(es))
    end)

    it("returns true after edit", function()
      editor.track_cell_edit(es, "1:1", 1, "a", "b")
      assert.is_true(editor.has_pending_changes(es))
    end)

    it("returns true after delete", function()
      editor.track_row_delete(es, 1)
      assert.is_true(editor.has_pending_changes(es))
    end)

    it("returns true after add", function()
      editor.track_row_add(es, { "x" })
      assert.is_true(editor.has_pending_changes(es))
    end)
  end)

  describe("get_edit_summary", function()
    it("returns zeros when clean", function()
      local s = editor.get_edit_summary(es)
      assert.equals(0, s.updates)
      assert.equals(0, s.inserts)
      assert.equals(0, s.deletes)
    end)

    it("counts modifications", function()
      editor.track_cell_edit(es, "1:1", 1, "a", "b")
      editor.track_cell_edit(es, "1:2", 2, "c", "d")
      local s = editor.get_edit_summary(es)
      assert.equals(2, s.updates)
      assert.equals(0, s.inserts)
      assert.equals(0, s.deletes)
    end)

    it("counts deletes", function()
      editor.track_row_delete(es, 1)
      editor.track_row_delete(es, 2)
      local s = editor.get_edit_summary(es)
      assert.equals(0, s.updates)
      assert.equals(0, s.inserts)
      assert.equals(2, s.deletes)
    end)

    it("counts adds", function()
      editor.track_row_add(es, { "a" })
      local s = editor.get_edit_summary(es)
      assert.equals(0, s.updates)
      assert.equals(1, s.inserts)
      assert.equals(0, s.deletes)
    end)
  end)
end)

---------------------------------------------------------------------------
-- UT5: edit_state merge — same cell multiple edits, modify then delete
---------------------------------------------------------------------------
describe("edit_state merge", function()
  local es

  before_each(function()
    es = editor.create_edit_state()
  end)

  it("same cell edited multiple times keeps only first old_val", function()
    editor.track_cell_edit(es, "1:2", 2, "orig", "v1")
    editor.track_cell_edit(es, "1:2", 2, "orig", "v2")
    assert.equals("orig", es.modified_cells["1:2"].old_val)
    assert.equals("v2", es.modified_cells["1:2"].new_val)
  end)

  it("modify then delete removes modified_cells, keeps deleted", function()
    editor.track_cell_edit(es, "3:2", 2, "old", "new")
    editor.track_row_delete(es, 3)
    assert.is_nil(es.modified_cells["3:2"])
    assert.is_true(es.deleted_rows[3])
  end)

  it("delete then modify does not track (row is deleted)", function()
    editor.track_row_delete(es, 3)
    editor.track_cell_edit(es, "3:2", 2, "old", "new")
    assert.is_nil(es.modified_cells["3:2"])
    assert.is_true(es.deleted_rows[3])
  end)

  it("reset clears everything", function()
    editor.track_cell_edit(es, "1:1", 1, "a", "b")
    editor.track_row_delete(es, 2)
    editor.track_row_add(es, { "c" })
    editor.reset_edit_state(es)
    assert.is_false(es.dirty)
    assert.same({}, es.modified_cells)
    assert.same({}, es.deleted_rows)
    assert.same({}, es.added_rows)
    assert.same({}, es.cell_errors)
  end)
end)

---------------------------------------------------------------------------
-- UT6: generate_update — UPDATE SQL generation
---------------------------------------------------------------------------
describe("generate_update", function()
  local columns = {
    { name = "id", ctype = "integer", primary_key = true },
    { name = "name", ctype = "text" },
    { name = "email", ctype = "varchar" },
  }

  it("generates UPDATE with primary key WHERE clause", function()
    local sql = edit_commit.generate_update(
      "public", "users", columns,
      { { col = 2, old_val = "Alice", new_val = "Bob" } },
      { "1" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_truthy(sql:match("UPDATE"))
    assert.is_truthy(sql:match('"public"%."users"'))
    assert.is_truthy(sql:match('"name"'))
    assert.is_truthy(sql:match("Bob"))
    assert.is_truthy(sql:match("WHERE"))
    assert.is_truthy(sql:match('"id"%s*=%s*1'))
  end)

  it("generates UPDATE with all-column WHERE for no PK", function()
    local cols_no_pk = {
      { name = "name", ctype = "text" },
      { name = "email", ctype = "varchar" },
    }
    local sql = edit_commit.generate_update(
      "public", "users", cols_no_pk,
      { { col = 2, old_val = "old@email", new_val = "new@email" } },
      { "Alice", "old@email" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_truthy(sql:match("WHERE"))
  end)

  it("skips row_num column (col=1 is row number)", function()
    local cols_with_rn = {
      { name = "_row_num", ctype = "integer" },
      { name = "id", ctype = "integer", primary_key = true },
      { name = "name", ctype = "text" },
    }
    local sql = edit_commit.generate_update(
      "public", "users", cols_with_rn,
      { { col = 3, old_val = "Alice", new_val = "Bob" } },
      { "1" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_truthy(sql:match('"name"'))
    assert.is_truthy(sql:match("Bob"))
  end)
end)

---------------------------------------------------------------------------
-- UT7: generate_insert — INSERT SQL generation
---------------------------------------------------------------------------
describe("generate_insert", function()
  local columns = {
    { name = "id", ctype = "integer", primary_key = true },
    { name = "name", ctype = "text" },
    { name = "email", ctype = "varchar" },
  }

  it("generates INSERT with correct columns and values", function()
    local sql = edit_commit.generate_insert(
      "public", "users", columns,
      { "[Auto]", "Charlie", "charlie@test.com" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_truthy(sql:match("INSERT INTO"))
    assert.is_truthy(sql:match('"public"%."users"'))
    assert.is_truthy(sql:match("Charlie"))
    assert.is_truthy(sql:match("charlie@test.com"))
    assert.is_falsy(sql:match("id"))
  end)

  it("skips [Auto] columns", function()
    local sql = edit_commit.generate_insert(
      "public", "users", columns,
      { "[Auto]", "Dave", "dave@test.com" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_falsy(sql:match('"id"'))
    assert.is_truthy(sql:match('"name"'))
    assert.is_truthy(sql:match('"email"'))
  end)

  it("handles all [Auto] columns", function()
    local all_auto = {
      { name = "id", ctype = "integer" },
    }
    local sql = edit_commit.generate_insert(
      "public", "users", all_auto,
      { "[Auto]" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_truthy(sql:match("INSERT INTO"))
  end)
end)

---------------------------------------------------------------------------
-- UT8: generate_delete — DELETE SQL generation
---------------------------------------------------------------------------
describe("generate_delete", function()
  local columns = {
    { name = "id", ctype = "integer", primary_key = true },
    { name = "name", ctype = "text" },
  }

  it("generates DELETE with primary key", function()
    local sql = edit_commit.generate_delete(
      "public", "users", columns,
      { "1" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_truthy(sql:match("DELETE FROM"))
    assert.is_truthy(sql:match('"public"%."users"'))
    assert.is_truthy(sql:match("WHERE"))
    assert.is_truthy(sql:match('"id"%s*=%s*1'))
  end)

  it("generates DELETE with all columns for no PK", function()
    local cols_no_pk = {
      { name = "name", ctype = "text" },
    }
    local sql = edit_commit.generate_delete(
      "public", "users", cols_no_pk,
      { "Alice" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_truthy(sql:match("DELETE FROM"))
    assert.is_truthy(sql:match("WHERE"))
  end)
end)

---------------------------------------------------------------------------
-- UT9: dialect quoting — three dialects
---------------------------------------------------------------------------
describe("dialect quoting", function()
  local columns = {
    { name = "id", ctype = "integer", primary_key = true },
    { name = "name", ctype = "text" },
  }

  it("postgres uses double quotes", function()
    local sql = edit_commit.generate_delete(
      "public", "users", columns, { "1" }, "postgres"
    )
    assert.is_truthy(sql:match('"public"%."users"'))
    assert.is_truthy(sql:match('"id"%s*=%s*1'))
  end)

  it("mysql uses backticks", function()
    local sql = edit_commit.generate_delete(
      "mydb", "users", columns, { "1" }, "mysql"
    )
    assert.is_truthy(sql:match("`mydb`%.`users`"))
    assert.is_truthy(sql:match("`id`%s*=%s*1"))
  end)

  it("sqlite uses double quotes", function()
    local sql = edit_commit.generate_delete(
      "", "users", columns, { "1" }, "sqlite"
    )
    assert.is_truthy(sql:match('"users"'))
  end)

  it("postgres INSERT uses double quotes", function()
    local sql = edit_commit.generate_insert(
      "public", "users", columns, { "[Auto]", "Alice" }, "postgres"
    )
    assert.is_truthy(sql:match('"name"'))
  end)

  it("mysql INSERT uses backticks", function()
    local sql = edit_commit.generate_insert(
      "mydb", "users", columns, { "[Auto]", "Alice" }, "mysql"
    )
    assert.is_truthy(sql:match("`name`"))
  end)
end)

---------------------------------------------------------------------------
-- UT10: JSON format — formatting and parsing
---------------------------------------------------------------------------
describe("JSON format", function()
  it("is_json_column detects json", function()
    assert.is_true(editor.is_json_column({ ctype = "json" }))
    assert.is_true(editor.is_json_column({ ctype = "jsonb" }))
  end)

  it("is_json_column rejects non-json", function()
    assert.is_false(editor.is_json_column({ ctype = "text" }))
    assert.is_false(editor.is_json_column({ ctype = "integer" }))
  end)

  it("is_boolean_column detects boolean", function()
    assert.is_true(editor.is_boolean_column({ ctype = "boolean" }))
    assert.is_true(editor.is_boolean_column({ ctype = "bool" }))
  end)

  it("is_boolean_column rejects non-boolean", function()
    assert.is_false(editor.is_boolean_column({ ctype = "text" }))
  end)

  it("is_enum_column detects enum with values", function()
    assert.is_true(editor.is_enum_column({ ctype = "USER-DEFINED", enum_values = { "a", "b" } }))
  end)

  it("is_enum_column rejects non-enum", function()
    assert.is_false(editor.is_enum_column({ ctype = "text" }))
    assert.is_false(editor.is_enum_column({ ctype = "USER-DEFINED" }))
  end)

  it("format_json_input formats table to indented string", function()
    local input = { a = 1, b = "hello" }
    local result = editor.format_json_input(input)
    assert.is_truthy(result:match("a"))
    assert.is_truthy(result:match("1"))
  end)

  it("format_json_input returns string as-is", function()
    local result = editor.format_json_input('{"a":1}')
    assert.equals('{"a":1}', result)
  end)

  it("parse_json_input decodes valid JSON", function()
    local result = editor.parse_json_input('{"a":1}')
    assert.same({ a = 1 }, result)
  end)

  it("parse_json_input returns nil for invalid JSON", function()
    local result = editor.parse_json_input("{bad}")
    assert.is_nil(result)
  end)
end)

---------------------------------------------------------------------------
-- UT11: SQL log — logging format and accumulation
---------------------------------------------------------------------------
describe("SQL log", function()
  it("format_log_entry creates valid structure", function()
    local entry = edit_commit.format_log_entry({
      source = "dataset_commit",
      table_name = "users",
      connection = "pg-ecommerce",
      dialect = "postgres",
      database = "public",
      sql = 'UPDATE "public"."users" SET "name" = \'Bob\' WHERE "id" = 1',
      status = "success",
      elapsed_ms = 12,
      edit_summary = { updates = 1, inserts = 0, deletes = 0 },
    })
    assert.is_not_nil(entry)
    assert.is_truthy(entry:match('"source"'))
    assert.is_truthy(entry:match('"dataset_commit"'))
    assert.is_truthy(entry:match('"sql"'))
    assert.is_truthy(entry:match('"status"'))
    assert.is_truthy(entry:match('"success"'))
    assert.is_truthy(entry:match('"ts"'))
    assert.is_truthy(entry:match('"elapsed_ms"'))
  end)

  it("format_log_entry handles error status", function()
    local entry = edit_commit.format_log_entry({
      source = "dataset_commit",
      table_name = "users",
      connection = "pg-ecommerce",
      dialect = "postgres",
      database = "public",
      sql = 'INSERT INTO "users" VALUES (1)',
      status = "error",
      elapsed_ms = 5,
      error_msg = "duplicate key",
    })
    assert.is_truthy(entry:match('"error"'))
    assert.is_truthy(entry:match('"duplicate key"'))
  end)

  it("format_log_entry handles manual_exec source", function()
    local entry = edit_commit.format_log_entry({
      source = "manual_exec",
      connection = "my-blog",
      dialect = "mysql",
      database = "blog",
      sql = "SELECT * FROM posts",
      status = "success",
      elapsed_ms = 3,
    })
    assert.is_truthy(entry:match('"manual_exec"'))
  end)
end)

---------------------------------------------------------------------------
-- Additional: edit_cell checks
---------------------------------------------------------------------------
describe("edit guards", function()
  it("is_numeric_type detects integer types", function()
    assert.is_true(editor.is_numeric_type("integer"))
    assert.is_true(editor.is_numeric_type("int"))
    assert.is_true(editor.is_numeric_type("bigint"))
    assert.is_true(editor.is_numeric_type("smallint"))
    assert.is_true(editor.is_numeric_type("numeric"))
    assert.is_true(editor.is_numeric_type("decimal"))
    assert.is_true(editor.is_numeric_type("real"))
    assert.is_true(editor.is_numeric_type("float"))
    assert.is_false(editor.is_numeric_type("text"))
    assert.is_false(editor.is_numeric_type("boolean"))
  end)

  it("is_date_type detects date types", function()
    assert.is_true(editor.is_date_type("date"))
    assert.is_true(editor.is_date_type("timestamp"))
    assert.is_true(editor.is_date_type("timestamptz"))
    assert.is_false(editor.is_date_type("text"))
    assert.is_false(editor.is_date_type("integer"))
  end)

  it("is_uuid_type detects uuid", function()
    assert.is_true(editor.is_uuid_type("uuid"))
    assert.is_false(editor.is_uuid_type("text"))
  end)

  it("count_pending_changes returns correct counts", function()
    local es = editor.create_edit_state()
    editor.track_cell_edit(es, "1:1", 1, "a", "b")
    editor.track_cell_edit(es, "1:2", 2, "c", "d")
    editor.track_row_delete(es, 3)
    editor.track_row_add(es, { "x" })

    local counts = editor.count_pending_changes(es)
    assert.equals(2, counts.modified)
    assert.equals(1, counts.deleted)
    assert.equals(1, counts.added)
  end)

  it("pending_changes_text formats correctly", function()
    local es = editor.create_edit_state()
    editor.track_cell_edit(es, "1:1", 1, "a", "b")
    editor.track_row_delete(es, 2)
    editor.track_row_add(es, { "x" })

    local text = editor.pending_changes_text(es)
    assert.is_truthy(text:match("%+1"))
    assert.is_truthy(text:match("~1"))
    assert.is_truthy(text:match("%-1"))
  end)

  it("pending_changes_text returns nil when clean", function()
    local es = editor.create_edit_state()
    assert.is_nil(editor.pending_changes_text(es))
  end)
end)
