# Poste — Agent Context

## What is Poste?

Poste is a **file-based, keyboard-first, multi-protocol request execution tool**. It lets developers define HTTP requests, SQL queries, Redis commands, and MongoDB operations in plain text files, then execute them from Neovim (primary) or CLI.

Think: JetBrains HTTP Client + kulala.nvim + database query tools, unified under one tool, with keyboard-driven UX as a first-class requirement.

## Origin

The author uses JetBrains IDE's built-in HTTP client, database tools, and kulala.nvim. They all share a pattern: requests defined in files, cursor-based execution. But they have pain points:

- No mouse-free text selection/copy in response panels (JetBrains)
- Fragmented tools for different protocols
- No integration between observability tools and request definitions

Poste solves this by making **Neovim the UI** — responses land in editable buffers where all Vim operations (yank, visual select, search) work natively.

## Companion Project

Poste is designed to integrate with [Ocular](https://github.com/beyondlex/poste) — a middleware traffic visualization tool (also by this author). Ocular observes traffic; Poste sends it. The integration: in Ocular's TUI, press `s` on a captured event to export it as a Poste request file.

## Architecture

```
poste/
├── crates/
│   ├── poste-core/     # Request parsing, env variable substitution
│   ├── poste-exec/     # Protocol execution (HTTP, Redis, SQL, etc.)
│   └── poste-cli/      # CLI binary (`poste` command)
└── lua/
    └── poste/          # Neovim plugin (NOT YET CREATED)
```

### Crate Responsibilities

- **poste-core**: Parses request files, extracts the request at a given cursor line, substitutes `{{variables}}` from environment config. Protocol-agnostic.
- **poste-exec**: Takes a parsed `Request` and executes it against the appropriate protocol. Returns a structured `Response`.
- **poste-cli**: CLI wrapper. Loads env, parses request, calls executor, prints result.

### Planned (Not Yet Built)

- **lua/poste/**: Neovim plugin. Calls the CLI binary, manages response buffers, keymaps.
- **Ocular integration**: A `s` keybinding in Ocular TUI to export events to Poste request files.

## Request File Format

Each protocol uses its natural file extension. Requests within a file are separated by `###`.

### .http (JetBrains HTTP Client compatible)

```http
### Request name
GET {{api_base}}/users
Authorization: Bearer {{api_token}}
Content-Type: application/json

{"key": "value"}
```

### .sql (SQL queries)

```sql
-- @connection postgres://{{db_user}}:{{db_pass}}@{{db_host}}:{{db_port}}/{{db_name}}

### Query name
SELECT * FROM users WHERE active = true;
```

### .redis (Redis commands)

```
# @connection redis://{{redis_host}}

### Command name
GET session:user:42
```

### Connection Declaration

- `-- @connection <url>` (SQL files, `--` comment)
- `# @connection <url>` (Redis/Mongo files, `#` comment)
- HTTP files embed the URL in the request line itself

### Environment Variables

`{{variable_name}}` syntax, replaced at execution time from the current environment.

## Environment Configuration

**`.reqq/env.json`** in project root. JetBrains `http-client.env.json` style — flat env names mapping to variable dictionaries:

```json
{
  "dev": {
    "api_base": "http://localhost:8080",
    "db_host": "127.0.0.1"
  },
  "prod": {
    "api_base": "https://api.example.com",
    "db_host": "prod-db.internal"
  }
}
```

## Supported Protocols

| Protocol | File Extension | Status |
|----------|---------------|--------|
| HTTP | `.http` | ✅ Implemented |
| PostgreSQL | `.sql` | 🔲 Planned |
| MySQL | `.sql` | 🔲 Planned |
| Redis | `.redis` | 🔲 Planned |
| MongoDB | `.mongo` | 🔲 Planned |
| RabbitMQ (AMQP) | `.amqp` | 🔲 Planned |

## Tech Stack

- **Language**: Rust (workspace with multiple crates)
- **Async**: Tokio
- **HTTP Client**: reqwest 0.12
- **CLI**: clap 4 (derive)
- **Serialization**: serde + serde_json
- **Error handling**: anyhow + thiserror
- **Neovim plugin**: Lua (not yet created)

## Build & Run

```bash
cargo build                    # Build all crates
cargo run -- run examples/api.http --line 2 --env dev  # Execute a request
cargo test                     # Run tests (none yet)
```

## Conventions

- Edition: Rust 2021
- Error handling: `anyhow::Result` in application code, `thiserror` in library error types
- No unwraps in non-test code
- Async everywhere (Tokio runtime)
- Workspace-level dependency management

## Current Status

See ROADMAP.md for the full development plan. Currently in **Phase 1** — HTTP requests work end-to-end via CLI. Neovim plugin and database protocols are next.
