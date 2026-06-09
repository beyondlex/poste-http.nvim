--- Poste CLI binary installer.
--- Downloads prebuilt binary from GitHub Releases to stdpath("data")/poste/bin/.
--- Called automatically from plugin/poste.lua on first load.
local M = {}

local REPO = "beyondlex/poste"
local BASE = vim.fn.stdpath("data") .. "/poste"
local BIN_DIR = BASE .. "/bin"
local VERSION_FILE = BASE .. "/.version"

--- Detect platform string matching release asset names.
local function detect_platform()
  local uname = vim.loop.os_uname()
  local sys = uname.sysname
  local machine = uname.machine
  if sys == "Linux" and machine == "x86_64" then return "x86_64-linux" end
  if sys == "Linux" and machine == "aarch64" then return "aarch64-linux" end
  if sys == "Darwin" and machine == "x86_64" then return "x86_64-macos" end
  if sys == "Darwin" and machine == "arm64" then return "aarch64-macos" end
  if sys:find("Windows") and machine == "x86_64" then return "x86_64-windows" end
  return nil
end

--- Full path to the binary (including .exe suffix on Windows).
local function binary_path()
  local plat = detect_platform()
  if plat and plat:find("windows") then
    return BIN_DIR .. "/poste.exe"
  end
  return BIN_DIR .. "/poste"
end

--- Archive extension for the platform.
local function archive_ext(platform)
  if platform:find("windows") then return ".zip" end
  return ".tar.gz"
end

--- Download URL for a release asset.
--- @param platform string  e.g. "x86_64-linux"
--- @param version string   e.g. "latest" or "v0.1.0"
function M.download_url(platform, version)
  version = version or "latest"
  local arch = "poste-" .. platform .. archive_ext(platform)
  if version == "latest" then
    return string.format("https://github.com/%s/releases/latest/download/%s", REPO, arch)
  end
  return string.format("https://github.com/%s/releases/download/%s/%s", REPO, version, arch)
end

--- Checksum URL for a release asset.
function M.checksum_url(platform, version)
  version = version or "latest"
  local arch = "poste-" .. platform .. archive_ext(platform) .. ".sha256"
  if version == "latest" then
    return string.format("https://github.com/%s/releases/latest/download/%s", REPO, arch)
  end
  return string.format("https://github.com/%s/releases/download/%s/%s", REPO, version, arch)
end

--- Verify SHA256 checksum of downloaded archive against release asset.
--- Returns true if checksum matches or verification is unavailable.
local function verify_checksum(archive_path, platform, version)
  local url = M.checksum_url(platform, version)
  local tmp = BIN_DIR .. "/checksum.tmp"

  local ok = vim.fn.system({ "curl", "-sfL", url, "-o", tmp })
  if vim.v.shell_error ~= 0 then
    -- checksum file unavailable — skip verification
    pcall(os.remove, tmp)
    return true
  end

  local f = io.open(tmp, "r")
  if not f then return true end
  local expected = f:read("*a"):match("^(%S+)")
  f:close()
  pcall(os.remove, tmp)

  if not expected then return true end

  local actual = vim.fn.system({ "sha256sum", archive_path }):match("^(%S+)")
  if not actual then
    -- macOS has shasum
    actual = vim.fn.system({ "shasum", "-a", "256", archive_path }):match("^(%S+)")
  end

  return actual == expected
end

--- Download and install the poste binary.
--- @param version string  tag or "latest" (default)
--- @return boolean        success
function M.download(version)
  version = version or "latest"
  local platform = detect_platform()
  if not platform then
    vim.notify(
      "[Poste] Unsupported platform: " .. vim.inspect(vim.loop.os_uname()),
      vim.log.levels.ERROR
    )
    return false
  end

  vim.fn.mkdir(BIN_DIR, "p")

  local url = M.download_url(platform, version)
  local ext = archive_ext(platform)
  local tmp_archive = BIN_DIR .. "/download" .. ext

  vim.notify("[Poste] Downloading " .. url, vim.log.levels.INFO)

  local ok = vim.fn.system({ "curl", "-fL", url, "-o", tmp_archive })
  if vim.v.shell_error ~= 0 then
    vim.notify("[Poste] Download failed (exit " .. vim.v.shell_error .. ")", vim.log.levels.ERROR)
    pcall(os.remove, tmp_archive)
    return false
  end

  if not verify_checksum(tmp_archive, platform, version) then
    vim.notify("[Poste] Checksum mismatch — download corrupted", vim.log.levels.ERROR)
    pcall(os.remove, tmp_archive)
    return false
  end

  if ext == ".zip" then
    vim.fn.system({ "powershell", "-Command",
      "Expand-Archive", "-Force",
      "-Path", tmp_archive,
      "-DestinationPath", BIN_DIR
    })
  else
    vim.fn.system({ "tar", "xzf", tmp_archive, "-C", BIN_DIR })
  end

  pcall(os.remove, tmp_archive)

  if platform:find("windows") then
    local final_path = BIN_DIR .. "/poste.exe"
    -- tar/zip may create a subdirectory; flatten if needed
    if vim.fn.filereadable(final_path) ~= 1 then
      vim.fn.system({ "powershell", "-Command",
        "Get-ChildItem -Recurse -Filter poste.exe " ..
        "-Path " .. BIN_DIR .. " | Move-Item -Destination " .. BIN_DIR .. "/poste.exe -Force"
      })
    end
  else
    vim.fn.system({ "chmod", "+x", BIN_DIR .. "/poste" })
  end

  local version_tag = version
  if not version_tag:match("^v") and version_tag ~= "latest" then
    version_tag = "v" .. version_tag
  end
  local f = io.open(VERSION_FILE, "w")
  if f then
    f:write(version_tag .. "\n")
    f:close()
  end

  vim.notify("[Poste] Installed " .. version_tag .. " (" .. platform .. ")", vim.log.levels.INFO)
  return true
end

--- Ensure the binary is available.
--- Called at plugin startup. Returns the binary path if found, nil otherwise.
--- Checks (in order): user config, local dev build, default data path, then attempted download.
function M.ensure()
  -- 1. User-configured path (state.config.poste_binary)
  local state_ok, state = pcall(require, "poste.state")
  if state_ok and state.config.poste_binary ~= "" then
    local p = state.config.poste_binary
    if vim.fn.filereadable(p) == 1 then
      return vim.fn.fnamemodify(p, ":p")
    end
  end

  -- 2. Local dev build (in-repo development)
  for _, path in ipairs({ "./target/debug/poste", "./target/release/poste" }) do
    if vim.fn.filereadable(path) == 1 then
      return vim.fn.fnamemodify(path, ":p")
    end
  end

  -- 3. Default installed path (stdpath data)
  local bp = binary_path()
  if vim.fn.filereadable(bp) == 1 then
    return bp
  end

  -- 4. Fallback: attempt download
  local ok = M.download("latest")
  if not ok then
    vim.notify(
      "[Poste] Binary not found and download failed. "
        .. "Set `vim.g.poste_binary = \"/path/to/poste\"` in your config.",
      vim.log.levels.WARN
    )
    return nil
  end
  return binary_path()
end

--- Force re-download the latest binary.
function M.update()
  pcall(os.remove, binary_path())
  pcall(os.remove, VERSION_FILE)
  return M.download("latest")
end

--- Return installed version string, or nil.
function M.installed_version()
  local f = io.open(VERSION_FILE, "r")
  if not f then return nil end
  local v = f:read("*l")
  f:close()
  return v
end

return M
