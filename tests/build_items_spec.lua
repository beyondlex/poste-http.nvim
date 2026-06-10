-- Unit tests for build_items()
-- Tests completion item generation from word lists

local completion = require("poste.http.completion")
local build_items = completion._test.build_items

describe("build_items", function()
  it("returns empty table for empty input", function()
    local items = build_items({}, 1)
    assert.equals(0, #items)
  end)

  it("builds items with correct structure", function()
    local items = build_items({ "word1", "word2" }, 14) -- KIND_KEYWORD = 14

    assert.equals(2, #items)

    -- Check first item structure
    local item = items[1]
    assert.equals("word1", item.label)
    assert.equals(14, item.kind)
    assert.equals("word1", item.insertText)
    assert.equals("word1", item.filterText)
    assert.equals("word1", item.sortText)
    assert.is_nil(item.detail)
  end)

  it("preserves word order", function()
    local words = { "alpha", "beta", "gamma" }
    local items = build_items(words, 10) -- KIND_PROPERTY

    assert.equals("alpha", items[1].label)
    assert.equals("beta", items[2].label)
    assert.equals("gamma", items[3].label)
  end)

  it("uses the same kind for all items", function()
    local items = build_items({ "a", "b", "c" }, 12) -- KIND_VALUE

    for _, item in ipairs(items) do
      assert.equals(12, item.kind)
    end
  end)

  it("handles words with special characters", function()
    local items = build_items({ "Content-Type", "application/json" }, 10)

    assert.equals("Content-Type", items[1].label)
    assert.equals("application/json", items[2].label)
  end)

  it("sets all required LSP CompletionItem fields", function()
    local items = build_items({ "test" }, 6) -- KIND_VARIABLE
    local item = items[1]

    -- Required fields for LSP completion
    assert.is_not_nil(item.label)
    assert.is_not_nil(item.kind)
    assert.is_not_nil(item.insertText)

    -- Optional but expected fields
    assert.is_not_nil(item.filterText)
    assert.is_not_nil(item.sortText)
  end)
end)
