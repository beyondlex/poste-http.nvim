# Dataset Buffer Performance Optimization Plan

## Overview

Target: Neovim-side dataset buffer code under `lua/poste/sql/`, optimizing large result set rendering, horizontal/vertical navigation, pagination, search, filtering, sorting, and highlights.

Layout: `lua/poste/sql/` — dataset buffer code
Strategy: benchmark-first; compare across branches via `git worktree`.

---

## Step 0: Benchmark Harness + P0 Leak Fix (→ `main` branch)

### Files

| File | Purpose |
|------|---------|
| `tests/bench_dataset_driver.lua` | Stable action API, mock data, timer, assertions |
| `tests/bench_dataset.lua` | Scenario matrix, run() entry, compare() diff tool |
| `tests/bench_run.sh` | Convenience runner script |

### `bench_dataset_driver.lua` — Design

**Responsibility**: Wrap poste module internals behind stable action names; provide repeatable measurement infrastructure.

```lua
-- Exports
M.load_poste_modules()       -- one-time: require all poste.sql.* modules
M.reset_state()              -- clear D.tabs, cell, force GC
M.generate_dataset(rows, cols)  → mock data object
M.measure(fn, iterations)    → { duration_ms, memory_mb_before, memory_mb_after }
M.measure_phases({ phase_fn_map })  → { phase_name = ms, ... }  -- optional diagnostics

-- Actions (stable; survive refactor)
M.render_dataset(data)
M.page_next() / page_prev() / page_first() / page_last()
M.move_right(n) / move_left(n) / move_down(n) / move_up(n)
M.move_to_first_col() / move_to_last_col()
M.move_to_first_row() / move_to_last_row()
M.sort_current_col()
M.search_query(text)
M.search_next() / search_prev()
M.filter_current_cell()
M.clear_filter_search()
M.tab_next() / tab_prev()

-- Optional phase probes (best effort; may change after refactor)
M.phase_format_current_impl(data)
M.phase_render_buffer_current_impl(lines, meta)
M.phase_highlights_current_impl(lines, meta)

-- Assertions
M.assertions_for(scenario)   → { all_passed, details: { name → passed/error } }

-- Leak detection
M.install_call_counter()     -- wraps buffer_nav.update_header_float with counter
M.header_float_call_count    -- read after each action
```

Keep the benchmark contract action-oriented. Phase timings are useful while the current functions exist, but they must not be required for comparison because the optimization work may split or remove internals such as `format_resultset()`, `apply_dataset_highlights()`, or `update_header_float()`.

### `bench_dataset.lua` — Design

**Scenario matrix** (9 combinations):

| rows | cols | pagination | label |
|------|------|------------|-------|
| 100 | 5 | true | `100x5_paged` |
| 100 | 20 | true | `100x20_paged` |
| 1000 | 10 | true | `1kx10_paged` |
| 1000 | 10 | false | `1kx10_all` |
| 10000 | 5 | true | `10kx5_paged` |
| 10000 | 10 | false | `10kx10_all` |
| 10000 | 10 | true | `10kx10_paged` |
| 50000 | 5 | true | `50kx5_paged` |
| 50000 | 5 | false | `50kx5_all` |

**Actions measured per scenario** (with iterations & warmup):

| Action | Iterations | Notes |
|--------|------------|-------|
| `render_initial` | 1 | includes format + buffer write + highlights |
| `page_next` / `page_prev` | 10 each | |
| `page_first` / `page_last` | 5 each | |
| `move_right_50` | 5 | 50 cells right, may wrap |
| `move_down_100` | 5 | 100 cells down, clamps within the visible page |
| `move_to_first_col` / `move_to_last_col` | 10 each | |
| `move_to_first_row` / `move_to_last_row` | 10 each | |
| `sort_current_col` | 3 | (asc, desc, reset cycle) |
| `search_query` | 3 | searches for common substring |
| `search_next` / `search_prev` | 10 each | |
| `filter_current_cell` | 3 | |
| `clear_filter_search` | 3 | |
| `render_twice_repeated` | 1 | detects autocmd leak |

**Mock data distribution** (per cell):
- 60% text (3-30 random lowercase chars)
- 15% number (1–1000000)
- 10% boolean
- 10% NULL (vim.NIL)
- 5% JSON object `{ id = N, nested = { a = 1, b = "str" } }`

