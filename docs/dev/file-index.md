# Poste File Index

> Quick reference to key files across the project

---

## Lua Plugin

### Shared (`lua/poste-http/`)

| File | Description |
|------|-------------|
| `init.lua` | Entry point, `setup()` |
| `state.lua` | Shared state management |
| `select.lua` | Generic Picker UI |
| `indicators.lua` | Spinner/✓/✘ indicators |
| `buffer_setup.lua` | Buffer boilerplate creation |
| `constants.lua` | Shared constants |
| `errors.lua` | Structured error collection |
| `help.lua` | Help window |

### AI integration (`lua/poste-http/ai/`, optional poste-ai.nvim extension)

| File | Description |
|------|-------------|
| `ai/init.lua` | Context registration on poste-ai.nvim, `:PosteHttpChat`, `a`/`ga` ask prefill |
| `ai/blocks.lua` | Pure `.http` block helpers (list/slice/refs/truncate) + `focus()` seam |
| `ai/system_prompt.lua` | `http` context system prompt (poste-http dialect knowledge) |
| `ai/mentions.lua` | `@req/<Name>` mention match/complete/resolve |
| `ai/auto_context.lua` | Implicit focused-request + dependency-chain context block |
| `ai/commands.lua` | `/requests`, `/env` slash commands |
| `ai/actions.lua` | ```http codeblock confirm/execute (regular pipeline) + `ga` header |

### UI Components (`lua/poste-http/ui/`)

Reusable rendering components — the seed of a standalone Neovim UI component
library. Pure functions, unit-tested without windows (`float.lua` is the one
thin window primitive; its geometry helper is unit-tested and its `open()`
adds the guards — failure cleanup, close-keymaps, `WinClosed`/`on_close` —
that hand-rolled floats used to apply unevenly).

| File | Description |
|------|-------------|
| `columns.lua` | Column-aligned list layout: `render(rows, cols, opts)` → aligned lines + per-cell byte ranges for extmarks. Per-column align (left/right), fixed/max/flex widths, ellipsis truncation, display-width aware (CJK-safe) |
| `text.lua` | Display-width aware truncation: `truncate(s, max)` (end `…`) and `middle(s, max)` (middle `…`). Single source replacing the byte/char-based copies |
| `semantics.lua` | HTTP semantics → highlight groups: `method_hl(method)`, `status_hl(status)`. Single mapping source (groups defined in `http/highlights.lua`) |
| `winbar.lua` | Winbar tab rows: `render_tabs(tabs, active_id)` and tab cycling `cycle(tabs, current_id, direction)` |
| `render.lua` | Scratch-buffer line writer: `set_lines(buf, lines, opts)` — modifiable toggle + optional filetype |
| `float.lua` | Centered floating window: `open(opts)` (scratch buffer, border/title, close keys, `on_close`, failure cleanup) and pure `center(w, h)` |
| `picker.lua` | Floating list picker with incremental search — snacks-less fallback used by `select.lua`; every close path resolves `on_select` exactly once |
| `keymaps.lua` | Config-driven keymap registration: `register(buf, section, action, default, handler)` / `register_all(buf, section, specs, base_opts)`; `false` in config disables an action |

### HTTP Module (`lua/poste-http/http/`)

#### Execution Pipeline

| File | Description |
|------|-------------|
| `run.lua` | Request execution orchestration (entry point) |
| `executors/init.lua` | Protocol executor dispatch — request-line method → executor; unknown methods fall back to HTTP |
| `executors/http.lua` | HTTP executor — thin wrapper over `curl_exec` |
| `executors/graphql.lua` | GraphQL executor — lowers `GRAPHQL` blocks to HTTP POST via curl |
| `executors/grpc.lua` | gRPC executor — wraps `grpcurl`, maps gRPC status codes onto the canonical response |
| `executors/websocket.lua` | WebSocket executor — batch session over `websocat`, frames into `metadata.frames` |
| `ws_session.lua` | Interactive WebSocket session — live frames, send/close keymaps, `state.live_session` |
| `format/messages.lua` | Messages view formatter — WebSocket frame transcript to lines |
| `block_operators.lua` | Extract `# @name value` operator comments from a request block |
| `response.lua` | Canonical response helpers — protocol-aware `ok` flag and `is_error` |
| `curl_exec.lua` | Build curl args, spawn via `jobstart`, temp file management |
| `response_parser.lua` | Parse curl `-D` headers, status, cookies, stderr verbose |
| `file_include.lua` | Expand `< path` directives in body |

#### Parsing & Variable Resolution

| File | Description |
|------|-------------|
| `describe.lua` | Single parse authority — tree-sitter based block metadata |
| `vars.lua` | `VarResolver` — 7-layer priority chain for `{{var}}` substitution |
| `cache.lua` | UI-level buffer index (line types, block bounds) |
| `var_collector.lua` | Variable collection/rollup for completion |
| `resolve.lua` | Shared async resolution pipeline for prompts/deps |
| `request_vars.lua` | Cross-request variable chaining (`{{Name.response.body.X}}`), prompt vars, form data |

#### UI & Rendering

