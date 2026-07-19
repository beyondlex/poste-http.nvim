---
name: http
description: >
  HTTP request execution in Poste — parser, executor, curl integration, Lua UI,
  pre/post scripts, assertions, variable chaining, jq filtering.
  Use when working on HTTP features only (not SQL/Redis). Loads ZERO SQL files.
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
metadata:
  trigger: http|\.http|curl|postman|pre.script|post.script|assertion|jq|\{\{|variables\.|client\.(test|log|assert|global)|response\.body|import|env\.json
---

# HTTP — Agent Skill

Only load files listed below. Do NOT read `lua/poste/sql/`, `crates/poste-exec/src/sql_executor/`,
`crates/poste-core/src/sql_parser.rs`, or any `sql_context/` files unless the task explicitly
crosses protocols.

## File Index

### Shared (load always)

| File | Why |
|------|-----|
| `AGENTS.md` | Architecture, conventions, build |
| `lua/poste/state.lua` | Shared state object |
| `lua/poste/init.lua` | Entry point, setup(), dispatches by filetype |
| `lua/poste/buffer_setup.lua` | Shared keymap registration for source buffers |
| `lua/poste/indicators.lua` | Spinner/✓/✘ indicators, request block boundary detection |
| `lua/poste/select.lua` | Picker UI (telescope/fzf/mini.pick fallback) |
| `lua/poste/util.lua` | `clean_nil`, `find_file_upwards`, `ensure_job_data` |
| `lua/poste/help.lua` | Keymap help window (HTTP section) |
| `crates/poste-core/src/request.rs` | `Protocol` enum, `Request` struct |
| `crates/poste-exec/src/executor.rs` | `Executor::execute()` dispatch, HTTP curl executor |
| `crates/poste-exec/src/response.rs` | `Response` struct, JSON output shape |
| `crates/poste-exec/src/cookie_jar.rs` | Cookie persistence for HTTP |

### HTTP Lua (`lua/poste/http/`)

| File | Role |
|------|------|
| `run.lua` | Entry: `run_request()`, stdin pipe to Rust binary, response handling |
| `buffer.lua` | Response buffer/window management, winbar tabs, multi-response nav |
| `format.lua` | Result rendering: body, headers, verbose trace, request payload |
| `view.lua` | Tab switching: body / verbose / request / assertions / script logs |
| `json.lua` | jq filter: `apply_filter()`, `restore_original()`, key path discovery |
| `completion.lua` | Blink.cmp source for `{{var}}` completion in HTTP source buffers |
| `symbols.lua` | Symbol outline: `show_symbols()` for request blocks |
| `env.lua` | Environment switching: `set_env()`, `pick_env()`, winbar builder |
| `nav.lua` | Source buffer navigation: `jump_next/prev`, `goto_definition/references` |
| `curl.lua` | `paste_curl()`: parse clipboard curl command into `.http` format |
| `copy.lua` | `copy_to_clipboard()`: export request as curl command |
| `scripts.lua` | Pre-request script: extraction, sandboxed execution, var injection, MD5 |
| `assertions.lua` | Post-response assertions: extraction, sandbox, result formatting |
| `request_vars.lua` | Cross-request chaining: `{{Name.res.body.X}}`, form data, magic vars |
| `import.lua` | Import resolution: cross-file request execution |
| `var_collector.lua` | Collect `@var` definitions from source buffer |
| `item_builder.lua` | Build completion items for HTTP source buffers |
| `context_detector.lua` | Detect context at cursor (within `###` block, inside `{%`, etc.) |
| `data.lua` | Dynamic data definitions for the HTTP script API |
| `highlights.lua` | Syntax highlighting for HTTP result buffers |
| `cache.lua` | UI buffer index (line types, block bounds); semantic via describe |
| `describe.lua` | Single parse authority — `poste run --describe` |
| `session.lua` | Per-request session lifecycle (clears request-scoped state) |
| `boundary_indicator.lua` | `###` block boundary indicator line |
| `history.lua` | Request history: floating UI, persistence, navigation |

### HTTP Rust

| File | Role |
|------|------|
| `crates/poste-core/src/parser.rs` | `###` block parsing, var substitution, file-level vars |
| `crates/poste-cli/src/main.rs` | CLI: `run`, `fmt`, `context` subcommands, stdin read |

## Do NOT Read (HTTP tasks)

These files are SQL-only. Skip them entirely:

- `lua/poste/sql/` (any file)
- `crates/poste-core/src/sql_parser.rs`
- `crates/poste-core/src/sql_context/`
- `crates/poste-exec/src/sql_executor.rs`
- `crates/poste-exec/src/sql_connection.rs`
- `crates/poste-exec/src/sql_dialect.rs`
- `crates/poste-exec/src/sql_introspect.rs`
- `crates/poste-exec/src/sql_ddl.rs`

## HTTP-Specific Conventions

### Request Flow

```
source buffer → run.lua → extract pre-script → run in sandbox
  → inject @vars → process form data → extract assertions
  → pipe to `poste run --stdin` → Rust parser → curl subprocess
  → JSON response → Lua rendering (buffer.lua / format.lua / view.lua)
```

### Key State Fields

All in `state` (from `lua/poste/state.lua`):

| Field | Set by | Used by |
|-------|--------|---------|
| `last_response` | `run.lua` | `view.lua`, `format.lua`, `json.lua` |
| `last_assertion_results` | `run.lua` | `buffer.lua` (winbar), `view.lua` |
| `last_script_logs` | `run.lua` | `buffer.lua` (winbar) |
| `global_vars` | pre-scripts via `client.global.set()` | `run.lua` (injection before send) |
| `script_variables` | `run.lua` | assertion scripts |
| `current_view` | `view.lua` | `buffer.lua` (winbar) |
| `_json.query` | `json.lua` | `buffer.lua` (winbar label) |
| `http_history` | `history.lua` | `history.lua` (list rendering) |

### Variable Priority

```
request-level @vars (highest) > file-level @vars > env.json > magic ($timestamp, $uuid)
```

### Pre-script / Assertion Script API

Pre-script (`< {% ... %}`):
- `request.variables.set(name, value)` — inject `@var` into request
- `request.variables.get(name)` — read request-level var
- `client.global.set(name, value)` — persist across requests
- `client.log(msg)` — visible in Script tab

Assertion (`> {% ... %}`):
- `client.test(name, fn)` — register test
- `client.assert(cond, msg)` — assert condition
- `response.status`, `response.body`, `response.headers`

### jq Filter

- `json.lua:apply_filter(query)` — runs `jq -r` on `state.last_response.body`
- Cleared on each new request (`run.lua` clears `state._json`)
- Hold mode `[H]` means filter stays across view switches

### File Inclusion

`< path/to/file` in the body section replaces the line with file contents.
Supports `~` and relative paths (relative to `.http` file directory).
**Fails with a clear error if the file cannot be read** — no silent fallback.

## Common Pitfalls

### `nvim_buf_set_lines` + Highlight Mismatch

`nvim_buf_set_lines` rejects strings with embedded `\n`. Always `sanitize_lines()`
before passing. Highlight functions that use `#line` as `end_col` must receive the
*post-split* lines too, or `end_col` will be out of range.

### Pre-Rendered / Cached Buffers Must Mirror Normal Path

If a buffer is pre-rendered (e.g. multi-response `[`/`]` switching), it must apply
*everything* the normal `render_view` path does — not just treesitter but also
`apply_verbose_highlights`, `apply_request_highlights`, file link highlight,
JSON buffer setup, etc. Grep all callers.

### State Lifecycle

Every global/cached state write needs a corresponding clear. Common offenders:
`state.response_index`, `state._json`, `state.last_responses`, `request_vars._dep_chain`.
Write the cleanup first, not last.

### Lua ↔ Rust Data

Field names, types, and encoding must match exactly between Lua and Rust.
Watch for: NUL bytes (break argv), `\r\n` vs `\n`, `###` in embedded content
(creates false block boundaries), `--line` arg vs stdin format.

### Job handler branches

When adding logic to `handle_job_stdout` and `handle_job_exit`, update BOTH
chain (`_dep_chain`) and non-chain (single request) branches. Missing one
causes whack-a-mole bugs.

### `--line` Shift After Injection

`run.lua` injects `@var` lines after the `###` header during pre-script and global
var processing. This shifts all subsequent lines. The `--line` argument sent to the
Rust parser must be adjusted (`line = line + injected_count`).

Both pre-script vars and global vars need this adjustment. See `run.lua:133,154`.

### jq State Stale on Re-Request

`state._json.query` and `state._json.original_lines` persist across requests.
`run.lua` clears them before setting `state.last_response`. If adding a new code
path that sets `state.last_response`, also clear `state._json`.

### Result Buffer Is Not Automatically Replaced

When a new response arrives, `buffer.lua` creates a new buffer. The old response
buffer is not automatically closed. Use `PosteCloseResult` or BufDelete pattern.

## Pre-Flight: Run Before Editing

Before making ANY change to `lua/poste/http/`, run:

```bash
tools/relation-check.sh
```

This scans the current (not stale) codebase and reports:
- **`nvim_buf_set_lines`** without `sanitize_lines` on the same path
- **State field lifecycle** — fields written but never cleared
- **Format function callers** — all places that call each `format_*` function
- **Pre-render paths** — cached/render functions and their highlights/extmarks

If the output is clean after your change, you're done. If it shows mismatches
(e.g. a new `nvim_buf_set_lines` without sanitize, or a state write without
clear), fix them before committing.

## Tests

```bash
tests/run.sh                          # Lua tests for HTTP + SQL
# HTTP-specific Lua tests are in tests/ -- check file names
# No Docker needed for HTTP tests (no curl subprocess mocking)
```

## Quick Reference

| Task | Entry file | Key functions |
|------|-----------|---------------|
| New request format feature | `parser.rs` | `parse_block()`, `substitute_vars()` |
| New script API method | `scripts.lua` + `data.lua` | sandbox env, `run_pre_script()` |
| New response tab | `view.lua` + `format.lua` | `show_view()`, format function |
| jq filter | `json.lua` | `apply_filter()`, `restore_original()` |
| Cross-request chaining | `request_vars.lua` | `resolve_request_variables()`, `cache_response()` |
| Winbar / tab UI | `buffer.lua` | `update_winbar()`, `get_active_tabs()` |
| History | `history.lua` | `show()`, `add_entry()`, `delete_entry()`, `load_from_disk()` |
| Curl import | `curl.lua` | `paste_curl()` |
