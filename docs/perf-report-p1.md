# P1: Split Formatting into Planning + Page Rendering

## Change Summary

Split `format_resultset()` (3-pass all-rows render) into two phases:

- `plan_resultset_layout(data)` — O(n_rows) width calc + numeric detection, no strings
- `render_page(layout, page, page_size)` — O(page_size) string render

Eliminated `padded_full` deepcopy. Page switches call `render_page` instead of slicing `padded_full`.

## Key Metrics

| Scenario | Action | Baseline | Optimized | Speedup |
|---|---|---|---|---|
| 50kx5_all | render_initial | 2453.7ms | 967.5ms | **2.54x** |
| 50kx5_paged | render_initial | 2198.5ms | 1289.3ms | **1.71x** |
| 50kx5_paged | render_twice_repeated | 4002.5ms | 1947.6ms | **2.06x** |
| 10kx10_all | render_initial | 730.6ms | 560.4ms | **1.30x** |
| 10kx10_paged | render_initial | 656.8ms | 480.1ms | **1.37x** |
| 10kx5_paged | render_initial | 411.7ms | 259.4ms | **1.59x** |

## Memory

50kx5_all render_initial: **-12.73MB** (no padded_full deepcopy).

## Files Changed

| File | Change |
|---|---|
| `lua/poste/sql/format.lua` | +`plan_resultset_layout`, `render_page`, `render_view`; `format_dataset` returns 3rd value `layout` |
| `lua/poste/sql/dataset.lua` | +`tab.layout`, `rows_source`, `view_indices`, `row_number_mode` |
| `lua/poste/sql/buffer.lua` | +`apply_rendered_page` helper; layout-aware path skips `padded_full`/`deepcopy` |
| `lua/poste/sql/buffer_page.lua` | `refresh_page` uses `render_page` from layout |
| `lua/poste/sql/init.lua` | Threads `layout` through to `render_dataset` |
| `lua/poste/sql/buffer_search.lua` | Pagination check recognizes `tab.layout` |
| `lua/poste/sql/buffer_nav.lua` | Pagination check recognizes `tab.layout` |
| `tests/bench_dataset_driver.lua` | `render_dataset` uses layout path |

## Verification

- All 9 plenary test suites: green (1 pre-existing fail in sql_completion_spec, unrelated)
- Winbar alignment: 10/10
- Assertions: all passed
- Header float calls: identical counts
