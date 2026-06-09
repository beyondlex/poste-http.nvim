--- Stable test driver for dataset benchmark.
--- Wraps poste module internals behind action names that survive refactoring.
--- Designed to work in headless Neovim (nvim --headless -c "..." -c "qa").
---
--- Usage:
---   local D = require("tests.bench_dataset_driver")
---   D.load_poste_modules()
---   local data = D.generate_dataset(10000, 10)
---   D.render_dataset(data)
---   local m = D.measure(function() D.move_right(10) end, 5)
---   local a = D.assertions_for({ cols = 10, rows = 10000 })
local M = {}

-- Default page size matches dataset.lua
local PAGE_SIZE = 50

-----------------------------------------------------------------
-- Module loading + state reset
-----------------------------------------------------------------

function M.load_poste_modules()
  require("poste.sql.highlights")
  require("poste.sql.format")
  require("poste.sql.buffer")
  require("poste.sql.buffer_nav")
  require("poste.sql.buffer_page")
  require("poste.sql.buffer_search")
  require("poste.sql.dataset")
  require("poste.state")
end

function M.reset_state()
  local D = require("poste.sql.dataset")
  D.close_header_float()
  if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
    pcall(vim.api.nvim_win_close, D.dataset_window, true)
  end
  if D.dataset_buffer and vim.api.nvim_buf_is_valid(D.dataset_buffer) then
    pcall(vim.api.nvim_buf_delete, D.dataset_buffer, { force = true })
  end
  D.tabs = {}
  D.active_tab_idx = 0
  D.dataset_buffer = nil
  D.dataset_window = nil
  D.float_buf = nil
  D.float_win = nil
  D.scroll_autocmd_id = nil
  D.resize_autocmd_id = nil
  local state = require("poste.state")
  state.sql.cell = { row = 1, col = 1 }
  state.sql.highlight_cell = true
  state.sql.last_dataset = nil
  M.reset_call_counter()
  collectgarbage("collect")
end

-----------------------------------------------------------------
-- Mock data generation
-----------------------------------------------------------------

--- Generate a mock resultset dataset.
--- @param rows number Number of rows
--- @param cols number Number of columns
--- @return table data Compatible with format.format_resultset()
function M.generate_dataset(rows, cols)
  math.randomseed(42)

  local columns = {}
  for c = 1, cols do
    columns[c] = {
      name = string.format("col_%d", c),
      type = (c % 3 == 0) and "integer" or "text",
    }
  end

  local row_data = {}
  for r = 1, rows do
    local row = {}
    for c = 1, cols do
      local rand = math.random()
      if rand < 0.60 then
        local len = math.random(3, 30)
        local chars = {}
        for i = 1, len do
          chars[i] = string.char(math.random(97, 122))
        end
        row[c] = table.concat(chars)
      elseif rand < 0.75 then
        row[c] = math.random(1, 1000000)
      elseif rand < 0.85 then
        row[c] = math.random() > 0.5
      elseif rand < 0.95 then
        row[c] = vim.NIL
      else
        row[c] = { id = r, nested = { a = 1, b = "str" } }
      end
    end
    row_data[r] = row
  end
  -- Ensure cell (1,1) is a predictable non-NULL value for filter tests
  row_data[1][1] = "filter_target"

  return {
    type = "resultset",
    results = {{
      columns = columns,
      rows = row_data,
      row_count = rows,
      execution_time_ms = 0,
      column_types = columns,
    }},
    total_rows = rows,
    total_execution_time_ms = 0,
    connection = "benchmark://localhost:9999/testdb",
    database = "testdb",
    dialect = "postgres",
    table_name = "bench_table",
  }
end

-----------------------------------------------------------------
-- Timing + memory
-----------------------------------------------------------------

--- Measure a function's execution time and memory delta.
--- @param fn function
--- @param iterations number
--- @return table { duration_ms, memory_mb_before, memory_mb_after, iterations }
function M.measure(fn, iterations)
  iterations = iterations or 1

  collectgarbage("collect")
  local mem_before = collectgarbage("count")

  local start = vim.loop.hrtime()
  for _ = 1, iterations do
    fn()
  end
  local elapsed_ns = vim.loop.hrtime() - start

  collectgarbage("collect")
  local mem_after = collectgarbage("count")

  return {
    duration_ms = elapsed_ns / 1e6 / iterations,
    memory_mb_before = mem_before / 1024,
    memory_mb_after = mem_after / 1024,
    iterations = iterations,
  }
end

