# HTTP Quick Reference

> `.http` file syntax cheatsheet

---

## File Structure

```
import ./auth.http                         ← file-level import (multiple allowed)
import ./orders.http as orders

@base_url = https://api.example.com        ← file-level variable
@token = eyJhbGci...

### Get users                              ← request block separator
@page_size = 20                            ← block-level variable
GET {{base_url}}/users?limit={{page_size}}
Authorization: Bearer {{token}}

{                                          ← request body
  "name": "test"
}

> {%                                      ← assertion script
  client.assert(response.status == 200);
%}
```

---

## Variable Types

| Type | Example | Priority | Description |
|------|---------|----------|-------------|
| Import param | `run #Login (@key=val)` | P1 highest | Caller-explicit, overrides everything |
| Block-level | `###` after `@var` | P2 | Scoped to current request block |
| File-level | `@base_url = https://api.com` | P3 | Entire file scope |
| Session | `client.global.set('k','v')` | P4 | Cross-request, set by scripts |
| Script | `request.variables.set('k','v')` | P5 | Script-set, same level as Session |
| Environment | `{{api_base}}` (from env.json) | P6 | Environment config |
| Magic | `{{$timestamp}}` `{{$uuid}}` | P7 lowest | Runtime-generated |
| Cross-request | `{{login.response.body.token}}` | separate | Independent path, response cache |

---

## Request Block Syntax

```
### Request Name
< {% pre-script %}                         ← Pre-request script (optional)
@block_var = value                         ← Block-level variable (optional)
METHOD URL [HTTP/version]                  ← Request line
Header-Key: Header-Value                   ← Headers (multiple allowed)
                                           ← Blank line (required, separates headers from body)
{ "key": "value" }                         ← Request body (optional)
> {% assertion %}                          ← Post-request assertion (optional)
```

---

## Request Methods

`GET` `POST` `PUT` `DELETE` `PATCH` `HEAD` `OPTIONS` `TRACE` `CONNECT`

---

## File Include / Upload

```
# JSON embedding (when Content-Type contains json)
POST /api/data
Content-Type: application/json

< /path/to/payload.json

# File upload (multipart/form-data)
POST /api/upload
Content-Type: multipart/form-data

< /path/to/file.txt
```

---

## Script API

### Pre-request (`< {% %}`)

```javascript
request.variables.set("key", "value");     // Set request variable
request.headers.set("X-Custom", "val");    // Modify request header
request.body = JSON.stringify({});         // Modify request body
client.log("message");                     // Log output
client.global.set("key", "value");         // Global variable (cross-request)
variables.base_url                         // Read @variable
env.api_base                               // Read env.json
```

### Post-request (`> {% %}`)

```javascript
response.status                            // HTTP status code
response.body                              // Response body string
response.headers                           // Response headers
response.latency                           // Response time (ms)
client.test("name", fn);                   // Test case
client.assert(condition, "message");       // Assertion
client.log("message");                     // Log output
```

---

## Cross-File References

```
# Import
import ./auth.http
import ./orders.http as orders

# Execute
run #Login                                 # No alias: searches global
run #orders.ListOrders                     # With alias: searches namespace
run #Login (@token=xyz)                    # Runtime variable override
run ./batch.http                           # Run entire file

# run also supports post-script (> {% %})
run #auth.op_login

> {%
  client.global.set('token', response.body.token)
%}
```

---

## Environment Variables

`env.json`:
```json
{
  "dev": {
    "api_base": "https://dev-api.example.com",
    "db_password": "dev_secret"
  },
  "prod": {
    "api_base": "https://api.example.com"
  }
}
```

Usage: `{{api_base}}` → automatically replaced based on current environment

---

## Commands & Keymaps

| Command / Key | Function |
|---------------|----------|
| `<leader>rr` | Execute current request |
| `]]` | Jump to next request |
| `[[` | Jump to previous request |
| `:PosteEnv` | Show current environment |
| `:PosteEnv <name>` | Switch environment |
| `q` (response buffer) | Close response window |
| `K` (image response) | Inline image preview; fallback to external open |
| `:PosteHttpHistory` | Open request history popup |
| `<C-h>` (history list) | Jump to right detail buffer |
| `<C-l>` (history detail) | Jump to left list buffer |
| `j` / `k` (history list) | Navigate history entries |
| `<CR>` (history list) | Focus detail panel |
| `dd` (history list) | Delete current entry |
| `q` (history popup) | Close history popup |

---

## Formatting Rules (`poste fmt`)

- Ensure a blank line before `###`
- `@var = value`: one space before and after `=`
- Header key: capitalize first letter, one space after colon
- JSON body: auto-pretty-print
- Remove trailing whitespace, collapse excess blank lines

---

## Request History (PosteHttpHistory)

`PosteHttpHistory` provides a near-full-screen floating popup showing all HTTP
request records from the current session, persisted to disk across Neovim sessions.

### Popup Layout

```
┌───────── " Poste HTTP History " ────────────────┐
│ Left List (36 cols)   │ Right Detail (remaining) │
│                       │                          │
│ Get Profile  23:32    │ [Body[H] | Rqst[R]       │
│ Request 3    23:30    │  | Verb[L] | Asserts[A]] │
│ Request 2    22:45    │ ════════════════════════ │
│ Request 1    21:34    │  (response content)      │
│ Login        20:33    │                          │
└───────────────────────┴──────────────────────────┘
```

### Operations

| Action | Location | Effect |
|--------|----------|--------|
| `j` / `k` | Left list | Navigate up/down, auto-update detail |
| `<CR>` | Left list | Jump cursor to right detail buffer |
| `dd` | Left list | Delete current history entry |
| `H` / `R` / `L` / `A` / `S` | Right detail | Switch Body / Rqst / Verb / Asserts / Script tabs |
| `<Tab>` / `<S-Tab>` | Right detail | Cycle through tabs |
| `<leader>j` / `<leader>jc` | Right detail (JSON view) | jq filter / restore |
| `<C-h>` | Right detail | Jump back to left list |
| `<C-l>` | Left list | Jump to right detail |
| `q` | Global | Close history popup |

### Storage

History is kept in the current Neovim session memory and cleared on close.
Max 100 entries. Response bodies over 100KB are truncated automatically.

---

*HTTP Quick Reference — Last updated: 2026-07-06*
