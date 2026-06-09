--- Dataset benchmark runner.
--- Iterates scenario matrix, collects action metrics, outputs JSON.
--- Also provides compare() to diff baseline vs optimized results.
---
--- Usage:
---   nvim --headless -c "set rtp+=." -c "runtime plugin/poste.lua" -c "lua require('tests.bench_dataset').run('output.json')" -c "qa"
---   nvim --headless -c "set rtp+=." -c "lua require('tests.bench_dataset').compare('a.json','b.json')" -c "qa"

local M = {}
local DRV = require("tests.bench_dataset_driver")

-----------------------------------------------------------------
-- Scenario matrix
-----------------------------------------------------------------

local SCENARIOS = {
  { rows = 100,  cols = 5,  pagination = true,  label = "100x5_paged" },
  { rows = 100,  cols = 20, pagination = true,  label = "100x20_paged" },
  { rows = 1000, cols = 10, pagination = true,  label = "1kx10_paged" },
  { rows = 1000, cols = 10, pagination = false, label = "1kx10_all" },
  { rows = 10000, cols = 5,  pagination = true,  label = "10kx5_paged" },
  { rows = 10000, cols = 10, pagination = false, label = "10kx10_all" },
  { rows = 10000, cols = 10, pagination = true,  label = "10kx10_paged" },
  { rows = 50000, cols = 5,  pagination = true,  label = "50kx5_paged" },
  { rows = 50000, cols = 5,  pagination = false, label = "50kx5_all" },
}

-----------------------------------------------------------------
-- Action definitions
-----------------------------------------------------------------

local function build_actions()
  return {
    {
      name = "render_initial",
      warmup = 0,
      iterations = 1,
      fn = function(scenario)
        DRV.reset_state()
        local data = DRV.generate_dataset(scenario.rows, scenario.cols)
        scenario._data = data
        DRV.render_dataset(data)
      end,
    },
    {
      name = "page_next",
      warmup = 2,
      iterations = 10,
      fn = function(_)
        DRV.page_next()
      end,
    },
    {
      name = "page_prev",
      warmup = 2,
      iterations = 10,
      fn = function(_)
        DRV.page_prev()
      end,
    },
    {
      name = "page_first",
      warmup = 1,
      iterations = 5,
      fn = function(_)
        DRV.page_first()
      end,
    },
    {
      name = "page_last",
      warmup = 1,
      iterations = 5,
      fn = function(_)
        DRV.page_last()
      end,
    },
    {
      name = "move_right_50",
      warmup = 1,
      iterations = 5,
      fn = function(_)
        DRV.move_right(50)
      end,
    },
    {
      name = "move_down_100",
      warmup = 1,
      iterations = 5,
      fn = function(_)
        DRV.move_down(100)
      end,
    },
    {
      name = "move_to_first_col",
      warmup = 2,
      iterations = 10,
      fn = function(_)
        DRV.move_to_first_col()
      end,
    },
    {
      name = "move_to_last_col",
      warmup = 2,
      iterations = 10,
      fn = function(_)
        DRV.move_to_last_col()
      end,
    },
    {
      name = "move_to_first_row",
      warmup = 2,
      iterations = 10,
      fn = function(_)
        DRV.move_to_first_row()
      end,
    },
    {
      name = "move_to_last_row",
      warmup = 2,
      iterations = 10,
      fn = function(_)
        DRV.move_to_last_row()
      end,
    },
    {
      name = "sort_current_col",
      warmup = 1,
      iterations = 3,
      fn = function(_)
        DRV.move_to_first_col()
        DRV.sort_current_col()
      end,
    },
    {
      name = "search_query",
      warmup = 1,
      iterations = 3,
      fn = function(scenario)
        DRV.search_query(scenario.cols >= 5 and "filter_target" or "a")
      end,
    },
    {
      name = "search_next",
      warmup = 2,
      iterations = 10,
      fn = function(_)
        DRV.search_next()
      end,
    },
    {
      name = "search_prev",
      warmup = 2,
      iterations = 10,
      fn = function(_)
        DRV.search_prev()
      end,
    },
    {
      name = "filter_current_cell",
      warmup = 1,
      iterations = 3,
      fn = function(_)
        DRV.move_to_first_col()
        DRV.move_to_first_row()
        DRV.filter_current_cell()
      end,
    },
    {
      name = "clear_filter_search",
      warmup = 1,
      iterations = 3,
      fn = function(_)
        DRV.clear_filter_search()
      end,
    },
    {
      name = "render_twice_repeated",
      warmup = 0,
      iterations = 1,
      fn = function(scenario)
        DRV.reset_state()
        local data = DRV.generate_dataset(scenario.rows, scenario.cols)
        scenario._data = data
        DRV.render_dataset(data)
        DRV.render_dataset(data)
        DRV.reset_call_counter()
        DRV.trigger_winscrolled()
      end,
    },
  }