--- Measure multiple phase functions, each once, returning individual durations.
--- @param phase_fns table<string, function>
--- @return table<string, number>
function M.measure_phases(phase_fns)
  local results = {}
  for name, fn in pairs(phase_fns) do
    local m = M.measure(fn, 1)
    results[name] = m.duration_ms
  end
  return results
end

-----------------------------------------------------------------
-- Stable action API
-----------------------------------------------------------------

local function tab()
  return require("poste.sql.dataset").T()
end

local function state()
  return require("poste.state").sql
end

local function D()
  return require("poste.sql.dataset")
end

function M.render_dataset(data, opts)
  opts = opts or {}
  local fmt = require("poste.sql.format")
  local layout = fmt.plan_resultset_layout(data)
  local lines, meta
  if layout then
    opts.layout = layout
    lines, meta = fmt.render_page(layout, 1, PAGE_SIZE)
    meta.total_rows = layout.total_rows
  else
    lines, meta = fmt.format_resultset(data)
  end
  require("poste.sql.buffer").render_dataset(lines, meta, opts)
end

function M.page_next()
  require("poste.sql.buffer_page").next_page()
end

function M.page_prev()
  require("poste.sql.buffer_page").prev_page()
end

function M.page_first()
  require("poste.sql.buffer_page").goto_first_page()
end

function M.page_last()
  require("poste.sql.buffer_page").goto_last_page()
end

function M.move_right(n)
  n = n or 1
  for _ = 1, n do
    require("poste.sql.buffer_nav").move_cell(0, 1)
  end
end

function M.move_left(n)
  n = n or 1
  for _ = 1, n do
    require("poste.sql.buffer_nav").move_cell(0, -1)
  end
end

function M.move_down(n)
  n = n or 1
  for _ = 1, n do
    require("poste.sql.buffer_nav").move_cell(1, 0)
  end
end

function M.move_up(n)
  n = n or 1
  for _ = 1, n do
    require("poste.sql.buffer_nav").move_cell(-1, 0)
  end
end

function M.move_to_first_col()
  require("poste.sql.buffer_nav").goto_first_col()
end

function M.move_to_last_col()
  require("poste.sql.buffer_nav").goto_last_col()
end

function M.move_to_first_row()
  require("poste.sql.buffer_nav").goto_first_row()
end

function M.move_to_last_row()
  require("poste.sql.buffer_nav").goto_last_row()
end

function M.sort_current_col()
  require("poste.sql.buffer_nav").sort_by_current_col()
end

