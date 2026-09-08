local M = {}
local text = require("poste-http.ui.text")
local semantics = require("poste-http.ui.semantics")
-- Fallback picker for the no-snacks path of show_symbols.
local picker = require("poste-http.ui.picker")

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

local truncate_middle = text.middle
local truncate = text.truncate

local function short_name(name)
  if not name then return "" end
  return name:match("([^%.]+)$") or name
end

local method_hl = semantics.method_hl

-- Index of the last request starting at or before cursor_line (nil if none).
-- Same "current block" semantics as outline.lua's find_current_item.
local function current_index(requests, cursor_line)
  local idx = nil
  for i, req in ipairs(requests) do
    if (req.line or 0) <= cursor_line then
      idx = i
    else
      break
    end
  end
  return idx
end

---------------------------------------------------------------------------
-- Parse requests from buffer
---------------------------------------------------------------------------

local function collect_requests(bufnr)
  local cache = require("poste-http.http.cache")
  local bc = cache.get_buffer_cache(bufnr)
  local requests = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for _, block in ipairs(bc.blocks or {}) do
    local name = block.name
    if name and name ~= "" then
      local method = nil
      local url_path = nil
      local in_pre_script = false
      local scan_end = math.min(block.end_line, #lines)

      for j = block.start_line + 1, scan_end do
        local next_line = lines[j]
        local skip = false

        if next_line:match("^%s*$") then skip = true end
        if not skip and in_pre_script then
          if next_line:match("%%}") then in_pre_script = false end
          skip = true
        end
        if not skip and next_line:match("^%s*<%s*{") then
          in_pre_script = true
          skip = true
          if next_line:match("%%}") then in_pre_script = false end
        end
        if not skip and next_line:match("^%s*@%S") then skip = true end
        if not skip and next_line:match("^%s*#") then skip = true end
        if not skip and next_line:match("^%s*<<") then skip = true end

        if not skip then
          local run_target = next_line:match("^%s*[Rr][Uu][Nn]%s+(%S+)")
          if run_target then
            method = "RUN"
            url_path = run_target
          else
            method = next_line:match("^%s*(%u+)%s+(%S+)")
            if not method then
              method = next_line:match("^%s*(%u+)%s+$")
            end
            if not method then
              method = next_line:match("^%s*(%u+)$")
            end
          end
          if method and method ~= "RUN" then
            url_path = extract_url_path(next_line)
            break
          end
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

local function jump_to_request(req)
  vim.api.nvim_win_set_cursor(0, { req.line, 0 })
  vim.cmd("normal! zz")
end

-- Snacks opens with the cursor on the first list row; on_show fires after the
-- items are sorted, so walk them and land on the marked current one (same
-- pattern as snacks' own git_branches source).
local function preselect_current(snacks, p)
  for i, item in ipairs(p:items()) do
    if item.current then
      p.list:view(i)
      snacks.picker.actions.list_scroll_center(p)
      break
    end
  end
end

local function show_snacks_picker(snacks, requests, current_idx)
  local max_method_width = 4
  for _, req in ipairs(requests) do
    local m = (req.method or "--"):len()
    if m > max_method_width then max_method_width = m end
  end

  local items = {}
  for i, req in ipairs(requests) do
    local method = req.method or "--"
    local url, short

    if method == "RUN" then
      url = req.url_path or "#" .. req.name
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
      current = (i == current_idx) or nil,
      _method = method,
      _pad = pad,
      _url = url,
      _short = short,
    }
  end

  snacks.picker.select(
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
      snacks = {
        on_show = function(p)
          preselect_current(snacks, p)
        end,
      },
    },
    function(item)
      if item and item.key then
        jump_to_request(item.key)
      end
    end
  )
end

-- Fallback picker (ui/picker primitive) when snacks.picker is unavailable.
local function show_fallback_picker(requests)
  local normalized = {}
  for _, req in ipairs(requests) do
    normalized[#normalized + 1] = {
      key = req,
      name = req.name,
      description = (req.method or "--") .. " " .. (req.url_path or ""),
    }
  end
  picker.open(normalized, "Requests", function(req)
    if req then
      jump_to_request(req)
    end
  end)
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

  local cursor = vim.api.nvim_win_get_cursor(0)
  local idx = cursor and current_index(requests, cursor[1]) or nil

  local ok_snacks, snacks = pcall(require, "snacks")
  if ok_snacks and snacks and snacks.picker then
    show_snacks_picker(snacks, requests, idx)
    return
  end
  show_fallback_picker(requests)
end

--- Collect request list for the outline/symbol method column.
--- @param bufnr number
--- @return table  list of { name, method, url_path }
function M.collect_requests(bufnr)
  return collect_requests(bufnr)
end

--- Index (1-based) of the request containing cursor_line, or nil when the
--- cursor sits above every request. Exported for the preselect spec.
--- @param requests table  list of { line = number, ... }
--- @param cursor_line number
--- @return number|nil
function M.current_index(requests, cursor_line)
  return current_index(requests, cursor_line)
end

return M