end

-----------------------------------------------------------------
-- Scenario setup before action measurement
-----------------------------------------------------------------

local function setup_scenario(scenario)
  DRV.reset_state()
  local data = DRV.generate_dataset(scenario.rows, scenario.cols)
  scenario._data = data
  DRV.render_dataset(data)

  local t = require("poste.sql.dataset").T()
  if t then
    t.pagination_enabled = scenario.pagination
    if not scenario.pagination then
      require("poste.sql.buffer_page").refresh_page()
    end
  end

  -- Move cursor to (1,1) for a consistent starting point
  local state = require("poste.state").sql
  state.cell.row = 1
  state.cell.col = 1
end

-----------------------------------------------------------------
-- run() entry point
-----------------------------------------------------------------

function M.run(output_path)
  output_path = output_path or "benchmark_output.json"

  DRV.load_poste_modules()
  DRV.install_call_counter()

  local git_hash = vim.fn.system("git rev-parse HEAD"):gsub("%s+", "")
  local timestamp = os.date("%Y-%m-%dT%H:%M:%S")

  local all_results = {}

  for _, scenario in ipairs(SCENARIOS) do
    print(string.format("[bench] %s  rows=%d cols=%d pagination=%s",
      scenario.label, scenario.rows, scenario.cols, tostring(scenario.pagination)))

    setup_scenario(scenario)

    local actions_result = {}
    local actions = build_actions()

    for _, action_def in ipairs(actions) do
      -- Warmup rounds
      for _ = 1, (action_def.warmup or 0) do
        action_def.fn(scenario)
      end

      -- Reset call counter before measurement
      DRV.reset_call_counter()

      -- Main measurement
      local metric = DRV.measure(
        function() action_def.fn(scenario) end,
        action_def.iterations
      )

      -- Optional phase probes for render_initial and render_twice_repeated
      local phases = nil
      if action_def.name == "render_initial" then
        phases = DRV.measure_phases({
          format   = function() DRV.phase_format_current_impl(scenario._data) end,
          render   = function()
            local lines, meta = require("poste.sql.format").format_resultset(scenario._data)
            DRV.phase_render_buffer_current_impl(lines, meta)
          end,
          highlights = function()
            local lines, meta = require("poste.sql.format").format_resultset(scenario._data)
            DRV.phase_highlights_current_impl(lines, meta)
          end,
        })
      elseif action_def.name == "render_twice_repeated" then
        phases = DRV.measure_phases({
          second_render = function()
            DRV.reset_state()
            local data = DRV.generate_dataset(scenario.rows, scenario.cols)
            DRV.render_dataset(data)
            DRV.render_dataset(data)
          end,
        })
      end

      -- Restore scenario pagination after actions that reset state
      if action_def.name == "render_initial" or action_def.name == "render_twice_repeated" then
        DRV.set_pagination(scenario.pagination)
      end

      -- Assertions
      local assertions = DRV.assertions_for(scenario)

      actions_result[action_def.name] = {
        duration_ms = metric.duration_ms,
        memory_mb_before = metric.memory_mb_before,
        memory_mb_after = metric.memory_mb_after,
        iterations = metric.iterations,
        phases = phases,
        assertions = assertions,
        header_float_calls = DRV.header_float_call_count,
      }
    end

    all_results[#all_results + 1] = {
      scenario = {
        rows = scenario.rows,
        cols = scenario.cols,
        pagination = scenario.pagination,
        label = scenario.label,
      },
      actions = actions_result,
    }
  end

  -- Write output
  local output = vim.json.encode({
    timestamp = timestamp,
    git_hash = git_hash,
    results = all_results,
  })

  local f = io.open(output_path, "w")
  if f then
    f:write(output)
    f:close()
    print(string.format("[bench] Results written to %s", output_path))
  else
    print(string.format("[bench] ERROR: Failed to write %s", output_path))
    print(output)
  end
end

-----------------------------------------------------------------
-- compare() diff tool
-----------------------------------------------------------------

