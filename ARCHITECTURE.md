# Poste Architecture

## Overview

Poste has two runtime modes:

1. **CLI** (`poste run`) — standalone command-line tool
2. **Neovim plugin** — Lua plugin that calls the CLI binary (planned)

Both modes share the same core pipeline:

```
Request File (.http/.sql/.redis)
    │
    ▼
┌──────────────┐     ┌─────────────┐
│  Parser      │ ◄── │ Environment │
│  (poste-core)│     │ (env.json)  │
└──────┬───────┘     └─────────────┘
       │
       │  Request { protocol, connection, body }
       ▼
┌──────────────┐
│  Executor    │
│  (poste-exec)│
└──────┬───────┘
       │
       │  Response { status, body, headers }
       ▼
┌──────────────┐
│  CLI output  │  or  Neovim buffer
└──────────────┘
```

## Crate Details

### poste-core

Pure logic, no I/O. Responsible for:

1. **Environment loading** — Parse `.reqq/env.json`, select active environment
2. **Request parsing** — Split file into blocks by `###`, extract the block at cursor line
3. **Variable substitution** — Replace `{{var}}` patterns with environment values
4. **Connection extraction** — Parse `@connection` directives from request block headers

Key types:
- `Environment` — HashMap of env_name → HashMap of var_name → value
- `Parser` — Holds env vars, provides `parse_at_line(content, line_num) -> Request`
- `Request` — { name, protocol, connection, body }
- `Protocol` — enum { Http, Redis, Mysql, Postgres, Mongodb, Amqp }

### poste-exec

Async I/O. Responsible for:

1. **Protocol dispatch** — Route request to the correct executor
2. **Connection management** — Parse connection URLs, establish connections
3. **Request execution** — Send the request, collect the response
4. **Response formatting** — Convert raw protocol responses to displayable format

Key types:
- `Executor` — Static dispatch: `execute(&Request) -> Response`
- `Response` — { status, body, headers } (will be protocol-specific in the future)

### poste-cli

Thin CLI wrapper. Responsible for:

1. Argument parsing (clap derive)
2. File I/O (read request file, find env.json)
3. Orchestration (load env → parse → execute → print)

### Neovim Plugin (planned)

Lua code that:

1. Detects request file types (.http, .sql, .redis, .mongo)
2. Provides keymaps (`<leader>rr`, `[[`, `]]`)
3. Calls `poste` CLI binary with current file + cursor line
4. Opens response in a new buffer with appropriate filetype
5. Manages environment state (`:PosteEnv`)

## Protocol Extension Pattern

Adding a new protocol requires:

1. **poste-core**: Add variant to `Protocol` enum, update protocol detection from file extension
2. **poste-exec**: Add `execute_<proto>()` method to `Executor`, add client dependency to Cargo.toml
3. **Neovim plugin**: Add filetype detection for new extension, add response formatting

## Design Decisions

### Why Neovim plugin + CLI (not pure TUI)?

The author's core requirement is keyboard-driven file editing with request execution. Neovim already provides world-class file editing, text selection, search, and buffer management. Reimplementing this in a Rust TUI would be 10x the work for an inferior result.

### Why per-protocol file extensions (not single file)?

- Syntax highlighting works naturally (SQL files get SQL highlighting)
- Parsers are simpler (no need to detect protocol per block)
- Different protocols have different connection semantics
- Team collaboration: DBAs work on .sql, frontend devs on .http

### Why JetBrains-style env.json?

- Familiar to JetBrains users (large target audience)
- Simple mental model: one file, all environments, all variables
- No hidden magic, no auto-matching, no fallback chains
- Easy to understand, easy to debug

### Why `@connection` in file headers?

- Explicit over implicit — the user always knows where a request goes
- Variables in connection URLs enable environment switching
- One connection per file keeps things simple
- File header is a natural place for metadata
