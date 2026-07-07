# Poste Architecture Overview

> Overall architecture of the multi-protocol request executor

---

## Core Design Principles

1. **Protocol isolation** — HTTP and SQL are fully isolated at the implementation layer, sharing only infrastructure
2. **File-driven** — All requests originate from `.http` / `.sql` / `.redis` files
3. **Keyboard-first** — Neovim plugin uses keyboard as primary interaction mode
4. **Rust + Lua** — Rust handles core logic (parsing, execution), Lua handles UI (completion, rendering)

---

## Layered Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   Neovim Plugin Layer (Lua)                   │
│  ┌────────────────────┐  ┌──────────────┐  ┌─────────────┐  │
│  │  lua/poste/http/   │  │  lua/poste/  │  │lua/poste/sql│  │
│  │  (HTTP-specific)   │  │  (shared)    │  │(SQL-specific)│  │
│  │                    │  │              │  │             │  │
│  │ init.lua           │  │ state.lua    │  │ init.lua    │  │
│  │ buffer.lua         │  │ select.lua   │  │ buffer.lua  │  │
│  │ completion.lua     │  │ indicators   │  │ completion  │  │
│  │ format.lua         │  │ constants    │  │ connections │  │
│  │ highlights.lua     │  │ error.lua    │  │ db_browser  │  │
│  │ assertions.lua     │  │ help.lua     │  │ editor.lua  │  │
│  │ scripts.lua        │  │              │  │ export.lua  │  │
│  │ curl.lua           │  │              │  │ import.lua  │  │
│  │ copy.lua           │  │              │  │ context.lua │  │
│  │ nav.lua            │  │              │  │ pagination  │  │
│  │ history.lua        │  │              │  │ format.lua  │  │
│  │ run.lua            │  │              │  │              │  │
│  │ view.lua           │  │              │  │              │  │
│  │ json.lua           │  │              │  │              │  │
│  │ import*.lua        │  │              │  │              │  │
│  └────────────────────┘  └──────────────┘  └─────────────┘  │
│                          ↓                                  │
│              init.lua: filetype dispatch                    │
│              poste_sql → sql.init.run_sql_request()         │
│              poste_http → http.init.run_request()           │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│                    Rust CLI (poste)                          │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ crates/poste-cli/                                     │  │
│  │   main.rs: run / conn / introspect / fmt / context    │  │
│  │           resolve / serve / import                     │  │
│  └───────────────────────────────────────────────────────┘  │
│                          ↓                                  │
│  ┌─────────────────┐  ┌─────────────────────────────────┐   │
│  │ crates/poste-   │  │ crates/poste-exec/              │   │
│  │ core/           │  │                                 │   │
│  │ parser.rs       │  │ executor.rs (HTTP/Redis)        │   │
│  │ sql_parser.rs   │  │ sql_executor.rs(PG/MySQL/SQLite)│   │
│  │ sql_context/    │  │ sql_connection.rs               │   │
│  │ request.rs      │  │ sql_dialect.rs                  │   │
│  │ env.rs          │  │ sql_introspect.rs               │   │
│  │ formatter.rs    │  │ sql_ddl.rs                      │   │
│  │ importer.rs     │  │ response.rs                     │   │
│  │ lib.rs          │  │ cookie_jar.rs                   │   │
│  └─────────────────┘  └─────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│                  Infrastructure Layer                        │
│  env.json          — Environment variables ({{var}} subst)  │
│  connections.json  — Database connection config             │
│  ~/.cache/poste/   — Cache (query history, metadata, etc.)  │
└─────────────────────────────────────────────────────────────┘
```

---

## Protocol Implementation Comparison

| Dimension | HTTP | SQL |
|-----------|------|-----|
| File extension | `.http`, `.rest` | `.sql`, `.mysql`, `.sqlite` |
| Parser | `parser.rs` | `sql_parser.rs` |
| Executor | `executor.rs` (curl) | `sql_executor.rs` (sqlx) |
| Result panel | Right vertical split | Bottom horizontal split |
| Navigation | Normal text cursor | Cell (hjkl) navigation |
| Completion | `http/completion.lua` | `sql/completion.lua` |
| Syntax highlighting | `syntax/poste_http.vim` | `syntax/poste_sql.vim` |
| Formatter | `poste fmt` (✅ implemented) | N/A |

---

## Shared vs Isolated

### Shared Files (Infrastructure Layer)

| File | Purpose |
|------|---------|
| `crates/poste-core/src/request.rs` | Shared Request type, Protocol enum |
| `crates/poste-core/src/parser.rs` | Shared `substitute_vars()` variable substitution |
| `crates/poste-core/src/env.rs` | env.json loading |
| `crates/poste-core/src/lib.rs` | Module exports |
| `lua/poste/state.lua` | Shared state (env, current connection, etc.) |
| `lua/poste/select.lua` | Generic Picker UI |
| `lua/poste/indicators.lua` | Generic spinner/✓/✘ |
| `ftdetect/poste.vim` | Filetype detection |

### Isolated Files (Protocol-Specific)

| HTTP-specific | SQL-specific |
|---------------|-------------|
| `lua/poste/http/init.lua` | `lua/poste/sql/init.lua` |
| `lua/poste/http/buffer.lua` | `lua/poste/sql/buffer.lua` |
| `lua/poste/http/format.lua` | `lua/poste/sql/format.lua` |
| `lua/poste/http/completion.lua` | `lua/poste/sql/completion.lua` |
| `lua/poste/http/highlights.lua` | `lua/poste/sql/highlights.lua` |
| `lua/poste/http/assertions.lua` | `lua/poste/sql/context.lua` |
| `lua/poste/http/scripts.lua` | `lua/poste/sql/connections.lua` |
| `lua/poste/http/curl.lua` | `lua/poste/sql/db_browser/` |
| `lua/poste/http/copy.lua` | `lua/poste/sql/editor.lua` |
| `lua/poste/http/nav.lua` | `lua/poste/sql/export.lua` |
| `lua/poste/http/view.lua` | `lua/poste/sql/import.lua` |
| `lua/poste/http/run.lua` | `lua/poste/sql/table_ops.lua` |
| `syntax/poste_http.vim` | `syntax/poste_sql.vim` |
| | `syntax/poste_dataset.vim` |

---

## Key Dispatch Points

### Lua-side dispatch

`lua/poste/init.lua`'s `run_request()`:

```lua
function M.run_request()
  local ft = vim.bo.filetype
  if ft == "poste_sql" or ft == "poste_sqlite" then
    require("poste.sql.init").run_sql_request()
    return
  end
  -- Existing HTTP/Redis flow unchanged
