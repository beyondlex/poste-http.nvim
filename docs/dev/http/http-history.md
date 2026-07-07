# HTTP Request History (PosteHttpHistory)

> Session-level HTTP request history with management UI.

## Overview

PosteHttpHistory provides a window-sized floating popup with a request list on the left (reverse chronological) and selected request details on the right. History exists only for the current Neovim session — cleared on close.

## Data Model

### Storage

History is stored in memory (`state.http_history`), not persisted to disk. Automatically cleared when Neovim closes.

### Session State (`state.lua`)

```lua
M.http_history = {}               -- entry[] (newest first)
M.http_history_max = 100          -- max entries
M.http_history_id_counter = 0     -- auto-increment ID
```

### Entry Structure

| Field | Type | Description |
|-------|------|-------------|
| `id` | number | Auto-increment unique ID |
| `name` | string | Request name (`###` content) or `"Request #N"` |
| `time` | number | `os.time()` |
| `source_file` | string | Source `.http` file path |
| `response` | table | Full response JSON (Rust output structure) |
| `assertion_results` | table\|nil | `{ passed, failed, total, tests, logs }` |
| `script_logs` | table\|nil | `{ "log line", ... }` |

Each entry's `response.body` is truncated at 100KB when serialized.

## UI Layout

```
┌─────────────── " Poste HTTP History " ──────────────────────┐
│ ┌─ Left List (30-40 col) ─┐ ┌─ Right Detail (remaining) ──┐ │
│ │ Get Profile   23:32     │ │ [Body[H] | Rqst[R] | Verb[L]│ │
│ │─────────────────────────│ │  | Asserts[A]]  (winbar)     │ │
│ │ Request 3     23:30     │ │──────────────────────────────│ │
│ │ Request 2     22:45     │ │  (rendered via format.lua)   │ │
│ │ Request 1     21:34     │ │                              │ │
│ │ Login         20:33     │ │                              │ │
│ └─────────────────────────┘ └──────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

### Left List Buffer

- `j`/`k` navigation, real-time right detail update
- `<CR>`: Jump cursor to right detail buffer
- `dd`: Delete entry
- `q`: Close popup

### Right Detail Buffer

- Winbar tab switching (same as response buffer):
  - `H` — Body
  - `R` — Rqst (request payload)
  - `L` — Verb (verbose)
  - `A` — Asserts
  - `S` — Script
  - `<Tab>` / `<S-Tab>` — Cycle tabs
- jq filter: `<leader>j` / `<leader>jc` / `<leader>jr` / `<leader>jo`
- `q`: Close popup

## Implementation Files

### New Files

| File | Lines | Role |
|------|-------|------|
| `lua/poste/http/history.lua` | ~400 | Main module: UI, memory management, navigation |

### Modified Files

| File | Change |
|------|--------|
| `lua/poste/state.lua` | +4 fields + keymap section |
| `lua/poste/http/run.lua` | +1 call to `history.add_entry()` |
| `lua/poste/init.lua` | +1 command `:PosteHttpHistory` |

## Key Design Decisions

1. **Self-contained module** — history.lua manages its own floating window + two buffers. Doesn't modify buffer.lua / view.lua / format.lua.
2. **Detail rendering independent of `state.last_response`** — Calls `format.format_body(entry.response)` with entry's own response data. Tab state local to history detail buffer.
3. **jq support** — Self-contained in `entry._jq`, doesn't pollute `state._json`.
4. **No persistence** — Pure in-memory storage, no cross-project interference.
5. **Body truncation** — `response.body` truncated at 100KB to control memory.

## Edge Cases

- **Empty history**: Shows "(no history)", `q` closes
- **Delete last entry**: List clears, detail shows "(no history)"
- **Same request re-executed**: Two entries kept (different id/time)
- **Batch execution**: Each response gets its own entry
- **Source buffer deleted**: Entry still valid (full response stored)
- **Large response body**: Full in memory, truncated only on serialization

## User Configuration

```lua
require("poste").setup({
  http_history_max = 100,
  keymaps = {
    http_history = {
      close = "q",
      delete_entry = "dd",
      focus_detail = "<CR>",
    },
  },
})
```