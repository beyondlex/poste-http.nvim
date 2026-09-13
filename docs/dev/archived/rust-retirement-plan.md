# Rust Retirement Plan

> ✅ **All phases completed.** The Rust CLI dependency has been eliminated from
> `poste-http.nvim`. HTTP requests are now parsed, resolved, formatted, and executed
> entirely in Lua, using tree-sitter as the single parse authority and curl as the
> sole subprocess.
>
> See [Architecture Overview](./architecture-overview.md) for the current architecture.

---

## Target architecture (achieved)

```
Lua orchestration → curl subprocess → HTTP
```

No Rust. One language. One parse authority (tree-sitter). One variable resolver.

## Migration status

### Phase 0: Safety net — Contract tests for Rust output ✅

- Golden fixtures for `run --json`, `run --describe`, `resolve --format content`, `resolve --format curl`
- Lua contract tests validate fixture shapes
- Integration tests compare CLI output against fixtures (skipped when binary unavailable)

### Phase 1: Tree-sitter as single parse authority ✅

- `describe.lua` uses `vim.treesitter.get_string_parser` as primary path
- CLI fallback preserved for environments without the tree-sitter parser
- `describe_content()` returns same `BlockMeta[]` shape as before

### Phase 2: Variable resolver in Lua ✅

- `lua/poste-http/http/vars.lua` — `VarResolver` with 7-layer priority chain
- Magic var resolution (`$timestamp`, `$uuid`, `$date`, `$randomInt`)
- Iterative `{{var}}` substitution (up to 20 iterations)
- `build_resolver_from_state()` — builds resolver from buffer + state
- `collect_file_vars()` / `collect_block_vars()` — extract `@var` definitions
- `load_env_vars()` — walk up directories for `env.json`
- Removed `poste resolve` calls from `copy.lua`, `nav.lua`, `run.lua`

### Phase 3: Direct curl execution ✅

- `curl_exec.lua` — build curl args, spawn via `jobstart`, temp file management
- `response_parser.lua` — parse `-D` headers, status, cookies, stderr verbose
- `file_include.lua` — expand `< path` directives in body
- `run.lua` no longer calls `poste run` — uses `curl_exec.execute()` directly

### Phase 4: Formatter in Lua ✅

- `format_file.lua` — tree-sitter based `.http` file formatter
- `PosteHttpFormat` command in `init.lua` uses Lua formatter, no longer needs `poste fmt`

### Phase 5: Import parsers in Lua ✅

- `import_parser.lua` — shared utilities (schema-to-example, `$ref` resolution, `env.json` generation)
- `import_openapi.lua` — pure Lua OpenAPI 3.x parser
- `import_swagger.lua` — pure Lua Swagger 2.0 parser
- `import_postman.lua` — pure Lua Postman Collection v2.1 parser
- All import commands no longer call `poste import`

### Phase 6: Cleanup ✅

- `AGENTS.md` updated to remove Rust CLI references
- Architecture docs updated to reflect Lua-only architecture
- No Rust code in `poste-http.nvim` repository
- No `poste` binary required for HTTP operations
- Fresh install requires only: Neovim, curl, tree-sitter (for grammar)

---

## Dependency graph

```
Phase 0 (contract tests)
  └── protects everything below
Phase 1 (tree-sitter describe)
  └── unblocks Phase 2 (no Rust for block metadata)
Phase 2 (Lua VarResolver)
  └── unblocks Phase 3 (no Rust for variable resolution)
Phase 3 (direct curl)
  └── removes the main Rust dependency
Phase 4 (Lua formatter)
  └── independent, can be done any time after Phase 1
Phase 5 (Lua import)
  └── independent, can be done any time
Phase 6 (cleanup)
  └── after all phases complete
```

Phases 1-3 must be sequential (each builds on the previous).
Phases 4-5 can be done in parallel with Phase 3.

---

## Risk assessment

| Risk | Mitigation |
|------|-----------|
| Tree-sitter grammar misses edge cases | Phase 0 contract tests catch mismatches. Fix grammar before switching. |
| curl output parsing differs from Rust | Phase 0 golden fixtures. Parse the same way Rust does (read `-D` file, stdout, stderr). |
| Binary response handling breaks | Same approach as Rust: detect content-type, save to temp file, return summary. |
| Cookie jar format changes | `-b`/`-c` with Netscape format is stable. Reuse same file path convention. |
| Import parsers miss spec features | Start with the most common subset (REST endpoints, JSON bodies, API key auth). Add edge cases as needed. |
| Performance regression | Lua string operations are fast enough for `.http` files. The bottleneck is curl, not parsing. |