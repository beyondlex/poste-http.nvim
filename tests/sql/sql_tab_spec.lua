--- Tests for the dataset tab system (tab-based state isolation).
---
--- Each tab holds its own meta, sort, cursor, scroll, and header.
--- Multi-statement execution is not yet implemented, but the tab
--- infrastructure must work correctly when multiple tabs are created.

local buffer = require("poste.sql.buffer")
local t = buffer._test

describe("tab system", function()
  before_each(function()
    t.reset()
  end)

  describe("tab_count", function()
    it("returns 0 after reset", function()
      assert.equals(0, t.tab_count())
    end)

    it("returns 1 after creating a tab", function()
      t.create_tab(1)
      assert.equals(1, t.tab_count())
    end)

    it("returns N after creating multiple tabs", function()
      t.create_tab(1)
      t.create_tab(2)
      t.create_tab(3)
      assert.equals(3, t.tab_count())
    end)
  end)

  describe("active_tab_idx", function()
    it("starts at 0", function()
      assert.equals(0, t.active_tab_idx())
    end)

    it("reflects set_active", function()
      t.create_tab(1)
      t.create_tab(2)
      t.set_active(2)
      assert.equals(2, t.active_tab_idx())
    end)
  end)

  describe("state isolation", function()
    it("tabs have independent sort state", function()
      local a = t.create_tab(1, { sort = { col = 3, ascending = true } })
      local b = t.create_tab(2, { sort = { col = 1, ascending = false } })

      assert.equals(3, a.sort.col)
      assert.is_true(a.sort.ascending)
      assert.equals(1, b.sort.col)
      assert.is_false(b.sort.ascending)
    end)

    it("tabs have independent cursor position", function()
      local a = t.create_tab(1, { cursor = { row = 5, col = 3 } })
      local b = t.create_tab(2, { cursor = { row = 1, col = 7 } })

      assert.equals(5, a.cursor.row)
      assert.equals(3, a.cursor.col)
      assert.equals(1, b.cursor.row)
      assert.equals(7, b.cursor.col)

      -- Mutating a does not affect b
      a.cursor.row = 99
      local b2 = t.get_tab(2)
      assert.equals(1, b2.cursor.row)
    end)

    it("tabs have independent scroll position", function()
      t.create_tab(1, { leftcol = 42 })
      t.create_tab(2, { leftcol = 7 })

      local a = t.get_tab(1)
      local b = t.get_tab(2)
      assert.equals(42, a.leftcol)
      assert.equals(7, b.leftcol)
    end)

    it("tabs have independent header text", function()
      t.create_tab(1, { header_text = "  │ id │ name │" })
      t.create_tab(2, { header_text = "  │ col_a │ col_b │ col_c │" })

      local a = t.get_tab(1)
      local b = t.get_tab(2)
      assert.equals("  │ id │ name │", a.header_text)
      assert.equals("  │ col_a │ col_b │ col_c │", b.header_text)
    end)

    it("tabs have independent meta", function()
      t.create_tab(1, {
        meta = { type = "resultset", total_rows = 10, row_count = 10, col_count = 3 },
      })
      t.create_tab(2, {
        meta = { type = "resultset", total_rows = 0, row_count = 0, col_count = 5 },
      })

      local a = t.get_tab(1)
      local b = t.get_tab(2)
      assert.equals(10, a.meta.total_rows)
      assert.equals(3, a.meta.col_count)
      assert.equals(0, b.meta.total_rows)
      assert.equals(5, b.meta.col_count)
    end)

    it("setting one tab's sort does not affect another", function()
      t.create_tab(1)
      t.create_tab(2)

      t.set_active(1)
      t.create_tab(1, { sort = { col = 2, ascending = true } })

      local b = t.get_tab(2)
      assert.is_nil(b.sort)
    end)
  end)

  describe("create_tab", function()
    it("sequential creation gives correct count", function()
      t.create_tab(1)
      t.create_tab(2)
      assert.equals(2, t.tab_count())
      assert.is_not_nil(t.get_tab(2))
    end)

    it("returns the tab object", function()
      local tab = t.create_tab(1)
      assert.is_not_nil(tab)
      assert.is_not_nil(tab.cursor)
      assert.equals(1, tab.cursor.row)
      assert.equals(1, tab.cursor.col)
    end)
  end)

  describe("default tab state", function()
    it("has default cursor (1,1)", function()
      local tab = t.create_tab(1)
      assert.equals(1, tab.cursor.row)
      assert.equals(1, tab.cursor.col)
    end)

    it("has nil sort and meta", function()
      local tab = t.create_tab(1)
      assert.is_nil(tab.sort)
      assert.is_nil(tab.meta)
    end)

    it("has leftcol 0", function()
      local tab = t.create_tab(1)
      assert.equals(0, tab.leftcol)
    end)
  end)

  describe("tab_count public API", function()
    it("buffer.tab_count() returns 0 when empty", function()
      assert.equals(0, buffer.tab_count())
    end)

    it("buffer.tab_count() returns correct count", function()
      t.create_tab(1)
      t.create_tab(2)
      assert.equals(2, buffer.tab_count())
    end)
  end)
end)
