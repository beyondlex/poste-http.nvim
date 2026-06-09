# Horizontal Scroll Rendering Optimization

## Problem

H/L cursor movement in dataset buffer is visually laggy when rows have many columns (50+).

Trace shows Lua processing time is ~0.1ms per keypress — not the bottleneck. The lag is Neovim's screen redraw pipeline: with 50+padded columns (~1000+ chars/line), each horizontal redraw must process the entire long line (syntax, extmarks, TUI output), regardless of visible window width.

Verified: 5 columns scrolls fine; 50 columns stutters. Terminal emulator (Alacritty, Ghostty) and multiplexer (Zellij) don't cause it — Neovim CPU rises during scroll.

## Root Cause

`format.lua` renders every data row as a single padded string with all columns, written to the Neovim buffer. When Neovim redraws after a horizontal scroll (`leftcol` change), it processes the full line length for every visible row, not just the visible slice. With 50 columns this is 50× more work than 1 column per row.

Current flow:
```
format_resultset → padded_full (all columns, all rows)
  → buffer: nvim_buf_set_lines(full lines)
  → apply_dataset_highlights (extmarks on full lines)
  → h/l: position_cursor (read line from buffer, compute ranges, set cursor)
  → h/l: update_header_float (re-slice header text for float window)
  → WinScrolled autocmd → update_header_float again
```

## Solution: Buffer-Line Truncation

Keep full rendered rows in Lua (`tab._full_lines`), but only write the visible window slice to the Neovim buffer.

### Changes

#### `dataset.lua`
- Add `tab._full_lines = nil` — one-per-tab cache of fully-rendered data rows (without header/border lines, those are static)

#### `format.lua`
- No changes needed — `plan_resultset_layout` + `render_page`/`render_view` already produce correct output

#### `buffer.lua` — `apply_rendered_page()`
- After computing `padded` (full lines with header removed), save full data rows to `tab._full_lines`
- Create `visible` slice by truncating each data row: for each line in `padded`, keep columns from `leftcol` to `leftcol + win_width` (byte positions derived from `│` separators or using the existing `find_cell_ranges` approach)
- Write `visible` to buffer instead of `padded`
- Extmarks still need to work on truncated lines; adjust highlight positions accordingly

#### `buffer_nav.lua` — `position_cursor()`
- Read the full line from `tab._full_lines[row]` instead of `nvim_buf_get_lines(buf, ...)` — avoids buffer roundtrip and ensures `find_cell_ranges` sees the complete line
- Cursor column positioning unchanged (uses `find_cell_ranges` on the full line)

#### `buffer_nav.lua` — `update_header_float()`
- No change needed — already computes `slice_header_to_win` from `tab.header_text` + `index`
- But: when leftcol changes, `WinScrolled` autocmd fires, which calls this. If we also truncate buffer lines during scroll, we need to avoid double-triggering.

#### `buffer_nav.lua` — new `truncate_lines(leftcol, win_width)` or integrate into `update_header_float`
- On `WinScrolled` (or any leftcol change), recompute the visible slice from `tab._full_lines`
- `nvim_buf_set_lines` only for the data region (preserve header/border lines, footer)
- Reapply extmarks for the visible slice

#### `highlights.lua` — `apply_dataset_highlights()`
- Must work on truncated lines — row number columns are at the start of each line regardless of truncation, NULL values need scanning over the truncated portion
- Border and header lines are unaffected (always fully visible)

### Data Flow

```
format → render_page → lines (full width)
  → apply_rendered_page:
    → tab._full_lines = padded[data_start..data_end]
    → visible = truncate(padded, leftcol=0, win_width)
    → nvim_buf_set_lines(buf, 0, -1, visible)
    → apply_dataset_highlights(buf, visible, meta)
  → h/l:
    → tab._full_lines[row] (not buffer) for find_cell_ranges
    → nvim_win_set_cursor
    → if leftcol changed:
      → recompute visible slice from tab._full_lines
      → nvim_buf_set_lines(data_lines only)
      → reapply highlights on visible slice
```

### Implementation Order

1. Add `tab._full_lines` storage in `dataset.lua`
2. Modify `apply_rendered_page` in `buffer.lua` to save full lines and write truncated
3. Modify `position_cursor` in `buffer_nav.lua` to read from `tab._full_lines`
4. Add truncation on `WinScrolled` + `update_header_float`
5. Adjust `apply_dataset_highlights` for truncated lines

### Trade-offs

- **+** Buffer lines are short (~win_width chars), Neovim redraw is fast
- **+** No change to extmark semantics (they apply to visible slice)
- **+** `find_cell_ranges` still works correctly (uses full line from Lua table)
- **-** `WinScrolled` now triggers a partial buffer write
- **-** Slightly more Lua memory for `tab._full_lines` (one extra copy of data rows)
- **-** Extmark positions shift when truncation changes (need to be reapplied)
