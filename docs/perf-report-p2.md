# P2: Reduce Repeated Work in Hot Navigation Paths

## Change Summary

### 2a: Header Float Reuse (`buffer_nav.lua` + `dataset.lua`)

`update_header_float()` previously closed + recreated float buf/win on every call. Now:
- Early return when `leftcol`, `win_width`, `header_text` unchanged — **zero cost** when nothing moved
- Reuse existing `float_buf`/`float_win` (update content in-place, resize win) on subsequent calls
- Fall through to create fresh only on first call or after manual close

### 2b + 2c: find_cell_ranges (`highlights.lua` + `buffer_nav.lua`)

`position_cursor()` did two `find_cell_range()` calls (two separator scans, two `strdisplaywidth` lookups). Now one `find_cell_ranges()` call returns both target and last-col ranges from a single scan.

## Key Metrics

| Scenario | Action | Baseline | Optimized | Speedup |
|---|---|---|---|---|
| 50kx5_paged | move_right_50 | 13.98ms | 2.26ms | **6.18x** |
| 50kx5_paged | move_to_first_col | 0.35ms | 0.05ms | **7.79x** |
| 50kx5_paged | move_to_last_col | 0.31ms | 0.05ms | **6.67x** |
| 10kx10_paged | move_to_first_col | 0.28ms | 0.04ms | **6.37x** |
| 10kx10_paged | move_to_last_col | 0.30ms | 0.05ms | **5.43x** |
| 10kx10_paged | move_right_50 | 12.53ms | 2.81ms | **4.46x** |
| 10kx5_paged | move_to_first_col | 0.30ms | 0.05ms | **6.43x** |
| 10kx5_paged | move_to_last_col | 0.28ms | 0.04ms | **6.68x** |
| 10kx5_paged | sort_current_col | 0.36ms | 0.09ms | **4.01x** |
| 50kx5_paged | sort_current_col | 0.40ms | 0.07ms | **5.80x** |
| 50kx5_paged | filter_current_cell | 0.45ms | 0.12ms | **3.88x** |

## Cumulative P1+P2 Gains (vs main branch baseline)

| Scenario | Action | Baseline | Optimized | Speedup |
|---|---|---|---|---|
| 50kx5_all | render_initial | 2453.68ms | 948.30ms | **2.59x** |
| 50kx5_all | render_twice_repeated | 4493.75ms | 1358.58ms | **3.31x** |
| 50kx5_paged | render_twice_repeated | 4002.52ms | 1456.54ms | **2.75x** |
| 50kx5_paged | move_right_50 | 13.98ms | 2.26ms | **6.18x** |
| 10kx10_all | render_twice_repeated | 1307.21ms | 575.98ms | **2.27x** |
| 10kx10_paged | render_twice_repeated | 1248.92ms | 592.28ms | **2.11x** |

## Memory

50kx5_all render_initial: **-12.73MB** (no padded_full deepcopy, same as P1).

## Files Changed

| File | Change |
|---|---|
| `lua/poste/sql/dataset.lua` | +`_float_cache_leftcol/width/header`; reset in `close_header_float` |
| `lua/poste/sql/buffer_nav.lua` | Header float reuse (early return + buf/win reuse); `position_cursor` single `find_cell_ranges` call |
| `lua/poste/sql/highlights.lua` | +`find_cell_ranges(line, target, last)` returns `{target, last?}` from one sep scan |
| `tests/bench_dataset_driver.lua` | Fix phase highlights: write lines to buffer before applying (layout path buffer shorter than full format) |

## Verification

- All 9 plenary test suites: green
- All 277 Rust tests: green
- Header float calls: identical counts (250 per scenario for move_right_50)
- Assertions: all passed
- Behavioral note: `find_cell_ranges` inherits the same one-entry sep cache as `find_cell_range`