**Output JSON schema**:

```json
{
  "timestamp": "2026-06-09T10:00:00",
  "git_hash": "abc123",
  "results": [
    {
      "scenario": { "rows": 10000, "cols": 10, "pagination": true, "label": "10kx10_paged" },
      "actions": {
        "render_initial": {
          "duration_ms": 12.34,
          "memory_mb_before": 45.0,
          "memory_mb_after": 68.0,
          "iterations": 1,
          "phases": { "format": 8.1, "render": 2.0 },
          "assertions": { "all_passed": true, "details": { ... } },
          "header_float_calls": 0
        },
        ...
      }
    }
  ]
}
```

Each measured action must also assert stable UI/behavior invariants:

- active cell row/column
- current page and total pages
- visible row count and buffer line count
- dataset buffer/window validity
- `leftcol` after horizontal movement
- winbar text is non-empty for resultsets
- header float text aligns with the current `leftcol`
- search match count and current match index after search actions

**compare(baseline, optimized) output**:

```
=== Performance Comparison ===
Baseline:   main_results.json (2026-06-09T10:00:00)
Optimized:  opt_results.json  (2026-06-09T11:00:00)

Scenario             Action               Baseline  Optimized    Speedup
─────────────────────────────────────────────────────────────────────────
10kx10_paged         render_initial       120.45ms   12.34ms    9.76x
10kx10_paged         page_next             15.67ms    1.23ms   12.74x
...
```

### P0 Fix: `buffer.lua` — autocmd leak

**Location**: `lua/poste/sql/buffer.lua:327`

**Change**: delete old `D.scroll_autocmd_id` before creating new `WinScrolled`, mirroring existing `resize_autocmd_id` cleanup.

```diff
+ if D.scroll_autocmd_id then
+   pcall(vim.api.nvim_del_autocmd, D.scroll_autocmd_id)
+   D.scroll_autocmd_id = nil
+ end
  D.scroll_autocmd_id = vim.api.nvim_create_autocmd("WinScrolled", {
    buffer = D.dataset_buffer,
    callback = function()
      require("poste.sql.buffer_nav").update_header_float()
    end,
  })
```

**Validation**: `render_twice_repeated` action should render the same dataset twice, trigger a deterministic horizontal scroll/header refresh, and compare `header_float_call_count`. Before the fix, repeated renders can add duplicate `WinScrolled` callbacks; after the fix, the count should stay stable.

---

## Step 1 (P1): Split Formatting into Planning + Page Rendering

### Files: `lua/poste/sql/format.lua`, `lua/poste/sql/buffer.lua`

### Current problem

`format_resultset()` does three inseparable passes in one call:
1. `calc_column_widths()` — scans ALL rows
2. `is_numeric_column()` — scans ALL rows
3. `data_row()` — renders ALL rows

Then `render_dataset()` slices the visible page. 100K rows → 100K formatted, 50 displayed.

### Design

```lua
-- format.lua

-- Phase 1: full-table metadata (scans all rows once)
M.plan_resultset_layout = function(data) → Layout
  -- returns: { columns, col_widths, numeric_cols, row_num_width, total_rows,
  --            original_row_count, data } — no rendered strings

-- Phase 2: page-level rendering (scans only page_size rows)
M.render_page = function(layout, page, page_size) → lines, meta
  -- renders border + header + page rows + footer
  -- row numbers reflect global position

-- Alternative: render arbitrary row slice (for filters/search)
M.render_view = function(layout, view_indices, page, page_size, opts) → lines, meta
  -- view_indices: 1-based indices into layout.data.results[1].rows
  -- opts.row_number_mode = "source" | "view"
```

`render_view()` must support two row-number modes to preserve current behavior:

- normal pagination uses source row numbers, matching today's full-render-then-slice behavior
- filtered views use view row numbers, matching today's `format_resultset(filtered_data)` behavior

### Tab state changes

```lua
-- dataset.lua tab struct additions
tab.layout = nil              -- Layout object from plan_resultset_layout()
tab.rows_source = nil         -- original result rows, treated as immutable
tab.view_indices = nil        -- active row indices into rows_source
tab.row_number_mode = "source"
tab.page = 1
tab.page_size = 50
```

### Page switch performance

