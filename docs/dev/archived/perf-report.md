# Dataset Buffer Performance Review

Scope: Neovim-side dataset buffer code under `lua/poste/sql/`, with special attention to large result sets, horizontal/vertical navigation, pagination, search, filtering, sorting, highlights, and the existing `perf-plan.md`.

Evidence level: code-path review only. No runtime profile was collected in this pass.

## Findings

### P0: `WinScrolled` autocmds accumulate on every render

Location: `lua/poste/sql/buffer.lua:317`, `lua/poste/sql/buffer.lua:327`

`render_dataset()` deletes `D.resize_autocmd_id` before creating a new `WinResized` autocmd, but it does not delete the previous `D.scroll_autocmd_id` before creating a new `WinScrolled` autocmd. Re-running queries or re-rendering tabs can accumulate multiple scroll callbacks for the same dataset buffer. Every scroll then calls `buffer_nav.update_header_float()` multiple times.

Evidence: direct code-path inference. `D.scroll_autocmd_id` is only deleted in `close()`, not before replacement during render.

Behavior risk: low. Deleting the previous scroll autocmd before registering a new one should preserve UI behavior while removing duplicate work.

Recommendation: in `render_dataset()`, mirror the resize cleanup for `D.scroll_autocmd_id`. Prefer an augroup keyed to the dataset buffer if the autocmd lifecycle grows more complex.

### P0: initial render still formats and stores the full dataset before pagination

Location: `lua/poste/sql/format.lua:331`, `lua/poste/sql/format.lua:336`, `lua/poste/sql/format.lua:371`, `lua/poste/sql/buffer.lua:249`, `lua/poste/sql/buffer.lua:252`

`format_resultset()` calculates widths, numeric-column flags, and rendered lines across all rows before `render_dataset()` slices the visible page. For a 100K-row result, pagination reduces only the final buffer write, not the expensive format phase or full `padded_full` storage.

Evidence: `format_resultset()` iterates all rows for width detection, numeric detection, and line construction; `render_dataset()` deep-copies the full padded line list before slicing.

Behavior risk: medium. Current rendering derives column widths from the full result set, so page-only formatting can make column widths change between pages. If stable widths are part of the current UX, keep a width cache computed from a bounded sample or compute full widths once and render pages lazily from that metadata.

Recommendation: split formatting into reusable phases: column metadata/width planning, page row rendering, and footer/header rendering. The benchmark should measure both full-width planning and visible-page rendering separately.

### P1: header float rebuild is too expensive for horizontal movement and scroll

Location: `lua/poste/sql/buffer_nav.lua:68`, `lua/poste/sql/buffer_nav.lua:84`, `lua/poste/sql/dataset.lua:49`, `lua/poste/sql/buffer.lua:327`

`update_header_float()` closes the current header float, creates a new buffer, writes one line, and opens a new window every time it runs. `close_header_float()` also scans every tabpage window looking for relative windows anchored to the dataset window. Horizontal movement calls this directly, and `WinScrolled` calls it during scroll.

Evidence: direct code-path inference from `move_cell()` for horizontal movement and autocmd callbacks.

Behavior risk: low to medium. Reusing the existing float window and buffer should preserve appearance, but the implementation must handle invalid windows, changed width, changed dataset window, and closed buffers.

Recommendation: reuse `D.float_buf` and `D.float_win` when valid. Only recreate on invalid window/buffer or width/anchor changes. Cache the last rendered `{ leftcol, win_width, header_text }` and skip writes when unchanged.

### P1: search highlight replay scans all matches on every page/search jump

Location: `lua/poste/sql/buffer_search.lua:10`, `lua/poste/sql/buffer_search.lua:21`, `lua/poste/sql/buffer_search.lua:62`, `lua/poste/sql/buffer_search.lua:73`

`apply_search_highlights()` clears the search namespace and iterates over every match, even when pagination means only one page can be visible. With a common search term in a large table, `n`/`N`, page refresh, and tab switch pay O(total_matches) just to rediscover visible matches.

Evidence: direct code-path inference. The loop checks `match_page == page` for every match.

Behavior risk: low. The visible highlights should remain identical if matches are indexed by page.

Recommendation: store `tab.search_matches_by_page[page]` or store start/end offsets into a sorted match list. `apply_search_highlights()` should only iterate visible-page matches.

### P1: sort and filter duplicate large datasets and reformat all rows

