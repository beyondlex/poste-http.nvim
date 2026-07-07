# OpenAPI / Swagger / Postman Import Plan

> TDD-driven import feature: convert OpenAPI 3.x, Swagger 2.0, and Postman Collection exports to Poste-native `.http` file trees.

## Overall Architecture

```
User Interaction Layer (Neovim Lua)
  poste.http.import_openapi    ← Three new Lua modules, reusing finder component
  poste.http.import_swagger       File/directory selection
  poste.http.import_postman
       │
       │ Calls CLI
       ▼
CLI Layer (crates/poste-cli)
  poste import openapi <file> --out <dir>    ← New import subcommand
  poste import swagger <file> --out <dir>
  poste import postman <file> --out <dir>
       │
       ▼
Core Conversion Layer (crates/poste-core)
  src/import/
    ├── mod.rs          ← ImportResult + SpecImporter trait + common types
    ├── openapi.rs      ← OpenAPI 3.x parser → .http conversion
    ├── swagger.rs      ← Swagger 2.0 → internal OAS3 → reuse openapi.rs
    └── postman.rs      ← Postman Collection v2.1 parser
```

### Layer Responsibilities

| Layer | Responsibility | Test Method |
|-------|---------------|-------------|
| **Rust Core** | Pure conversion logic, spec → in-memory .http file tree | `cargo test` unit tests |
| **Rust CLI** | clap subcommands + file I/O + disk write | Integration tests |
| **Lua UI** | Finder file/directory selection → call CLI → show results | Manual verification |

### Dependencies

```toml
# crates/poste-core/Cargo.toml
openapiv3 = "2.0"         # OpenAPI 3.x structured types
serde_yaml = "0.9"        # YAML parsing
```

## Output File Structure

### Input: OpenAPI spec

```yaml
openapi: "3.0.0"
info:
  title: Petstore API
servers:
  - url: https://api.petstore.com/v1
paths:
  /pets:
    get:
      operationId: listPets
      parameters:
        - in: query, name: limit, schema: { type: integer }
    post:
      operationId: createPet
      requestBody:
        content:
          application/json:
            example: { "name": "Fluffy" }
  /pets/{petId}:
    get:
      operationId: getPetById
```

### Output: .http file tree

```
api/
├── env.json
├── pets.http                 # tag: pets
│   ├── @base_url = {{base_url}}
│   ├── ### listPets — GET /pets
│   │   GET {{base_url}}/pets?limit={{limit}}
│   ├── ### createPet — POST /pets
│   │   POST {{base_url}}/pets
│   │   Content-Type: application/json
│   │   {"name": "Fluffy"}
│   └── ### getPetById — GET /pets/{petId}
│       GET {{base_url}}/pets/{{petId}}
└── _index.http
    ├── import ./pets.http as pets
    └── import ./store.http as store
```

### OpenAPI Mapping Rules

| OpenAPI | .http Representation |
|---------|---------------------|
| `info.title` | Directory name (configurable) |
| `servers[0].url` | `@base_url = {{base_url}}` + `env.json` entry |
| `GET /pets/{petId}` | `GET {{base_url}}/pets/{{petId}}` |
| `parameters[].in: query` | Append `?key={{val}}` to request line |
| `parameters[].in: header` | `Header-Name: {{paramName}}` after request line |
| `parameters[].in: path` | `{{paramName}}` in URL + `@paramName` file variable |
| `requestBody` example | Inline JSON body, dynamic fields as `{{var}}` |
| `security[].apiKey` | `Authorization: {{api_key}}` template + `env.json` placeholder |

## Implementation Plan (TDD, 18 Steps)

### Phase 0: Infrastructure (Steps 0–2)

**Step 0** — Add Rust dependencies (`openapiv3`, `serde_yaml`)

**Step 1** — Define `ImportResult`, `HttpFile`, `SpecImporter` trait

**Step 2** — Add `poste import` CLI subcommand framework (3 subcommands + disk write)

### Phase 1: OpenAPI 3.x (Steps 3–7)

**Step 3** — Core converter: path grouping + basic request generation