| Before | After |
|--------|-------|
| `format_resultset(100K rows)` = O(100K) format | `plan_resultset_layout(100K rows)` = O(100K) width calc |
| `vim.deepcopy(padded)` = O(100K) | `render_page(layout, page, 50)` = O(50) lines |
| `padded = sliced` | No full padded array |
| Total: **~O(200K)** | Total: **~O(100K + 50)** |

Note: first render still scans all rows for width planning. Subsequent page switches only do O(page_size). The width scan is unavoidable for stable column widths (requirement: column widths must remain consistent across pages).

### Column width stability

`plan_resultset_layout()` scans all rows once. `render_page()`/`render_view()` uses the same `col_widths` for every page. No width jitter.

Important integration rule: after this step, `buffer.render_dataset()` should not reconstruct `padded_full` from already-rendered full lines. Add a new render path or options shape that accepts layout/page output directly, otherwise the new formatter can accidentally reintroduce the old O(n_rows) work.

---

## Step 2 (P2): Reduce Repeated Work in Hot Navigation Paths

### 2a: Header Float Reuse

**File**: `lua/poste/sql/buffer_nav.lua`

**Current**: `update_header_float()` closes float, creates new buf, writes one line, opens new window on every horizontal move + scroll.

**Design**:
```lua
function M.update_header_float()
  local tab, win = D.T(), D.dataset_window
  if not tab or not tab.header_text or not win or not vim.api.nvim_win_is_valid(win) then return end

  local win_width = vim.api.nvim_win_get_width(win)
  if win_width <= 0 then return end

  local leftcol = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().leftcol
  end)

  -- Skip if nothing changed
  if leftcol == D._float_last_leftcol and win_width == D._float_last_width
     and tab.header_text == D._float_last_header then return end

  D._float_last_leftcol = leftcol
  D._float_last_width = win_width
  D._float_last_header = tab.header_text

  local padded = "  " .. tab.header_text
  local index = tab.header_index or require("poste.sql.buffer_nav").build_header_index(padded)
  local text = slice_header_to_win(leftcol, win_width, padded, index)

  local float_buf = D.float_buf
  local float_win = D.float_win

  if float_buf and vim.api.nvim_buf_is_valid(float_buf) then
    -- Reuse buf: update content in place
    vim.api.nvim_set_option_value("modifiable", true, { buf = float_buf })
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, { text })
    vim.api.nvim_set_option_value("modifiable", false, { buf = float_buf })

    if float_win and vim.api.nvim_win_is_valid(float_win) then
      -- Reuse win: just ensure width is correct
      vim.api.nvim_win_set_config(float_win, { width = win_width })
      return
    end
  end

  -- Fallthrough: create new buf + win (first time or after close)
  D.close_header_float()
  -- ... existing creation logic ...
end
```

**Key**: `D.close_header_float()` is only called when we actually need to create fresh. The `close_header_float` scanning of all tabpage windows becomes a cold path.

Also reset float cache state in `D.close_header_float()`:

```lua
D._float_last_leftcol = nil
D._float_last_width = nil
D._float_last_header = nil
```

When creating a new float buffer, set `buftype=nofile`, `bufhidden=wipe`, `swapfile=false`, and restore `modifiable=false` after writing. This avoids hidden scratch buffers surviving longer than expected.

### 2b: find_cell_ranges — Multi-range from one parse

**File**: `lua/poste/sql/highlights.lua`

**Current**: `position_cursor()` calls `find_cell_range()` for target column (line 169) and last column (line 186). The second call can reuse the one-entry separator cache because Lua strings compare by content, but `position_cursor()` still does two range lookups and two display-width calculations.

**Design**:
```lua
-- Return both target and last-col ranges from one sep scan
function M.find_cell_ranges(line, target_col, col_count)
  if not line or line == "" then return nil end

  local seps
  -- Cache keyed by line content (same as current one-entry)
  if _cache_line == line then
    seps = _cache_seps
  else
    seps = compute_seps(line)
    _cache_line = line
    _cache_seps = seps
  end

  if target_col > #seps - 1 then return nil end
  if col_count > #seps - 1 then return nil end

  local function range_for(col)
    local next_sep = seps[col]
    local close_sep = seps[col + 1]
    return { ext_start = next_sep + 2, ext_end = close_sep - 1, cursor_col = next_sep + 2 }
  end

  return {
    target = range_for(target_col),
    last   = range_for(col_count),
  }
end
```