| File | Description |
|------|-------------|
| `buffer.lua` | Right vertical split result panel |
| `view.lua` | Response tab management (Body/Verbose/Assertions) |
| `format.lua` | JSON formatting (dispatches to `format/`) |
| `format/body.lua` | HTTP response body formatting |
| `format/verbose.lua` | Verbose response rendering |
| `format/image.lua` | Image preview (floating window + inline) |
| `format/image_meta.lua` | Pure image metadata (dimensions, size, JPEG EXIF) |
| `format/multipart.lua` | Multipart body parsing |
| `highlights.lua` | HTTP syntax highlighting (extmarks) |
| `json.lua` | JSON folding, jq filter, outline |
| `session.lua` | Per-request HTTP session lifecycle |
| `boundary_indicator.lua` | Block boundary indicators |

#### Completion

| File | Description |
|------|-------------|
| `completion.lua` | HTTP smart completion (blink.cmp + nvim-cmp) |
| `context_detector.lua` | Context detection for completion |
| `item_builder.lua` | Completion item builder |
| `grpc_proto.lua` | gRPC completion index — `pkg.Service/Method` and JSON body message fields/enums from `# @grpc-proto` files (offline `grpcurl list|describe`, chained into nested types) or server reflection; mtime-keyed cache; `# @grpc-proto` path items |
| `graphql_schema.lua` | GraphQL schema-aware body completion — SDL parsing, `# @graphql-schema` block operator, query-text position walker, field/arg/enum/type items; mtime-keyed cache; `# @graphql-schema` path items |
| `data.lua` | HTTP history data format helpers, keyword definitions |

#### Scripts & Assertions

| File | Description |
|------|-------------|
| `scripts.lua` | Pre-request script execution (`< {% %}`) |
| `assertions.lua` | Post-request assertion execution (`> {% %}`) |
| `script_block.lua` | Shared `< {% %}`/`> {% %}` block extraction (used by scripts.lua + assertions.lua) |
| `script_sandbox.lua` | Shared sandbox env builder (whitelisted stdlibs, curated `os` without execute/io, + injected API) |
| `orchestration.lua` | SCRIPT-block orchestration: `client.run()` coroutine scheduler + typed responses |
| `errors.lua` | Structured pre/post-request error collection + Error tab formatting/highlights |
| `lua_docs.lua` | Lua API documentation helpers |
| `md5.lua` | MD5 helper |
| `script_snippet.lua` | Script snippet insertion |

#### Navigation & Editing

| File | Description |
|------|-------------|
| `nav.lua` | Block navigation, variable lookup, go-to-definition |
| `symbols.lua` | Document symbol outline |
| `outline.lua` | Sidebar outline |
| `textobj.lua` | Text object support |
| `folding.lua` | Code folding |
| `diagnostics.lua` | Diagnostics (linting) |
| `treesitter.lua` | Tree-sitter integration (highlights, inspect) |
| `ts_query.lua` | Tree-sitter query helpers |

#### Import & Export

| File | Description |
|------|-------------|
| `import.lua` | Import/run across files (`import ./path`, `run #Name`) |
| `import_openapi.lua` | OpenAPI 3.x spec → `.http` files (pure Lua) |
| `import_swagger.lua` | Swagger 2.0 spec → `.http` files (pure Lua) |
| `import_postman.lua` | Postman Collection v2.1 → `.http` files (pure Lua) |
| `import_parser.lua` | Shared import utilities (schema-to-example, `$ref` resolution, `env.json` generation) |
| `image_cache.lua` | Image URL download + disk cache (TTL, stale fallback, temp-file tracking) and the content-type tables shared with `format/image.lua` |
| `copy.lua` | Curl command export |
| `curl.lua` | Paste curl command as `.http` format |

#### Other

| File | Description |
|------|-------------|
| `env.lua` | Environment switching UI |
| `history.lua` | HTTP request history UI + disk persistence (`stdpath("data")/poste-http/history.json`) |
| `format_file.lua` | `.http` file formatter (pure Lua, string-based) |

## VimScript

| File | Description |
|------|-------------|
| `syntax/poste_http.vim` | HTTP syntax highlighting |
| `ftdetect/poste.vim` | Filetype detection (.http) |

---

## Tests

| Type | Location | Description |
|------|----------|-------------|
| Lua tests | `tests/http/*_spec.lua` | busted framework |
| Contract tests | `tests/contract/` | Golden fixtures for response shapes |
| Tree-sitter grammar | `tree-sitter-poste-http/` | Grammar tests |
| Body injection grammars | `tree-sitter-poste-json/`, `tree-sitter-poste-graphql/` | `poste_json` / `poste_graphql` parsers (JSON/GraphQL + `{{var}}`), injected into request bodies; rtp queries under `queries/poste_*` |

---

## Examples

| Type | Location | Description |
|------|----------|-------------|
| HTTP examples | `examples/http/` | HTTP request examples |
| HTTP playground | `playground/http/` | Test scenarios |

---

## Config Files

| File | Description |
|------|-------------|
| `env.json` | Environment variables ({{var}} substitution) |

---

*File index — Last updated: 2026-09-07*
