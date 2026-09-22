--- Image URL download + on-disk cache for image previews.
---
--- Split from format/image.lua (2026-08-30 review U6): `format/` is the
--- response-body → lines rendering layer; fetching and caching preview
--- artifacts is infrastructure. No windows, no adapter probing — pure
--- file/network logic so it is unit-testable headless.
---
--- Content-type detection lives here too: the download cache, the preview
--- renderers and the URL guesser all key off the same mime tables.

local M = {}

-- Extension for a cached/downloaded image file, by content type.
local image_exts = {
  ["image/png"] = ".png",
  ["image/jpeg"] = ".jpg",
  ["image/gif"] = ".gif",
  ["image/webp"] = ".webp",
  ["image/svg+xml"] = ".svg",
  ["image/avif"] = ".avif",
  ["image/bmp"] = ".bmp",
  ["image/tiff"] = ".tiff",
  ["image/x-icon"] = ".ico",
}

-- URL file extension → content type (for guessing from a URL).
local image_url_exts = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  svg = "image/svg+xml",
  avif = "image/avif",
  bmp = "image/bmp",
  tiff = "image/tiff",
  tif = "image/tiff",
  ico = "image/x-icon",
}

-- Renderable image content types (parameters stripped before lookup).
local image_content_types = {
  ["image/png"] = true,
  ["image/jpeg"] = true,
  ["image/gif"] = true,
  ["image/webp"] = true,
  ["image/svg+xml"] = true,
  ["image/avif"] = true,
  ["image/bmp"] = true,
  ["image/tiff"] = true,
  ["image/x-icon"] = true,
  ["image/vnd.microsoft.icon"] = true,
}

local function extension_for(content_type)
  return image_exts[content_type] or ".bin"
end

function M.is_image_content_type(content_type)
  if not content_type then return false end
  local mime = content_type:match("^([^;]+)") or content_type
  return image_content_types[mime] == true
end

--- Guess the content type from a URL's file extension.
--- @param url string
--- @return string|nil content_type
function M.guess_image_content_type(url)
  local ext = (url:match(".*%.([^%.%?/]+)") or ""):lower()
  return image_url_exts[ext]
end

--- 32-bit XOR via arithmetic (no bit ops; some Lua targets lack `~`/bit.*).
local function bxor32(a, b)
  local r, p = 0, 1
  while a > 0 or b > 0 do
    local a2, b2 = a % 2, b % 2
    if a2 ~= b2 then r = r + p end
    a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
  end
  return r
end

--- Stable hex id for cache filenames derived from a URL.
local function url_hash(str)
  local ok, hex = pcall(vim.fn.sha256, str)
  if ok and hex and #hex >= 16 then return hex:sub(1, 32) end
  -- FNV-1a fallback when sha256 is unavailable
  local hash = 2166136261
  for i = 1, #str do
    hash = (bxor32(hash, str:byte(i)) * 16777619) % 4294967296
  end
  return string.format("%08x", hash)
end

--- Cache path for a downloaded image URL, e.g. <cache_dir>/img/<hash><ext>.
--- @param url string
--- @param content_type string|nil
--- @return string cached_file_path
function M.cache_path_for_url(url, content_type)
  local state = require("poste-http.state")
  local cfg = state.config or {}
  local cache_dir = cfg.response_cache_dir or vim.fn.stdpath("cache") .. "/poste_res"
  local ct = content_type or M.guess_image_content_type(url) or "image/png"
  return cache_dir .. "/img/" .. url_hash(url) .. extension_for(ct)
end

-- Temp downloads registered for deferred cleanup (see cleanup_temp_files).
local temp_files = {}

--- Track a temp file for cleanup_temp_files.
--- @param path string
function M.register_temp_file(path)
  temp_files[#temp_files + 1] = path
end

--- Remove all tracked temp files. Safe to call repeatedly.
function M.cleanup_temp_files()
  for _, f in ipairs(temp_files) do
    pcall(os.remove, f)
  end
  temp_files = {}
end

--- Download an image URL to a cached file.
--- Reuses a fresh cached copy within `image_url_cache_ttl_seconds` (default 1h,
--- 0/negative disables caching). Falls back to a stale cached file if
--- re-download fails.
--- Returns the file path and content type, or nil on failure.
function M.download_image_url(url)
  local ct = M.guess_image_content_type(url) or "image/png"
  local state = require("poste-http.state")
  local cfg = state.config or {}
  local cache_dir = cfg.response_cache_dir or vim.fn.stdpath("cache") .. "/poste_res"
  local ttl = cfg.image_url_cache_ttl_seconds
  local cache_path = M.cache_path_for_url(url, ct)

  -- Fresh cached copy → reuse without downloading
  if ttl and ttl > 0 and cache_path and vim.fn.filereadable(cache_path) == 1 then
    local st = (vim.uv or vim.loop).fs_stat(cache_path)
    local age
    if st and st.mtime and st.mtime.sec then
      age = os.time() - st.mtime.sec
    end
    if age and age < ttl then
      return cache_path, ct
    end
  end

  -- Download to a temp file, then move it into the cache
  vim.fn.mkdir(cache_dir .. "/img", "p")
  local ms = math.floor(((vim.uv or vim.loop).hrtime() / 1e6) % 1000)
  local tmp = cache_dir .. "/img/url_" .. os.date("%Y%m%d_%H%M%S") .. string.format("_%03d", ms) .. extension_for(ct)
  M.register_temp_file(tmp)
  local cmd = { "curl", "-s", "-S", "-L", "--max-time", "15", "-o", tmp }
  -- End-of-options guard (curl_exec precedent): the URL is the only
  -- free-position argv slot, so `--` stops a pathological URL — e.g. one
  -- harvested from a response body — from parsing as flags.
  cmd[#cmd + 1] = "--"
  cmd[#cmd + 1] = url
  vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    table.remove(temp_files)
    pcall(os.remove, tmp)
    -- Download failed → fall back to a stale cached copy if we have one
    if cache_path and vim.fn.filereadable(cache_path) == 1 then
      return cache_path, ct
    end
    return nil, ct
  end

  if ttl and ttl > 0 and cache_path then
    local renamed = pcall(os.rename, tmp, cache_path)
    if renamed then
      table.remove(temp_files)
      return cache_path, ct
    end
  end
  return tmp, ct
end

return M