### 2c: strdisplaywidth consolidation

`position_cursor()` computes `strdisplaywidth` for target cell and last column separately. Merge into a single pass using the `find_cell_ranges` result.

Do not key the cache only by row number. A row line can change when sorting, filtering, pagination, or column widths change. Either cache by rendered line content, or include a render generation id on the tab and key by `{ tab_id, render_generation, visible_row }`.

---

## Step 3 (P3): View-Based Search/Filter/Sort

### Files: `lua/poste/sql/buffer_search.lua`, `lua/poste/sql/buffer_nav.lua`, `lua/poste/sql/dataset.lua`

### Current problem

- Sort: mutates `res.rows`, deep-copies full dataset, re-formats all rows
- Filter: deep-copies original data, builds new rows, re-formats all rows
- Search: scans all rows/cols, `apply_search_highlights()` iterates all matches

### Design: Row index views

```lua
-- dataset.lua tab additions
tab.rows_source = nil          -- reference to source rows (immutable)
tab.filtered_indices = nil     -- { 1, 5, 17, ... } row indices after filter
tab.sort = nil                 -- existing { col, ascending }
tab.view_indices = nil         -- final ordered row indices into rows_source
tab.row_number_mode = "source" -- "source" for normal pages, "view" for filtered pages

-- Helper:
local function compute_view_indices(tab)
  local src = tab.rows_source
  if not src then return end
  local indices = {}
  if tab.filtered_indices then
    for i, idx in ipairs(tab.filtered_indices) do indices[i] = idx end
  else
    for i = 1, #src do indices[i] = i end
  end

  if tab.sort then
    local col = tab.sort.col
    local ascending = tab.sort.ascending
    table.sort(indices, function(a, b)
      local va, vb = src[a][col], src[b][col]
      -- same comparison logic as current implementation
    end)
  end

  tab.view_indices = indices
end
```

### Sort changes

```lua
function M.sort_by_current_col()
  -- ... existing col + ascending logic ...

  if is_reset then
    tab.sort = nil
  else
    tab.sort = { col = col, ascending = ascending }
  end

  tab.rows_source = tab.rows_source or res.rows
  compute_view_indices(tab)
  -- Re-render current page from view_indices
  tab.layout = tab.layout or require("poste.sql.format").plan_resultset_layout(data)
  local lines, meta = require("poste.sql.format").render_view(
    tab.layout, tab.view_indices, tab.page, tab.page_size,
    { row_number_mode = tab.row_number_mode or "source" }
  )
  require("poste.sql.buffer").render_dataset(lines, meta, {
    keep_tabs = true,
    tab_index = D.active_tab_idx,
    layout = tab.layout,
    view_indices = tab.view_indices,
  })
end
```

Note: no `vim.deepcopy(data)`. No mutation of `res.rows`. Only index manipulation.

### Filter changes

```lua
function M.filter_by_current_cell()
  -- ... existing col/value extraction ...

  tab.rows_source = tab.rows_source or res.rows
  tab.row_number_mode = "view"

  local indices = {}
  for i, row in ipairs(tab.rows_source) do
    if row[col] == filter_val then
      indices[#indices + 1] = i
    end
  end
  tab.filtered_indices = indices
  compute_view_indices(tab)

  -- Render from layout + view_indices
  tab.layout = tab.layout or require("poste.sql.format").plan_resultset_layout(data)
  local lines, meta = require("poste.sql.format").render_view(
    tab.layout, tab.view_indices, tab.page, tab.page_size,
    { row_number_mode = "view" }
  )
  require("poste.sql.buffer").render_dataset(lines, meta, {
    data = data,
    keep_tabs = true,
    tab_index = D.active_tab_idx,
    layout = tab.layout,
    view_indices = tab.view_indices,
  })
end
```

Note: no `vim.deepcopy(data)`. Filter becomes O(n_rows) scan of original rows + O(page_size) render.

Clear filter/search must reset `filtered_indices`, `view_indices`, and `row_number_mode` before rendering the unfiltered view. Do not keep stale filtered indices after `<leader>cr`.

### Search: page-indexed matches

