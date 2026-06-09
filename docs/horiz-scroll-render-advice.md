Now I have a thorough understanding of the codebase and the design doc. Let me provide a detailed review of `horiz-scroll-render.md`, organized per the SKILL.md's review format.

---

## Review of `docs/horiz-scroll-render.md`

### 1. Findings: Gaps and Issues (ordered by severity)

#### 🔴 P0 — `_full_lines` doesn't exist in the layout-aware path

The doc says `tab._full_lines` is to be "added in `dataset.lua`" and implies all rendered rows are already stored. But the code has **two rendering paths**:

- **Layout-aware path** (`buffer.lua:266-281`): Calls `apply_rendered_page(tab, lines, meta)`. This path does NOT store `tab.padded_full` — it only stores `tab.padded` (current page, already header-stripped and padded). The "full lines" to cache here must be the **page's data rows at full width**, which `tab.padded` already is. But the doc's naming `_full_lines` is ambiguous: does "full" mean "all rows in the dataset" or "full-width (untruncated)"? This needs to be unambiguous.

- **Legacy path** (`buffer.lua:283-380`): Stores `tab.padded_full` (all pages, full dataset). For paginated views, `tab.padded` is a page slice of `padded_full`.

**Fix for the doc**: Define `tab._full_width_lines` explicitly: a Lua table of the **currently visible page's data rows at full rendered width** (NOT all dataset rows). For the layout-aware path, this is exactly `tab.padded`'s data slice. For the legacy path, it's the page slice from `padded_full`.

#### 🔴 P0 — `highlight_cell` reads from buffer in multiple call sites

The doc only mentions `position_cursor` reading from `tab._full_lines`. But `highlight_cell` at `highlights.lua:347` also reads the buffer:

```lua
line = line or vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
```

The following callers do NOT pass the `line` parameter and will break with truncated buffer lines:
- `buffer.lua:112` — tab switch highlight
- `buffer.lua:440` — initial render highlight  
- `buffer_nav.lua:195` — `goto_first_col`
- `buffer_nav.lua:205` — `goto_last_col`
- `buffer_nav.lua:214` — `goto_first_row`
- `buffer_nav.lua:223` — `goto_last_row`
- `buffer_nav.lua:548` — `toggle_row_numbers` (calls `highlight_cell` after render)
- `buffer_search.lua:64` — search match jump
- `buffer_search.lua:287` — `find_column` jump

Every one of these must either pass a pre-fetched full-width line or `highlight_cell` itself must read from `tab._full_width_lines`.

#### 🔴 P0 — Search highlights broken on truncated lines

`buffer_search.lua:26` reads the buffer line for `find_cell_range`:

```lua
local line = vim.api.nvim_buf_get_lines(D.dataset_buffer, buf_line - 1, buf_line, false)[1]
if line then
  local range = sql_highlights.find_cell_range(line, match.col + 1)
```

On truncated buffer lines, `│` separators for columns beyond the visible window don't exist. `find_cell_range` will return `nil` for those columns. **All search matches in off-screen columns silently disappear.** This needs to read from `_full_width_lines` instead.

#### 🟡 P1 — Extmark position adjustment completely unspecified

The doc says "Extmarks still need to work on truncated lines; adjust highlight positions accordingly" but provides **zero detail on HOW**. This is the hardest part of the implementation. The current `apply_dataset_highlights`:

1. Scans for `│` separators via `find_cell_range` → positions are **different** on truncated vs full lines
2. Scans for `(NULL)` patterns → works on truncated lines (NULL in visible portion is found)
3. Highlights row numbers via `find_cell_range(line, 1)` → row number column may be **off-screen**

Three approaches exist and the doc should pick one:

| Approach                                       | Description                                                                                                 | Trade-off                                                              |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| **A: Compute on full lines, offset positions** | Run `find_cell_range` on `_full_width_lines[row]`, subtract `truncation_byte_offset` from extmark positions | Correct but requires computing the byte offset of the truncation point |
| **B: Only highlight visible portion**          | Run highlight logic directly on truncated lines; accept that off-screen NULLs/row-nums get no extmarks      | Simpler, less correct, extmarks reapplied on every scroll anyway       |
| **C: Don't truncate — use conceal**            | Keep full lines in buffer, use `syntax` conceal or `extmark` conceal to hide off-screen chars               | Neovim still processes full line for syntax; might not help            |

