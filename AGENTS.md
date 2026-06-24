# Poste

File-driven, keyboard-first multi-protocol request executor (Rust CLI + Neovim).

`.http`/`.sql`/`.redis` → execute → results in editable Vim buffer.

## Protocol First

**Identify the protocol before loading context.** 

| Task mentions | Load | Skip |
|---------------|------|------|
| `.http`, `curl`, `jq`, pre-script, assertion, `{{var}}`, import, env vars | HTTP skill + shared files | `lua/poste/sql/`, `sql_executor`, `sql_parser`, `sql_context` |
| `.sql`, `pg`, `mysql`, `sqlite`, completion, table/column/schema, dataset, db_browser | SQL skill + shared files | `lua/poste/http/`, `executor.rs` (curl) |
| Redis, Mongo, AMQP | `executor.rs` + shared | sql + http Lua modules |
| Rust CLI (`poste run/conn/introspect/fmt/context`) | `main.rs` + both skills | — |

Use `.opencode/skills/` skills for detailed file indexes. For SQL completion
specifically, load `.opencode/skills/sql-completion/SKILL.md` in addition to
the general SQL skill. `docs/dev/file-index.md` has the complete file lookup table.

## Layout

`crates/poste-core/` — parser, sql_parser, request, env (no I/O)
`crates/poste-exec/` — executor, sql_executor, sql_connection, sql_dialect, response, cookie_jar
`crates/poste-cli/` — `poste run/connection/introspect`

`lua/poste/` — Neovim plugin
`lua/poste/sql/` — SQL-only (isolated from HTTP)
`syntax/` — Vim syntax files
`docs/` — user docs + dev docs
`tests/` — Lua tests + SQL integration (Docker)
`examples/` — sample .http/.sql/.redis

## Code Conventions

**Protocol directory discipline.** New Lua code for HTTP goes in `lua/poste/http/`,
for SQL in `lua/poste/sql/`. Never put SQL logic in `lua/poste/http/` or vice versa.
Rust: HTTP in `executor.rs`, SQL in `sql_executor.rs`. Shared infra (`state.lua`,
`init.lua` dispatch, `Protocol` enum) lives at the parent level.

**TDD first.** Write the test before the implementation. For Rust: `#[cfg(test)]`
inline tests. For Lua: add to `tests/` and run `tests/run.sh`. The HTTP TDD
guide at `docs/dev/http/tdd-guide.md` covers workflow and patterns.

**Update docs on change.** Every new feature or behavior change must update the
relevant `docs/dev/` or `docs/user/` file. If the change affects what a skill
(`.opencode/skills/`) describes, update the skill too — stale skills waste tokens.

**Rust**: Edition 2021, `anyhow::Result` (app) / `thiserror` (lib), no `unwrap()`
outside tests, Tokio, workspace deps, `#[cfg(test)]` for new features.

**Lua**: `vim.api.*` conventions, `local M = {} ... return M` exports, HTTP/SQL
isolated, shared state in `state.lua`.

**SQL isolation**: share only at infra layer — `state.lua` (`.sql` ns),
`init.lua` (filetype dispatch), `executor.rs` (Protocol enum), `ftdetect/poste.vim`
(ext → filetype). Changing HTTP must not affect SQL and vice versa.

## References

| Want | Go to |
|------|-------|
| Complete file index | `docs/dev/file-index.md` |
| Architecture overview | `docs/dev/architecture-overview.md` |
| Build & test commands | `docs/dev/testing.md` |
| HTTP user syntax | `docs/user/http/syntax.md` |
| SQL syntax & config | `docs/user/sql/quick-reference.md` |
| HTTP TDD guide | `docs/dev/http/tdd-guide.md` |
| SQL design | `docs/dev/sql/design.md` |
| Progress tracking | `PROGRESS.md` |