Location: `lua/poste/sql/buffer_nav.lua:438`, `lua/poste/sql/buffer_nav.lua:446`, `lua/poste/sql/buffer_nav.lua:463`, `lua/poste/sql/buffer_search.lua:179`, `lua/poste/sql/buffer_search.lua:184`, `lua/poste/sql/buffer_search.lua:193`, `lua/poste/sql/buffer_search.lua:207`

Sorting mutates `res.rows`, then deep-copies the full dataset before formatting. Filtering deep-copies the original data, builds filtered rows, and formats the full filtered result. Clearing a filter deep-copies and formats the full original data again.

Evidence: direct code-path inference.

Behavior risk: medium. Sort/filter semantics and reset behavior must remain unchanged.

Recommendation: separate immutable source rows from view rows. Store row index lists for sort/filter/search where possible, and render the current page from the active row index list. Avoid deep-copying the whole response unless mutation is required.

### P2: cell navigation repeats line parsing and display-width work

Location: `lua/poste/sql/buffer_nav.lua:168`, `lua/poste/sql/buffer_nav.lua:169`, `lua/poste/sql/buffer_nav.lua:171`, `lua/poste/sql/buffer_nav.lua:186`, `lua/poste/sql/highlights.lua:317`

`position_cursor()` reads the row line, finds the target cell range, computes display width up to the target, then finds the last-column range and computes display width again. `highlight_cell()` can reuse the passed line, so the extra buffer read is already avoided for movement calls, but the current row is still parsed multiple times.

Evidence: direct code-path inference.

Behavior risk: low if the cursor placement and `leftcol` behavior are preserved.

Recommendation: cache separator positions by rendered line or by `{ tab, page, row }`, and return both target range and last-column range from a single parsed representation. Be careful: the current `find_cell_range()` cache uses Lua string content equality, so new strings from `nvim_buf_get_lines()` do not automatically break the cache.

### P2: dataset highlights are page-bounded only while pagination stays enabled

Location: `lua/poste/sql/buffer.lua:252`, `lua/poste/sql/buffer.lua:281`, `lua/poste/sql/buffer_page.lua:45`, `lua/poste/sql/buffer_page.lua:59`, `lua/poste/sql/highlights.lua:185`, `lua/poste/sql/highlights.lua:197`

`apply_dataset_highlights()` scans `lines` and data rows passed to it. During normal paginated render, it receives the sliced page, so it is not scanning all 100K rows. When pagination is disabled, or when `tab.padded = tab.padded_full`, it scans every displayed row.

Evidence: direct code-path inference.

Behavior risk: medium. Removing row-number extmarks changes the specific `PosteSqlRowNum` styling unless syntax is enhanced to distinguish the row-number column from normal numeric cells.

Recommendation: keep border/header highlighting cheap, and either retain row-number extmarks only for visible lines or add syntax that accurately covers the row-number column. Do not assume `syntax/poste_dataset.vim` fully replaces row-number highlighting today.

### P3: benchmark targets are coupled to volatile function names

Location: `perf-plan.md:29`, `perf-plan.md:30`, `perf-plan.md:43`

The plan measures functions like `format.format_resultset()`, `highlights.apply_dataset_highlights()`, and `update_header_float()` directly. Those are exactly the functions likely to be split, renamed, or removed by the proposed refactor. A function-level benchmark can become unusable after optimization.

Evidence: plan review.

Behavior risk: none for product code; high risk for the benchmark's usefulness.

Recommendation: benchmark stable user actions first, and collect function-level phase timings as optional diagnostics. Stable actions include initial render, next/prev page, first/last page, horizontal move, vertical move, sort current column, search query, next search match, filter by current cell, and tab switch. The harness can call public keymaps or a small stable test driver API rather than private implementation functions.

## Notes On `perf-plan.md`

### What the plan gets right

- It correctly identifies full formatting before pagination as the largest likely cost.
- It correctly calls out header float recreation as a hot horizontal movement cost.
- It correctly identifies `vim.deepcopy()` in render/sort/filter as a large allocation source.
- It correctly treats search and filtering as full-table operations that need explicit measurement.
- It correctly includes both pagination-enabled and pagination-disabled baselines.

### Corrections and missing considerations

1. `find_cell_range()` cache reasoning is partly wrong.

`perf-plan.md` says `nvim_buf_get_lines()` returns a newly allocated string and therefore `==` cache comparison fails. In Lua, string equality is by content. The code comment in `highlights.lua:265` explicitly relies on this. The remaining issue is not that the cache cannot hit; it is that only one line is cached, and navigation still asks for target and last-column ranges separately.