**Recommendation**: Approach A. The byte offset of the truncation point can be found by scanning `│` separators in the full-width line until the display-width sum exceeds `leftcol`.

#### 🟡 P1 — Row number column WILL scroll off-screen

The doc states:

> row number columns are at the start of each line regardless of truncation

This is **incorrect**. When `leftcol > row_num_width + 2` (2 = `D.PADDING_SPACES`), the row number column is partially or fully scrolled off-screen. The truncation function must handle this — either:
- Always anchor row number column (don't truncate it), or
- Let it scroll off naturally (simpler, matches user expectation for wide tables)

The doc should explicitly choose one.

#### 🟡 P1 — `WinResized` not addressed for truncation

The doc mentions `WinScrolled` for truncation but not `WinResized`. When the window resizes horizontally, `win_width` changes → the truncation width changes → every data line needs re-truncation. The `WinResized` autocmd already exists at `buffer.lua:422` (for `update_header_float`). Truncation must also respond to it.

#### 🟡 P1 — No truncation algorithm specification

The doc says "byte positions derived from `│` separators" but doesn't specify the algorithm. The header already has a proven approach in `buffer_nav.lua:67-91` (`slice_header_to_win` + `build_header_index`):

1. Build a character index: `{byte_start, byte_end, display_start, display_end, is_sep}`
2. Walk the index, keeping characters whose `display_end > leftcol AND display_start < leftcol + win_width`
3. For partially-visible characters at edges, replace with spaces

For data lines, building a full index per line on every scroll would be expensive (50 cols × 100 rows = 5000 char entries). A cheaper alternative: find `│` positions, compute display width up to each `│`, find the first `│` to the left of `leftcol`, and byte-slice from there.

**The doc should specify the cheaper algorithm explicitly** rather than hand-waving at "byte positions derived from separators."

#### 🟢 P2 — Extmark reapply cost on every scroll

The doc says "Reapply extmarks for the visible slice" on every `WinScrolled`. The NULL highlight scan (`highlights.lua:222-232`) iterates ALL visible data lines doing `line:find("%(NULL%)")` — this is O(visible_rows × line_length) per scroll. For 100 visible rows, that's ~100 regex scans per h/l keystroke. Combined with the extmark `nvim_buf_set_extmark` calls, this could become a new bottleneck.

**Mitigation**: Either:
- Cache NULL positions per line (compute once on render, reuse on scroll), or
- Skip NULL highlight on scroll if only `leftcol` changed (NULL positions relative to line start are unchanged — only their byte offsets shift)

#### 🟢 P2 — No measurement baseline

The SKILL.md explicitly says: **"Do not use 'seems faster' as evidence."** The doc has no:
- Baseline measurement (ms per h/l keystroke at 50 columns)
- Target metric (<16ms? <8ms?)
- Measurement method (the `_trace` instrumentation in `buffer_nav.lua:11-31` already exists and works!)

The doc should include a section like:

```
## Baseline Metrics

Enable `state.sql._trace = true`, press `l` 10 times on a 50-column dataset.
Current measurements:
  move_cell:       X.XXXms
  position_cursor: X.XXXms
  highlight_cell:  X.XXXms
  update_header_float: X.XXXms
  total:           X.XXXms

Target: <16ms total per keystroke (60fps).
```

#### 🟢 P2 — Missing CJK/multi-byte handling

The `build_header_index` function carefully handles multi-byte UTF-8 and display width. The truncation algorithm needs the same care: a byte slice at position N may split a multi-byte character. The approach should be display-width-based, not byte-based, similar to `slice_header_to_win`.

#### 🟢 P2 — Three border lines are also long but not addressed

The border lines (`┌─┬─┐`, `├─┼─┤`, `└─┴─┘`) at `format.lua:407,418,432` are rendered at full table width. With 50 columns these are ~1000 chars each. The doc says "preserve header/border lines" — but they cause the same Neovim redraw cost, just for 3 lines instead of N data lines. Impact is negligible. The doc should note this explicitly as "intentionally not optimized."

#### 🟢 P2 — `buffer_page.refresh_page` not integrated into plan

The doc's implementation order doesn't mention `buffer_page.lua`. Both `refresh_page` paths (layout-aware at line 17-61, legacy at line 65-117) write full lines to the buffer via `nvim_buf_set_lines(buf, 0, -1, false, ...)`. After truncation is added, these must also write truncated lines (or call the shared truncation function).

#### 🟢 P3 — No alternative approaches considered

The SKILL.md says to "propose measured optimizations." The doc presents only one approach. Worth mentioning alternatives that were considered and rejected:

- **Virtual text**: Render each cell as `nvim_buf_set_extmark` virtual text. No long lines at all. Trade-off: cursor navigation becomes complex (virtual text isn't "real" text).
- **Conceal**: Use `:syn-conceal` to hide off-screen characters. Trade-off: Neovim still processes the full line for syntax highlighting.
- **`sidescroll` tuning**: Increase `sidescroll` to reduce redraw frequency. Trade-off: jumpier scrolling.

#### 🟢 P3 — Missing interaction with `toggle_row_numbers`

When `toggle_row_numbers` fires (`buffer_nav.lua:567-575`), it calls `apply_dataset_highlights(buf, tab.padded, tab.meta)` — passing `tab.padded` (full-width lines), not truncated lines. After truncation is implemented, `tab.padded` will still be full-width while the buffer holds truncated lines. The highlight positions computed from `tab.padded` won't match the buffer. This needs to either use `_full_width_lines` explicitly or have `apply_dataset_highlights` become aware of truncation.

---

### 2. Evidence

- **Trace data**: The `_trace` instrumentation at `buffer_nav.lua:11-31` confirms Lua processing is ~0.1ms. The lag is Neovim's redraw, verified by testing 5 vs 50 columns.
- **Code-path inference**: With 50 columns at ~20 chars/col, each data line is ~1000+ chars. Neovim's TUI output, syntax engine, and extmark renderer all process the full line per redraw. This is a known Neovim limitation (see `:help ui-screen-line`).
- **Suspected**: The exact contribution of extmarks vs syntax vs TUI output to the redraw cost is not isolated.

### 3. Behavior Risk Assessment

| Change                                 | Risk                                                                                                                                                        |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Buffer lines truncated                 | **Medium** — affects all modules that read buffer lines (`highlight_cell`, `apply_search_highlights`, `apply_dataset_highlights`). Must update all readers. |
| `_full_width_lines` added to tab state | **Low** — one extra table reference per tab. Memory is O(page_rows × line_length).                                                                          |
| Extmark positions shift                | **High risk of visual bugs** — wrong positions = highlights on wrong cells. Must get byte-offset math right.                                                |
| `WinScrolled` triggers buffer write    | **Medium** — potential for feedback loops if buffer write triggers another `WinScrolled`. Need a guard flag.                                                |
| Keymaps unchanged                      | **None** — no keymap changes.                                                                                                                               |
| Cursor behavior unchanged              | **None** — `position_cursor` logic unchanged (reads from full-width lines).                                                                                 |
| Header float                           | **None** — `update_header_float` already handles truncation.                                                                                                |

### 4. Recommendations (Smallest Viable Fixes)

1. **Add `tab._full_width_lines`**: In `apply_rendered_page`, after computing `padded`, extract `padded[data_start..data_end]` into `tab._full_width_lines`. This is the set of *currently visible* data rows at full rendered width. Don't store header/border/footer lines — they're static and can be read from `tab.padded`.

2. **Add `M.truncate_lines(tab, leftcol, win_width)` in a shared module** (probably `buffer_nav.lua` or a new `buffer_truncate.lua`):
   - Walk each line in `tab._full_width_lines`
   - Find `│` separator positions
   - Compute display width to each separator
   - Find the first separator whose right edge > `leftcol`
   - Byte-slice from `sep_pos - 1` (keep the `│`) to end
   - Left-pad if needed for partial first column

3. **Make all buffer readers go through `_full_width_lines`**: Change `highlight_cell` to always read from `tab._full_width_lines[row]`. Change `apply_search_highlights` to read from `_full_width_lines`.

4. **On `WinScrolled` + `WinResized`**: If `leftcol` changed, call `truncate_lines` + `nvim_buf_set_lines` for data region only + reapply highlights for visible slice.

### 5. Refactor Plan (staged per SKILL.md)

**P0: Low-risk containment**
- Add `tab._full_width_lines` storage in `dataset.lua`
- Populate it in `apply_rendered_page` and `buffer_page.refresh_page`
- Change `highlight_cell` to read from `tab._full_width_lines[row]` (remove buffer read fallback)
- Change `apply_search_highlights` to read from `tab._full_width_lines`
- Fix `_full_lines` terminology in the doc to `_full_width_lines` (clarify: "full width" not "full dataset")

**P1: Structure hot paths**
- Implement `M.truncate_to_visible(lines, leftcol, win_width)` — pure function, testable
- Wire `WinScrolled` to call truncate + buffer write
- Wire `WinResized` similarly
- Add guard flag to prevent `WinScrolled` → buffer write → `WinScrolled` loop
- Update `apply_dataset_highlights` to work on truncated lines (or compute from `_full_width_lines` with byte offsets)
- Add CJK-aware display-width handling in truncation

**P2: Deeper optimization**
- Cache NULL positions per line (compute once, offset on scroll)
- Profile extmark reapply cost; batch extmark calls if needed
- Consider lazy extmark application (only for visible cells within ±1 screen of viewport)
- Define cross-module contract: "always read line content from `tab._full_width_lines`, never from buffer for cell logic"

### 6. Validation Checklist

```bash
# Lua tests
tests/run.sh

# Rust tests  
cargo test
```

Manual checks:
- [ ] 50-column dataset: h/l scroll is smooth (no visible stutter)
- [ ] Cell highlight (blue bg) follows correct cell after h/l
- [ ] `0` / `$` jump to first/last column works
- [ ] `K` preview shows correct cell content
- [ ] `yy` / `yc` yank correct cell/column values
- [ ] Search (`<leader>/`) finds matches in all columns, including scrolled-off ones
- [ ] Search highlight appears on correct cell after scroll
- [ ] `n` / `N` cycles through search matches across columns
- [ ] Filter (`<leader>ce`) still works
- [ ] Sort (`s`) still produces correct header with indicator
- [ ] Tab switching preserves scroll position and cell highlight
- [ ] Pagination (`H`/`L`) writes truncated lines
- [ ] `zh` toggles cell highlight on/off correctly on truncated view
- [ ] `zN` toggles row numbers correctly
- [ ] Window resize re-truncates correctly
- [ ] Header float syncs with truncated content
- [ ] Winbar text unchanged
- [ ] `vim.g.poste_sql_debug` and `_trace` still work
- [ ] No `WinScrolled` → truncate → `WinScrolled` infinite loop

---

### Summary: What the doc needs

| #   | What to add/change                                                               | Where in doc                               |
| --- | -------------------------------------------------------------------------------- | ------------------------------------------ |
| 1   | Clarify `_full_lines` → `_full_width_lines` (page-scoped, not dataset-scoped)    | Solution → `dataset.lua`                   |
| 2   | Add "Two rendering paths" analysis (layout-aware vs legacy)                      | New section before Solution                |
| 3   | List ALL buffer readers that need updating (not just `position_cursor`)          | Solution → `highlights.lua`                |
| 4   | Add search highlight interaction (`apply_search_highlights` reads buffer)        | Solution → new subsection                  |
| 5   | Specify extmark adjustment algorithm (Approach A: compute on full lines, offset) | Solution → `highlights.lua`                |
| 6   | Fix incorrect claim about row number column always visible                       | Solution → `highlights.lua`                |
| 7   | Add truncation algorithm pseudocode                                              | Solution → new `truncate_lines` subsection |
| 8   | Add `WinResized` to the autocmd list                                             | Solution → `buffer_nav.lua`                |
| 9   | Add `buffer_page.refresh_page` to implementation order                           | Implementation Order                       |
| 10  | Add baseline metrics section with `_trace` usage                                 | New section before Solution                |
| 11  | Add CJK/multi-byte note to truncation algorithm                                  | Solution → `truncate_lines`                |
| 12  | Note border lines as intentionally not truncated                                 | Trade-offs                                 |
| 13  | Add alternative approaches considered                                            | New section after Solution                 |
| 14  | Add `toggle_row_numbers` interaction                                             | Solution → `highlights.lua`                |
| 15  | Add memory bound analysis                                                        | Trade-offs                                 |
| 16  | Add validation checklist                                                         | New section at end                         |
