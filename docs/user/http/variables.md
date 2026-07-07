# Variable Resolution in Poste

Poste provides a unified variable system that lets you define, reference, and
override variables across multiple sources. Every `{{variable}}` reference in
a `.http` file resolves through a single, consistent priority chain —
regardless of whether you're inspecting it with `K`, copying as curl, viewing
the Verbose preview, or executing the request.

---

## Quick Reference

```
Priority  Source                          Example
─────────────────────────────────────────────────────────────
 1 (highest)  Import parameters           run #Login (@timeout=30)
 2            Request-local variables     @timeout = 20      (inside ### block)
 3            File-level variables        @timeout = 10      (before first ###)
 4            Session variables           client.global.set('timeout', '5')
 5            Script variables            request.variables.set('timeout', '3')
 6            Environment variables       env.json → { "dev": { "timeout": "2" } }
 7 (lowest)   Magic / built-in            {{$timestamp}}, {{$uuid}}
```

**Scoping rule**: the narrower the scope, the higher the priority.

---

## Variable Sources

### 1. Import Parameters (`run #Name (@key=value)`)

The highest priority. When executing a request from another file via `run`:

```http
import ./auth.http as auth

### Login
run auth#Login (@username=admin, @password=secret, @timeout=30)
```

These override everything — request-local `@var`, file-level `@var`, session
variables, env.json, and magic. They act like function arguments passed to the
imported request.

```http
### In auth.http:
@timeout = 10                              ← file-level default (P3)

### Login
@timeout = 20                              ← request-local default (P2)
POST https://api.example.com/login
Content-Type: application/json

{
  "timeout": {{timeout}}                   ← resolves to 30 (P1 wins)
}
```

### 2. Request-Local Variables (`@var` inside a `###` block)

Defined between the `###` marker and the request line. These act as local
variables scoped to a single request block.

```http
### Get User
@user_id = 42
@include_details = true
GET https://api.example.com/users/{{user_id}}?details={{include_details}}
```

### 3. File-Level Variables (`@var` before the first `###`)

Defined in the file header, available to all request blocks in the file.

```http
@host = https://api.example.com
@api_version = v2

### List Users
GET {{host}}/{{api_version}}/users

### Get User
GET {{host}}/{{api_version}}/users/{{user_id}}
```

### 4. Session Variables (`client.global.set`)

Set via pre- or post-scripts using `client.global.set()`. These persist across
requests within the same Neovim session.

```http
### Login
POST https://api.example.com/login
Content-Type: application/json

{"username": "admin", "password": "secret"}

> {%
  client.global.set('session_token', response.body.token)
  client.global.set('user_id', response.body.user.id)
%}

### Get Profile
GET https://api.example.com/profile/{{user_id}}
Authorization: Bearer {{session_token}}
```

### 5. Script Variables (`request.variables.set`)

Set via pre-scripts using `request.variables.set()`. Also available to
subsequent requests at the same priority level as session variables.

```http
### Pre-script sets a variable
< {%
  request.variables.set('request_id', os.time())
%}
GET https://api.example.com/items?rid={{request_id}}
```

### 6. Environment Variables (`env.json`)

Load the active environment from `env.json`, which is searched upward from
the file's directory.

```json
{
  "dev": {
    "api_base": "https://dev-api.example.com",
    "db_name": "dev_db"
  },
  "prod": {
    "api_base": "https://api.example.com",
    "db_name": "prod_db"
  }
}
```

```http
@host = {{api_base}}     ← file-level (P3) — env.json (P5) not used directly
GET {{host}}/health
```

> **Note**: File-level `@var` takes priority over env.json (P3 > P5), so you
> can define a file-level default that the environment file won't override.

### 7. Magic Variables (Built-in)

Generated at runtime. These have the lowest priority and are used as fallbacks.

| Variable | Description | Example Output |
|----------|-------------|---------------|
| `{{$timestamp}}` | Unix timestamp + random suffix | `1783337325636861` |
| `{{$uuid}}` | Random UUID v4 | `fa973fb4-b7ed-44bd-8d18-e13579a8bb90` |
| `{{$date}}` | Current date (YYYY-MM-DD) | `2026-07-06` |
| `{{$randomInt}}` | Random integer (0–9999999) | `7421539` |

---

## Multi-Line Variables

For longer values, use the block syntax:

```http
@payload =>>>
{
  "name": "test",
  "value": 123
}
<<<

### Create Item
POST https://api.example.com/items
Content-Type: application/json

{{payload}}
```

Supports `{{var}}` references within the value, resolved iteratively.

---

## Transitive (Chained) Resolution

Variables can reference other variables. Resolution is iterative (up to 20
passes) to handle chains:

