local M = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function extract_url_path(line)
  if not line then return nil end
  local url = line:match("^%s*%u+%s+(.+)")
  if not url then return nil end
  local path = url:match("://[^/]*(.*)")
  if not path then
    path = url:match("}}(.*)")
  end
  if not path then
    path = url:match("^(/.*)")
  end
  if path and path ~= "" then
    path = path:gsub("%?.*", "")
  end
  return path and path ~= "" and path or nil
end

local function truncate_middle(s, max)
  if not s or #s <= max then return s or "" end
  local half = math.floor((max - 1) / 2)
  return s:sub(1, half) .. "…" .. s:sub(#s - half + 1)
end

local function truncate(s, max)
  if not s then return "" end
  if #s <= max then return s end
  return s:sub(1, max - 1) .. "…"
end

local function short_name(name)
  if not name then return "" end
  return name:match("([^%.]+)$") or name
end

local function method_hl(method)
  if not method or method == "--" then return "PosteMethodOther" end
  if method == "run" then return "PosteRun" end
  local m = method:upper()
  if m == "GET" then return "PosteMethodGET"
  elseif m == "POST" then return "PosteMethodPOST"
  elseif m == "PUT" then return "PosteMethodPUT"
  elseif m == "DELETE" then return "PosteMethodDELETE"
  elseif m == "PATCH" then return "PosteMethodPATCH"
  elseif m == "HEAD" then return "PosteMethodHEAD"
  else return "PosteMethodOther" end
end

---------------------------------------------------------------------------
-- Parse requests from buffer
---------------------------------------------------------------------------

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
          if not method then
            local run_target = next_line:match("^%s*run%s+(%S+)")
            if run_target then
              method = "run"
              url_path = run_target
            end
          end
          if method and method ~= "run" then
            url_path = extract_url_path(next_line)
          end
          break
        end
      end

      table.insert(requests, {
        name = name,
        method = method or "--",
        url_path = url_path,
        line = block.start_line,
      })
    end
  end

  return requests
end

---------------------------------------------------------------------------
-- Snacks picker
---------------------------------------------------------------------------

local function show_snacks_picker(requests)
  local max_method_width = 4
  for _, req in ipairs(requests) do
    local m = (req.method or "--"):len()
    if m > max_method_width then max_method_width = m end
  end

  local items = {}
  for _, req in ipairs(requests) do
    local method = req.method or "--"
    local url, short

    if method == "run" then
      url = "#" .. req.name
      short = short_name(req.name)
    else
      url = req.url_path or ""
      short = req.name or ""
    end

    url = truncate_middle(url, 55)
    short = truncate(short, 30)
    local pad = string.rep(" ", max_method_width - method:len())

    items[#items + 1] = {
      text = method .. pad .. "  " .. url .. "  " .. short,
      key = req,
      _method = method,
      _pad = pad,
      _url = url,
      _short = short,
    }
  end

  Snacks.picker.select(
    items,
    {
      prompt = "Requests",
      layout = "select",
      format_item = function(item, supports_chunks)
        if supports_chunks then
          return {
            { item._method .. item._pad, method_hl(item._method) },
            { "  ", "" },
            { item._url, "String" },
            { "  ", "" },
            { item._short, "Comment" },
          }
        end
        return item.text
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
