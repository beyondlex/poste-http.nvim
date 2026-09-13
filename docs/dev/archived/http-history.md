# HTTP Request History (PosteHttpHistory)

> Session-level HTTP request history with management UI.

## Overview

PosteHttpHistory provides a window-sized floating popup with a request list on the left (reverse chronological) and selected request details on the right. History exists only for the current Neovim session — cleared on close.

## Data Model

### Storage

History is persisted to disk (`state.config.history_file`, default
`stdpath("data")/poste-http/history.json`) on every `add_entry`/`delete_entry`
and loaded back at startup via `history.load()`. Disable with
`persist_history = false`. Transient `_jq` fields are stripped before saving.

### Session State (`state.lua`)

```lua
M.http_history = {}               -- entry[] (newest first)
M.http_history_max = 100          -- max entries (config.http_history_max)
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
│ ┌─ Left List (46 col) ─────────┐ ┌─ Right Detail (rest) ──┐ │
│ │ POST    RegisterUser 200 12ms│ │ [Body[H] | Rqst[R] | L │ │
│ │ GET     GetUser      200 9ms │ │  | Asserts[A]] (winbar)│ │
│ │ GET     GetProfile  404 123ms│ │────────────────────────│ │
│ │ POST    Login       201 32ms │ │ (rendered via format)  │ │
│ └──────────────────────────────┘ └────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

### Left List Buffer

Each row is `METHOD  Name  Status  Elapsed  HH:MM`:

- `METHOD` — HTTP method (or `-` for failed requests), colored via the same
  `PosteMethodGET`/`PosteMethodPOST`/... highlight groups as the source buffer
- `Status` — `response.status` (or `-` for failed requests), colored via the
  same `PosteStatus2xx`/`PosteStatus3xx`/`PosteStatus4xx`/`PosteStatus5xx`
  groups as the verbose view
- `Elapsed` — `response.latency_ms` rendered as `12.00 ms` (or `1.20 s` above
  one second), highlighted with `PosteLatency`
- `HH:MM` — request time, gray (`Comment`)

Other behavior:

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
- **Large response body**: Body truncated to 100KB on entry, then persisted as-is

## User Configuration

```lua
require("poste-http").setup({
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
