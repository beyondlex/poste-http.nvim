--- Symbol outline: pick an HTTP request from the current file.
--- Uses Telescope when available, falls back to vim.ui.select.

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

--- Scan buffer and collect all ### request blocks.
--- @param bufnr number Buffer handle
--- @return table[] List of { name, method, url_path, line }
local function collect_requests(bufnr)
  local requests = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for i, line in ipairs(lines) do
    local name = line:match("^%s*###%s+(.+)$")
    if name then
      local method = nil
      local url_path = nil
      local in_pre_script = false

      for j = i + 1, math.min(i + 20, #lines) do
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

        if not skip then
          method = next_line:match("^%s*(%u+)%s")
          if method then
            url_path = extract_url_path(next_line)
          end
          break
        end
      end

      table.insert(requests, { name = name, method = method, url_path = url_path, line = i })
    end
  end

  return requests
end

---------------------------------------------------------------------------
-- Telescope picker
---------------------------------------------------------------------------

--- Truncate a string with ellipsis if it exceeds max length.
local function truncate(s, max)
  if not s then return "" end
  if #s <= max then return s end
  return s:sub(1, max - 1) .. "…"
end

--- Show requests in a Telescope picker.
local function show_telescope_picker(requests)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  -- Calculate max URL path length (cap at 40)
  local max_path_len = 0
  for _, req in ipairs(requests) do
    if req.url_path then
      max_path_len = math.max(max_path_len, #req.url_path)
    end
  end
  max_path_len = math.min(max_path_len, 40)

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 8 },                    -- method
      { remaining = true },             -- name
      { width = max_path_len + 1 },     -- url path
      { width = 6 },                    -- line number
    },
  })

  local function make_display(entry)
    local path = entry.value.url_path
    return displayer({
      { entry.value.method or "—", "PosteSymbolMethod" },
      { entry.value.name, "Normal" },
      { path and truncate(path, 40) or "", "Comment" },
      { "L" .. entry.value.line, "Comment" },
    })
  end

  pickers.new({}, {
    prompt_title = "Requests",
    finder = finders.new_table({
      results = requests,
      entry_maker = function(req)
        local search_text = (req.method and ("[" .. req.method .. "] ") or "") .. req.name
        if req.url_path then
          search_text = search_text .. " " .. req.url_path
        end
        return {
          value = req,
          display = make_display,
          ordinal = search_text,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, _)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selection then
          vim.api.nvim_win_set_cursor(0, { selection.value.line, 0 })
          vim.cmd("normal! zz")
        end
      end)
      return true
    end,
  }):find()
end

---------------------------------------------------------------------------
-- Fallback: vim.ui.select
---------------------------------------------------------------------------

--- Show requests using vim.ui.select (works with any UI provider).
local function show_select_picker(requests)
  local items = {}
  for i, req in ipairs(requests) do
    local method_str = req.method and ("[" .. req.method .. "] ") or ""
    local path_str = req.url_path and (" " .. truncate(req.url_path, 40)) or ""
    items[i] = method_str .. req.name .. path_str .. "  (L" .. req.line .. ")"
  end

  vim.ui.select(items, {
    prompt = "Requests:",
    format_item = function(item) return item end,
  }, function(_, idx)
    if idx and requests[idx] then
      vim.api.nvim_win_set_cursor(0, { requests[idx].line, 0 })
      vim.cmd("normal! zz")
    end
  end)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Show symbol picker for the current buffer.
--- Prefers Telescope if available, falls back to vim.ui.select.
function M.show_symbols()
  local bufnr = vim.api.nvim_get_current_buf()
  local requests = collect_requests(bufnr)

  if #requests == 0 then
    vim.notify("No requests found in this file", vim.log.levels.INFO)
    return
  end

  -- Try Telescope first
  local ok = pcall(show_telescope_picker, requests)
  if ok then return end

  -- Fallback to vim.ui.select
  show_select_picker(requests)
end

return M
