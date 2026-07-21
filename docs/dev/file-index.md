# Poste File Index

> Quick reference to key files across the project

---

## Rust Core

| Function | File | Description |
|----------|------|-------------|
| HTTP/Redis parsing | `crates/poste-core/src/parser.rs` | Tokenize, parse_block, variable substitution |
| SQL parsing | `crates/poste-core/src/sql_parser.rs` | @connection extraction, statement splitting |
| SQL context | `crates/poste-core/src/sql_context/` | Tokenizer, scope resolver, context detection |
| Variable resolver | `crates/poste-core/src/parser.rs` | `VarResolver` struct with priority chain |
| Shared Request type | `crates/poste-core/src/request.rs` | Protocol enum, Request struct |
| Env.json loading | `crates/poste-core/src/env.rs` | Environment variable loading |
| Formatter | `crates/poste-core/src/formatter.rs` | `.http` file formatting engine |
| Importer (OpenAPI/etc) | `crates/poste-core/src/importer.rs` | Import specs to `.http` format |
| HTTP/Redis execution | `crates/poste-exec/src/executor.rs` | Dispatch → curl execution |
| SQL execution | `crates/poste-exec/src/sql_executor.rs` | PG/MySQL/SQLite executor |
| Connection management | `crates/poste-exec/src/sql_connection.rs` | connections.json read/write, test |
| Dialect abstraction | `crates/poste-exec/src/sql_dialect.rs` | Dialect trait + 3 implementations |
| Introspection | `crates/poste-exec/src/sql_introspect.rs` | Schema/table/column/index queries |
| DDL generation | `crates/poste-exec/src/sql_ddl.rs` | DDL statement generator |
| Response structure | `crates/poste-exec/src/response.rs` | Unified response format |
| Cookie management | `crates/poste-exec/src/cookie_jar.rs` | Cookie persistence |
| CLI entry | `crates/poste-cli/src/main.rs` | run/connection/introspect/fmt/context/resolve/serve/import |

---

## Lua Plugin

### Shared (`lua/poste/`)

| File | Description |
|------|-------------|
| `init.lua` | Entry point, filetype dispatch |
| `state.lua` | Shared state management |
| `select.lua` | Generic Picker UI |
| `indicators.lua` | Spinner/✓/✘ indicators |
| `buffer_setup.lua` | Buffer boilerplate creation |
| `constants.lua` | Shared constants |
| `error.lua` | Error handling |
| `help.lua` | Help window |

### HTTP Module (`lua/poste/http/`)

| File | Description |
|------|-------------|
| `init.lua` | HTTP execution entry |
| `buffer.lua` | Right vertical split result panel |
| `run.lua` | Request execution orchestration |
| `curl.lua` | curl command building |
| `copy.lua` | curl command export |
| `format.lua` | JSON formatting |
| `highlights.lua` | HTTP syntax highlighting (extmarks) |
| `completion.lua` | HTTP smart completion |
| `assertions.lua` | Post-request assertion execution |
| `scripts.lua` | Pre-request script execution |
| `nav.lua` | Block navigation, variable lookup |
| `view.lua` | Response tab management (Body/Verbose/Assertions) |
| `json.lua` | JSON folding, jq filter, outline |
| `history.lua` | HTTP request history UI + persistence |
| `symbols.lua` | Document symbol outline |
| `outline.lua` | Sidebar outline |
| `request_vars.lua` | Request variable handling, prompt vars |
| `resolve.lua` | Shared async resolution pipeline for prompts/deps |
| `var_collector.lua` | Variable collection/rollup |
| `context_detector.lua` | Context detection for completion |
| `cache.lua` | UI-level buffer index (line types, block bounds); semantic blocks via describe |
| `describe.lua` | Single parse authority — `poste run --describe` wrapper |
| `session.lua` | Per-request HTTP session lifecycle (clears request-scoped state) |
| `env.lua` | Environment switching UI |
| `import.lua` | Import/run across files |
| `import_openapi.lua` | OpenAPI import |
| `import_swagger.lua` | Swagger import |
| `import_postman.lua` | Postman import |
| `data.lua` | HTTP history data format helpers |
| `item_builder.lua` | Completion item builder |
| `boundary_indicator.lua` | Block boundary indicators |
| `lua_docs.lua` | Lua API documentation helpers |
| `md5.lua` | MD5 helper |
| `script_snippet.lua` | Script snippet insertion |

### SQL Module

SQL Lua code moved to [poste-sql.nvim](https://github.com/beyondlex/poste-sql.nvim) (separate repo).
| `dataset.lua` | Dataset data model |
| `insert_hint.lua` | INSERT template helpers |
| `prototype.lua` | SQL prototype utilities |

---

## VimScript

| File | Description |
|------|-------------|
| `syntax/poste_http.vim` | HTTP syntax highlighting |
| `syntax/poste_sql.vim` | SQL syntax highlighting |
| `syntax/poste_dataset.vim` | Dataset buffer syntax |
| `ftdetect/poste.vim` | Filetype detection (.http/.sql/.sqlite) |
| `ftplugin/poste_sql.vim` | SQL filetype plugin settings |

---

## Tests

| Type | Location | Description |
|------|----------|-------------|
| Rust unit tests | `crates/*/src/*_tests.rs` | Inline tests |
| Rust integration | `crates/*/tests/` | Integration tests |
| Lua tests | `tests/*.lua` | busted framework |
| SQL integration | `tests/sql/` | Docker Compose (PG + MySQL) |
| HTTP completion tests | `tests/http_completion_spec.lua` | HTTP completion validation |
| SQL completion tests | `tests/sql_completion_spec.lua` | SQL completion validation |

---

## Examples

| Type | Location | Description |
|------|----------|-------------|
| HTTP examples | `playground/http/` | HTTP request examples |
| SQL examples | `examples/*.sql` | SQL query examples |
| Redis examples | `examples/*.redis` | Redis command examples |
| SQL test queries | `tests/sql/queries/` | Integration test queries |
| SQL init scripts | `tests/sql/init/` | Docker init scripts |

---

## Config Files

| File | Description |
|------|-------------|
| `env.json` | Environment variables ({{var}} substitution) |
| `connections.json` | Database connection config |

---

*File index — Last updated: 2026-07-07*