**Step 4** — Parameter handling: query → URL query string, header → header, path → placeholder

**Step 5** — RequestBody + Example handling

**Step 6** — Security/Auth handling

**Step 7** — env.json generation

### Phase 2: Swagger 2.0 (Steps 8–9)

**Step 8** — Swagger → OpenAPI 3 in-memory converter (reuse OAS3 converter)

**Step 9** — Swagger CLI integration

### Phase 3: Postman Collection (Steps 10–12)

**Step 10** — Postman Collection v2.1 parser (independent from OpenAPI)

**Step 11** — Postman body conversion

**Step 12** — Postman script conversion

### Phase 4: Neovim Lua UI (Steps 13–15)

**Step 13** — Register three `:PosteImport*` user commands

**Step 14** — Reuse SQL import/export finder components for file/directory selection

**Step 15** — CLI call + result feedback

### Phase 5: Integration Tests (Steps 16–18)

**Step 16** — Real-world spec end-to-end tests

**Step 17** — Edge cases: invalid input, huge specs, special characters, empty collections

**Step 18** — Auto-generate `_index.http` master file, handle existing output directory warnings

## File Checklist

### New Rust

| File | Step | Description |
|------|------|-------------|
| `crates/poste-core/src/import/mod.rs` | 1 | ImportResult, HttpFile, SpecImporter trait |
| `crates/poste-core/src/import/openapi.rs` | 3–7 | OpenAPI 3.x converter |
| `crates/poste-core/src/import/swagger.rs` | 8 | Swagger 2.0 → OAS3 converter |
| `crates/poste-core/src/import/postman.rs` | 10–12 | Postman Collection converter |
| `crates/poste-core/src/import/tests/mod.rs` | 0–18 | All unit tests |

### New Lua

| File | Step | Description |
|------|------|-------------|
| `lua/poste/http/import_openapi.lua` | 13–15 | Neovim UI: OpenAPI |
| `lua/poste/http/import_swagger.lua` | 13–15 | Neovim UI: Swagger |
| `lua/poste/http/import_postman.lua` | 13–15 | Neovim UI: Postman |

### Modified Files

| File | Step | Change |
|------|------|--------|
| `crates/poste-core/Cargo.toml` | 0 | Add openapiv3, serde_yaml |
| `crates/poste-core/src/lib.rs` | 1 | `pub mod import` |
| `crates/poste-cli/src/main.rs` | 2 | Add Import subcommand enum + dispatch |
| `lua/poste/init.lua` | 13 | Register 3 user commands |

## Implementation Order

```
Step 0  →  Infrastructure + dependencies
Step 1  →  ImportResult + SpecImporter trait
Step 2  →  CLI subcommand framework + output write
──────────  Skeleton complete ═══
Step 3  →  OpenAPI: path/method/request line
Step 4  →  OpenAPI: parameters (query/header/path)
Step 5  →  OpenAPI: RequestBody + Example
Step 6  →  OpenAPI: Security/Auth
Step 7  →  OpenAPI: env.json generation
──────────  OpenAPI complete ═══
Step 8  →  Swagger: 2.0 → OAS3 converter
Step 9  →  Swagger: CLI integration
──────────  Swagger complete ═══
Step 10 →  Postman: basic parsing
Step 11 →  Postman: body conversion
Step 12 →  Postman: script conversion
──────────  Postman complete ═══
Step 13 →  Lua command registration
Step 14 →  Lua: finder file/directory selection
Step 15 →  Lua: CLI call + result feedback
──────────  Neovim UI complete ═══
Step 16 →  Real spec end-to-end tests
Step 17 →  Edge case handling
Step 18 →  Incremental dev aids
──────────  Acceptance ═══
```

## References

- SQL Import: `lua/poste/sql/import.lua` — finder file selection pattern
- SQL Export: `lua/poste/sql/export.lua` — finder directory selection pattern
- Curl Import: `lua/poste/http/curl.lua` — existing single-request import
- HTTP Formatter: `crates/poste-core/src/formatter.rs` — .http file Region definitions
- CLI Structure: `crates/poste-cli/src/main.rs` — clap subcommand patterns
