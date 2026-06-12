# Poste

File-driven, keyboard-first multi-protocol request executor (Rust CLI + Neovim).

`.http`/`.sql`/`.redis` → execute → results in editable Vim buffer.

## Protocols

| Proto | Ext | Status | Impl |
|-------|-----|--------|------|
| HTTP | `.http`/`.rest` | ✅ | `executor.rs` (curl) |
| PG | `.sql` | ✅ | `sql_executor.rs` (sqlx) |
| MySQL | `.mysql` | ✅ | `sql_executor.rs` (sqlx) |
| SQLite | `.sqlite` | ✅ | `sql_executor.rs` (sqlx) |
| Redis | `.redis` | ✅ | `executor.rs` (redis) |
| MongoDB | `.mongo` | ❌ Stub | `executor.rs` |
| AMQP | `.amqp` | ❌ Stub | `executor.rs` |

## Layout

`crates/poste-core/` — parser, sql_parser, request, env (no I/O)
`crates/poste-exec/` — executor, sql_executor, sql_connection, sql_dialect, response, cookie_jar
`crates/poste-cli/` — `poste run/connection/introspect`

`lua/poste/` — Neovim plugin
`lua/poste/sql/` — SQL-only (isolated from HTTP)
`syntax/` — Vim syntax files
`docs/` — design docs
`tests/` — Lua tests + SQL integration (Docker)
`examples/` — sample .http/.sql/.redis

## Build

```bash
cargo build / test / clippy -- -D warnings
cargo run -- run <file> --line N --env <env>
tests/run.sh              # Lua tests
cd tests/sql && docker compose up -d   # PG+MySQL on 15432/13306
```

## File Format

- **HTTP**: `###` blocks, `{{var}}`, `@name = val`, `{{Name.res.body.X}}` chaining
- **SQL**: `-- @connection name`, `;`-separated statements, `USE db;`
- **Redis**: `# @connection redis://host:port`, `;`-separated commands

## Config

- `env.json` (walk up): `{ "dev": { "api_base": "..." } }` — `{{var}}` substitution
- `connections.json` (walk up): `{ "pg-dev": { "dialect": "postgres", "host": ..., "port": ..., "database": ..., "user": ..., "password": "{{var}}" } }`
- SQL ref: `-- @connection pg-dev`

## Code Conventions

**Rust**: Edition 2021, `anyhow::Result` (app) / `thiserror` (lib), no `unwrap()` outside tests, Tokio, workspace deps, `#[cfg(test)]` for new features.

**Lua**: `vim.api.*` conventions, `local M = {} ... return M` exports, HTTP/SQL isolated, shared state in `state.lua`.

**SQL isolation**: share only at infra layer — `state.lua` (`.sql` ns), `init.lua` (filetype dispatch), `executor.rs` (Protocol enum), `ftdetect/poste.vim` (ext → filetype). Changing HTTP must not affect SQL and vice versa.

## SQL Integration Tests

`tests/sql/`: Docker Compose with PG 16 + MySQL 8.0 (ports 15432/13306).
Connections: `pg-ecommerce`, `pg-analytics`, `my-blog`, `my-inventory`.
Init scripts in `tests/sql/init/`. Run: `docker compose down -v && docker compose up -d` after changes.
Queries: `tests/sql/queries/`. Execute: `cargo run -- run tests/sql/queries/postgres.sql --line 4 --env dev`.

## Current Focus

All P0-P2 SQL completion tasks done (15/15). See `PROGRESS.md` for next priorities.

## File Index

| Want | File |
|------|------|
| Architecture | `AGENTS.md` (this) |
| SQL progress | `PROGRESS.md` |
| SQL design | `docs/sql-design.md` |
| Dataset UI | `docs/dataset-ui-design.md` |
| HTTP syntax | `docs/http-syntax.md` |
| HTTP entry (Lua) | `lua/poste/init.lua` → `run_request()` |
| SQL entry (Lua) | `lua/poste/sql/init.lua` |
| SQL entry (Rust) | `crates/poste-exec/src/sql_executor.rs` |
| Parser | `crates/poste-core/src/parser.rs` |
| SQL parser | `crates/poste-core/src/sql_parser.rs` |
| Connection mgmt | `crates/poste-exec/src/sql_connection.rs` |
| Dialect trait | `crates/poste-exec/src/sql_dialect.rs` |
| Shared state | `lua/poste/state.lua` |
| Response struct | `crates/poste-exec/src/response.rs` |
| HTTP result buf | `lua/poste/buffer.lua` |
| SQL result buf | `lua/poste/sql/buffer.lua` |
| Completion | `lua/poste/sql/completion.lua` (SQL), `lua/poste/completion.lua` (HTTP) |