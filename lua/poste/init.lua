local uv = vim.uv or vim.loop

local M = {}

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
local config = {
  poste_binary = vim.fn.exepath("poste"),
  default_env = "dev",
  split_direction = "vertical",
  split_size = 80,
  log_file = vim.fn.stdpath("cache") .. "/poste.log",
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local current_env = config.default_env
local response_buffer = nil
local response_window = nil
local last_response = nil       -- parsed JSON table from --json output
local current_view = "body"     -- "body" | "headers" | "verbose"
local indicator_ns = vim.api.nvim_create_namespace("poste_indicator")
local indicator_mark = nil      -- extmark id of current indicator
local indicator_buf = nil       -- buffer the indicator is on
local spinner_timer = nil       -- uv timer for spinner animation

-- Define highlight groups with fg only (no background).
-- Resolve links fully: if the source group is itself a link, follow it.
local function resolve_hl(name)
  local hl = vim.api.nvim_get_hl(0, { name = name })
  while hl.link do
    hl = vim.api.nvim_get_hl(0, { name = hl.link })
  end
  return hl
end

local function setup_hl()
  -- Latency uses a distinct purple color
  vim.api.nvim_set_hl(0, "PosteLatency", { fg = 0xb48ead })

  for _, pair in ipairs({
    { "PosteSpinner", "DiagnosticInfo" },
    { "PosteSuccess", "DiagnosticOk" },
    { "PosteError",   "DiagnosticError" },
  }) do
    local src = resolve_hl(pair[2])
    local fg = src.fg or src.ctermfg
    if not fg then
      fg = pair[1] == "PosteError" and 0xff0000
        or pair[1] == "PosteSuccess" and 0x00ff00
        or 0x00aaff
    end
    -- fg only, no bg — hl_mode="combine" on extmark handles bg inheritance
    vim.api.nvim_set_hl(0, pair[1], { fg = fg })
  end
end
setup_hl()
-- Re-apply when colorscheme changes or after full startup
vim.api.nvim_create_autocmd("ColorScheme", { callback = setup_hl })
vim.api.nvim_create_autocmd("VimEnter", { callback = setup_hl, once = true })

---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------
local function log(level, msg)
  if not config.log_file or config.log_file == "" then return end
  local ts = os.date("%Y-%m-%d %H:%M:%S")
  local line = string.format("[%s] [%s] %s\n", ts, level, msg)
  local f = io.open(config.log_file, "a")
  if f then
    f:write(line)
    f:close()
  end
end

---------------------------------------------------------------------------
-- Binary discovery
---------------------------------------------------------------------------
local function find_poste_binary()
  if config.poste_binary ~= "" then
    return config.poste_binary
  end
  local local_paths = {
    "./target/debug/poste",
    "./target/release/poste",
  }
  for _, path in ipairs(local_paths) do
    if vim.fn.filereadable(path) == 1 then
      return vim.fn.fnamemodify(path, ":p")
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Request line detection + status indicators (virtual text)
---------------------------------------------------------------------------

--- Extract the full request block from the buffer at the given line.
--- Returns { request_line = "GET ...", headers = { { "Key", "Value" }, ... } }.
--- This parses from the ### marker down to the next ### or EOF.
local function extract_request_block(buf, start_line)
  -- Walk backward to find ### separator
  local header_line = nil
  for i = start_line, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      header_line = i
      break
    end
  end
  if not header_line then return { request_line = "", headers = {} } end

  local total = vim.api.nvim_buf_line_count(buf)
  local request_line = nil
  local headers = {}

  for i = header_line + 1, total do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then break end  -- next block

    -- Skip comments (lines starting with # or --)
    if text:match("^%s*#") or text:match("^%s*%-%-") then
      -- skip
    elseif not request_line and text:match("%S") then
      -- First non-empty non-comment line is the request line
      request_line = text
    elseif request_line then
      -- After request line: headers until empty line, then body
      if text:match("^%s*$") then
        break  -- empty line = end of headers
      end
      local key, val = text:match("^([^:]+):%s*(.*)")
      if key then
        table.insert(headers, { vim.trim(key), vim.trim(val) })
      end
    end
  end

  return { request_line = request_line or "", headers = headers }
end

--- Find the request definition line: walk backward from `start_line` to
--- find the ### separator, then return the first non-empty, non-comment
--- line after it (the GET/POST/SET/etc line).
--- Returns (line_number_0indexed, nil) or (nil, nil) if not found.
local function find_request_line(buf, start_line)
  -- Walk backward to find ### separator
  local header_line = nil
  for i = start_line, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      header_line = i
      break
    end
  end

  if not header_line then return nil end

  local total = vim.api.nvim_buf_line_count(buf)
  for i = header_line + 1, total do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then break end  -- next block
    if text:match("%S") and not text:match("^%s*#") and not text:match("^%s*%-%-") then
      return i - 1  -- 0-indexed for extmark
    end
  end

  return nil
end

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_gen = 0  -- generation counter to invalidate stale spinner callbacks

--- Place or update a virtual-text indicator on the request line.
--- status: "running" | "success" | "error"
--- latency_ms: optional, shown after ✓ on success
local function set_indicator(buf, line_0, status, latency_ms)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if not line_0 then return end

  -- Invalidate any in-flight spinner callbacks
  spinner_gen = spinner_gen + 1
  local my_gen = spinner_gen

  -- Stop any running spinner
  if spinner_timer then
    pcall(function() spinner_timer:stop() end)
    spinner_timer:close()
    spinner_timer = nil
  end

  -- Clear all extmarks in this namespace on this buffer (clean slate)
  vim.api.nvim_buf_clear_namespace(buf, indicator_ns, 0, -1)
  indicator_mark = nil
  indicator_buf = buf

  if status == "running" then
    local frame = 1
    local function update_spinner()
      if my_gen ~= spinner_gen then return end  -- stale callback
      if not vim.api.nvim_buf_is_valid(buf) then return end
      vim.api.nvim_buf_clear_namespace(buf, indicator_ns, 0, -1)
      indicator_mark = vim.api.nvim_buf_set_extmark(buf, indicator_ns, line_0, 0, {
        virt_text = { { " " .. spinner_frames[frame] .. " ", "PosteSpinner" } },
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
      frame = (frame % #spinner_frames) + 1
    end
    update_spinner()
    spinner_timer = uv.new_timer()
    spinner_timer:start(100, 100, vim.schedule_wrap(update_spinner))

  elseif status == "success" then
    local virt_text = { { " ✓ ", "PosteSuccess" } }
    if latency_ms and latency_ms > 0 then
      table.insert(virt_text, { string.format("%.2f ms", latency_ms), "PosteLatency" })
    end
    indicator_mark = vim.api.nvim_buf_set_extmark(buf, indicator_ns, line_0, 0, {
      virt_text = virt_text,
      virt_text_pos = "eol",
      hl_mode = "combine",
    })

  elseif status == "error" then
    indicator_mark = vim.api.nvim_buf_set_extmark(buf, indicator_ns, line_0, 0, {
      virt_text = { { " ✘ ", "PosteError" } },
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
  end
end

---------------------------------------------------------------------------
-- Content-type → filetype mapping (for treesitter syntax highlighting)
---------------------------------------------------------------------------
local content_type_map = {
  ["application/json"] = "json",
  ["application/ld+json"] = "json",
  ["application/vnd.api+json"] = "json",
  ["text/html"] = "html",
  ["application/xhtml+xml"] = "html",
  ["text/xml"] = "xml",
  ["application/xml"] = "xml",
  ["application/rss+xml"] = "xml",
  ["application/atom+xml"] = "xml",
  ["text/javascript"] = "javascript",
  ["application/javascript"] = "javascript",
  ["text/css"] = "css",
  ["text/markdown"] = "markdown",
  ["text/yaml"] = "yaml",
  ["application/x-yaml"] = "yaml",
  ["text/plain"] = "text",
}

local function detect_filetype(content_type)
  if not content_type or content_type == "" then
    return "text"
  end
  -- Strip charset and other parameters: "application/json; charset=utf-8" → "application/json"
  local mime = content_type:match("^([^;]+)") or content_type
  mime = vim.trim(mime):lower()
  return content_type_map[mime] or "text"
end

---------------------------------------------------------------------------
-- View formatters
---------------------------------------------------------------------------

--- Split a string into lines
local function split_lines(str)
  if not str or str == "" then return { "" } end
  -- Normalize \r\n to \n, then strip any remaining \r
  str = str:gsub("\r\n", "\n"):gsub("\r", "")
  -- Remove trailing newline to avoid empty last line
  if str:sub(-1) == "\n" then
    str = str:sub(1, -2)
  end
  local lines = {}
  for line in str:gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end
  -- Remove empty last line if present
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return #lines > 0 and lines or { "" }
end

--- Try to pretty-print JSON body; return as-is if not JSON or if already formatted
local function pretty_body(body, content_type)
  if not body or body == "" then return "" end

  -- If body already has newlines, it's already formatted (curl does this)
  if body:find("\n") then
    return body
  end

  -- Only try to format compact JSON
  if content_type and content_type:find("json") then
    local ok, decoded = pcall(vim.json.decode, body)
    if ok and decoded then
      -- Use vim.json.encode for proper JSON formatting
      local ok2, pretty = pcall(vim.json.encode, decoded, { indent = "  " })
      if ok2 and pretty then return pretty end
    end
  end
  return body
end

--- Body view: the main response content
local function format_body(r)
  local body = pretty_body(r.body, r.content_type)
  return split_lines(body)
end

--- Markdown table helper: returns lines for a two-column table
local function md_table(headers, rows)
  local lines = {}
  table.insert(lines, "| " .. table.concat(headers, " | ") .. " |")
  local seps = {}
  for _ = 1, #headers do table.insert(seps, "---") end
  table.insert(lines, "| " .. table.concat(seps, " | ") .. " |")
  for _, row in ipairs(rows) do
    table.insert(lines, "| " .. table.concat(row, " | ") .. " |")
  end
  return lines
end

--- Headers view: protocol-aware metadata display
local function format_headers(r)
  local lines = {}

  if r.protocol == "error" then
    table.insert(lines, "# Request Headers")
    table.insert(lines, "")
    if r.headers and #r.headers > 0 then
      for _, h in ipairs(r.headers) do
        table.insert(lines, string.format("**%s**: %s", h[1], h[2]))
      end
    else
      table.insert(lines, "_(no request headers)_")
    end

  elseif r.protocol == "http" then
    table.insert(lines, "# Response Headers")
    table.insert(lines, "")
    if r.headers and #r.headers > 0 then
      for _, h in ipairs(r.headers) do
        table.insert(lines, string.format("**%s**: %s", h[1], h[2]))
      end
    else
      table.insert(lines, "_(no headers)_")
    end

  elseif r.protocol == "redis" then
    table.insert(lines, "# Connection Info")
    table.insert(lines, "")
    table.insert(lines, string.format("**Server**: %s", r.url or ""))
    if r.metadata then
      if r.metadata.command then
        table.insert(lines, string.format("**Last Command**: %s", r.metadata.command))
      end
      if r.metadata.type then
        table.insert(lines, string.format("**Value Type**: %s", r.metadata.type))
      end
    end

  else
    -- Generic fallback for future protocols
    table.insert(lines, "# Response Metadata")
    table.insert(lines, "")
    if r.metadata then
      local has_content = false
      for k, v in pairs(r.metadata) do
        table.insert(lines, string.format("**%s**: %s", k, v))
        has_content = true
      end
      if not has_content then
        table.insert(lines, "_(no metadata)_")
      end
    else
      table.insert(lines, "_(no metadata)_")
    end
  end

  return lines
end

--- Extract connection info from curl verbose trace
local function extract_connection_info(verbose)
  if not verbose or verbose == "" then
    return {}
  end

  local info = {}
  local lines_list = {}
  for l in verbose:gmatch("[^\r\n]+") do
    table.insert(lines_list, l)
  end

  -- Find proxy info
  for _, l in ipairs(lines_list) do
    if l:match("Uses proxy env variable") then
      local proxy = l:match("'([^']+)'")
      if proxy then info.proxy = proxy end
      break
    end
  end

  -- Find TLS info
  for _, l in ipairs(lines_list) do
    if l:match("SSL connection using") then
      info.tls = l:gsub("^%*%s*", "")
      break
    end
  end

  -- Find HTTP version
  for _, l in ipairs(lines_list) do
    if l:match("HTTP/%d") then
      local http_ver = l:match("HTTP/(%d[.%d]*)")
      if http_ver then info.http = "HTTP/" .. http_ver end
      break
    end
  end

  -- Find exit code
  for _, l in ipairs(lines_list) do
    if l:match("Connection #%d+ left intact") then
      info.exit = "0"
      break
    end
  end

  return info
end

--- Verbose view: markdown-friendly layout with full details
local function format_verbose(r)
  local lines = {}

  -- Error responses get a dedicated layout
  if r.protocol == "error" then
    table.insert(lines, "# Error")
    table.insert(lines, "")
    table.insert(lines, "**Request**: " .. (r.metadata and r.metadata.request_line or r.url or ""))
    table.insert(lines, "**Env**: " .. (r.metadata and r.metadata.env or ""))
    table.insert(lines, "**Exit code**: " .. (r.metadata and r.metadata.exit_code or ""))
    table.insert(lines, "**Status**: " .. (r.status_text or ""))

    if r.body and r.body ~= "" then
      table.insert(lines, "")
      table.insert(lines, "## Details")
      table.insert(lines, "")
      table.insert(lines, "```")
      for l in r.body:gmatch("[^\r\n]+") do
        table.insert(lines, l)
      end
      table.insert(lines, "```")
    end

    return lines
  end

  -- HTTP protocol
  if r.protocol == "http" then
    local method = (r.metadata and r.metadata.method) or "GET"
    local duration = string.format("%.2f ms", r.latency_ms or 0)
    local timestamp = (r.metadata and r.metadata.timestamp) or ""
    local env_name = (r.metadata and r.metadata.env) or current_env

    -- Summary header
    table.insert(lines, string.format("# %s %s", method, r.url or ""))
    table.insert(lines, "")
    table.insert(lines, string.format("**%s** | %s | %s | %s",
      r.status_text or "", duration, env_name, timestamp))
    table.insert(lines, "")

    -- Request section
    table.insert(lines, "## Request")
    table.insert(lines, "")

    -- Request headers
    local req_headers = r.metadata and r.metadata.request_headers
    if req_headers and req_headers ~= "" then
      table.insert(lines, "### Headers")
      table.insert(lines, "")
      for l in req_headers:gmatch("[^\r\n]+") do
        -- Parse "Key: Value" format and convert to **Key**: Value
        local key, value = l:match("^([^:]+):%s*(.+)$")
        if key and value then
          table.insert(lines, string.format("**%s**: %s", key, value))
        else
          table.insert(lines, l)
        end
      end
      table.insert(lines, "")
    end

    -- Request body (payload)
    local req_body = r.metadata and r.metadata.request_body
    if req_body and req_body ~= "" then
      table.insert(lines, "### Body")
      table.insert(lines, "")
      -- Determine language for syntax highlighting
      local lang = ""
      if req_headers and req_headers:lower():find("application/json") then
        lang = "json"
      elseif req_headers and req_headers:lower():find("application/xml") then
        lang = "xml"
      end
      table.insert(lines, "```" .. lang)
      for l in req_body:gmatch("[^\r\n]+") do
        table.insert(lines, l)
      end
      table.insert(lines, "```")
      table.insert(lines, "")
    end

    -- Separator between Request and Response
    table.insert(lines, "---")
    table.insert(lines, "")

    -- Response section
    table.insert(lines, "## Response")
    table.insert(lines, "")

    -- Response headers
    if r.headers and #r.headers > 0 then
      table.insert(lines, "### Headers")
      table.insert(lines, "")
      for _, h in ipairs(r.headers) do
        table.insert(lines, string.format("**%s**: %s", h[1], h[2]))
      end
      table.insert(lines, "")
    end

    -- Response body
    if r.body and r.body ~= "" then
      table.insert(lines, "### Body")
      table.insert(lines, "")
      -- Determine language for syntax highlighting
      local lang = ""
      if (r.content_type or ""):find("json") then
        lang = "json"
      elseif (r.content_type or ""):find("html") then
        lang = "html"
      elseif (r.content_type or ""):find("xml") then
        lang = "xml"
      end
      table.insert(lines, "```" .. lang)
      for l in r.body:gmatch("[^\r\n]+") do
        table.insert(lines, l)
      end
      table.insert(lines, "```")
      table.insert(lines, "")
    end

    -- Connection info (extracted from curl trace)
    local verbose = r.metadata and r.metadata.verbose
    if verbose and verbose ~= "" then
      local conn_info = extract_connection_info(verbose)
      if next(conn_info) then
        table.insert(lines, "---")
        table.insert(lines, "")
        table.insert(lines, "## Connection")
        table.insert(lines, "")
        if conn_info.proxy then
          table.insert(lines, "**Proxy**: " .. conn_info.proxy)
        end
        if conn_info.tls then
          table.insert(lines, "**TLS**: " .. conn_info.tls)
        end
        if conn_info.http then
          table.insert(lines, "**HTTP**: " .. conn_info.http)
        end
        if conn_info.exit then
          table.insert(lines, "**Exit Code**: " .. conn_info.exit)
        end
      end
    end

    return lines
  end

  -- Non-HTTP protocols: generic layout
  table.insert(lines, "# Request")
  table.insert(lines, "")
  table.insert(lines, "| Field | Value |")
  table.insert(lines, "|-------|-------|")
  table.insert(lines, "| **Protocol** | " .. (r.protocol or "unknown") .. " |")
  table.insert(lines, "| **URL** | " .. (r.url or "") .. " |")
  table.insert(lines, "| **Latency** | " .. (r.latency_ms or 0) .. "ms |")

  if r.metadata then
    if r.metadata.method then
      table.insert(lines, "| **Method** | " .. r.metadata.method .. " |")
    end
    if r.metadata.command then
      table.insert(lines, "| **Command** | " .. r.metadata.command .. " |")
    end
  end

  table.insert(lines, "")
  table.insert(lines, "## Response")
  table.insert(lines, "")
  table.insert(lines, "| Field | Value |")
  table.insert(lines, "|-------|-------|")
  table.insert(lines, "| **Status** | " .. (r.status_text or "") .. " |")
  table.insert(lines, "| **Content-Type** | " .. (r.content_type or "") .. " |")
  table.insert(lines, "| **Body size** | " .. #(r.body or "") .. " bytes |")

  if r.metadata and r.metadata.type then
    table.insert(lines, "| **Type** | " .. r.metadata.type .. " |")
  end

  return lines
end

---------------------------------------------------------------------------
-- Winbar (tab indicators)
---------------------------------------------------------------------------
local function update_winbar(active)
  if not response_window or not vim.api.nvim_win_is_valid(response_window) then
    return
  end

  local tabs = {
    { id = "body",    label = "Body [B]" },
    { id = "headers", label = "Headers [H]" },
    { id = "verbose", label = "Verbose [V]" },
  }

  local parts = {}
  for _, tab in ipairs(tabs) do
    if tab.id == active then
      table.insert(parts, "%#TabLineSel# " .. tab.label .. " %*")
    else
      table.insert(parts, "%#TabLine# " .. tab.label .. " %*")
    end
  end

  vim.wo[response_window].winbar = table.concat(parts)
end

---------------------------------------------------------------------------
-- Buffer management
---------------------------------------------------------------------------
local function get_response_buffer()
  if response_buffer and vim.api.nvim_buf_is_valid(response_buffer) then
    return response_buffer
  end

  response_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = response_buffer })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = response_buffer })
  vim.api.nvim_set_option_value("swapfile", false, { buf = response_buffer })
  vim.api.nvim_set_option_value("modifiable", false, { buf = response_buffer })
  vim.api.nvim_buf_set_name(response_buffer, "poste://response")

  local opts = { buffer = response_buffer, noremap = true, silent = true }

  -- Close window
  vim.keymap.set("n", "q", function()
    if response_window and vim.api.nvim_win_is_valid(response_window) then
      vim.api.nvim_win_close(response_window, true)
      response_window = nil
    end
  end, opts)

  -- Tab switching keymaps
  vim.keymap.set("n", "B", function() M.show_view("body") end, opts)
  vim.keymap.set("n", "H", function() M.show_view("headers") end, opts)
  vim.keymap.set("n", "V", function() M.show_view("verbose") end, opts)

  return response_buffer
end

--- Ensure the response split is open and display the given lines
local function render_buffer(lines, filetype)
  local buf = get_response_buffer()

  -- Make buffer modifiable, write lines, lock again
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Set filetype for treesitter highlighting
  vim.bo[buf].filetype = filetype or "text"

  -- Open split window if not already open
  if not response_window or not vim.api.nvim_win_is_valid(response_window) then
    local saved_win = vim.api.nvim_get_current_win()
    local cmd = config.split_direction == "vertical" and "vsplit" or "split"
    vim.cmd(cmd)
    response_window = vim.api.nvim_get_current_win()

    if config.split_direction == "vertical" then
      vim.api.nvim_win_set_width(response_window, config.split_size)
    else
      vim.api.nvim_win_set_height(response_window, config.split_size)
    end

    vim.api.nvim_set_current_win(saved_win)
  end

  vim.api.nvim_win_set_buf(response_window, buf)

  -- Move cursor to top
  pcall(vim.api.nvim_win_set_cursor, response_window, { 1, 0 })
end

---------------------------------------------------------------------------
-- Public: switch view
---------------------------------------------------------------------------
function M.show_view(view)
  current_view = view
  if not last_response then return end

  local lines, filetype
  if view == "body" then
    lines = format_body(last_response)
    filetype = detect_filetype(last_response.content_type)
  elseif view == "headers" then
    lines = format_headers(last_response)
    filetype = "markdown"
  elseif view == "verbose" then
    lines = format_verbose(last_response)
    filetype = "markdown"
  else
    lines = { "Unknown view: " .. view }
    filetype = "text"
  end

  render_buffer(lines, filetype)
  update_winbar(view)
end

---------------------------------------------------------------------------
-- Prompt variables
---------------------------------------------------------------------------

--- Find the request block boundaries for a given cursor line.
--- Returns (start_line, end_line) as 0-indexed inclusive ranges.
--- A request block starts at ### and ends before the next ### or EOF.
local function find_request_block_bounds(buf, cursor_line)
  local total = vim.api.nvim_buf_line_count(buf)

  -- Walk backward to find ###
  local start_line = nil
  for i = cursor_line, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      start_line = i
      break
    end
  end

  if not start_line then return nil, nil end

  -- Walk forward to find end of block (next ### or EOF)
  local end_line = total
  for i = start_line + 1, total do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if text:match("^%s*###") then
      end_line = i - 1
      break
    end
  end

  return start_line, end_line
end

--- Handle @prompt directives in the current request block only.
--- Syntax:
---   # @prompt variable_name                   → text input
---   # @prompt variable_name [opt1, opt2, ...] → selection from list (up/down arrows)
--- Only processes @prompt lines within the request block containing cursor_line.
--- Always prompts for input (no caching) so users can use different values each time.
--- Returns the modified full buffer content with prompts replaced.
local function handle_prompt_variables(buf, cursor_line, content)
  local start_line, end_line = find_request_block_bounds(buf, cursor_line)
  if not start_line then return content end

  local lines = vim.split(content, "\n", { plain = true })
  local result = {}

  for i, line in ipairs(lines) do
    -- Only process @prompt within the current request block (1-indexed)
    if i >= start_line and i <= end_line then
      -- Match: # @prompt varname [opt1, opt2, ...]  (selection mode)
      local varname_sel, options_str = line:match("^%s*#%s*@prompt%s+(%S+)%s*%[([^%]]+)%]")

      if varname_sel and options_str then
        -- Parse options: split by comma and trim
        local options = {}
        for opt in options_str:gmatch("[^,]+") do
          local trimmed = vim.trim(opt)
          if trimmed ~= "" then
            table.insert(options, trimmed)
          end
        end

        if #options == 0 then
          table.insert(result, line)
          goto continue
        end

        -- Show synchronous selection UI using vim.fn.inputlist.
        -- We avoid vim.ui.select because plugins (dressing.nvim, telescope-ui-select)
        -- often make it async, which would break the synchronous flow here.
        local choices = { string.format("Select value for '%s' (press Enter to confirm, 0/empty to cancel):", varname_sel) }
        for idx, opt in ipairs(options) do
          table.insert(choices, string.format("%d. %s", idx, opt))
        end

        local choice = vim.fn.inputlist(choices)
        if choice and choice >= 1 and choice <= #options then
          table.insert(result, string.format("@%s = %s", varname_sel, options[choice]))
        else
          -- User cancelled (0 or out of range)
          table.insert(result, line)
        end
      else
        -- Match: # @prompt varname  (text input mode)
        local varname = line:match("^%s*#%s*@prompt%s+(%S+)")

        if varname then
          local ok, value = pcall(vim.fn.input, {
            prompt = string.format("Enter value for '%s': ", varname),
            default = "",
          })

          if ok and value and value ~= "" then
            table.insert(result, string.format("@%s = %s", varname, value))
          else
            table.insert(result, line)
          end
        else
          table.insert(result, line)
        end
      end
    else
      table.insert(result, line)
    end

    ::continue::
  end

  return table.concat(result, "\n")
end

---------------------------------------------------------------------------
-- Form data (multipart/form-data, url-encoded, file uploads, magic vars)
---------------------------------------------------------------------------

--- Process form data magic variables and file inclusions in the request body.
--- - Replaces {{\$timestamp}} with a unique timestamp
--- - Replaces lines like `< /path/to/file` with actual file contents
--- Operates on the current request block only.
local function process_form_data(src_buf, cursor_line, content)
  local start_line, end_line = find_request_block_bounds(src_buf, cursor_line)
  if not start_line then return content end

  -- Generate unique timestamp for this request (used as multipart boundary)
  local timestamp = tostring(os.time()) .. math.random(100000, 999999)

  local lines = vim.split(content, "\n", { plain = true })
  local result = {}

  for i, line in ipairs(lines) do
    if i >= start_line and i <= end_line then
      -- Replace {{$timestamp}} with unique value
      local processed = line:gsub("{{%$timestamp}}", timestamp)

      -- Check if this is a file inclusion line: `< /path/to/file`
      local file_path = processed:match("^%s*<%s+(.+)$")
      if file_path then
        file_path = vim.trim(file_path)
        -- Expand ~ to home directory
        if file_path:sub(1, 1) == "~" then
          file_path = vim.fn.expand("~") .. file_path:sub(2)
        end
        -- Read file contents
        local f = io.open(file_path, "rb")
        if f then
          local file_content = f:read("*a")
          f:close()
          table.insert(result, file_content)
          log("INFO", string.format("Included file: %s (%d bytes)", file_path, #file_content))
        else
          log("ERROR", string.format("Cannot open file: %s", file_path))
          table.insert(result, processed)  -- keep original line on error
        end
      else
        table.insert(result, processed)
      end
    else
      table.insert(result, line)
    end
  end

  return table.concat(result, "\n")
end

---------------------------------------------------------------------------
-- Request variables (cross-request reference)
---------------------------------------------------------------------------

-- Cache for executed request responses: { [request_name] = response_table }
local request_response_cache = {}

--- Remove resolved @prompt lines from content (keep @var = value lines)
local function strip_prompt_lines(content)
  local result = {}
  for _, l in ipairs(vim.split(content, "\n", { plain = true })) do
    if not l:match("^%s*#%s*@prompt%s+%S+") then
      table.insert(result, l)
    end
  end
  return table.concat(result, "\n")
end

--- Collect all ### request blocks with their names and line ranges.
--- Returns list of { name = "Request Name", start_line = 1, end_line = 5 }
--- All line numbers are 1-indexed.
local function collect_requests(buf)
  local requests = {}
  local total = vim.api.nvim_buf_line_count(buf)
  local i = 1

  while i <= total do
    local line_text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if line_text:match("^%s*###") then
      local name = vim.trim(line_text:gsub("^%s*###", ""))
      local start_line = i
      local end_line = total

      -- Find end of this block (next ### or EOF)
      for j = i + 1, total do
        local next_text = vim.api.nvim_buf_get_lines(buf, j - 1, j, false)[1] or ""
        if next_text:match("^%s*###") then
          end_line = j - 1
          break
        end
      end

      table.insert(requests, {
        name = name,
        start_line = start_line,
        end_line = end_line,
      })
      i = end_line + 1
    else
      i = i + 1
    end
  end

  return requests
end

--- Navigate a nested table using a dot-separated path.
--- Supports: "data.user.name" → data.user.name
---           "items[0].id"    → items[0].id (array indexing)
--- Automatically parses JSON strings when navigating deeper
local function get_nested_value(obj, path)
  if not obj or path == "" then return nil end

  local current = obj
  for part in path:gmatch("[^.]+") do
    -- If current is a string, try to parse it as JSON
    if type(current) == "string" then
      local ok, parsed = pcall(vim.json.decode, current)
      if ok and type(parsed) == "table" then
        current = parsed
      else
        return nil  -- Can't navigate into non-JSON string
      end
    end

    if type(current) ~= "table" then return nil end

    -- Handle array indexing: items[0] or items[2]
    local field, idx = part:match("^(.+)%[(%d+)%]$")
    if field and idx then
      current = current[field]
      if type(current) == "table" then
        current = current[tonumber(idx) + 1]  -- Lua is 1-indexed
      else
        return nil
      end
    else
      current = current[part]
    end
  end

  return current
end

--- Extract a value from a cached request response.
--- pattern format: "RequestName.response.body.field.subfield"
---                 "RequestName.response.headers.Content-Type"
---                 "RequestName.request.headers.Authorization"
local function resolve_request_variable(pattern, cached_responses)
  -- Parse: RequestName.(response|request).(body|headers)[.path]
  local req_name, source, target = pattern:match("^([^%.]+)%.([^%.]+)%.([^%.]+)")
  if not req_name or not source or not target then
    return nil
  end

  -- Extract optional path after target (e.g., "body.user.name" → path = "user.name")
  local full_match = req_name .. "." .. source .. "." .. target
  local path = pattern:sub(#full_match + 2)  -- +2 for the dot separator

  local response = cached_responses[req_name]
  if not response then
    log("WARN", string.format("Request variable: '%s' not found in cache", req_name))
    return nil
  end

  if source == "response" then
    if target == "body" then
      local body = response.body
      if not body or body == "" then return nil end

      -- If no path, return the whole body
      if path == "" then return body end

      -- Try to parse as JSON and navigate
      local ok, parsed = pcall(vim.json.decode, body)
      if not ok then
        log("WARN", string.format("Cannot parse response body as JSON for '%s'", req_name))
        return nil
      end
      return get_nested_value(parsed, path)

    elseif target == "headers" then
      if not response.headers then return nil end
      for _, h in ipairs(response.headers) do
        if h[1]:lower() == path:lower() then
          return h[2]
        end
      end
    end

  elseif source == "request" then
    if target == "body" then
      local body = response.metadata and response.metadata.request_body
      if not body or body == "" or path == "" then return body end
      local ok, parsed = pcall(vim.json.decode, body)
      if ok then return get_nested_value(parsed, path) end

    elseif target == "headers" then
      local headers_str = response.metadata and response.metadata.request_headers
      if not headers_str then return nil end
      for line in headers_str:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^:]+):%s*(.+)$")
        if key and value and vim.trim(key):lower() == path:lower() then
          return vim.trim(value)
        end
      end
    end
  end

  return nil
end

--- Scan block text for request variable references: {{RequestName.response.body.field}}
--- Returns list of { full = "{{...}}", request_name = "RequestName" }
local function find_request_variable_refs(block_text)
  local refs = {}
  for full_ref in block_text:gmatch("{{([^}]+)}}") do
    -- Request variables contain .response. or .request.
    if full_ref:match("%.response%.") or full_ref:match("%.request%.") then
      local req_name = full_ref:match("^([^%.]+)%.")
      if req_name then
        table.insert(refs, { full = "{{" .. full_ref .. "}}", request_name = req_name })
      end
    end
  end
  return refs
end

--- Execute a dependent request and return its response.
--- Uses cache if available.
local function execute_dependent_request(binary, file, env_name, dep_req, buf_content)
  -- Check cache first
  if request_response_cache[dep_req.name] then
    log("INFO", string.format("Using cached response for '%s'", dep_req.name))
    return request_response_cache[dep_req.name]
  end

  -- Execute via CLI
  local cmd = string.format("%s run %s --line %d --env %s --json --stdin",
    vim.fn.shellescape(binary),
    vim.fn.shellescape(file),
    dep_req.start_line,  -- 1-indexed, cursor on ### line
    vim.fn.shellescape(env_name)
  )

  log("INFO", string.format("Executing dependent request '%s' at line %d", dep_req.name, dep_req.start_line))

  -- Capture stdout/stderr in buffers
  local stdout_buf = {}
  local stderr_buf = {}

  local job_id = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stdout_buf, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_buf, line)
          end
        end
      end
    end,
  })

  if job_id <= 0 then
    log("ERROR", "Failed to start job for dependent request")
    return nil
  end

  -- Send buffer content (with prompts already resolved)
  local clean_content = strip_prompt_lines(buf_content)
  vim.fn.chansend(job_id, clean_content)
  vim.fn.chanclose(job_id, "stdin")

  -- Wait for completion (blocking)
  local exit_codes = vim.fn.jobwait({ job_id })
  if exit_codes[1] ~= 0 then
    log("WARN", string.format("Dependent request '%s' failed with exit code %d", dep_req.name, exit_codes[1]))
    if #stderr_buf > 0 then
      log("WARN", "stderr: " .. table.concat(stderr_buf, "\n"))
    end
    return nil
  end

  -- Parse output
  if #stdout_buf == 0 then
    log("WARN", "No output from dependent request")
    return nil
  end

  local stdout_text = table.concat(stdout_buf, "\n")
  local ok, parsed = pcall(vim.json.decode, stdout_text)
  if not ok then
    log("WARN", string.format("Failed to parse dependent request response: %s", stdout_text:sub(1, 100)))
    return nil
  end

  -- Cache the response
  request_response_cache[dep_req.name] = parsed
  log("INFO", string.format("Cached response for '%s'", dep_req.name))

  return parsed
end

--- Resolve all request variables in the buffer content for the current request block.
--- Executes dependent requests if not already cached.
--- Returns modified buffer content with variables substituted.
local function resolve_request_variables(binary, file, env_name, buf, cursor_line, content)
  local requests = collect_requests(buf)

  -- Find the current request block
  local current_req = nil
  for _, req in ipairs(requests) do
    if cursor_line >= req.start_line and cursor_line <= req.end_line then
      current_req = req
      break
    end
  end

  if not current_req then
    return content
  end

  -- Extract current block text
  local all_lines = vim.split(content, "\n", { plain = true })
  local block_lines = {}
  for i = current_req.start_line, current_req.end_line do
    table.insert(block_lines, all_lines[i] or "")
  end
  local block_text = table.concat(block_lines, "\n")

  -- Find request variable references
  local refs = find_request_variable_refs(block_text)
  if #refs == 0 then
    return content
  end

  log("INFO", string.format("Found %d request variable reference(s)", #refs))

  -- Execute dependent requests and build cache
  local cached_responses = {}
  for _, ref in ipairs(refs) do
    if not cached_responses[ref.request_name] then
      -- Find the request block
      local dep_req = nil
      for _, req in ipairs(requests) do
        if req.name == ref.request_name then
          dep_req = req
          break
        end
      end

      if dep_req then
        local response = execute_dependent_request(binary, file, env_name, dep_req, content)
        if response then
          cached_responses[ref.request_name] = response
        end
      else
        log("WARN", string.format("Referenced request '%s' not found", ref.request_name))
      end
    end
  end

  -- Substitute variables in block text
  local resolved_block = block_text
  for _, ref in ipairs(refs) do
    local value = resolve_request_variable(ref.full:sub(3, -3), cached_responses)  -- strip {{ }}
    if value then
      resolved_block = resolved_block:gsub(vim.pesc(ref.full), tostring(value))
    else
      log("WARN", string.format("Could not resolve variable: %s", ref.full))
    end
  end

  -- Replace block in full content
  local result_lines = {}
  for i, l in ipairs(all_lines) do
    if i >= current_req.start_line and i <= current_req.end_line then
      table.insert(result_lines, vim.split(resolved_block, "\n", { plain = true })[i - current_req.start_line + 1] or l)
    else
      table.insert(result_lines, l)
    end
  end

  return table.concat(result_lines, "\n")
end

---------------------------------------------------------------------------
-- Run request
---------------------------------------------------------------------------
function M.run_request()
  local binary = find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found. Make sure it's in PATH or built locally.", vim.log.levels.ERROR)
    return
  end

  local src_buf = vim.api.nvim_get_current_buf()
  local line = vim.fn.line(".")

  -- Use buffer name (file path) for env.json discovery and extension detection.
  -- The file may not exist on disk — that's fine with --stdin.
  local file = vim.api.nvim_buf_get_name(src_buf)
  if file == "" then
    -- Unnamed buffer: use cwd with default .http extension
    file = vim.fn.getcwd() .. "/untitled.http"
  end

  -- Read content directly from the buffer (unsaved changes included)
  local buf_lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
  local buf_content = table.concat(buf_lines, "\n")

  -- Handle @prompt directives: only process those in the current request block
  buf_content = handle_prompt_variables(src_buf, line, buf_content)

  -- Resolve request variables: execute dependent requests and substitute {{RequestName.response.body.field}}
  buf_content = resolve_request_variables(binary, file, current_env, src_buf, line, buf_content)

  -- Process form data magic variables and file inclusions
  buf_content = process_form_data(src_buf, line, buf_content)

  -- Get the current request name for caching
  local requests = collect_requests(src_buf)
  local current_req_name = nil
  for _, req in ipairs(requests) do
    if line >= req.start_line and line <= req.end_line then
      current_req_name = req.name
      break
    end
  end

  -- Extract the full request block (request line + headers) for error display
  local req_block = extract_request_block(src_buf, line)
  local req_text = req_block.request_line

  -- Find the request definition line and show spinner
  local req_line = find_request_line(src_buf, line)
  set_indicator(src_buf, req_line, "running")

  local cmd = string.format("%s run %s --line %d --env %s --json --stdin",
    vim.fn.shellescape(binary),
    vim.fn.shellescape(file),
    line,
    vim.fn.shellescape(current_env)
  )

  log("INFO", string.format("cmd: %s", cmd))

  local stderr_buf = {}  -- accumulate stderr lines

  local job_id = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      while #data > 0 and data[#data] == "" do
        data[#data] = nil
      end
      if #data == 0 then return end

      local output = table.concat(data, "\n")
      log("INFO", "stdout: " .. output:sub(1, 200))

      vim.schedule(function()
        local ok, parsed = pcall(vim.json.decode, output)
        if ok and parsed and type(parsed) == "table" then
          last_response = parsed
          -- Cache response for subsequent request variable references
          if current_req_name then
            request_response_cache[current_req_name] = parsed
          end
          M.show_view("body")
          set_indicator(src_buf, req_line, "success", parsed.latency_ms)
        else
          -- JSON parse failed — replace last_response with error object
          log("WARN", "JSON parse failed, showing raw output")
          set_indicator(src_buf, req_line, "error")
          last_response = {
            protocol = "error",
            status = 0,
            status_text = "JSON parse failed",
            latency_ms = 0,
            url = vim.trim(req_text),
            content_type = "text/plain",
            headers = req_block.headers,
            body = output,
            cookies = {},
            metadata = {
              method = "",
              error = "JSON parse failed",
              exit_code = "?",
              request_line = vim.trim(req_text),
              env = current_env,
            },
          }
          M.show_view("verbose")
        end
      end)
    end,
    on_stderr = function(_, data)
      if not data then return end
      while #data > 0 and data[#data] == "" do
        data[#data] = nil
      end
      if #data == 0 then return end
      for _, l in ipairs(data) do
        table.insert(stderr_buf, l)
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        log("ERROR", string.format("exit code %d (line %d, env %s)", code, line, current_env))
        vim.schedule(function()
          set_indicator(src_buf, req_line, "error")

          -- Replace last_response with a synthetic error object so all tabs
          -- (Body/Headers/Verbose) show the error, not a stale success.
          local stderr_text = table.concat(stderr_buf, "\n")
          last_response = {
            protocol = "error",
            status = 0,
            status_text = "Failed (exit " .. code .. ")",
            latency_ms = 0,
            url = vim.trim(req_text),
            content_type = "text/plain",
            headers = req_block.headers,
            body = stderr_text ~= "" and stderr_text or "Request failed with exit code " .. code,
            cookies = {},
            metadata = {
              method = "",
              error = stderr_text,
              exit_code = tostring(code),
              request_line = vim.trim(req_text),
              env = current_env,
            },
          }
          M.show_view("verbose")
        end)
      end
    end,
  })

  -- Send buffer content via stdin and close the pipe
  if job_id > 0 then
    vim.fn.chansend(job_id, buf_content)
    vim.fn.chanclose(job_id, "stdin")
  end
end

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------
function M.jump_next()
  local line = vim.fn.line(".")
  local total = vim.fn.line("$")
  for i = line + 1, total do
    local text = vim.fn.getline(i)
    if text:match("^###") then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  vim.notify("No more requests", vim.log.levels.INFO)
end

function M.jump_prev()
  local line = vim.fn.line(".")
  for i = line - 1, 1, -1 do
    local text = vim.fn.getline(i)
    if text:match("^###") then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  vim.notify("No previous requests", vim.log.levels.INFO)
end

---------------------------------------------------------------------------
-- Environment
---------------------------------------------------------------------------
function M.set_env(env_name)
  current_env = env_name
  vim.notify("Environment switched to: " .. env_name, vim.log.levels.INFO)
end

function M.get_env()
  return current_env
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
function M.setup(opts)
  opts = opts or {}
  config = vim.tbl_deep_extend("force", config, opts)

  local function setup_buffer_keymaps(buf)
    local keymap_opts = { buffer = buf, noremap = true, silent = true }
    vim.keymap.set("n", "<leader>rr", M.run_request, keymap_opts)
    vim.keymap.set("n", "]]", M.jump_next, keymap_opts)
    vim.keymap.set("n", "[[", M.jump_prev, keymap_opts)
  end

  -- Commands
  vim.api.nvim_create_user_command("PosteRun", function()
    M.run_request()
  end, { desc = "Run request at cursor" })

  vim.api.nvim_create_user_command("PosteEnv", function(args)
    if args.args == "" then
      vim.notify("Current environment: " .. current_env, vim.log.levels.INFO)
    else
      M.set_env(args.args)
    end
  end, {
    nargs = "?",
    desc = "Switch environment or show current",
  })

  -- Autocommand: set up keymaps for supported file types
  vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    pattern = { "*.http", "*.rest", "*.redis" },
    callback = function()
      vim.bo.filetype = "http"
      setup_buffer_keymaps(0)
    end,
  })

  -- Already-open buffers
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("%.http$") or name:match("%.rest$") or name:match("%.redis$") then
      vim.api.nvim_buf_set_option(buf, "filetype", "http")
      setup_buffer_keymaps(buf)
    end
  end

  -- Status line integration
  _G.poste_status = function()
    return string.format("[env: %s]", current_env)
  end
end

return M
