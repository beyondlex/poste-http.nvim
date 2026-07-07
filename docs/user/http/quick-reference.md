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

Full keymap reference in [Keymaps](../keymaps.md). Quick overview:

| Command / Key | Function |
|---------------|----------|
| `<leader>rr` | Execute current request |
| `]]` / `[[` | Jump to next/previous request |
| `:PosteEnv [name]` | Show/switch environment |
| `K` | Show variable value / response chain |
| `<leader>rc` | Copy request as curl |
| `<leader>l` | Open request history |
| `q` (response buffer) | Close response window |

For complete keymaps, see [Keymaps Reference](../keymaps.md).

*HTTP Quick Reference — Last updated: 2026-07-06*
