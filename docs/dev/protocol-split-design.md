# Protocol Split Design: HTTP ↔ SQL

> Splitting the current monorepo into two independent projects — `poste.nvim` (HTTP + Redis) and `poste-sql.nvim`.
>
> Status: **Proposal** · Last updated: 2026-07-21

---

## Motivation

HTTP and SQL share little commonality at the feature level. Keeping them in one repo creates friction:

1. **Shared-file coupling** — `lua/poste/init.lua` unconditionally loads SQL during `setup()`, even for HTTP-only users
2. **Dispatch entanglement** — `buffer_setup.lua`, `indicators.lua`, and help windows must understand both protocols
3. **Uneven release cycles** — HTTP evolves faster than SQL; bundling them forces SQL users to take HTTP changes and vice versa
4. **Cognitive overhead** — contributors must understand the full project to modify shared files
5. **Plugin load cost** — SQL modules (~20+ files) load on every Neovim startup even if user never opens `.sql`

---

## Current Architecture

```
poste/                          # Single repo
├── lua/poste/
│   ├── init.lua                ← Coupled: loads HTTP + SQL unconditionally
│   ├── state.lua               ← Shared: keymaps, config, M.sql namespace
│   ├── buffer_setup.lua        ← Coupled: dispatches to SQL via filetype check
│   ├── indicators.lua          ← Shared: imports poste.http.cache (reverse coupling)
│   ├── select.lua              ← Shared: generic picker
│   ├── help.lua                ← Coupled: shows HTTP and SQL keymaps together
│   ├── constants.lua           ← Shared
│   ├── util.lua                ← Shared
│   ├── install.lua             ← Shared
│   ├── cli.lua                 ← Shared
│   ├── http/                   ← HTTP protocol Lua
│   └── sql/                    ← SQL protocol Lua
├── crates/
│   ├── poste-core/             ← Shared: Protocol enum, parser, request.rs
│   ├── poste-exec/             ← Shared: executor.rs + sql_executor/
│   └── poste-cli/              ← Shared: single binary
├── ftdetect/poste.vim          ← Coupled: .http + .redis + .sql + .sqlite
├── syntax/                     ← Split: poste_http.vim + poste_sql.vim (already separate)
└── plugin/poste.lua            ← Shared: calls require("poste").setup()
```

### Specific coupling points

| Point | File | Problem |
|-------|------|---------|
| CP1 | `lua/poste/init.lua:55` | `require("poste.sql.init").setup(opts)` — always loads SQL |
| CP2 | `lua/poste/init.lua:175-225` | Single autocmd block handles `.http`, `.redis`, `.sql`, `.sqlite` |
| CP3 | `lua/poste/buffer_setup.lua:35-40` | `goto_definition` keymap checks filetype and dispatches to SQL |
| CP4 | `lua/poste/indicators.lua:86` | `require("poste.http.cache")` — shared module depends on HTTP |
| CP5 | `lua/poste/help.lua` | Single help window shows both HTTP and SQL keymaps |
| CP6 | `lua/poste/state.lua:222-241` | `M.sql` namespace lives in shared state file |
| CP7 | `lua/poste/http/run.lua:533-536` | HTTP run module imports SQL init |
| CP8 | `crates/poste-exec/src/executor.rs` | Single dispatch routes to HTTP, Redis, and SQL |
| CP9 | `crates/poste-cli/src/run.rs` | Single `execute()` function handles all protocols |
| CP10 | `crates/poste-core/src/request.rs` | `Protocol` enum unifies all protocols in one type |
| CP11 | `ftdetect/poste.vim` | Single file sets filetypes for all protocols |

---

## Target Architecture

### Option A: Core + SQL Plugin (Recommended)