2. Page-level formatting may change visible layout.

Current widths come from all rows via `calc_column_widths()`. Formatting only the current page can make columns resize when paging, which changes horizontal scroll behavior and header alignment. If the UX should stay stable, use a separate width-planning strategy: full scan once, bounded sample, server-provided metadata, or cached incremental width metadata.

3. `apply_dataset_highlights()` is not always a full-dataset scan.

With pagination enabled, `render_dataset()` slices `padded` before calling `apply_dataset_highlights()`. It becomes a full displayed-buffer scan when pagination is disabled. The report/benchmark should distinguish initial formatting cost from visible-page highlight cost.

4. Syntax does not fully replace row-number extmarks.

`syntax/poste_dataset.vim` covers separators, borders, NULL, numbers, booleans, and meta lines. It does not specifically style the row-number column as `PosteSqlRowNum`. Removing row-number extmarks without replacing that behavior is a small UI change.

5. The benchmark needs stable action-level metrics.

Use stable user actions as the primary comparison surface. Function-level metrics should be optional and discovered dynamically. Example structure:

```text
action.render_initial
action.page_next
action.page_last
action.move_right_50
action.move_down_100
action.sort_current_col
action.search_query
action.search_next
action.filter_current_cell
action.tab_switch

phase.format
phase.render_buffer
phase.highlights
phase.header_update
phase.search_index
```

After refactor, `phase.*` may map to new internals, but `action.*` remains comparable.

6. The benchmark should assert behavior, not only time.

For each action, record invariants: active cell, page number, row count shown, `leftcol`, buffer line count, winbar text, header text, search match count, and whether the dataset window/buffer remain valid. This prevents optimizing away required UI behavior.

7. The benchmark should report memory and allocation pressure when possible.

At minimum record `collectgarbage("count")` before/after each scenario and force a GC between cases. Time-only metrics will miss the cost of `padded_full`, `meta_full`, `original_data`, and repeated deep copies.

8. The benchmark should include repeated-render scenarios.

Because `WinScrolled` autocmds currently accumulate, a single render baseline will miss the leak. Include repeated render of the same dataset, then trigger scroll/header update and count elapsed time or registered autocmd behavior.

9. The plan should include a compatibility layer for tests.

If the refactor splits `format_resultset()` or replaces `update_header_float()`, tests and benchmarks should use a stable test facade, for example `tests/bench_dataset_driver.lua`, that exposes user-level actions. The facade can adapt to internal function changes while preserving benchmark output schema.

## Suggested Revised Plan

### P0: Fix lifecycle leaks and build stable benchmark

- Delete old `D.scroll_autocmd_id` before creating a new `WinScrolled` autocmd.
- Add `tests/bench_dataset.lua` with action-level metrics as the stable contract.
- Include repeated render, pagination on/off, and memory before/after.
- Add correctness invariants to the benchmark output.

### P1: Split formatting into planning and page rendering

- Extract width/numeric planning from visible row rendering.
- Keep stable column widths unless the user explicitly accepts page-local widths.
- Render only current-page lines for normal paginated views.
- Keep enough metadata to support pagination, cursor placement, header alignment, search, sort, and filter.

### P2: Reduce repeated UI work in hot navigation paths

- Reuse the header float window/buffer.
- Skip header updates when `{ leftcol, width, header }` is unchanged.
- Cache parsed cell ranges for visible rows or current row.
- Update only current/previous cell highlights.

### P3: Make search/filter/sort view-based

- Keep source rows immutable.
- Represent sorted/filtered results as row indexes or views.
- Build search match indexes by page.
- Render the current page from the active view.

### P4: Tighten highlight behavior

- Keep border/header highlights small.
- Make row-number highlighting visible-range only or replace it with equivalent syntax.
- Avoid full namespace rebuilds when only the current cell/search match changes.

## Validation Recommendations

Run after changes:

```bash
tests/run.sh
cargo test
```

Manual checks:

- Large result initial render with pagination enabled.
- Toggle pagination to all rows and back.
- `H`, `L`, `<leader>hh`, `<leader>ll`.
- Long horizontal movement with `h`, `l`, `0`, `$`.
- `s` sort cycle: ascending, descending, reset.
- `<leader>/`, `n`, `N`, `<leader>ce`, `<leader>cr`.
- Tab switching across multi-statement results.
- Header float alignment after horizontal scroll, resize, and repeated query execution.
