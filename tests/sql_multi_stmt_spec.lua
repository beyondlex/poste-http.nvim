--- Tests for multi-statement SQL execution:
--- - find_stmt_lines: locate statement start line numbers in buffer
--- - extract_visual_block: build synthetic ### block from visual selection

local init = require("poste.sql.init")
local t = init._test

describe("find_stmt_lines", function()
  it("returns one statement for a single line without semicolon", function()
    local lines = { "SELECT * FROM users" }
    local stmts = t.find_stmt_lines(lines, 1, 1)
    assert.same({ 1 }, stmts)
  end)

  it("returns one statement for a single line with semicolon", function()
    local lines = { "SELECT * FROM users;" }
    local stmts = t.find_stmt_lines(lines, 1, 1)
    assert.same({ 1 }, stmts)
  end)

  it("returns two statements on two lines", function()
    local lines = {
      "SELECT * FROM users;",
      "SELECT * FROM orders;",
    }
    local stmts = t.find_stmt_lines(lines, 1, 2)
    assert.same({ 1, 2 }, stmts)
  end)

  it("skips blank lines between statements", function()
    local lines = {
      "SELECT * FROM users;",
      "",
      "SELECT * FROM orders;",
    }
    local stmts = t.find_stmt_lines(lines, 1, 3)
    assert.same({ 1, 3 }, stmts)
  end)

  it("skips comment lines between statements", function()
    local lines = {
      "SELECT * FROM users;",
      "-- some comment",
      "SELECT * FROM orders;",
    }
    local stmts = t.find_stmt_lines(lines, 1, 3)
    assert.same({ 1, 3 }, stmts)
  end)

  it("skips directive comments", function()
    local lines = {
      "SELECT * FROM users;",
      "-- @database test",
      "SELECT count(*) FROM orders;",
    }
    local stmts = t.find_stmt_lines(lines, 1, 3)
    assert.same({ 1, 3 }, stmts)
  end)

  it("handles multi-line statements", function()
    local lines = {
      "SELECT *",
      "FROM users;",
      "SELECT count(*)",
      "FROM orders;",
    }
    local stmts = t.find_stmt_lines(lines, 1, 4)
    assert.same({ 1, 3 }, stmts)
  end)

  it("handles trailing semicolon on separate line", function()
    local lines = {
      "SELECT * FROM users",
      ";",
      "SELECT * FROM orders;",
    }
    local stmts = t.find_stmt_lines(lines, 1, 3)
    assert.same({ 1, 3 }, stmts)
  end)

  it("returns last statement even without trailing semicolon", function()
    local lines = {
      "SELECT * FROM users;",
      "SELECT * FROM orders",
    }
    local stmts = t.find_stmt_lines(lines, 1, 2)
    assert.same({ 1, 2 }, stmts)
  end)

  it("works within a sub-range of the buffer", function()
    local lines = {
      "SELECT 1;",
      "SELECT 2;",
      "SELECT 3;",
      "SELECT 4;",
    }
    local stmts = t.find_stmt_lines(lines, 2, 4)
    assert.same({ 2, 3, 4 }, stmts)
  end)
end)

describe("extract_visual_block", function()
  it("wraps selection in synthetic ### with directives", function()
    local lines = {
      "-- @connection pg-ecommerce",
      "",
      "SELECT * FROM users;",
      "SELECT * FROM orders;",
    }
    local content, stmts, dc = t.extract_visual_block(lines, 3, 4)
    assert.truthy(content:find("-- @connection pg-ecommerce", 1, true))
    assert.truthy(content:find("###", 1, true))
    assert.truthy(content:find("SELECT * FROM users;", 1, true))
    assert.truthy(content:find("SELECT * FROM orders;", 1, true))
    assert.same({ 3, 4 }, stmts)
    assert.same(2, dc)
  end)

  it("handles empty directive section", function()
    local lines = {
      "SELECT 1;",
      "SELECT 2;",
    }
    local content, stmts, dc = t.extract_visual_block(lines, 1, 2)
    assert.truthy(content:find("###", 1, true))
    assert.same({ 1, 2 }, stmts)
    assert.same(0, dc)
  end)

  it("extracts directives from file header", function()
    local lines = {
      "-- @connection pg-ecommerce",
      "-- @database analytics",
      "",
      "SELECT count(*) FROM users;",
    }
    local content, stmts, dc = t.extract_visual_block(lines, 4, 4)
    assert.truthy(content:find("-- @connection", 1, true))
    assert.truthy(content:find("-- @database", 1, true))
    assert.truthy(content:find("###", 1, true))
    assert.truthy(content:find("SELECT", 1, true))
    assert.same({ 4 }, stmts)
    assert.same(3, dc)
  end)
end)