```
poste.nvim (monorepo)           poste-sql.nvim (separate repo)
├── lua/poste/                  ├── lua/poste/sql/
│   ├── init.lua                │   ├── init.lua (was poste.sql.init)
│   ├── state.lua               │   ├── buffer.lua
│   ├── constants.lua           │   ├── completion.lua
│   ├── select.lua              │   ├── context.lua
│   ├── indicators.lua          │   ├── connections.lua
│   ├── buffer_setup.lua        │   ├── db_browser/
│   ├── util.lua                │   ├── export.lua
│   ├── install.lua             │   ├── format.lua
│   ├── cli.lua                 │   ├── editor.lua
│   ├── help.lua                │   ├── import.lua
│   ├── error.lua               │   ├── introspect.lua
│   └── http/                   │   ├── statement.lua
│       ├── init.lua            │   ├── syntax.lua
│       ├── run.lua             │   └── ...
│       ├── format.lua          ├── ftdetect/ (.sql only)
│       └── ...                 ├── syntax/ (poste_sql.vim)
├── ftdetect/ (.http/.redis)    ├── plugin/poste-sql.lua
├── syntax/ (poste_http.vim)    └── depends: poste.nvim (shared infra + binary)
├── plugin/poste.lua
└── crates/ (unchanged)
    ├── poste-core/
    ├── poste-exec/
    └── poste-cli/
```

**Key design decisions:**

1. **Rust binary stays monolithic** — `poste` binary compiles all protocols. SQL plugin users just need the same binary. Splitting Rust would mean duplicating `poste-core` and maintaining two CI pipelines for negligible gain.

2. **Shared Lua stays in `poste.nvim`** — `state.lua`, `select.lua`, `indicators.lua`, `util.lua`, `cli.lua`, `install.lua`, `constants.lua`, `error.lua` are genuinely protocol-neutral. SQL plugin depends on them.

3. **SQL plugin uses `require("poste.*")` paths** — no path aliasing needed. The `poste.nvim` plugin must be on `rtp` for SQL plugin to work.

4. **`poste-sql.nvim` only ships `lua/poste/sql/`** — its `plugin/poste-sql.lua` calls `require("poste.sql.init").setup()` which is now moved from `poste.nvim` to `poste-sql.nvim`.

### Option B: Two Independent Plugins (Alternative)

Each plugin duplicates shared Lua code. Appropriate if zero external dependency is critical.

```
poste-http.nvim                 poste-sql.nvim
├── lua/poste/                  ├── lua/poste/
│   ├── init.lua                │   ├── init.lua
│   ├── state.lua  (copy)       │   ├── state.lua   (copy)
│   ├── constants.lua (copy)    │   ├── constants.lua (copy)
│   ├── select.lua   (copy)     │   ├── select.lua   (copy)
│   ├── indicators.lua (copy)   │   ├── indicators.lua (copy)
│   ├── util.lua    (copy)      │   ├── util.lua    (copy)
│   ├── install.lua (copy)      │   ├── install.lua (copy)
│   ├── cli.lua     (copy)      │   ├── cli.lua     (copy)
│   ├── help.lua    (copy)      │   ├── help.lua    (copy)
│   ├── error.lua   (copy)      │   ├── error.lua   (copy)
│   └── http/                   │   └── sql/
├── ftdetect/                   ├── ftdetect/
├── syntax/                     ├── syntax/
├── plugin/poste.lua            ├── plugin/poste.lua
└── crates/ (same binary)       └── crates/ (same binary)
```

**Not recommended** — ~10 shared files duplicated, drift inevitable.

---

## Migration Plan

### Phase 1: Decouple (within current repo)

Remove all cross-coupling between HTTP and SQL code without changing the repo structure.

| Step | File | Change |
|------|------|--------|
| D1 | `lua/poste/init.lua` | Remove `require("poste.sql.init").setup(opts)`. SQL sets up its own autocmds via `plugin/poste-sql.lua` |
| D2 | `lua/poste/init.lua:175-225` | Split autocmd: `.sql`/`.sqlite` handled by SQL plugin's `ftdetect/` + `plugin/` |
| D3 | `lua/poste/buffer_setup.lua:35-40` | Remove SQL dispatch from `goto_definition`. SQL plugin installs its own keymap |
| D4 | `lua/poste/indicators.lua:86` | Remove `require("poste.http.cache")`. Move that logic into HTTP-specific path |
| D5 | `lua/poste/help.lua` | Split into `http/help.lua` and `sql/help.lua`. Shared help shows only what's installed |
| D6 | `lua/poste/state.lua:222-241` | Move `M.sql` namespace into `lua/poste/sql/state.lua` (loaded by SQL plugin) |
| D7 | `lua/poste/http/run.lua:533-536` | Remove SQL delegation. SQL plugin handles its own `run_request` |
| D8 | `ftdetect/poste.vim` | Remove `.sql`/`.sqlite` entries. Handled by SQL plugin's own `ftdetect/` |

