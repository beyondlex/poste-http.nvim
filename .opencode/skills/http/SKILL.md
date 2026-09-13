# HTTP — Agent Skill

# Poste HTTP — Lua + curl

File-driven HTTP request executor. `.http` → execute → results in editable buffer.

## Architecture

```
source buffer → run.lua → extract pre-script → run in sandbox
  → inject @vars → process form data → extract assertions
  → vars.lua resolve {{var}} → tree-sitter describe
  → curl_exec.lua → curl subprocess
  → response_parser.lua → Lua rendering
```

**No Rust CLI.** All parsing, resolving, formatting, and import parsing are pure Lua.
The only subprocess is `curl` (migration record:
`docs/dev/archived/rust-retirement-plan.md`).

## File Index

### Shared (lua/poste-http/)

| File | Why |
|------|-----|
| `lua/poste-http/state.lua` | Shared state object |
| `lua/poste-http/init.lua` | Entry point, setup(), dispatches by filetype |
| `lua/poste-http/buffer_setup.lua` | Shared keymap registration for source buffers |
| `lua/poste-http/indicators.lua` | Spinner/✓/✘ indicators, request block boundary detection |
| `lua/poste-http/select.lua` | Picker UI |
| `lua/poste-http/util.lua` | `clean_nil`, `find_file_upwards`, `ensure_job_data` |
| `lua/poste-http/help.lua` | Keymap help window (HTTP section) |

### HTTP Lua (`lua/poste-http/http/`)

#### Execution

| File | Role |
|------|------|
| `run.lua` | Entry: `run_request()`, pipeline orchestration, response handling |
| `curl_exec.lua` | Build curl args, spawn via `vim.fn.jobstart`, temp file management |
| `response_parser.lua` | Parse curl `-D` headers, status, cookies, stderr verbose |
| `file_include.lua` | Expand `< path` directives in body |

#### Parsing & Variables

| File | Role |
|------|------|
| `describe.lua` | Single parse authority — tree-sitter based `BlockMeta[]` extraction |
| `vars.lua` | `VarResolver` — 7-layer priority chain for `{{var}}` substitution |
| `cache.lua` | UI-level buffer index (line types, block bounds, var names, imports) |
| `resolve.lua` | Shared async resolution pipeline for prompts/deps |
| `request_vars.lua` | Cross-request chaining (`{{Name.res.body.X}}`), form data, magic vars |
| `var_collector.lua` | Variable collection for completion |

#### UI

| File | Role |
|------|------|
| `buffer.lua` | Response buffer/window management, winbar tabs, multi-response nav |
| `format.lua` | Result rendering dispatcher (body, verbose, assertions, script logs) |
| `format/body.lua` | HTTP response body formatting |
| `format/verbose.lua` | Verbose response rendering + highlights |
| `format/image.lua` | Image preview |
| `format/multipart.lua` | Multipart body parsing |
| `view.lua` | Tab switching: body / verbose / request / assertions / script logs |
| `json.lua` | jq filter: `apply_filter()`, key path discovery |
| `highlights.lua` | Syntax highlighting for HTTP result buffers |
| `session.lua` | Per-request session lifecycle |
| `boundary_indicator.lua` | `###` block boundary indicator line |

#### Navigation & Editing

| File | Role |
|------|------|
| `nav.lua` | Source buffer navigation: `jump_next/prev`, `goto_definition/references` |
| `symbols.lua` | Symbol outline: `show_symbols()` for request blocks |
| `outline.lua` | Sidebar outline |
| `textobj.lua` | Text object support |
| `folding.lua` | Code folding |
| `treesitter.lua` | Tree-sitter integration (highlights, inspect) |
| `ts_query.lua` | Tree-sitter query helpers |
| `diagnostics.lua` | Diagnostics (linting) |

#### Completion

| File | Role |
|------|------|
| `completion.lua` | Blink.cmp source for `{{var}}` completion in HTTP source buffers |
| `context_detector.lua` | Detect context at cursor (within `###` block, inside `{%`, etc.) |
| `item_builder.lua` | Build completion items for HTTP source buffers |
| `data.lua` | Dynamic data definitions for the HTTP script API |

#### Scripts & Assertions

| File | Role |
|------|------|
| `scripts.lua` | Pre-request script: extraction, sandboxed execution, var injection |
| `assertions.lua` | Post-response assertions: extraction, sandbox, result formatting |
| `lua_docs.lua` | Lua API documentation helpers |
| `md5.lua` | MD5 helper |
| `script_snippet.lua` | Script snippet insertion |

#### Import & Export

| File | Role |
|------|------|
| `import.lua` | Import resolution: cross-file request execution |
| `import_openapi.lua` | OpenAPI 3.x → `.http` (pure Lua) |
| `import_swagger.lua` | Swagger 2.0 → `.http` (pure Lua) |
| `import_postman.lua` | Postman Collection v2.1 → `.http` (pure Lua) |
| `import_parser.lua` | Shared import utilities |
| `copy.lua` | Copy request as curl command |
| `curl.lua` | Paste clipboard curl command as `.http` format |

#### Other

| File | Role |
|------|------|
| `env.lua` | Environment switching: `set_env()`, `pick_env()`, winbar builder |
| `history.lua` | Request history: floating UI, persistence, navigation |
| `format_file.lua` | `.http` file formatter (tree-sitter based) |

## Variable Priority

```
import_params (highest) > request_vars > file_vars > session_vars > script_vars > env > magic
```

## Request Flow

```
source buffer → run.lua → extract pre-script → run in sandbox
  → inject @vars → process form data → extract assertions
  → vars.lua resolve {{var}} → describe.lua tree-sitter parse
  → curl_exec.lua → curl subprocess → response_parser.lua
  → Lua rendering (buffer.lua / format.lua / view.lua)
```

## Key State Fields

All in `state` (from `lua/poste-http/state.lua`):

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

## Tests

```bash
tests/run.sh                          # Lua tests
# Contract tests for response shapes: tests/contract/
```

## Reference

| Task | Entry file | Key functions |
|------|-----------|---------------|
| Debug tree-sitter parse | `treesitter.lua` | `M.inspect()` |
| New response tab | `view.lua` + `format.lua` | `show_view()`, format function |
| jq filter | `json.lua` | `apply_filter()`, `restore_original()` |
| Cross-request chaining | `resolve.lua` + `request_vars.lua` | `resolve()`, `cache_response()` |
| Winbar / tab UI | `buffer.lua` | `update_winbar()`, `get_active_tabs()` |
| History | `history.lua` | `show()`, `add_entry()`, `delete_entry()` |
| Curl import | `curl.lua` | `paste_curl()` |
| Curl export | `copy.lua` | `copy_as_curl()` |
| File formatting | `format_file.lua` | `format()`, `format_buffer()` |