# Poste

**Send requests from files. Keyboard-first. Multi-protocol.**

A Neovim plugin and CLI tool for executing HTTP, Redis, SQL, MongoDB, and AMQP requests from plain text files. Inspired by JetBrains HTTP Client and kulala.nvim, with a focus on keyboard-driven workflows.

## Features

- **File-based requests** — Define requests in `.http`, `.sql`, `.redis`, `.mongo` files
- **Environment variables** — JetBrains-style `env.json` for managing dev/staging/prod
- **Keyboard-first** — All operations accessible without mouse, response buffers are fully editable
- **Multi-protocol** — HTTP, Redis, MySQL, PostgreSQL, MongoDB, RabbitMQ
- **Ocular integration** — Capture requests from Ocular events and save to request files

## Quick Start

### Install

```bash
# Neovim plugin (lazy.nvim)
{
  "beyondlex/poste",
  config = function()
    require("poste").setup()
  end,
}

# CLI
cargo install --path crates/poste-cli
```

### Create a request file

`requests/api.http`:

```http
### List users
GET {{api_base}}/users
Authorization: Bearer ***

### Create user
POST {{api_base}}/users
Content-Type: application/json

{"name": "John", "email": "john@test.com"}
```

`requests/queries.sql`:

```sql
-- @connection postgres://{{db_user}}:***@{{db_host}}:{{db_port}}/{{db_name}}

### Active users
SELECT * FROM users WHERE active = true;
```

### Define environments

`.reqq/env.json`:

```json
{
  "dev": {
    "api_base": "http://localhost:8080",
    "api_token": "dev-token-xxx",
    "db_host": "127.0.0.1",
    "db_port": "5432",
    "db_name": "myapp",
    "db_user": "app_user",
    "db_pass": "local-pass"
  },
  "prod": {
    "api_base": "https://api.example.com",
    "api_token": "prod-token-xxx",
    "db_host": "prod-db.internal",
    "db_port": "5432",
    "db_name": "myapp",
    "db_user": "app_user",
    "db_pass": "***"
  }
}
```

### Execute

In Neovim:
- `<leader>rr` — Execute request at cursor
- `]]` / `[[` — Jump to next/previous request
- `gs` — Show symbol outline with fuzzy search (uses Telescope if available, falls back to `vim.ui.select`)
- `:ReqqEnv dev` — Switch environment

CLI:
```bash
poste run requests/api.http --line 2 --env dev
```

## Completion

Poste provides context-aware completions for `.http` files:

- **HTTP methods** — `GET`, `POST`, `PUT`, etc.
- **Header names** — `Content-Type`, `Accept-Encoding`, `Authorization`, etc.
- **Header values** — `application/json`, `Bearer `, `gzip`, etc.

### blink.cmp (LazyVim default)

Registration is automatic — no extra config needed. Poste registers itself as a blink.cmp provider at setup time.

### nvim-cmp

If you use nvim-cmp instead, buffer-level registration is also automatic. No extra config needed.

### Check status

```vim
:PosteCmpStatus
```

## Architecture

```
poste/
├── crates/
│   ├── poste-core/    # Request parsing, environment management
│   ├── poste-exec/    # Protocol execution (HTTP, Redis, SQL, etc.)
│   └── poste-cli/     # CLI binary
└── lua/
    └── poste/         # Neovim plugin
```

Reuses [Ocular](https://github.com/beyondlex/ocular) protocol parsers for wire-level protocol handling.

## Ocular Integration

In Ocular TUI, press `s` on an event to save it as a request file:

```
Ocular event: SELECT * FROM users WHERE id = 42 (mysql-legacy)
    ↓ press `s`
Appended to: requests/queries.sql
    ↓ open in Neovim
Cursor on new request, <leader>rr to re-execute
```

## License

MIT