end
```

### Rust-side dispatch

`crates/poste-exec/src/executor.rs` dispatch:

```rust
match request.protocol {
    Protocol::Http | Protocol::Redis => executor::execute_http(request).await,
    Protocol::Postgres => sql_executor::execute_postgres(request).await,
    Protocol::Mysql => sql_executor::execute_mysql(request).await,
    Protocol::Sqlite => sql_executor::execute_sqlite(request).await,
}
```

---

## Data Flow

### HTTP Request Flow

```
.http file
  → parser.rs parse → Request struct
  → executor.rs execute → curl call
  → Response JSON
  → http/buffer.lua render → right vertical split
```

### SQL Request Flow

```
.sql file
  → sql_parser.rs parse → Request + context
  → sql_executor.rs execute → sqlx query
  → Response JSON (structured result set)
  → sql/buffer.lua render → bottom horizontal split (Dataset)
```

---

## Dependency Graph

```
poste-cli ──→ poste-exec ──→ poste-core
                │
                ├── sqlx (PG/MySQL/SQLite)
                ├── curl-rust (HTTP)
                └── redis-rs (Redis)

lua/poste ──→ Rust CLI (via system/jobstart)
```

---

## Testing Strategy

| Layer | Tool | Location |
|-------|------|----------|
| Rust unit tests | `#[cfg(test)]` | `crates/*/src/*_tests.rs` |
| Rust integration | `cargo test` | `crates/*/tests/` |
| Lua unit tests | busted (`tests/run.sh`) | `tests/*.lua` |
| SQL integration | Docker Compose | `tests/sql/` |

---

## Related Documents

- [HTTP Developer Docs](./http/README.md)
- [SQL Developer Docs](./sql/README.md)
- [HTTP TDD Guide](./http/tdd-guide.md)
- [File Index](./file-index.md)
- [Testing Guide](./testing.md)

---

*Architecture overview — Last updated: 2026-07-07*