```lua
-- During search_query:
tab.search_matches_by_page = {}
local all_indices = tab.view_indices
if not all_indices then
  all_indices = {}
  for i = 1, #tab.rows_source do all_indices[i] = i end
end
local total_count = 0
for view_pos, src_idx in ipairs(all_indices) do
  local row = tab.rows_source[src_idx]
  local page = math.ceil(view_pos / tab.page_size)
  if not tab.search_matches_by_page[page] then
    tab.search_matches_by_page[page] = {}
  end
  for ci, val in ipairs(row) do
    -- ... match test ...
    if match then
      total_count = total_count + 1
      tab.search_matches_by_page[page][#tab.search_matches_by_page[page] + 1] = {
        row = view_pos,
        source_row = src_idx,
        col = ci,
        global_match_idx = total_count,
      }
    end
  end
end
tab.search_total_matches = total_count
tab.search_idx = total_count > 0 and 1 or 0  -- global index across all pages

-- apply_search_highlights(): only iterate tab.search_matches_by_page[current_page]
-- jump_to_search_match(): cross-page jumps trigger page change + refresh
```

Performance: `apply_search_highlights()` goes from O(total_matches) to O(page_matches). For a 100K row table where 50% rows match, this is 50K → 25 (with page_size=50).

Search must run over the active view, not always over raw `res.rows`, otherwise search results after filtering/sorting will jump to the wrong visible row.

---

## Step 4 (P4): Tighten Highlight Behavior

### Files: `lua/poste/sql/highlights.lua`

### Current

`apply_dataset_highlights()` iterates all `lines` passed to it. With pagination enabled, it only sees the sliced page (already efficient). Without pagination, it sees all rows.

### Design

- No change to paginated path (already O(page_size))
- Pagination-disabled: if > 1000 rows, defer non-critical highlights (row number extmarks) via `vim.schedule()`
- Avoid full namespace rebuild on cell movement: `highlight_cell()` already only clears `ns_cell` and sets one extmark. No change needed here.
- Row-number column: keep extmark-based highlighting for now (per decision). No change.

---

## Implementation Order

| Order | What | Files | Verification |
|-------|------|-------|-------------|
| 0a | Benchmark harness (driver + runner + compare) | `tests/bench_dataset_driver.lua`, `tests/bench_dataset.lua`, `tests/bench_run.sh` | Run on main, get baseline JSON |
| 0b | P0 autocmd leak fix | `lua/poste/sql/buffer.lua` | `render_twice_repeated` action shows same header_float_calls before/after |
| 1 | P1: split formatting | `lua/poste/sql/format.lua`, `lua/poste/sql/buffer.lua`, `lua/poste/sql/dataset.lua` | `page_next`/`page_prev` 10x+ faster; column widths stable |
| 2 | P2: reuse header float + cache cell ranges | `lua/poste/sql/buffer_nav.lua`, `lua/poste/sql/highlights.lua` | `move_right_50` avoids float recreation and skips unchanged header writes; find_cell_ranges parses once |
| 3 | P3: view-based sort/filter/search | `lua/poste/sql/buffer_nav.lua`, `lua/poste/sql/buffer_search.lua`, `lua/poste/sql/dataset.lua` | `sort_current_col` no deepcopy; `apply_search_highlights` O(page_matches) |
| 4 | P4: highlight tightening | `lua/poste/sql/highlights.lua` | Validate with assertions, manual visual check |

---

## Validation

```bash
# Unit tests
tests/run.sh

# Rust tests
cargo test

# Benchmark comparison
./tests/bench_run.sh opt_results.json
nvim --headless \
  -c "set rtp+=." \
  -c "lua require('tests.bench_dataset').compare('main_results.json', 'opt_results.json')" \
  -c "qa"
```

**Manual checks** (on non-headless Neovim):
- Large result initial render with pagination enabled
- Toggle pagination to all rows and back
- `H`, `L`, `<leader>hh`, `<leader>ll`
- Long horizontal movement with `h`, `l`, `0`, `$`
- `s` sort cycle: ascending, descending, reset
- `<leader>/`, `n`, `N`, `<leader>ce`, `<leader>cr`
- Tab switching across multi-statement results
- Header float alignment after horizontal scroll, resize, and repeated query execution

Before starting implementation, capture a baseline JSON on the current branch and keep it outside files touched by the refactor. The benchmark is only useful if the output schema remains stable across all optimization steps.
