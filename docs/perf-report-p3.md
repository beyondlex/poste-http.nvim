# P3: View-Based Sort/Filter/Search

## Change Summary

### Sort (`buffer_nav.lua`)
- No `vim.deepcopy(data)`. No mutation of `res.rows`.
- `tab.sort` → `compute_view_indices(tab)` → `render_view(layout, view_indices, ...)`
- Sort is index manipulation only: O(n_rows) for sort comparison, O(page_size) for render.

### Filter (`buffer_search.lua`)
- No `vim.deepcopy(data)`. No `original_data` backup.
- Scan `tab.rows_source`, build `tab.filtered_indices`, recompute `view_indices`.
- `row_number_mode = "view"` so filtered rows show 1-based position.
- Render via `render_view` from existing layout.

### Search (`buffer_search.lua`)
- `tab.search_matches_by_page[page]` — matches partitioned by page at build time.
- `apply_search_highlights()` iterates only current page matches: O(page_matches) vs O(total_matches).
- `jump_to_search_match()` uses `match.row` as view position (compatible with filtered/sorted views).
- Search scans `tab.view_indices` (or identity over `rows_source`) instead of `res.rows`.

### Page navigation (`buffer_page.lua`)
- `refresh_page()` now uses `#tab.view_indices` for `total_rows` when filter is active.
- `render_view` / `render_page` dispatch based on `tab.view_indices` presence.

## Key Metrics (vs main branch baseline)

| Scenario | Action | Baseline | Optimized | Speedup |
|---|---|---|---|---|
| 10kx5_paged | sort_current_col | 0.36ms | 0.06ms | **5.68x** |
| 10kx10_paged | sort_current_col | 0.35ms | 0.07ms | **5.19x** |
| 50kx5_paged | sort_current_col | 0.40ms | 0.09ms | **4.52x** |
| 10kx5_paged | filter_current_cell | 0.37ms | 0.09ms | **4.28x** |
| 50kx5_paged | filter_current_cell | 0.45ms | 0.11ms | **4.14x** |
| 100x5_paged | sort_current_col | 0.21ms | 0.04ms | **5.21x** |
| 10kx10_paged | filter_current_cell | 0.38ms | 0.11ms | **3.62x** |
| 1kx10_paged | filter_current_cell | 0.34ms | 0.09ms | **3.59x** |

## Cumulative P1+P2+P3 Gains (vs main branch baseline)

| Scenario | Action | Baseline | Optimized | Speedup |
|---|---|---|---|---|
| 10kx5_paged | render_initial | 411.72ms | 181.77ms | **2.27x** |
| 10kx10_all | render_initial | 730.62ms | 323.58ms | **2.26x** |
| 10kx5_paged | render_twice_repeated | 763.03ms | 255.31ms | **2.99x** |
| 10kx10_paged | render_twice_repeated | 1248.92ms | 497.50ms | **2.51x** |
| 50kx5_paged | render_twice_repeated | 4002.52ms | 1372.67ms | **2.92x** |
| 50kx5_paged | move_right_50 | 13.98ms | 2.06ms | **6.77x** |
| 10kx10_paged | move_to_first_col | 0.28ms | 0.04ms | **6.58x** |

## Memory

50kx5_all render_initial: **-12.73MB** (same as P1 — no padded_full deepcopy).

## Files Changed

| File | Change |
|---|---|
| `lua/poste/sql/dataset.lua` | +`compute_view_indices(tab)`; +`filtered_indices`, `search_matches_by_page`, `search_total_matches` |
| `lua/poste/sql/buffer_nav.lua` | `sort_by_current_col` → index-based (no deepcopy, no `original_rows`, uses `render_view`) |
| `lua/poste/sql/buffer_search.lua` | `filter_by_current_cell` → index scan + `render_view`; `clear_filter_search` resets `view_indices` + calls `refresh_page`; `show_search` builds `search_matches_by_page`; `apply_search_highlights` O(page_matches); `jump_to_search_match` uses view positions |
| `lua/poste/sql/buffer_page.lua` | `refresh_page` uses `#tab.view_indices` for `total_rows` when view is active |

## Verification

- All 9 plenary test suites: green (354 pass, 2 pending)
- All 277 Rust tests: green
- Header float calls: identical counts (250 per scenario for move_right_50)
- Assertions: all passed
- Legacy (non-layout) fallback path preserved for `sort`, `filter`, `clear_filter_search`, `refresh_page`