```http
@base = /api/v1
@endpoint = {{base}}/users

### List Users
GET https://api.example.com{{endpoint}}
```

This resolves in two passes: `{{endpoint}}` → `{{base}}/users` → `/api/v1/users`.

---

## Cross-Request References

References to other request responses (`{{Name.res.body.field}}`) are handled
separately and do NOT participate in the priority chain. They are resolved by
looking up the cached response of the named request.

```http
### Login
POST https://api.example.com/login
Content-Type: application/json

{"username": "admin", "password": "secret"}

### Dashboard
GET https://api.example.com/dashboard/{{Login.response.body.user.id}}
```

See [Request Variables](../../../examples/README_request_variables.md) for
detailed documentation.

---

## Variable Prompt (`<<name`)

Prompt the user for a variable value at execution time:

```http
<<username
<<role [admin, editor, viewer]
POST https://api.example.com/login
Content-Type: application/json

{
  "username": "{{username}}",
  "role": "{{role}}"
}
```

The prompted value is injected as a request-local `@var` (priority 2).

---

## Script API for Variables

### Pre-script (`< {% %}`)

```lua
request.variables.set("key", "value")     -- Set script variable (P5)
client.global.set("key", "value")         -- Set session variable (P4)
client.global.get("key")                  -- Get session variable
variables.key                             -- Read @var (file or request level)
env.key                                   -- Read current env.json value
```

### Post-script (`> {% %}`)

```lua
client.global.set("key", "value")         -- Set session variable (P4)
client.global.get("key")                  -- Get session variable
variables.key                             -- Read @var
env.key                                   -- Read current env.json value
```

---

## How Resolution Works

### CLI-based Resolution

All variable resolution goes through a single resolver in the Rust CLI.
When you press `K` on a `{{variable}}`, copy as curl, or view the Verbose
preview, Poste calls:

```
poste resolve --file request.http --block 42 --var session_id \
  --session-vars '{"session_id":"sess-123"}' \
  --env dev
```

The resolver checks each layer in priority order and returns the first match.

### Unified Priority Chain

```
 Narrow scope ┌──────────────────────────────────────┐ Higher priority
              │  1. Import parameters                │  ← run #Name (@k=v)
              │  2. Request-local @var               │  ← inside ### block
              │  3. File-level @var                  │  ← before first ###
              │  4. Session variables                │  ← client.global
              │  5. Script variables                 │  ← request.variables
              │  6. Environment variables            │  ← env.json
              │  7. Magic (built-in)                 │  ← $timestamp, $uuid...
 Wide scope   └──────────────────────────────────────┘ Lower priority
```

### Cross-Request Refs (separate path)

`{{Login.res.body.token}}` does NOT go through the priority chain. It is
resolved independently by looking up the cached response of the named request.

---

## CLI Usage

The `poste resolve` command provides the same resolution logic used internally:

```bash
# Resolve a single variable (like K key)
poste resolve --file request.http --block 42 --var session_id \
  --session-vars '{"session_id":"sess-123"}' \
  --env dev

# Resolve and format as curl (like <leader>rc)
poste resolve --file request.http --block 42 --format curl \
  --session-vars '{"session_id":"sess-123"}' \
  --env dev

# Resolve full request content (like Verbose preview)
poste resolve --file request.http --block 42 --format content \
  --session-vars '{"session_id":"sess-123"}' \
  --env dev

# With import parameters (highest priority)
poste resolve --file request.http --block 12 --var timeout \
  --import-params '{"timeout":"30"}' \
  --env dev

# Pipe buffer content (for unsaved buffers)
echo '@host = http://localhost:8888
GET {{host}}/health' | poste resolve --stdin --file /tmp/test.http --block 2 --var host
```

### Options

| Option | Description |
|--------|-------------|
| `--file <PATH>` | `.http` file path |
| `--block <LINE>` | Block line number |
| `--var <NAME>` | Resolve a single variable |
| `--format <FORMAT>` | Output: `value`, `content`, `verbose`, `curl` |
| `--import-params <JSON>` | Import parameters `{"key":"val"}` |
| `--session-vars <JSON>` | Session/global variables |
| `--script-vars <JSON>` | Script variables |
| `--env <NAME>` | Environment name (default: `dev`) |
| `--stdin` | Read content from stdin |

---

## Comparison with Other Tools

| Feature | Poste | Kulala | REST Client (VS Code) |
|---------|-------|--------|----------------------|
| Priority layers | 7 (P1–P7) | 3–4 | 3–4 |
| Import params | P1 (highest) | — | — |
| Session vars | P4 (client.global) | — | — |
| Script vars | P5 (request.variables) | — | — |
| Cross-request refs | Separate path | Similar | Similar |
| CLI resolver | `poste resolve` | — | — |
