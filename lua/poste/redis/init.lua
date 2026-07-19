--- Redis protocol module.
---
--- Handles filetype dispatch for poste_redis buffers,
--- Redis response formatting, and extmark-based syntax highlighting.
local M = {}

local redis_ns = vim.api.nvim_create_namespace("poste_redis")

--- Apply extmark-based coloring to Redis response buffer.
function M.apply_highlights(buf, lines, rtype)
  local hl_group = "PosteRedis" .. (rtype:gsub("^%l", string.upper):gsub("_", ""))
  vim.api.nvim_buf_clear_namespace(buf, redis_ns, 0, -1)
  for i, line in ipairs(lines) do
    local row = i - 1
    for match_start, match_end in line:gmatch('()"()') do
      if match_start and match_end then
        local start_col = match_start - 1
        vim.api.nvim_buf_set_extmark(buf, redis_ns, row, start_col, {
          end_row = row, end_col = match_end,
          hl_group = "PosteRedisString", priority = 100,
        })
      end
    end
    for num in line:gmatch("%d+") do
      local s, e = line:find(num, 1, true)
      if s then
        vim.api.nvim_buf_set_extmark(buf, redis_ns, row, s - 1, {
          end_row = row, end_col = e,
          hl_group = "PosteRedisNumber", priority = 100,
        })
      end
    end
    if line:find("^%[") then
      local s, e = line:find("^%[.-%]")
      if s then
        vim.api.nvim_buf_set_extmark(buf, redis_ns, row, s - 1, {
          end_row = row, end_col = e,
          hl_group = hl_group, priority = 150,
        })
      end
    end
    if line:match("^✓ ") then
      vim.api.nvim_buf_set_extmark(buf, redis_ns, row, 0, {
        end_row = row, end_col = #line,
        hl_group = "PosteRedisStatus", priority = 150,
      })
    end
    if line:match("^time:") or line:match("^db:") then
      local s = line:find(":")
      if s then
        vim.api.nvim_buf_set_extmark(buf, redis_ns, row, 0, {
          end_row = row, end_col = s,
          hl_group = "PosteVerboseKey", priority = 100,
        })
        vim.api.nvim_buf_set_extmark(buf, redis_ns, row, s, {
          end_row = row, end_col = #line,
          hl_group = "Comment", priority = 100,
        })
      end
    end
    if line:find("^─") then
      vim.api.nvim_buf_set_extmark(buf, redis_ns, row, 0, {
        end_row = row, end_col = #line,
        hl_group = "PosteVerboseSeparator", priority = 100,
      })
    end
    if line:find("score │ member") then
      vim.api.nvim_buf_set_extmark(buf, redis_ns, row, 0, {
        end_row = row, end_col = #line,
        hl_group = "PosteVerboseKey", priority = 100,
      })
    end
  end
end

return M