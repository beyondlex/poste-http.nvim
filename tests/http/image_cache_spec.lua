-- Tests for the image URL download/cache module (poste-http.http.image_cache).
--
-- Split from format/image.lua (2026-08-30 review U6): fetching and caching
-- preview artifacts is infrastructure, not response-body rendering.

local image_cache = require("poste-http.http.image_cache")
local state = require("poste-http.state")

describe("poste-http.http.image_cache", function()
  local saved_config
  local saved_system
  local cache_dir
  local cache_files = {}

  local function make_cache_file(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "wb"))
    f:write(content or "PNG")
    f:close()
    table.insert(cache_files, path)
  end

  before_each(function()
    saved_config = state.config
    saved_system = vim.fn.system
    cache_dir = vim.fn.tempname() .. "_imgcache"
    state.config = vim.deepcopy(state.config)
    state.config.response_cache_dir = cache_dir
    state.config.image_url_cache_ttl_seconds = 3600
  end)

  after_each(function()
    for _, f in ipairs(cache_files) do
      pcall(os.remove, f)
    end
    cache_files = {}
    pcall(vim.fn.delete, cache_dir, "rf")
    vim.fn.system = saved_system
    state.config = saved_config
  end)

  describe("content type detection", function()
    it("is_image_content_type accepts image mimes, ignores parameters", function()
      assert.is_true(image_cache.is_image_content_type("image/png"))
      assert.is_true(image_cache.is_image_content_type("image/jpeg; charset=binary"))
      assert.is_true(image_cache.is_image_content_type("image/vnd.microsoft.icon"))
      assert.is_false(image_cache.is_image_content_type("application/json"))
      assert.is_false(image_cache.is_image_content_type(nil))
    end)

    it("guess_image_content_type maps URL extensions", function()
      assert.equals("image/png", image_cache.guess_image_content_type("https://x/a.png"))
      assert.equals("image/svg+xml", image_cache.guess_image_content_type("https://x/a.svg"))
      assert.equals("image/x-icon", image_cache.guess_image_content_type("https://x/favicon.ico"))
      assert.is_nil(image_cache.guess_image_content_type("https://x/a.txt"))
      assert.is_nil(image_cache.guess_image_content_type("https://x/noext"))
    end)
  end)

  describe("cache paths", function()
    it("are stable per URL and vary by content type", function()
      local url = "https://example.com/photo"
      local p1 = image_cache.cache_path_for_url(url)
      local p2 = image_cache.cache_path_for_url(url)
      assert.equals(p1, p2)
      assert.matches("^" .. cache_dir .. "/img/", p1)
      assert.matches("%.png$", p1, "png is the default content type")
      assert.matches("%.jpg$", image_cache.cache_path_for_url(url, "image/jpeg"))
      assert.matches("%.svg$", image_cache.cache_path_for_url(url, "image/svg+xml"))
    end)

    it("use different paths for different URLs", function()
      local a = image_cache.cache_path_for_url("https://x/a.png")
      local b = image_cache.cache_path_for_url("https://x/b.png")
      assert.not_equals(a, b)
    end)
  end)

  describe("download_image_url", function()
    it("reuses a fresh cached copy without downloading", function()
      local url = "https://cache-unit/fresh.png"
      local cached = image_cache.cache_path_for_url(url)
      make_cache_file(cached, "FRESH")

      local system_calls = 0
      vim.fn.system = function()
        system_calls = system_calls + 1
        return ""
      end

      local path, ct = image_cache.download_image_url(url)
      assert.equals(cached, path)
      assert.equals("image/png", ct)
      assert.equals(0, system_calls)
    end)

    it("downloads when ttl caching is disabled and returns the temp file", function()
      state.config.image_url_cache_ttl_seconds = 0
      local url = "https://cache-unit/nottl.png"

      vim.fn.system = function(cmd)
        -- end-of-options guard: the URL is the only free-position argv slot
        -- (curl_exec precedent), so `--` must precede it
        assert.equals("--", cmd[#cmd - 1], "URL must be guarded with --")
        assert.equals(url, cmd[#cmd])
        -- simulate curl: write the body to the -o target
        for i, arg in ipairs(cmd) do
          if arg == "-o" then
            local f = assert(io.open(cmd[i + 1], "wb"))
            f:write("BODY")
            f:close()
          end
        end
        return ""
      end

      local path, ct = image_cache.download_image_url(url)
      assert.equals("image/png", ct)
      assert.matches("/img/url_", path)
      assert.matches("%.png$", path)
      local f = io.open(path, "rb")
      assert.equals("BODY", f:read("*a"))
      f:close()
      -- temp files are tracked for cleanup
      image_cache.cleanup_temp_files()
      assert.equals(0, vim.fn.filereadable(path), "cleanup must remove temp downloads")
    end)

    it("replaces an expired cache entry via download", function()
      local url = "https://cache-unit/expire.png"
      local cached = image_cache.cache_path_for_url(url)
      make_cache_file(cached, "STALE")
      local uv = vim.uv or vim.loop
      uv.fs_utime(cached, 0, 0) -- age past ttl

      vim.fn.system = function(cmd)
        for i, arg in ipairs(cmd) do
          if arg == "-o" then
            local f = assert(io.open(cmd[i + 1], "wb"))
            f:write("NEW")
            f:close()
          end
        end
        return ""
      end

      local path, ct = image_cache.download_image_url(url)
      assert.equals(cached, path, "fresh download moves into the cache path")
      assert.equals("image/png", ct)
      local f = io.open(path, "rb")
      assert.equals("NEW", f:read("*a"))
      f:close()
    end)

    it("falls back to a stale cached copy when the download fails", function()
      local url = "https://cache-unit/fallback.png"
      local cached = image_cache.cache_path_for_url(url)
      make_cache_file(cached, "STALE")
      local uv = vim.uv or vim.loop
      uv.fs_utime(cached, 0, 0)

      -- run the `false` shell command: exits non-zero, sets shell_error
      vim.fn.system = function() saved_system({ "false" }) end

      local path, ct = image_cache.download_image_url(url)
      assert.equals(cached, path)
      assert.equals("image/png", ct)
    end)

    it("returns nil when there is no cache and the download fails", function()
      local url = "https://cache-unit/none.png"
      vim.fn.system = function() saved_system({ "false" }) end
      local path, ct = image_cache.download_image_url(url)
      assert.is_nil(path)
      assert.equals("image/png", ct)
    end)

    it("fails the download on an HTTP error page (curl -f) instead of caching it", function()
      -- Regression: without -f, a 404/500 error page exited curl with 0 and
      -- its HTML body was renamed into the cache as the "image" — rendered
      -- as garbage and served by the TTL (and the stale fallback) for the
      -- whole cache window. -f must be part of the argv so HTTP errors take
      -- the same fallback path as a transport failure.
      local url = "https://cache-unit/error-page.png"
      local seen_cmd
      vim.fn.system = function(cmd)
        seen_cmd = cmd
        return ""
      end
      image_cache.download_image_url(url)
      local has_fail = false
      for _, arg in ipairs(seen_cmd) do
        if arg == "-f" then has_fail = true end
      end
      assert.is_true(has_fail, "curl must run with -f so HTTP errors fail the call")
    end)
  end)

  describe("temp file tracking", function()
    it("cleanup_temp_files removes registered files and resets the list", function()
      local f1 = vim.fn.tempname() .. "_t1"
      local f2 = vim.fn.tempname() .. "_t2"
      io.open(f1, "w"):close()
      io.open(f2, "w"):close()
      image_cache.register_temp_file(f1)
      image_cache.register_temp_file(f2)
      image_cache.cleanup_temp_files()
      assert.equals(0, vim.fn.filereadable(f1))
      assert.equals(0, vim.fn.filereadable(f2))
      -- second call is a safe no-op
      assert.has_no_errors(image_cache.cleanup_temp_files)
    end)
  end)

  describe("cached_image_path", function()
    it("returns the cache path only while the copy is fresh", function()
      local url = "https://cache-unit/freshlookup.png"
      local cached = image_cache.cache_path_for_url(url)
      make_cache_file(cached, "FRESH")
      assert.equals(cached, image_cache.cached_image_path(url))
    end)

    it("returns nil when nothing is cached", function()
      assert.is_nil(image_cache.cached_image_path("https://cache-unit/never.png"))
    end)
  end)

  describe("download_image_url_async", function()
    -- The helper schedules on_exit like the real event loop; drain with vim.wait.
    local function stub_jobstart(exit_code, body)
      local saved = vim.fn.jobstart
      vim.fn.jobstart = function(cmd, opts)
        local out
        for i, arg in ipairs(cmd) do
          if arg == "-o" then out = cmd[i + 1] end
        end
        if body and out then
          local f = io.open(out, "wb")
          f:write(body)
          f:close()
        end
        vim.schedule(function() opts.on_exit(42, exit_code) end)
        return 42
      end
      return saved
    end

    it("serves a fresh cached copy synchronously without starting a job", function()
      local url = "https://cache-unit/async-fresh.png"
      local cached = image_cache.cache_path_for_url(url)
      make_cache_file(cached, "FRESH")
      local jobs = 0
      local saved = vim.fn.jobstart
      vim.fn.jobstart = function() jobs = jobs + 1; return 1 end
      local got
      image_cache.download_image_url_async(url, function(path, ct) got = { path = path, ct = ct } end)
      vim.fn.jobstart = saved
      assert.equals(cached, got.path)
      assert.equals("image/png", got.ct)
      assert.equals(0, jobs, "cache hit must not spawn curl")
    end)

    it("downloads via jobstart and moves the file into the cache", function()
      local url = "https://cache-unit/async-download.png"
      local cached = image_cache.cache_path_for_url(url)
      local saved = stub_jobstart(0, "BODY")
      local got
      image_cache.download_image_url_async(url, function(path, ct) got = { path = path, ct = ct } end)
      vim.wait(2000, function() return got ~= nil end)
      vim.fn.jobstart = saved
      assert.is_truthy(got, "callback must fire")
      assert.equals(cached, got.path)
      assert.equals("image/png", got.ct)
      local f = io.open(cached, "rb")
      assert.equals("BODY", f:read("*a"))
      f:close()
    end)

    it("falls back to a stale cached copy when the download fails", function()
      local url = "https://cache-unit/async-stale.png"
      local cached = image_cache.cache_path_for_url(url)
      make_cache_file(cached, "STALE")
      local saved = stub_jobstart(7, nil)
      local got
      image_cache.download_image_url_async(url, function(path, ct) got = { path = path, ct = ct } end)
      vim.wait(2000, function() return got ~= nil end)
      vim.fn.jobstart = saved
      assert.equals(cached, got.path, "stale copy wins over total failure")
      assert.equals("image/png", got.ct)
    end)

    it("calls back with nil when the download fails and no cache exists", function()
      local url = "https://cache-unit/async-dead.png"
      local saved = stub_jobstart(7, nil)
      local got = "unset"
      image_cache.download_image_url_async(url, function(path) got = path end)
      vim.wait(2000, function() return got ~= "unset" end)
      vim.fn.jobstart = saved
      assert.is_nil(got)
    end)
  end)
end)