function M.compare(baseline_path, optimized_path)
  local function read_json(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return vim.json.decode(content)
  end

  local baseline = read_json(baseline_path)
  local optimized = read_json(optimized_path)

  if not baseline then
    print(string.format("ERROR: Could not read %s", baseline_path))
    return
  end
  if not optimized then
    print(string.format("ERROR: Could not read %s", optimized_path))
    return
  end

  local lines = {}

  -- Header
  lines[#lines + 1] = ""
  lines[#lines + 1] = "=== Performance Comparison ==="
  lines[#lines + 1] = string.format("Baseline:   %s  (%s)", baseline_path, baseline.timestamp)
  lines[#lines + 1] = string.format("Optimized:  %s  (%s)", optimized_path, optimized.timestamp)
  lines[#lines + 1] = string.format("Baseline git:  %s", baseline.git_hash)
  lines[#lines + 1] = string.format("Optimized git: %s", optimized.git_hash)
  lines[#lines + 1] = ""

  -- Collect all action names from either result
  local all_action_names = {}
  local seen = {}
  for _, r in ipairs(baseline.results) do
    for name, _ in pairs(r.actions) do
      if not seen[name] then
        all_action_names[#all_action_names + 1] = name
        seen[name] = true
      end
    end
  end

  -- Duration table
  lines[#lines + 1] = "--- Duration (ms) ---"
  lines[#lines + 1] = string.format("%-12s %-22s %10s %10s %10s",
    "Scenario", "Action", "Baseline", "Optimized", "Speedup")
  lines[#lines + 1] = string.rep("-", 68)

  for _, scenario in ipairs(SCENARIOS) do
    local br, o_result
    for _, r in ipairs(baseline.results) do
      if r.scenario.label == scenario.label then br = r; break end
    end
    for _, r in ipairs(optimized.results) do
      if r.scenario.label == scenario.label then o_result = r; break end
    end
    if br and o_result then
      for _, name in ipairs(all_action_names) do
        local bm = br.actions[name]
        local om = o_result.actions[name]
        if bm and om then
          local bd = bm.duration_ms
          local od = om.duration_ms
          local speedup = (bd > 0 and od > 0) and string.format("%.2fx", bd / od) or "N/A"
          lines[#lines + 1] = string.format("%-12s %-22s %10.3f %10.3f %10s",
            scenario.label, name, bd, od, speedup)
        end
      end
    end
  end

  -- Memory delta table
  lines[#lines + 1] = ""
  lines[#lines + 1] = "--- Memory Δ (MB) ---"
  lines[#lines + 1] = string.format("%-12s %-22s %10s %10s",
    "Scenario", "Action", "Baseline", "Optimized")
  lines[#lines + 1] = string.rep("-", 58)

  for _, scenario in ipairs(SCENARIOS) do
    local br, o_result
    for _, r in ipairs(baseline.results) do
      if r.scenario.label == scenario.label then br = r; break end
    end
    for _, r in ipairs(optimized.results) do
      if r.scenario.label == scenario.label then o_result = r; break end
    end
    if br and o_result then
      for _, name in ipairs(all_action_names) do
        local bm = br.actions[name]
        local om = o_result.actions[name]
        if bm and om then
          local bd = (bm.memory_mb_after or 0) - (bm.memory_mb_before or 0)
          local od = (om.memory_mb_after or 0) - (om.memory_mb_before or 0)
          lines[#lines + 1] = string.format("%-12s %-22s %10.2f %10.2f",
            scenario.label, name, bd, od)
        end
      end
    end
  end

  -- Header float call count
  lines[#lines + 1] = ""
  lines[#lines + 1] = "--- Header float calls ---"
  lines[#lines + 1] = string.format("%-12s %-22s %10s %10s",
    "Scenario", "Action", "Baseline", "Optimized")
  lines[#lines + 1] = string.rep("-", 58)

  for _, scenario in ipairs(SCENARIOS) do
    local br, o_result
    for _, r in ipairs(baseline.results) do
      if r.scenario.label == scenario.label then br = r; break end
    end
    for _, r in ipairs(optimized.results) do
      if r.scenario.label == scenario.label then o_result = r; break end
    end
    if br and o_result then
      for _, name in ipairs(all_action_names) do
        local bm = br.actions[name]
        local om = o_result.actions[name]
        if bm and om then
          lines[#lines + 1] = string.format("%-12s %-22s %10d %10d",
            scenario.label, name,
            bm.header_float_calls or 0,
            om.header_float_calls or 0)
        end
      end
    end
  end

  -- Assertion failures
  lines[#lines + 1] = ""
  lines[#lines + 1] = "--- Assertion failures ---"
  local had_failures = false

  local function check_assertions(results, label)
    for _, r in ipairs(results) do
      for name, action in pairs(r.actions) do
        if action.assertions and not action.assertions.all_passed then
          had_failures = true
          for _, detail in pairs(action.assertions.details) do
            if type(detail) == "table" and detail.passed == false then
              lines[#lines + 1] = string.format("%s %-12s %-22s FAIL: %s (expected=%s got=%s)",
                label, r.scenario.label, name, detail.name,
                tostring(detail.expected or "?"), tostring(detail.got or "?"))
            end
          end
        end
      end
    end
  end

  check_assertions(baseline.results, "B ")
  check_assertions(optimized.results, "O ")

  if not had_failures then
    lines[#lines + 1] = "  (none)"
  end

  lines[#lines + 1] = ""
  print(table.concat(lines, "\n"))
end

return M