--- Search for text across all rows.  Bypasses the float-window prompt.
function M.search_query(text)
  local t = tab()
  if not t or not t.data then return end
  local res = t.data.results and t.data.results[1]
  if not res or not res.rows then return end
  t.search_text = text
  t.search_matches = {}
  local q = text:lower()
  for ri, row in ipairs(res.rows) do
    for ci, val in ipairs(row) do
      local s = (val == nil or val == vim.NIL) and "" or tostring(val)
      if s:lower():find(q, 1, true) then
        t.search_matches[#t.search_matches + 1] = { row = ri, col = ci }
      end
    end
  end
  if #t.search_matches > 0 then
    t.search_idx = 1
    require("poste.sql.buffer_search").apply_search_highlights()
  else
    t.search_idx = 0
    require("poste.sql.buffer_search").apply_search_highlights()
  end
end

function M.search_next()
  require("poste.sql.buffer_search").next_search_match()
end

function M.search_prev()
  require("poste.sql.buffer_search").prev_search_match()
end

function M.filter_current_cell()
  require("poste.sql.buffer_search").filter_by_current_cell()
end

function M.clear_filter_search()
  require("poste.sql.buffer_search").clear_filter_search()
end

function M.tab_next()
  require("poste.sql.buffer").next_tab()
end

function M.tab_prev()
  require("poste.sql.buffer").prev_tab()
end

-----------------------------------------------------------------
-- Optional phase probes (best-effort; may change after refactor)
-----------------------------------------------------------------

function M.phase_format_current_impl(data)
  if not data then return end
  require("poste.sql.format").format_resultset(data)
end

function M.phase_render_buffer_current_impl(lines, meta)
  if not lines then return end
  local buf = require("poste.sql.buffer").get_dataset_buffer()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

function M.phase_highlights_current_impl(lines, meta)
  if not lines then return end
  local buf = require("poste.sql.buffer").get_dataset_buffer()
  require("poste.sql.highlights").apply_dataset_highlights(buf, lines, meta)
end

-----------------------------------------------------------------
-- Correctness assertions
-----------------------------------------------------------------

--- Check invariants after an action.
--- @param scenario table { rows, cols, pagination }
--- @return table { all_passed, details }
function M.assertions_for(scenario)
  scenario = scenario or {}
  local t = tab()
  local meta = t and t.meta
  local s = state()
  local result = {}

  result.buffer_valid = {
    name = "buffer_valid",
    passed = D().dataset_buffer ~= nil and vim.api.nvim_buf_is_valid(D().dataset_buffer) or false,
  }

  result.meta_resultset = {
    name = "meta_type_resultset",
    passed = meta ~= nil and meta.type == "resultset",
  }

  if meta then
    result.data_start_line = {
      name = "data_start_line",
      passed = meta.data_start_line ~= nil,
    }
    result.col_count = {
      name = "col_count",
      passed = meta.col_count == scenario.cols,
      expected = scenario.cols,
      got = meta.col_count,
    }
    result.row_count_positive = {
      name = "row_count_positive",
      passed = (meta.row_count or 0) > 0,
      got = meta.row_count,
    }
    if t and t.pagination_enabled ~= nil then
      result.pagination_matches = {
        name = "pagination_matches",
        passed = t.pagination_enabled == scenario.pagination,
      }
    end
    if t and t.pagination_enabled and t.num_pages then
      result.page_in_range = {
        name = "page_in_range",
        passed = t.page >= 1 and t.page <= t.num_pages,
        page = t.page,
        num_pages = t.num_pages,
      }
      result.visible_rows_match = {
        name = "visible_rows_match",
        passed = t.visible_rows == nil or t.visible_rows <= t.page_size,
        visible_rows = t.visible_rows,
        page_size = t.page_size,
      }
    end
  end

  result.cell_in_bounds = {
    name = "cell_in_bounds",
    passed = s ~= nil and s.cell.row >= 1 and s.cell.col >= 1,
  }

  if meta and meta.row_count then
    result.cell_row_in_bounds = {
      name = "cell_row_in_bounds",
      passed = s.cell.row <= meta.row_count,
      row = s.cell.row,
      max_row = meta.row_count,
    }
  end

  if meta and meta.col_count then
    result.cell_col_in_bounds = {
      name = "cell_col_in_bounds",
      passed = s.cell.col <= meta.col_count,
      col = s.cell.col,
      max_col = meta.col_count,
    }
  end

  if t and t.search_text and #t.search_matches > 0 then
    result.search_match_count = {
      name = "search_match_count",
      passed = #t.search_matches > 0,
      count = #t.search_matches,
    }
    result.search_idx_in_range = {
      name = "search_idx_in_range",
      passed = (t.search_idx or 0) >= 0 and (t.search_idx or 0) <= #t.search_matches,
    }
  end

  if t and t.filter_active then
    result.filter_active = {
      name = "filter_active",
      passed = true,
      filter_col = t.filter_col,
      filter_val = t.filter_val,
    }
  end

  local all_passed = true
  for _, v in pairs(result) do
    if type(v) == "table" and v.passed == false then
      all_passed = false
    end
  end

  return { all_passed = all_passed, details = result }
end

-----------------------------------------------------------------
-- Leak detection: call counter for update_header_float
-----------------------------------------------------------------

M.header_float_call_count = 0
local orig_update_header_float = nil

function M.install_call_counter()
  if orig_update_header_float then return end
  local buf_nav = require("poste.sql.buffer_nav")
  orig_update_header_float = buf_nav.update_header_float
  buf_nav.update_header_float = function(...)
    M.header_float_call_count = M.header_float_call_count + 1
    return orig_update_header_float(...)
  end
end

function M.reset_call_counter()
  M.header_float_call_count = 0
end

--- Trigger WinScrolled for the dataset buffer to detect duplicate autocmds.
function M.trigger_winscrolled()
  local buf = D().dataset_buffer
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_exec_autocmds("WinScrolled", { buffer = buf })
  end
end

-----------------------------------------------------------------
-- Helpers for setting up pagination state
-----------------------------------------------------------------

--- Configure pagination on the current tab.
--- @param enabled boolean
function M.set_pagination(enabled)
  local t = tab()
  if not t then return end
  t.pagination_enabled = enabled
  if not enabled then
    require("poste.sql.buffer_page").refresh_page()
  end
end

--- Ensure search is cleared for a clean benchmark action.
function M.clear_search_state()
  local t = tab()
  if not t then return end
  t.search_text = nil
  t.search_matches = {}
  t.search_idx = 0
  if D().dataset_buffer and vim.api.nvim_buf_is_valid(D().dataset_buffer) then
    vim.api.nvim_buf_clear_namespace(D().dataset_buffer, D().search_ns, 0, -1)
  end
end

return M
