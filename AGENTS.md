# Poste HTTP

File-driven HTTP request executor (Rust CLI + Neovim). `.http` → execute → results in editable buffer.

## Protocol Scope

**HTTP only.** No SQL, no Redis. See [poste.nvim](https://github.com/beyondlex/poste.nvim) for shared infra, [poste-sql.nvim](https://github.com/beyondlex/poste-sql.nvim) for SQL.

| Task mentions | Load |
|---------------|------|
| `.http`, `curl`, `jq`, pre-script, assertion, `{{var}}`, import, env vars, completion, history | HTTP skill `.opencode/skills/http/SKILL.md` |
| Rust CLI (`poste run/conn/introspect/fmt/context`) | `main.rs` in poste.nvim |

## Design Principles

- **Extensibility over speed** — no shortcuts for quick wins
- **Vim ergonomics first** — keyboard-driven, no modal dialogs
- **TDD first** — write test before implementation
- **Bug fix → test** — every bug fix must include a test that would have caught it, to prevent regressions

## Code Conventions

- Lua: `local M = {} ... return M`, `vim.api.*` conventions
- HTTP code in `lua/poste/http/`, shared infra in `poste.nvim`
- No `require("poste.sql.*")` — SQL is a separate repo
- **Module name ownership**: `poste-http.nvim` comes before `poste-sql.nvim` in rtp.
  Never create files under `lua/poste/sql/` — they would shadow `poste-sql.nvim`'s
  modules silently.
- **HTTP grammar ↔ tree-sitter sync**: Any change to HTTP grammar (parser, syntax)
  must be mirrored in the tree-sitter grammar (`tree-sitter-http/grammar.js`) and
  its query files (`highlights.scm`, `injections.scm`, `locals.scm`).

## References

| Want | Go to |
|------|-------|
| **Shared infra (state, cli, select, install, indicators, buffer_setup, help, etc.)** | `../poste.nvim/lua/poste/` — edit there |
| **Rust CLI (crates, build system)** | `../poste.nvim/crates/` — edit there |
| File index | `docs/dev/file-index.md` |
| Architecture | `docs/dev/architecture-overview.md` |
| Build & test | `docs/dev/testing.md` |
| User syntax | `docs/user/http/syntax.md` |
| TDD guide | `docs/dev/http/tdd-guide.md` |
| Agent learnings | `LEARNINGS.md` |