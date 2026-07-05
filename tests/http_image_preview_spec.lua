local mock = dofile("./tests/helpers/mock_nvim.lua")
local state = require("poste.state")

local function has_call(name)
  for _, call in ipairs(mock.calls) do
    if call == name then
      return true
    end
  end
  return false
end

describe("http image preview", function()
  local format
  local view
  local original_image_preload
  local original_snacks_preload

  before_each(function()
    original_image_preload = package.preload["image"]
    original_snacks_preload = package.preload["snacks"]
    mock.setup({ buf_line_count = 18, current_cursor = { 1, 0 } })
    state.last_response = nil
    state.pending_request = nil
    state.current_view = "body"
    package.loaded["poste.http.format"] = nil
    package.loaded["poste.http.view"] = nil
    format = require("poste.http.format")
    view = require("poste.http.view")
  end)

  after_each(function()
    mock.teardown()
    package.loaded["poste.http.format"] = nil
    package.loaded["poste.http.view"] = nil
    package.loaded["image"] = nil
    package.preload["image"] = original_image_preload
    package.loaded["snacks"] = nil
    package.preload["snacks"] = original_snacks_preload
  end)

  it("uses image.nvim inline when available", function()
    local image_calls = {}
    package.preload["image"] = function()
      return {
        from_file = function(path, opts)
          table.insert(image_calls, { path = path, opts = opts })
          return {
            render = function() table.insert(image_calls, "render") end,
          }
        end,
      }
    end
    package.loaded["image"] = nil

    local tmp = vim.fn.tempname()
    local f = assert(io.open(tmp, "wb"))
    f:write("PNG")
    f:close()

    local ok = format.render_image_preview(1, tmp, "image/png", 7)
    assert.is_true(ok)
    assert.equals(2, #image_calls)
    assert.equals(tmp, image_calls[1].path)
    assert.is_table(image_calls[1].opts)
    assert.equals(1, image_calls[1].opts.buffer)
    assert.equals(1, image_calls[1].opts.window)
    assert.equals(6, image_calls[1].opts.y)
    assert.equals("render", image_calls[2])
    assert.is_false(has_call("nvim_open_win"))
  end)

  it("falls back to external viewer when image.nvim is unavailable", function()
    package.preload["image"] = function()
      error("not installed")
    end
    package.loaded["image"] = nil

    local tmp = vim.fn.tempname()
    local f = assert(io.open(tmp, "wb"))
    f:write("PNG")
    f:close()

    local ok = format.render_image_preview(1, tmp, "image/png")
    assert.is_false(ok)

    format.open_image_external(tmp)
    assert.is_true(has_call("jobstart"))
  end)

  it("uses snacks.image when available (priority over image.nvim)", function()
    local snacks_calls = {}
    local image_calls = 0
    package.preload["snacks"] = function()
      return {
        image = {
          supports = function(_) return true end,
          supports_terminal = function() return true end,
          placement = {
            new = function(buf, src, opts)
              table.insert(snacks_calls, { buf = buf, src = src, opts = opts })
              return { close = function() end }
            end,
          },
        },
      }
    end
    package.loaded["snacks"] = nil
    package.preload["image"] = function()
      return {
        from_file = function()
          image_calls = image_calls + 1
          return { render = function() end }
        end,
      }
    end
    package.loaded["image"] = nil

    local tmp = vim.fn.tempname()
    local f = assert(io.open(tmp, "wb"))
    f:write("PNG")
    f:close()

    local ok = format.render_image_preview(1, tmp, "image/png", 7)
    assert.is_true(ok)
    assert.equals(1, #snacks_calls)
    assert.equals(tmp, snacks_calls[1].src)
    assert.equals(0, image_calls)
  end)

  it("renders image responses automatically in body view", function()
    local render_calls = 0
    local clear_calls = 0
    local tmp = vim.fn.tempname()
    local f = assert(io.open(tmp, "wb"))
    f:write("PNG")
    f:close()

    package.preload["image"] = function()
      return {
        from_file = function()
          return {
            clear = function()
              clear_calls = clear_calls + 1
            end,
            render = function() render_calls = render_calls + 1 end,
          }
        end,
      }
    end
    package.loaded["image"] = nil

    state.last_response = {
      body = "",
      content_type = "image/png",
      metadata = {
        file_path = tmp,
        file_content_type = "image/png",
        file_size = 3,
      },
    }

    view.show_view("body")

    assert.equals(1, render_calls)
    local saw_anchor = false
    for _, call in ipairs(mock.calls) do
      if type(call) == "table" and call.pos and call.pos[1] == 18 then
        saw_anchor = true
        break
      end
    end
    assert.is_true(saw_anchor)

    format.close_image_preview()
    assert.equals(1, clear_calls)
  end)

  it("skips image.nvim for svg and falls back externally", function()
    local image_calls = 0
    package.preload["image"] = function()
      return {
        from_file = function()
          image_calls = image_calls + 1
          return { render = function() end }
        end,
      }
    end
    package.loaded["image"] = nil

    local tmp = vim.fn.tempname()
    local f = assert(io.open(tmp, "wb"))
    f:write("<svg></svg>")
    f:close()

    local ok = format.render_image_preview(1, tmp, "image/svg+xml")
    assert.is_false(ok)
    assert.equals(0, image_calls)

    format.open_image_external(tmp)
    assert.is_true(has_call("jobstart"))
  end)

  it("uses snacks.image for svg when available", function()
    local snacks_calls = {}
    package.preload["snacks"] = function()
      return {
        image = {
          supports = function(_) return true end,
          supports_terminal = function() return true end,
          placement = {
            new = function(buf, src, opts)
              table.insert(snacks_calls, { buf = buf, src = src, opts = opts })
              return { close = function() end }
            end,
          },
        },
      }
    end
    package.loaded["snacks"] = nil

    local tmp = vim.fn.tempname()
    local f = assert(io.open(tmp, "wb"))
    f:write("<svg></svg>")
    f:close()

    local ok = format.render_image_preview(1, tmp, "image/svg+xml")
    assert.is_true(ok)
    assert.equals(1, #snacks_calls)
    assert.equals(tmp, snacks_calls[1].src)
  end)

  it("has_snacks_image returns true when snacks is available", function()
    package.preload["snacks"] = function()
      return {
        image = {
          supports = function(_) return true end,
          supports_terminal = function() return true end,
        },
      }
    end
    package.loaded["snacks"] = nil
    format = require("poste.http.format")

    assert.is_true(format.has_snacks_image())
  end)

  it("has_snacks_image returns false when snacks is unavailable", function()
    assert.is_false(format.has_snacks_image())
  end)

  it("close_image_preview cleans up snacks placement", function()
    local close_calls = 0
    package.preload["snacks"] = function()
      return {
        image = {
          supports = function(_) return true end,
          supports_terminal = function() return true end,
          placement = {
            new = function()
              return {
                close = function() close_calls = close_calls + 1 end,
              }
            end,
          },
        },
      }
    end
    package.loaded["snacks"] = nil
    format = require("poste.http.format")

    local tmp = vim.fn.tempname()
    local f = assert(io.open(tmp, "wb"))
    f:write("PNG")
    f:close()

    format.render_image_preview(1, tmp, "image/png")
    format.close_image_preview()
    assert.equals(1, close_calls)
  end)
end)
