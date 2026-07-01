-- Tests for poste.state.event event bus.

local event = require("poste.state.event")

describe("Event Bus", function()
  before_each(function()
    event.clear()
  end)

  -------------------------------------------------------------------------
  -- on / emit
  -------------------------------------------------------------------------

  describe("on() and emit()", function()
    it("handler receives emitted data", function()
      local received = nil
      event.on("test:event", function(data)
        received = data
      end)
      event.emit("test:event", { value = 42 })
      assert.is_not_nil(received)
      assert.equals(42, received.value)
    end)

    it("multiple handlers receive the same event", function()
      local count = 0
      event.on("test:event", function() count = count + 1 end)
      event.on("test:event", function() count = count + 1 end)
      event.emit("test:event", {})
      assert.equals(2, count)
    end)

    it("unrelated events do not trigger handlers", function()
      local triggered = false
      event.on("event:a", function() triggered = true end)
      event.emit("event:b", {})
      assert.is_false(triggered)
    end)

    it("emit with no handlers does not error", function()
      event.emit("nonexistent:event", {})  -- should not crash
    end)
  end)

  -------------------------------------------------------------------------
  -- unsubscribe
  -------------------------------------------------------------------------

  describe("unsubscribe", function()
    it("returned function removes the handler", function()
      local count = 0
      local unsub = event.on("test:event", function() count = count + 1 end)
      event.emit("test:event", {})
      assert.equals(1, count)
      unsub()
      event.emit("test:event", {})
      assert.equals(1, count)  -- not incremented again
    end)

    it("calling unsubscribe twice is safe", function()
      local unsub = event.on("test:event", function() end)
      unsub()
      unsub()  -- should not error
    end)
  end)

  -------------------------------------------------------------------------
  -- once
  -------------------------------------------------------------------------

  describe("once()", function()
    it("handler fires only once", function()
      local count = 0
      event.once("test:event", function() count = count + 1 end)
      event.emit("test:event", {})
      event.emit("test:event", {})
      event.emit("test:event", {})
      assert.equals(1, count)
    end)

    it("returns unsubscribe function", function()
      local unsub = event.once("test:event", function() end)
      assert.is_function(unsub)
    end)
  end)

  -------------------------------------------------------------------------
  -- handler_count
  -------------------------------------------------------------------------

  describe("handler_count()", function()
    it("returns 0 for unknown event", function()
      assert.equals(0, event.handler_count("nonexistent"))
    end)

    it("returns accurate count", function()
      event.on("test:event", function() end)
      event.on("test:event", function() end)
      assert.equals(2, event.handler_count("test:event"))
    end)
  end)

  -------------------------------------------------------------------------
  -- clear
  -------------------------------------------------------------------------

  describe("clear()", function()
    it("removes handlers for a specific event", function()
      local count = 0
      event.on("test:event", function() count = count + 1 end)
      event.clear("test:event")
      event.emit("test:event", {})
      assert.equals(0, count)
    end)

    it("removes all handlers when called without arguments", function()
      local count = 0
      event.on("event:a", function() count = count + 1 end)
      event.on("event:b", function() count = count + 1 end)
      event.clear()
      event.emit("event:a", {})
      event.emit("event:b", {})
      assert.equals(0, count)
    end)
  end)

  -------------------------------------------------------------------------
  -- Error isolation
  -------------------------------------------------------------------------

  describe("error isolation", function()
    it("a failing handler does not prevent others from running", function()
      local second_ran = false
      event.on("test:event", function()
        error("handler failed")
      end)
      event.on("test:event", function()
        second_ran = true
      end)
      event.emit("test:event", {})
      assert.is_true(second_ran)
    end)
  end)
end)
