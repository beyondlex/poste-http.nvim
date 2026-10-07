local mock = require("helpers.mock_nvim")
local state = require("poste-http.state")

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
  local temp_files = {}

  local function make_tmp_file(content)
    local tmp = vim.fn.tempname()
    table.insert(temp_files, tmp)
    local f = assert(io.open(tmp, "wb"))
    f:write(content)
    f:close()
    return tmp
  end

  -- Minimal PNG header (IHDR) with the given pixel dimensions.
  local function png_bytes(w, h)
    local function be32(n)
      return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256, n % 256)
    end
    return "\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(w) .. be32(h) .. "\8\6\0\0\0"
  end

  before_each(function()
    original_image_preload = package.preload["image"]
    original_snacks_preload = package.preload["snacks"]
    mock.setup({ buf_line_count = 18, current_cursor = { 1, 0 } })
    state.last_response = nil
    state.pending_request = nil
    state.current_view = "body"
    package.loaded["poste-http.http.format"] = nil
    package.loaded["poste-http.http.view"] = nil
    format = require("poste-http.http.format")
    view = require("poste-http.http.view")
  end)

  after_each(function()
    mock.teardown()
    for _, tmp in ipairs(temp_files) do
      pcall(os.remove, tmp)
    end
    temp_files = {}
    package.loaded["poste-http.http.format"] = nil
    package.loaded["poste-http.http.view"] = nil
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

    local tmp = make_tmp_file("PNG")

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

    local tmp = make_tmp_file("PNG")

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

    local tmp = make_tmp_file("PNG")

    local ok = format.render_image_preview(1, tmp, "image/png", 7)
    assert.is_true(ok)
    assert.equals(1, #snacks_calls)
    assert.equals(tmp, snacks_calls[1].src)
    assert.equals(0, image_calls)
  end)

  it("renders image responses automatically in body view", function()
    local render_calls = 0
    local clear_calls = 0
    local tmp = make_tmp_file("PNG")

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
      if type(call) == "table" and call.pos and call.pos[1] == 17 then
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

    local tmp = make_tmp_file("<svg></svg>")

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

    local tmp = make_tmp_file("<svg></svg>")

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
    format = require("poste-http.http.format")

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
    format = require("poste-http.http.format")

    local tmp = make_tmp_file("PNG")

    format.render_image_preview(1, tmp, "image/png")
    format.close_image_preview()
    assert.equals(1, close_calls)
  end)

  -- Floating window preview tests
  describe("floating window preview", function()
    it("render_image_float creates a floating window", function()
      local tmp = make_tmp_file("PNG")

      local ok = format.render_image_float(tmp, "image/png")
      assert.is_true(ok)
      assert.is_true(has_call("nvim_open_win"))
    end)

    it("render_image_float creates floating window with snacks.image", function()
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

      local tmp = make_tmp_file("PNG")

      local ok = format.render_image_float(tmp, "image/png")
      assert.is_true(ok)
      assert.is_true(has_call("nvim_open_win"))
      assert.equals(1, #snacks_calls)
      assert.equals(tmp, snacks_calls[1].src)
    end)

    it("render_image_float creates floating window with image.nvim", function()
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

      local tmp = make_tmp_file("PNG")

      local ok = format.render_image_float(tmp, "image/png")
      assert.is_true(ok)
      assert.is_true(has_call("nvim_open_win"))
      assert.equals(2, #image_calls)
      assert.equals(tmp, image_calls[1].path)
    end)

    it("close_image_preview closes floating window", function()
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
      format = require("poste-http.http.format")

      local tmp = make_tmp_file("PNG")

      format.render_image_float(tmp, "image/png")
      assert.is_true(has_call("nvim_open_win"))
      format.close_image_preview()
      assert.is_true(has_call("nvim_win_close"))
    end)

    it("preview_image_url_float downloads and shows in floating window", function()
      -- Mock the async download at the image module level; the flow must go
      -- through download_image_url_async so curl never blocks the editor.
      local image_mod = require("poste-http.http.format.image")
      local download_called = false
      local original_async = image_mod.download_image_url_async
      image_mod.download_image_url_async = function(url, on_done)
        download_called = true
        on_done(make_tmp_file("PNG"), "image/png")
        return true
      end

      local url = "https://example.com/image-float-" .. tostring(os.clock()) .. ".png"
      local ok = format.preview_image_url_float(url)
      assert.is_true(ok)
      assert.is_true(download_called)
      assert.is_true(has_call("nvim_open_win"))

      -- Restore original function
      image_mod.download_image_url_async = original_async
    end)

    it("preview_image_url_float renders a fresh cached copy without downloading", function()
      local image_mod = require("poste-http.http.format.image")
      local image_cache = require("poste-http.http.image_cache")
      local url = "https://example.com/image-cached-" .. tostring(os.clock()) .. ".png"
      local cached = image_cache.cache_path_for_url(url)
      -- The img/ directory is created by the download path (new_temp_download_path
      -- mkdirs), never by cache_path_for_url — a clean cache dir needs it here
      -- or io.open fails with ENOENT (2026-10-08 review: suite exit 1 with the
      -- test never having run).
      vim.fn.mkdir(vim.fn.fnamemodify(cached, ":h"), "p")
      table.insert(temp_files, cached)
      local f = assert(io.open(cached, "wb"))
      f:write("PNG")
      f:close()

      local async_called = false
      local original_async = image_mod.download_image_url_async
      image_mod.download_image_url_async = function()
        async_called = true
        return true
      end

      local ok = format.preview_image_url_float(url)
      image_mod.download_image_url_async = original_async
      assert.is_true(ok)
      assert.is_false(async_called, "fresh cache hit must not download")
      assert.is_true(has_call("nvim_open_win"))
    end)

    it("preview_image_url_float notifies when the download fails", function()
      local image_mod = require("poste-http.http.format.image")
      local original_async = image_mod.download_image_url_async
      image_mod.download_image_url_async = function(url, on_done)
        -- job started fine, but curl exits non-zero → path is nil
        on_done(nil, "image/png")
        return true
      end
      local notified = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level) table.insert(notified, { msg = msg, level = level }) end

      local url = "https://example.com/image-fail-" .. tostring(os.clock()) .. ".png"
      local ok = format.preview_image_url_float(url)
      vim.notify = orig_notify
      image_mod.download_image_url_async = original_async

      assert.is_true(ok, "the preview flow itself started")
      -- one truthful "Downloading..." progress note, then the failure
      assert.equals(2, #notified)
      assert.truthy(notified[1].msg:match("Downloading image"))
      assert.equals(vim.log.levels.WARN, notified[2].level)
      assert.truthy(notified[2].msg:match("Failed to download"))
    end)

    it("render_image_float shows gray meta below the image", function()
      local tmp = make_tmp_file(png_bytes(1024, 768))

      local ok = format.render_image_float(tmp, "image/png")
      assert.is_true(ok)

      local buf_lines = nil
      local open_config = nil
      local meta_hl_rows = {}
      for _, call in ipairs(mock.calls) do
        if type(call) == "table" and call.start == 0 and call.lines then
          buf_lines = call.lines
        end
        if type(call) == "table" and call.config and call.config.title then
          open_config = call.config
        end
        if type(call) == "table" and call.opts and call.opts.hl_group == "PosteImageMeta" then
          meta_hl_rows[#meta_hl_rows + 1] = call.line
        end
      end

      assert.is_table(buf_lines)
      -- row 0 is the blank anchor the image renders below; meta follows after
      assert.equals("", buf_lines[1])
      local saw_dims = false
      for _, l in ipairs(buf_lines) do
        if l:match("1024%*768") then saw_dims = true end
      end
      assert.is_true(saw_dims, "meta lines should include pixel dimensions")

      -- meta rows are highlighted gray
      assert.is_true(#meta_hl_rows >= 1, "meta lines should get the PosteImageMeta highlight")
      assert.is_true(meta_hl_rows[1] >= 1, "meta highlight should not cover the blank anchor row")

      assert.is_table(open_config)
      assert.match("PNG", open_config.title)
      assert.match("1024%*768", open_config.title)
      assert.is_true(open_config.width < 80, "popup should hug image instead of staying 80 cols wide")
      assert.is_true(open_config.height >= #buf_lines, "popup should fit blank anchor + meta rows")
    end)

    it("render_image_float draws below meta lines (image.nvim)", function()
      local image_calls = {}
      package.preload["image"] = function()
        return {
          from_file = function(path, opts)
            table.insert(image_calls, { path = path, opts = opts })
            return { render = function() table.insert(image_calls, "render") end }
          end,
        }
      end
      package.loaded["image"] = nil

      local tmp = make_tmp_file(png_bytes(64, 64))
      local ok = format.render_image_float(tmp, "image/png")
      assert.is_true(ok)

      local buf_lines = nil
      for _, call in ipairs(mock.calls) do
        if type(call) == "table" and call.start == 0 and call.lines then
          buf_lines = call.lines
        end
      end
      -- image.nvim draws at 0-based row == number of buffer lines (below the gray meta)
      assert.equals(#buf_lines, image_calls[1].opts.y)
    end)

    it("render_image_float anchors snacks.image on the blank top row", function()
      local snacks_calls = {}
      package.preload["snacks"] = function()
        return {
          image = {
            supports = function() return true end,
            supports_terminal = function() return true end,
            placement = {
              new = function(buf, src, opts)
                table.insert(snacks_calls, opts)
                return { close = function() end }
              end,
            },
          },
        }
      end
      package.loaded["snacks"] = nil

      local tmp = make_tmp_file(png_bytes(64, 64))
      local ok = format.render_image_float(tmp, "image/png")
      assert.is_true(ok)

      local buf_lines = nil
      for _, call in ipairs(mock.calls) do
        if type(call) == "table" and call.start == 0 and call.lines then
          buf_lines = call.lines
        end
      end

      assert.is_table(snacks_calls[1].pos)
      assert.equals(1, snacks_calls[1].pos[1], "snacks anchors on the blank top row")
      assert.is_true(
        snacks_calls[1].pos[1] <= #buf_lines,
        "snacks requires pos row <= buf line count (placement:valid)"
      )
      -- render area is constrained so the image fits above the meta lines
      assert.is_number(snacks_calls[1].width)
      assert.is_number(snacks_calls[1].height)
      assert.is_true(snacks_calls[1].width > 0)
      assert.is_true(snacks_calls[1].height > 0)
    end)
  end)

  describe("unified popup preview", function()
    it("preview_response_image opens a popup for image responses (no external viewer)", function()
      local buf = require("poste-http.http.buffer")
      local tmp = make_tmp_file("PNG")
      state.last_response = {
        body = "",
        content_type = "image/png",
        metadata = { file_path = tmp, file_content_type = "image/png", file_size = 3 },
      }

      local ok = buf.preview_response_image()
      assert.is_true(ok)
      assert.is_true(has_call("nvim_open_win"), "image response should preview in a popup")
      assert.is_false(has_call("jobstart"), "image response should not open the system viewer")
    end)

    it("preview_response_image returns false for non-image responses", function()
      local buf = require("poste-http.http.buffer")
      state.last_response = {
        body = "{}",
        content_type = "application/json",
        metadata = { file_path = "cached.json", file_content_type = "application/json" },
      }

      assert.is_false(buf.preview_response_image())
      assert.is_false(has_call("nvim_open_win"))
      assert.is_false(has_call("jobstart"))
    end)
  end)

  describe("download URL caching", function()
    local saved_config
    local saved_system
    local system_calls
    local cache_dir
    local cache_files = {}

    -- Simulate a successful curl that writes the file passed after "-o".
    local function patch_curl()
      saved_system = vim.fn.system
      vim.fn.system = function(cmd)
        table.insert(system_calls, cmd)
        if type(cmd) == "table" then
          for i = 1, #cmd - 1 do
            if cmd[i] == "-o" and cmd[i + 1] then
              local f = assert(io.open(cmd[i + 1], "wb"))
              f:write("PNG")
              f:close()
            end
          end
        end
      end
    end

    before_each(function()
      saved_config = state.config
      state.config = vim.tbl_deep_extend("force", {}, saved_config)
      cache_dir = vim.fn.tempname()
      vim.fn.mkdir(cache_dir, "p")
      vim.fn.mkdir(cache_dir .. "/img", "p")
      state.config.response_cache_dir = cache_dir
      state.config.image_url_cache_ttl_seconds = 3600
      system_calls = {}
      patch_curl()
      saved_system({ "true" }) -- reset v:shell_error to 0 so downloads succeed
    end)

    after_each(function()
      for _, p in ipairs(cache_files) do
        pcall(os.remove, p)
      end
      cache_files = {}
      pcall(vim.loop.fs_rmdir, cache_dir .. "/img")
      pcall(vim.loop.fs_rmdir, cache_dir)
      state.config = saved_config
      vim.fn.system = saved_system
    end)

    it("cache_path_for_url is stable per URL", function()
      local url = "https://example.com/images/photo.png"
      local p1 = format.cache_path_for_url(url)
      local p2 = format.cache_path_for_url(url)
      assert.equals(p1, p2, "same URL should map to the same cache path")
      assert.is_not_equals(p1, format.cache_path_for_url(url .. "?time=1"), "different URL should map elsewhere")
      assert.match("%.png$", p1)
      assert.match("^" .. cache_dir .. "/img/", p1)
    end)

    it("download_image_url reuses a fresh cached copy without curling", function()
      local url = "https://example.com/images/logo.png"
      local cached = format.cache_path_for_url(url)
      local f = assert(io.open(cached, "wb"))
      f:write("FRESH")
      f:close()
      table.insert(cache_files, cached)

      local res, ct = format.download_image_url(url)
      assert.equals(cached, res)
      assert.equals("image/png", ct)
      assert.equals(0, #system_calls, "no download should happen for a fresh cache hit")
    end)

    it("download_image_url re-downloads once the cache expires and replaces it", function()
      local url = "https://example.com/images/now.png"
      local cached = format.cache_path_for_url(url)
      local f = assert(io.open(cached, "wb"))
      f:write("STALE")
      f:close()
      table.insert(cache_files, cached)
      -- age the cached file past the TTL so the fresh-cache branch is skipped
      local uv = vim.uv or vim.loop
      uv.fs_utime(cached, 0, 0)

      local res, ct = format.download_image_url(url)
      assert.equals(1, #system_calls, "cache miss should trigger a download")
      assert.equals("image/png", ct)
      assert.equals(cached, res, "fresh download should be moved into the cache path")
      local f2 = io.open(res, "rb")
      assert.equals("PNG", f2:read("*a"))
      f2:close()
    end)

    it("download_image_url falls back to a stale cached copy on download failure", function()
      local url = "https://example.com/images/fallback.png"
      local cached = format.cache_path_for_url(url)
      local f = assert(io.open(cached, "wb"))
      f:write("STALE")
      f:close()
      table.insert(cache_files, cached)
      local uv = vim.uv or vim.loop
      uv.fs_utime(cached, 0, 0) -- stale: expired + re-download fails

      -- make the "curl" fail by omitting the -o write and exiting non-zero
      vim.fn.system = function(cmd)
        table.insert(system_calls, cmd)
        saved_system({ "false" })
      end

      local res = format.download_image_url(url)
      assert.equals(cached, res, "stale cache should be used when re-download fails")
    end)
  end)
end)
