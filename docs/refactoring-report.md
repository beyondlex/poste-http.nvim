# Refactoring Report: Full Repository Scan

**Date:** 2026-06-10
**Scope:** All Rust files in `crates/` and all Lua files in `lua/poste/`
**Skill:** `poste-refactor`

---

## Baseline

- **Tests**: Tests do **not** compile — 9 pre-existing errors in `sql_introspect.rs` test code (`IntrospectType::from_str()` should be `parse_str()`)
- **Clippy**: 1 warning (`collapsible_match` in `tokenizer.rs:312`)
- **Target**: All Rust files in `crates/poste-core/`, `crates/poste-exec/`, `crates/poste-cli/` and all Lua files in `lua/poste/`

> ⚠️ `cargo check` (lib) and `cargo clippy` were blocked by auto-mode permissions — errors detected via manual inspection of test code.

---

## Bad Smells Found

### 🟥 HIGH Severity

| # | File:Line | Smell | Evidence |
|---|-----------|-------|----------|
| 1 | `sql_introspect.rs:770-820` | Test compilation errors | 9 uses of `IntrospectType::from_str(...)` — no such method exists; should use `parse_str()?` |
| 2 | `sql_executor.rs:260-493` | Function >50 lines | `pg_value_to_json()` is **234 lines** — enormous match arm on Postgres type OIDs |
| 3 | `sql_executor.rs:500-736` | Function >50 lines + **Duplicate code** | `mysql_value_to_json()` is **237 lines** — structurally identical to `pg_value_to_json()` with different type names. ~90% duplicate pattern |
| 4 | `sql_ddl.rs:39-598` | Function >50 lines | `column_def_sql()` is **560 lines** — huge function dispatching across 3 dialects |
| 5 | `lua/poste/init.lua` | Module >300 lines | **1448 lines** — very large module mixing setup, commands, and goto logic |
| 6 | `lua/poste/init.lua:325-709` | Function >30 lines | `M.goto_definition()` is **385 lines** — mixes SQL/HTTP symbol resolution |
| 7 | `lua/poste/init.lua:921-1448` | Function >30 lines | `M.setup()` is **528 lines** — enormous setup/config function |
| 8 | `lua/poste/http/completion.lua` | Module >300 lines | **1330 lines** — very large completion module |

### 🟨 MEDIUM Severity

| # | File:Line | Smell | Evidence |
|---|-----------|-------|----------|
| 9 | `sql_executor.rs:791-937` | Function >50 lines | `build_response()` is **147 lines** |
| 10 | `sql_executor.rs:94-247` | Function >50 lines | `translate_pg_mysql_compat()` is **154 lines** |
| 11 | `sql_connection.rs:199-467` | Function >50 lines | `find_connections_json()` is **269 lines** |
| 12 | `main.rs:353-481` | Function >50 lines | `handle_context_command()` is **129 lines** |
| 13 | `sql_parser.rs:47-243` | Function >50 lines | `strip_directives()` is **~197 lines** |
| 14 | `lua/poste/init.lua:52-299` | Function >30 lines | `M.run_request()` is **248 lines** |
| 15 | `lua/poste/init.lua:710-908` | Function >30 lines | `M.goto_references()` is **199 lines** |
| 16 | `http/completion.lua:846-987` | Function >30 lines | `get_items_for_context()` is **142 lines** |
| 17 | `http/completion.lua:1023-1198` | Function >30 lines | `M.new()` is **176 lines** |
| 18 | `sql_context/tokenizer.rs:312` | Clippy warning | `collapsible_match` — can simplify if-into-match |

### 🟩 LOW Severity

| # | File:Line | Smell | Evidence |
|---|-----------|-------|----------|
| 19 | `sql_parser.rs:82,101` | `unwrap()` in production | `chars.next().unwrap()` — safe but could panic on empty/odd input |
| 20 | `main.rs:164,173,493` | `unwrap()` in production | `parent().unwrap()`, `to_str().unwrap()` — mostly safe but should use `?` |
| 21 | `env.rs:29` | `unwrap()` in production | `Regex::new(...).unwrap()` — infallible on static regex |
| 22 | `sql_context/statements.rs:13` | `unwrap()` in production | `offsets.last().unwrap()` — safe if `lines` is non-empty |
| 23 | `main.rs:488-554` | Function >50 lines | `load_env_vars()` is **67 lines** |
| 24 | `http/completion.lua:724-812` | Function >30 lines | `detect_context()` is **89 lines** |

---

## Risk Assessment

| Risk | Changes |
|------|---------|
| **Low** | #1 (test fix — pure mechanical replacement), #5 (clippy lint — trivially safe), #19-22 (unwrap replacements in safe paths) |
| **Medium** | #2-3 (row→JSON extraction — large refactor, must preserve all type mappings exactly), #4 (DDL column_def_sql — per-dialect dispatch), #5-8 (Lua module splits — require paths must be updated) |
| **High** | #3 specifically (pg vs mysql value conversion — any mismatch breaks SQL output for all Postgres/MySQL queries) |

---

## Noteworthy Observations

- `sqlite_value_to_json()` (lines 750-790) is only **42 lines** and uses a simpler try-each-type approach rather than match-on-OID — it does NOT share the duplicate pattern of pg/mysql converters
- The `DdlGenerator` trait in `sql_ddl.rs` already defines per-dialect structs (`PostgresDdl`, `MysqlDdl`, `SqliteDdl`) but `column_def_sql()` is a standalone free function that dispatches internally instead of being a trait method
- `lua/poste/init.lua` and `lua/poste/http/completion.lua` are the two largest Lua modules — both are strong candidates for splitting following the project's established submodule pattern (see `sql/init.lua` → `statement.lua` + `introspect.lua`)
- No `todo!()`, `unreachable!()`, `expect("")`, or mixed HTTP/SQL logic was found
- No unused imports detected
