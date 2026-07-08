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

## Design Principles

**Extensibility over speed.** Write code that's easy to extend and maintain
tomorrow. Don't cut corners for a quick win — technical debt compounds fast
in a multi-protocol project.

**Best practices, not over-engineering.** Always seek the right pattern for
the problem. But don't abstract before you have at least two concrete cases.
A simple solution that works is better than a generic one that's unfinished.

**Vim ergonomics first.** Every interaction should feel natural to a Vim user:
- Keyboard-driven, no modal dialogs or mouse requirements
- Consistent keymap patterns across HTTP, SQL, and Redis
- Minimal keystrokes for common operations
- Visual feedback (indicators, winbar, syntax highlights) for every action

## Session Start

At the beginning of a session:
1. Read `AGENTS.md` (this file) — rules and conventions
2. Identify the task protocol via the **Protocol First** table
3. Load the relevant `.opencode/skills/<protocol>/SKILL.md` for file index
4. Read `docs/dev/file-index.md` for quick file lookup
5. Read `LEARNINGS.md` — check if similar issues were solved before
6. Read relevant `docs/` files for the specific feature area

Do NOT scan the entire codebase. Use the file index and skills to load only
what's needed. This saves tokens and avoids confusion.

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

**Learn from mistakes.** When you fix a bug or encounter a non-obvious pitfall,
log it in `LEARNINGS.md`. Use a brief format:

```
- YYYY-MM-DD: <scope> — <one-line problem>. Fix: <one-line fix>. See <file>:<line>.
```

Check `LEARNINGS.md` before starting any task. Similar issues may have been solved
before. This lets the agent self-evolve across sessions.

## General Rules

**Read first, don't guess.** When touching an unfamiliar API (Neovim Lua API,
vim.fn, Rust stdlib, curl args, etc.), search the existing codebase for real
usage before writing new code. If no example exists, read the official docs
or write a minimal test in `tests/` — never assume an API's boundary
behaviors (what happens with NUL bytes, embedded newlines, async timing, nil
values, multi-return, etc.).

**Trace the full call graph.** When modifying a function, search the codebase
for all callers and sibling paths that share the same logic. Every `nvim_buf_set_lines`
needs `sanitize_lines` on input. Every state write needs a corresponding clear.
Every pre-render path must mirror everything the normal path does (not just
treesitter — extmarks, highlights, JSON setup, etc.).

**Write the cleanup first, not last.** Before adding a global/cached state
variable, decide when it gets cleared. State that outlives a single request
will accumulate and cause stale data bugs.

## Known High-Frequency Mistakes

| If you touch... | Also check... |
|----------------|---------------|
| `nvim_buf_set_lines` | All inputs need `sanitize_lines()`; all highlight fns using `#line` as `end_col` need same post-split lines |
| Pre-rendered / cached buffers | Every call from `render_view`, `render_detail`, `prepare_multi_responses`, verbose timer — all must apply both content AND extmarks |
| Global/cached state | Lifecycle: where set, where read, where cleared (before next request!) |
| Lua ↔ Rust data | Field names, types, encoding, special chars (NUL, `###`, `\n`, `\r\n`) — test both directions |
| Job stdout/exit handler | Both `on_stdout` and `on_exit` paths; both chain and non-chain branches |
| Variable injection (pre‑script, global, form) | Adjust `--line`, `block_end`, `block_start` for every line insert |

See `docs/dev/error-patterns-review.md` for full pattern analysis.

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
| Agent learnings | `LEARNINGS.md` |