After D1–D8, `poste.nvim` loads **zero** SQL modules. SQL modules only load when user opens a `.sql` file and SQL plugin is installed.

**Status: ✅ Complete (2026-07-21)** — All 8 decoupling steps implemented. All 519 Rust tests pass; all Lua tests pass (1 pre-existing image preview failure unrelated).

### Phase 2: Extract SQL Repo

**Status: ✅ Complete (2026-07-21)** — SQL files extracted to `poste-sql.nvim` at `/Users/lex/code/github/poste-sql.nvim/`.

1. Created `poste-sql.nvim` repo with `lua/poste/sql/` subtree
2. Added `plugin/poste-sql.lua` — checks for poste.nvim, then calls `require("poste.sql.init").setup()`
3. Added `ftdetect/poste_sql.vim` — sets filetype for `.sql` and `.sqlite`
4. Copied `syntax/poste_sql.vim`, `syntax/poste_dataset.vim`, `ftplugin/poste_sql.vim`
5. Removed `lua/poste/sql/` from `poste.nvim` repo
6. Removed `syntax/poste_sql.vim`, `syntax/poste_dataset.vim`, `ftplugin/poste_sql.vim` from `poste.nvim`
7. Removed `tests/sql/`, `docs/dev/sql/`, `docs/user/sql/` from `poste.nvim`
8. Cleaned up `poste.nvim` init.lua — removed `poste_sql` from `poste_status()`
9. Updated `architecture-overview.md` and `file-index.md` to reflect split

### Phase 3: Shared Infra Cleanup

After the split, prune `poste.nvim`:

- `state.lua` — remove `M.sql` namespace, remove SQL keymap sections
- `init.lua` — remove `poste_sql`/`poste_sqlite` from `poste_status()` check
- `help.lua` — show only HTTP + Redis keymaps
- `buffer_setup.lua` — remove SQL filetype dispatch

---

## Rust Side: No Split

The Rust binary stays monolithic for these reasons:

1. **Dependency graph is already clean** — `sql_executor/` is a separate module, zero imports from `executor.rs`
2. **No compile-time conflict** — sqlx and curl-rust coexist without issues
3. **CI cost** — one binary = one compile, one release artifact
4. **User experience** — both plugins use `:PosteUpdate` to get the same binary

The only Rust change needed: ensure `poste run` doesn't require SQL libraries when running HTTP requests (it already doesn't — dispatch is purely based on `Protocol` enum).

---

## Impact Analysis

### What breaks

| User scenario | Impact | Mitigation |
|---------------|--------|------------|
| Has both `.http` and `.sql` files | Must install both plugins | Clear README, single install command via lazy.nvim spec |
| Uses `require("poste.sql.*")` in custom scripts | Works if SQL plugin is installed | Error message if missing |
| Autocmds referencing `poste_sql` filetype | Unaffected | Filetype registration moved to SQL plugin |
| CI / test scripts | `tests/run.sh` must cover both repos | Each repo has its own tests |

### What improves

| Metric | Before | After |
|--------|--------|-------|
| Plugin load time (HTTP-only user) | Loads ~20 SQL modules | Zero SQL modules |
| Plugin load time (SQL-only user) | Loads ~30 HTTP modules | Zero HTTP modules |
| Shared-file touch conflicts | `init.lua` changed by both | Each repo owns its `init.lua` |
| Release cycle | Lockstep | Independent |
| New contributor onboarding | Must understand all protocols | Only needs to understand one |

### Compat scenarios

Users who want both install:

```lua
-- lazy.nvim
{
  "beyondlex/poste.nvim",
  opts = {},
  dependencies = {
    "beyondlex/poste-sql.nvim",  -- optional
  },
}
```

---

## Related Documents

- [Architecture Overview](./architecture-overview.md) — current layered architecture
- [Refactoring Plan](./refactoring-plan.md) — F1-F8 architecture debt remediation
- [HTTP Dev Docs](./http/README.md)
- [SQL Dev Docs](./sql/README.md)
- [File Index](./file-index.md)

---

*Protocol split design — Last updated: 2026-07-21*