-- Tests for poste.async.promise

local P = require("poste.async.promise")

describe("Promise", function()
  -------------------------------------------------------------------------
  -- Basic resolve/reject
  -------------------------------------------------------------------------

  describe("new()", function()
    it("resolves with value", function()
      local result = nil
      P.new(function(resolve) resolve(42) end):then_(function(v) result = v end)
      assert.equals(42, result)
    end)

    it("rejects with error", function()
      local err = nil
      P.new(_, function(reject) reject("fail") end):catch_(function(e) err = e end)
      assert.equals("fail", err)
    end)

    it("catches executor exception", function()
      local err = nil
      P.new(function() error("boom") end):catch_(function(e) err = e end)
      assert.is_not_nil(err)
    end)
  end)

  -------------------------------------------------------------------------
  -- Chaining with then_
  -------------------------------------------------------------------------

  describe("then_()", function()
    it("chains sequentially", function()
      local results = {}
      P.new(function(resolve) resolve(1) end)
        :then_(function(v)
          results[1] = v
          return 2
        end)
        :then_(function(v)
          results[2] = v
          return 3
        end)
        :then_(function(v)
          results[3] = v
        end)
      assert.equals(1, results[1])
      assert.equals(2, results[2])
      assert.equals(3, results[3])
    end)

    it("chains with nested promises", function()
      local final = nil
      P.new(function(resolve) resolve("a") end)
        :then_(function(v)
          return P.new(function(resolve) resolve(v .. "b") end)
        end)
        :then_(function(v)
          final = v
        end)
      assert.equals("ab", final)
    end)
  end)

  -------------------------------------------------------------------------
  -- Error propagation
  -------------------------------------------------------------------------

  describe("catch_()", function()
    it("catches rejection from previous then_", function()
      local err = nil
      P.new(function(resolve) resolve("ok") end)
        :then_(function() return P.new(_, function(reject) reject("nope") end) end)
        :catch_(function(e) err = e end)
      assert.equals("nope", err)
    end)
  end)

  -------------------------------------------------------------------------
  -- finally_
  -------------------------------------------------------------------------

  describe("finally_()", function()
    it("runs on resolve", function()
      local ran = false
      local val = nil
      P.new(function(resolve) resolve(42) end)
        :finally_(function() ran = true end)
        :then_(function(v) val = v end)
      assert.is_true(ran)
      assert.equals(42, val)
    end)

    it("runs on reject", function()
      local ran = false
      local err = nil
      P.new(_, function(reject) reject("fail") end)
        :finally_(function() ran = true end)
        :catch_(function(e) err = e end)
      assert.is_true(ran)
      assert.equals("fail", err)
    end)
  end)

  -------------------------------------------------------------------------
  -- Static methods
  -------------------------------------------------------------------------

  describe("P.resolve()", function()
    it("creates resolved promise", function()
      local val = nil
      P.resolve(99):then_(function(v) val = v end)
      assert.equals(99, val)
    end)
  end)

  describe("P.all()", function()
    it("resolves with all values", function()
      local vals = nil
      P.all{
        P.new(function(r) r(1) end),
        P.new(function(r) r(2) end),
        P.new(function(r) r(3) end),
      }:then_(function(v) vals = v end)
      assert.is_table(vals)
      assert.equals(1, vals[1])
      assert.equals(2, vals[2])
      assert.equals(3, vals[3])
    end)

    it("rejects if any promise rejects", function()
      local err = nil
      P.all{
        P.new(function(r) r(1) end),
        P.new(_, function(r) r("fail") end),
      }:catch_(function(e) err = e end)
      assert.equals("fail", err)
    end)
  end)
end)
