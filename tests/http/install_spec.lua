local harness = require("helpers.gui_harness")

describe("install", function()
  before_each(function()
    harness.setup {
      executable = function(name)
        if name == "cc" then return 1 end
        return 0
      end,
    }
    package.loaded["poste-http.install"] = nil
  end)

  after_each(function()
    harness.teardown()
  end)

  it("ensure_parsers skips when no C compiler", function()
    harness.teardown()
    harness.setup {
      executable = function(name) return 0 end,
    }
    package.loaded["poste-http.install"] = nil
    local install = require("poste-http.install")
    install.ensure_parsers()

    -- No notifications should be sent (no compiler, no attempt)
    local notify_count = 0
    for _, call in ipairs(harness.calls) do
      if call == "vim_notify" then notify_count = notify_count + 1 end
    end
    assert.equals(0, notify_count, "should not notify when no compiler")
  end)

  it("force_build reports up-to-date parsers as INFO, not ERROR", function()
    -- Everything fresh used to fall through to "No parsers were compiled"
    -- (ERROR): an install that is actually fine looked broken.
    local orig_filereadable, orig_getftime = vim.fn.filereadable, vim.fn.getftime
    vim.fn.filereadable = function(path)
      if path:match("parser%.c$") or path:match("%.so$") then return 1 end
      return orig_filereadable(path)
    end
    vim.fn.getftime = function(path)
      -- .so strictly newer than its source → needs_compile false, no reason
      if path:match("%.so$") then return 2000 end
      if path:match("parser%.c$") then return 1000 end
      return orig_getftime(path)
    end
    local install = require("poste-http.install")
    install.force_build()
    vim.fn.filereadable, vim.fn.getftime = orig_filereadable, orig_getftime

    local up_to_date, failure = false, false
    for i = 1, #harness.calls do
      if harness.calls[i] == "vim_notify" then
        local detail = harness.calls[i + 1]
        if detail and detail.msg then
          if detail.msg:match("up to date") then up_to_date = true end
          if detail.msg:match("No parsers") then failure = true end
        end
      end
    end
    assert.is_true(up_to_date, "should notify that parsers are up to date")
    assert.is_false(failure, "must not report a failure for a healthy install")
  end)

  it("force_build reports when no compiler found", function()
    harness.teardown()
    harness.setup {
      executable = function(name) return 0 end,
    }
    package.loaded["poste-http.install"] = nil
    local install = require("poste-http.install")
    install.force_build()

    local has_error = false
    for i = 1, #harness.calls do
      if harness.calls[i] == "vim_notify" then
        local detail = harness.calls[i + 1]
        if detail and detail.msg and detail.msg:match("No parsers") then
          has_error = true
        end
      end
    end
    assert.is_true(has_error, "should notify about no parsers compiled")
  end)
end)