# Stale Header Float After USE Execution

## Symptom

After executing a `USE dbname;` statement, the dataset panel (bottom split) still shows column headers from the previous `SELECT` result. The buffer content is correctly replaced with USE context info (`Context switched to: ...`, `Connection: ...`, `Dialect: ...`), but the floating header window persists on top.

## Timeline

1. Execute `SELECT * FROM warehouses;` → dataset panel renders correctly with a floating header window showing column names.
2. Execute `USE inventory;` → buffer content updates to USE context, but the old floating header remains visible.

## Debugging

### Step 1: Verify response from Rust executor

Added `vim.notify` with decoded response body. Confirmed Rust executor returns `{"type": "use", "database_name": "inventory", ...}` and Lua `format_dataset` correctly returns 6 lines of USE context.

### Step 2: Verify no stale callback overwrite

Added execution sequence counters (`exec_seq`) to check if a late SELECT callback overwrites the USE render after the fact. Logged every `on_stdout` callback with its seq number.

Findings:
```
START: exec_seq=1 current_seq=1    ← SELECT starts
CLEAR: float_win=nil               ← nothing to clear (first run)
CB: seq=1 exec_seq=1 skip=false    ← SELECT callback fires
FLOAT CREATED (type=resultset)     ← SELECT creates float window (handle 1005)
START: exec_seq=2 current_seq=2    ← USE starts
CLEAR: float_win=1005 valid=true   ← float window EXISTS
CB: seq=2 exec_seq=2 skip=false    ← USE callback fires
NO FLOAT (type=use)                ← USE does NOT create float (correct)
```

No stale callback overwrite. Both callbacks fire in the correct order with matching seq numbers. The callback suppression (`seq < exec_seq → skip`) never activated.

### Step 3: Identify float close failure

`close_header_float()` is called in `clear_panel()` (line ~750) with `float_win = 1005` actively showing. The function checks:

```lua
local had_float = float_win and vim.api.nvim_win_is_valid(float_win)
```

Despite `CLEAR: float_win=1005 valid=true` logging true, `close_header_float()` did NOT report closing the float. This means `nvim_win_is_valid(float_win)` returned `false` by the time it was evaluated within `close_header_float()` itself.

**Hypothesis**: `vim.notify` (called just before `close_header_float()` in `clear_panel`) may yield to the event loop, allowing the float window to be invalidated (e.g. by `WinScrolled` autocmd or window manager tidy-up) before the close call runs.

## Root Cause

**`float_win` as a cached window handle is unreliable.** Between setting the handle in `update_header_float()` and using it in `close_header_float()`, Neovim may invalidate the handle (e.g., window closed by another autocmd). The check `nvim_win_is_valid(float_win)` returns `false`, so `close_header_float()` does nothing — but the float window is still visible on screen.

## Fix

Instead of relying on the cached `float_win` variable, scan ALL windows in the current tabpage at close time:

```lua
local all_wins = vim.api.nvim_tabpage_list_wins(0)
for _, win in ipairs(all_wins) do
  if win ~= dataset_window then
    local ok, config = pcall(vim.api.nvim_win_get_config, win)
    if ok and config.relative == "win" and config.win == dataset_window then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end
```

This closes any float window anchored to `dataset_window`, regardless of `float_win` state.

## Affected Files

- `lua/poste/sql/buffer.lua` — `M.clear_panel()`, `close_header_float()`

## Prevention

When tracking Neovim object handles (window, buffer), never assume a cached handle remains valid. Always verify with a live scan when state cleanup is critical.