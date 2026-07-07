--- Symbol picker: pick an HTTP request from the current file.
--- Uses Snacks.picker when available.

local M = {}

---------------------------------------------------------------------------
-- Parse requests from buffer
---------------------------------------------------------------------------

--- Extract URL path from a request line.
--- e.g., "GET https://api.example.com/users" → "/users"
--- e.g., "GET {{host}}/api/v1/items" → "/api/v1/items"
local function extract_url_path(line)
  if not line then return nil end
  -- Match: METHOD <url>
  local url = line:match("^%s*%u+%s+(.+)")
  if not url then return nil end
  -- Extract path after host: skip protocol://host or {{var}}/host portion
  local path = url:match("://[^/]*(.*)") -- after ://host
  if not path then
    path = url:match("}}(.*)") -- after {{var}}
  end
  if not path then
    path = url:match("^(/.*)") -- already a path
  end
  return path and path ~= "" and path or nil
end

--- Truncate a string with ellipsis if it exceeds max length.
local function truncate(s, max)
  if not s then return "" end
  if #s <= max then return s end
  return s:sub(1, max - 1) .. "…"
end

--- Scan buffer and collect all ### request blocks.
--- Delegates outer ### detection to cache.lua block index.
--- @param bufnr number Buffer handle
--- @return table[] List of { name, method, url_path, line }
local function collect_requests(bufnr)
  local cache = require("poste.http.cache")
  local bc = cache.get_buffer_cache(bufnr)
  local requests = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for _, block in ipairs(bc.blocks or {}) do
    local name = block.name
    if name and name ~= "" then
      local method = nil
      local url_path = nil
      local in_pre_script = false
      local scan_end = math.min(block.start_line + 20, math.min(block.end_line, #lines))

      for j = block.start_line + 1, scan_end do
        local next_line = lines[j]
        local skip = false

        if next_line:match("^%s*$") then skip = true end
        if not skip and next_line:match("^%s*<%s*{%%") then
          in_pre_script = true
          skip = true
        end
        if not skip and in_pre_script then
          if next_line:match("%%}") then in_pre_script = false end
          skip = true
        end
        if not skip and next_line:match("^%s*@%w") then skip = true end
        if not skip and next_line:match("^%s*#") then skip = true end
        if not skip and next_line:match("^%s*<<") then skip = true end

        if not skip then
          method = next_line:match("^%s*(%u+)%s")
          if method then
            url_path = extract_url_path(next_line)
          end
          break
        end
      end

      table.insert(requests, { name = name, method = method, url_path = url_path, line = block.start_line })
    end
  end

  return requests
end

---------------------------------------------------------------------------
-- Snacks picker
---------------------------------------------------------------------------

--- Show requests using Snacks.picker.select.
local function show_snacks_picker(requests)
  local items = {}
  for _, req in ipairs(requests) do
    local method = req.method or "--"
    local text = method .. "  " .. truncate(req.name, 40)
    local desc = req.url_path and truncate(req.url_path, 45) or ""
    items[#items + 1] = {
      text = text,
      description = desc,
      key = req,
    }
  end

  Snacks.picker.select(
    items,
    {
      prompt = "Requests",
      layout = "select",
      format_item = function(item)
        return item.text .. (item.description ~= "" and "  " .. item.description or "")
      end,
    },
    function(item)
      if item and item.key then
        local req = item.key
        vim.api.nvim_win_set_cursor(0, { req.line, 0 })
        vim.cmd("normal! zz")
      end
    end
  )
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Show symbol picker for the current buffer.
function M.show_symbols()
  local bufnr = vim.api.nvim_get_current_buf()
  local requests = collect_requests(bufnr)

  if #requests == 0 then
    vim.notify("No requests found in this file", vim.log.levels.INFO)
    return
  end

  show_snacks_picker(requests)
end

return M
