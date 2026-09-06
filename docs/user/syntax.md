# Poste HTTP File Syntax Reference

> This document defines all supported syntax elements for `.http` / `.rest` files,
> used as a unified reference for completion, highlighting, formatting, and the Lua parser.

## 1. File Structure

```
┌─ import / run directives (file-level, before first ###)
│
├─ @variable definitions (file-level, before first ###)
│
├─ ### Request Block 1
│   │
│   ├─ < {% pre-script %}
│   ├─ @variable definitions (block-level)
│   ├─ Request line (METHOD URL)
│   ├─ Headers
│   ├─ Blank line
│   ├─ Body
│   └─ > {% assertion %}
│
├─ ### Request Block 2
│   └─ ...
│
├─ import / run directives (between blocks, same level as ###)
│
└─ ### Request Block N
```

## 2. Syntax Elements

### 2.1 Comments

```
# Hash comment
```

- Allowed anywhere in the file
- `--` style comments (SQL style) are NOT supported in HTTP files

### 2.2 Variable Definitions

**File-level variables** (before the first `###`):

```
@base_url = https://api.example.com
@token = eyJhbGciOiJIUzI1NiI
```

**Block-level variables** (between `###` and the request line):

```
### Get users
@page_size = 20
GET {{base_url}}/users?limit={{page_size}}
```

**Multi-line variables** (`=>>> ... <<<`):

```
@payload =>>>
{
  "name": "test",
  "value": 123
}
<<<
```

**Rules**:
- Variable name: `@` prefix followed by `\w+` (alphanumeric + underscore)
- Spaces around `=` are optional
- Values can be empty strings
- Block-level variables override file-level variables with the same name

### 2.3 Request Block Separator

```
### Get all users
```

- Starts with three `#` characters
- Followed by an optional request name
- A blank line should precede `###` (formatting rule)
- No trailing `###` needed at end of file

### 2.4 Request Line

```
GET {{base_url}}/users
POST https://api.example.com/data HTTP/1.1
PUT http://localhost:8080/api/items/1
```

**Format**:

```
<METHOD> <URL> [HTTP/<version>]
```

**Supported METHODS** (from `data.lua` `http_methods`):

```
GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, TRACE, CONNECT, SCRIPT, GRAPHQL, GRPC, WEBSOCKET
```

**Rules**:
- METHOD is uppercase
- Supports full URLs and relative paths (with `@base_url`)
- HTTP version is optional, defaults to `HTTP/1.1`

### 2.5 Headers

```
Authorization: Bearer {{token}}
Content-Type: application/json
Accept: application/json
X-Custom-Header: value
```

**Rules**:
- `Key: Value` format
- Key is case-insensitive (recommend capitalizing first letter: `Content-Type`)
- Values can be plain text or `{{}}` references
- Multi-line header values are NOT supported (current limitation)

### 2.6 Blank Line Separator

```
POST /api/data
Content-Type: application/json
                                   ← blank line: headers end, body begins
{
  "name": "test"
}
```

- One blank line between headers and body
- Multiple blank lines are treated as one

### 2.7 Request Body

```
POST /api/data
Content-Type: application/json

{
  "name": "test",
  "value": 123
}
```

**Supported types**:
- Plain text
- JSON (syntax-highlighted when Content-Type contains `json`)
- URL-encoded form data (`key=value&key2=value2`)
- `multipart/form-data` (via `request_vars.lua`)

**File upload in multipart form data** (`< path`):

```
POST /api/upload
Content-Type: multipart/form-data; boundary=----boundary

< /path/to/file.txt
```

**Rules**:
- `<` followed by a space, then the file path
- Path supports absolute paths, `./` relative paths, `~/` home directory
- **Only valid inside `multipart/form-data`** bodies (file upload parts)
- If file is not found, the original line is preserved with a warning

> **Removed**: `< path` for JSON body embedding (e.g., `< /path/to/payload.json` with `Content-Type: application/json`) has been removed. Use Lua import instead: `import ./vars.lua as m` then `{{m.key}}` or `@var = m.key`.

### 2.8 Variable References

```
{{base_url}}
{{token}}
{{$uuid}}
{{login.response.body.token}}
```

**Rules**:
- Wrapped in `{{` and `}}`
- Variable names allow letters, digits, and dots
- Resolution follows a priority chain (see [Variable Resolution](./variables.md) for full details):

| Priority | Source | Example |
|----------|--------|---------|
| P1 (highest) | Import parameters | `run #Login (@timeout=30)` |
| P2 | Block-level @var | Defined between `###` and request line |
| P3 | File-level @var | Defined before first `###` |
| P4 | Session variables | `client.global.set('key', 'val')` |
| P5 | Script variables | `request.variables.set('key', 'val')` |
| P6 | Environment variables | `env.json` → `{{key}}` |
| P7 (lowest) | Magic variables | `$timestamp`, `$uuid` |

**Cross-request references** (`{{RequestName.response.body.path}}`) do **NOT** participate in the priority chain — they are resolved independently via response cache.

See [Variable Resolution in Detail](./variables.md) for complete documentation on all variable sources, magic variables, prompt variables, and transitive resolution.

### 2.9 Pre-request Script

```
< {%
  request.variables.set("key", JSON.stringify(request.body));
  client.log("Pre-processing done");
%}
```

**Single-line format**:

```
< {% client.log("pre-flight"); %}
```

**External script reference**:

```
< ./scripts/preprocess.lua
< ../shared/auth.lua
```

**Rules**:
- Starts with `<` (must be at beginning of line)
- `{% %}` wraps JS/Lua code
- Multi-line: `{%` on its own line, `%}` on its own line
- External script paths start with `./` or `../` and end with `.lua`

**Available API**:

```
request.variables      — Manipulate request variables
request.headers        — Manipulate request headers
request.body           — Read/modify request body
client.log(msg)        — Log output
client.global.set(key, value)  — Global variables (cross-request)
client.global.get(key)
variables.*                — Read @variable definitions (file + block level)
env.*                      — Read current env.json config (not yet implemented)
```

### 2.10 Post-request Assertion

```
> {%
  client.test("Status is 200", function() {
    client.assert(response.status == 200, "Expected 200");
  });
%}
```

**Single-line format**:

```
> {% client.assert(response.status == 200); %}
```

**External script reference**:

```
> ./scripts/validate.lua
```

**Rules**:
- Starts with `>` (must be at beginning of line)
- `{% %}` wraps JS/Lua code
- Multi-line: `{%` on its own line, `%}` on its own line
- External script paths start with `./` or `../` and end with `.lua`

**Available API**:

```
response.status        — HTTP status code
response.body          — Response body string
response.headers       — Response headers
response.latency       — Response time (ms)
client.test(name, fn)  — Test case
client.assert(cond, msg)  — Assertion
client.log(msg)        — Log output
variables.*            — Read @variable definitions (not yet implemented)
env.*                  — Read current env.json config (not yet implemented)
```

### 2.11 Environment Override

```
### request name
@env = production
GET https://prod.example.com/api
```

**Rules**:
- `@env` as a block-level variable, placed between `###` and the request line
- Overrides the currently selected environment
- Defaults to `state.current_env` when not specified
- Currently not implemented

### 2.12 Variable Prompt

```
<<username
<<role [admin, user, guest]
<<item [{{listItems.response.body.items}}]
```

**Rules**:
- `<<` followed by variable name — prompts the user for input at execution time
- Square brackets `[]` provide option lists for selection
- Options can reference other request responses: `[{{ReqName.response.body.field}}]`
- Prompt variables are resolved as `@varname = value` injected into the request block
- Prefix with `# <<varname` to comment out the prompt line

**Implementation status**: Execution ✅ (interactive prompt with option lists), Highlight ✅ (`PostePromptVar`), Completion ❌

### 2.13 File References (import / run)

Compatible with [kulala](https://kulala.app/usage/import-and-run)'s `import` and `run`
mechanism for reusing requests across files.

**Syntax**:

```
import ./auth.http
import ./orders.http as orders

### Get users
GET https://api.example.com/users

run #Login                       ← no alias: searches all unaliased imports

run #orders.ListOrders           ← with alias: searches only that namespace

run #orders.ListOrders (@status=pending)

run ./batch.http (@env=staging)

run ./batch.http
```

**Rules**:

**import basics**
- `import <path>` — imports all named requests from the target file
- Multiple imports can reference the same path, resolved independently
- Supports nesting: imported files can themselves import other files

**import as alias (extended syntax)**
- `import <path> as <alias>` — aliased import with namespace isolation
- Aliases must be unique: `import ./a as ns` then `import ./b as ns` → error
- Alias naming: `\w[\w_]*` (same as `@variable`)

**Alias access syntax**
- `#alias.RequestName` — access a request in an aliased namespace
- Uses `.` as separator, consistent with cross-request refs `{{Name.res.body.x}}`

**Alias and bare name mixing rules**
- Bare `#Login` only searches unaliased imports
- Aliased imports can only be accessed via `#alias.RequestName`
- Duplicate names across unaliased imports: later overrides earlier, warning emitted

**run execution**
- `run <path>` — run all requests in the target file
- `run #Name` — run a specific named imported request
- `run #alias.Name` — run a request in an aliased namespace
- `run #Name (@var=value, ...)` — override variables at runtime
- `run` supports post-scripts/assertions (`> {% ... %}`), same as regular blocks
- Variable overrides apply only to this execution, not the original request

**Variable / directive propagation**
- Imported file-level `@var` merges into the shared scope (same as kulala)
- Variable override priority: run inline `@var` > block-level `@var` > file-level `@var`
- File-level compat directives (`# @kulala-*`) propagate to imported blocks

**Implementation status**: Implemented — `import` (with `as` aliases), `run #Name` / `run #alias.Name` / `run ./path`, inline variable overrides, nesting, and `client.run` orchestration all work. Spec: `tests/http/import_spec.lua`.

### 2.14 Request Orchestration (SCRIPT blocks + `client.run`)

A request block whose request line is `SCRIPT` runs as a script-only block. When
the block also contains a post-script (`> {% ... %}`), its Lua body executes as
an **orchestration script**: `client.run()` calls imported requests like
functions, and the returned response can be inspected and chained into later
calls.

**Syntax**:

```
import ./requests.http as alias

### Login then fetch profile
SCRIPT
> {%
  local login = client.run("#alias.login", { username = "u", password = "p" })
  assert(login.status == 200, "login failed")

  local profile = client.run("#alias.get_profile", { Authorization = login.body.token })
  assert(profile.status == 200, "get profile failed")
  client.log("profile: " .. profile.body.username)
%}
```

**Rules**:

- `client.run(target, args)` executes an imported request. `target` is
  `#Name` or `#alias.Name`, resolved through the file's `import` directives.
- `args` is a Lua table of named values. Values are converted to HTTP strings:
  strings as-is, numbers/booleans via `tostring`, tables as JSON. They are
  injected as `@var` overrides — the target request references them with
  `{{name}}` (or in headers/body).
- The returned value is a typed response object:
  - `status`, `status_text`, `url`, `latency_ms`, `content_type`, `cookies`,
    `metadata`, `protocol`
  - `headers` — case-insensitive access (`r.headers["Content-Type"]`)
  - `body` — lazily JSON-decoded (a table when the body is JSON, otherwise the
    raw string)
- Execution is sequential: the script suspends until each `client.run` request
  finishes. Each call's response is also rendered in the multi-response chain.
- `client.log(msg)` / `print(...)` output goes to the Script Logs tab.
- `assert` / `client.assert(cond, msg)` abort the script on failure; the error
  is shown in the Assertions tab.
- `client.test(name, fn)` works like in assertion blocks; a failed test aborts
  the orchestration with the test name and error.
- `response` is available for compatibility and is the synthetic SCRIPT
  response; `variables` and `env` expose `@var` definitions and the active
  environment, same as pre/post scripts.
- A request failure (unresolved target, curl error, etc.) raises inside
  `client.run` and aborts the script with the request name in the message.

**Implementation status**: `client.run`, sequential execution, typed responses,
logs and error rendering are implemented. `client.run` for `./path` batch
targets and parallel execution are not yet implemented.

### 2.15 GraphQL Requests

Use `GRAPHQL` instead of `POST`. The body is the query text; an optional
variables JSON object follows after a blank line.

**Syntax**:

```
### Get user
GRAPHQL {{base_url}}/graphql
Authorization: Bearer {{token}}

query User($id: ID!) {
  user(id: $id) { name email }
}

{
  "id": "42"
}
```

**Rules**:

- `GRAPHQL` requests execute as HTTP `POST` with `Content-Type: application/json`
- The request body is sent as `{"query": ..., "variables": ...}`
- The variables block is the last blank-line-separated body chunk when it
  parses as a JSON object; a broken `{`/`[`-shaped tail fails the request
  with a clear error instead of being sent
- Set `Content-Type: application/graphql` explicitly to send the raw query
  text without any transformation (variables must then be embedded in the
  query string itself)
- All standard machinery applies: `{{var}}` resolution, pre-scripts,
  `> {% %}` assertions (`response.body` is the raw GraphQL JSON response,
  including its `errors` array), cross-request references
  (`{{GetUser.response.body.data.user.name}}`), and jq filtering
- Requires no external tooling — plain HTTP under the hood

**Implementation status**: Implemented (parser, executor, completion,
highlighting). GraphQL-specific extras (error surfacing, query injections)
are not yet implemented.

### 2.16 gRPC Requests

Use `GRPC` with a `host:port/package.Service/Method` target. Requires the
`grpcurl` binary (`:checkhealth poste-http` verifies it).

**Syntax**:

```
### gRPC echo
# @grpc-import-path ./protos
# @grpc-proto echo.proto
GRPC {{grpc_host}}/grpc.examples.echo.EchoService/Echo
X-Trace-Id: {{trace_id}}

{
  "message": "hello {{name}}"
}
```

**Rules**:

- Header lines become gRPC metadata
- The body is the request message JSON, sent once the connection is open
- Proto resolution prefers server reflection; use the operators below when
  the server has reflection disabled
- Supported operator comments:

| Operator | grpcurl flag | Repeatable |
|----------|--------------|------------|
| `# @grpc-import-path <dir>` | `-import-path` | yes |
| `# @grpc-proto <file>` | `-proto` | yes |
| `# @grpc-proto-set <file>` | `-proto-set` | yes |
| `# @grpc-plaintext` | `-plaintext` | — |
| `# @grpc-tls` | `-tls` | — |
| `# @grpc-flags <raw args>` | appended verbatim | yes |

- `GRPC host:port` without a method path lists the server's services via
  reflection (`grpcurl list`)
- Completion: after the host `/`, services and methods are suggested from the
  pinned `# @grpc-proto`/`# @grpc-proto-set` files (offline `grpcurl
  list`/`describe`) or from server reflection when no proto is pinned;
  inside the JSON body, message fields (including nested objects, array
  elements, and oneof members) complete as keys and enum-typed fields
  complete their values; `# @grpc-proto`/`# @grpc-proto-set` arguments
  complete proto file paths. The index is built in the background, so the
  first query on a changed block may return nothing until `grpcurl` finishes
- Assertions see gRPC semantics: `response.status` is the gRPC status code
  (0 = OK, 1–16 = error codes, e.g. 5 = NotFound), `response.body` is the
  response message JSON, and `response.ok`/the response indicator reflect
  gRPC success rather than HTTP >= 400
- Supported call types: unary and server-streaming. Client-streaming and
  bidirectional streaming are not supported
- The full grpcurl command line is logged with sensitive header values
  redacted

**Implementation status**: Implemented (parser, executor, operators,
health check). Client-streaming / bidi and streaming-frame rendering are
not yet implemented.

### 2.17 WebSocket Requests

Use `WEBSOCKET` with a `ws://` or `wss://` URL. Requires the `websocat`
binary (`:checkhealth poste-http` verifies it).

**Syntax**:

```
### Subscribe to the feed
# @ws-wait-ms 5000
WEBSOCKET wss://stream.example.com/v1/feed
Sec-WebSocket-Protocol: chat.v1

{"type": "subscribe", "channel": "news"}
{"type": "ping"}
```

**Rules**:

- Header lines are sent as extra handshake headers
- Every non-empty body line is sent as one text frame once the connection
  is open
- After all frames are sent, the response is collected until the wait
  window elapses or the server closes, then rendered
- `# @ws-wait-ms <ms>` sets the collection window (default 3000);
  `# @ws-flags <raw args>` passes extra websocat options (repeatable)
- The response renders in the **Msgs** tab (`M`): `→` outgoing frames,
  `←` incoming frames. The Body tab shows the received transcript
- `response.status` is the WebSocket close code (1000 = normal,
  1006 = abnormal); `response.ok` reflects it, and assertions can inspect
  `response.metadata.frames`
- Frames are line-based: a frame containing newlines shows as multiple
  rows
- Add `# @ws-interactive` to keep the connection open after the initial
  frames are sent: incoming frames append to the Msgs tab live, `s` prompts
  for a message to send, `c` closes the session, and wiping the response
  buffer closes it too. A live session does not block other requests, but
  only one session can be live at a time

**Implementation status**: Implemented (parser, executor, batch and
interactive sessions, messages tab, live frame append). Client-side frame
filtering and multiple simultaneous sessions are not yet implemented.

## 3. Variable Resolution Order

See [Variable Resolution](./variables.md) for the complete documentation. Key highlights:

- **7 priority layers** from import parameters (P1, highest) to magic variables (P7, lowest)
- **Cross-request references** (`{{Name.response.body.X}}`) are resolved via an independent response cache
- **Narrower scope = higher priority**: import params > block-level > file-level > session > script > env > magic

---

## 4. Differences from Standard HTTP

| Standard HTTP | Poste HTTP |
|---|---|
| Single request per file | Multiple requests via `###` separators |
| No variables | `{{}}` references + `@variable` definitions |
| No scripts | `< {% %}` pre-script + `> {% %}` assertion |
| No comments | `#` comments supported |
| No cross-request | `{{req.response.body.x}}` |
| Content-Type determines body format | Content-Type + magic variables |
| Single file | `import` / `run` cross-file references (kulala-compatible) |

## 5. Implementation Status Checklist

Highlighting is tree-sitter based (`tree-sitter-poste-http/queries/highlights.scm`,
themed in `http/highlights.lua`). Last verified against the code: 2026-09-05.

| Syntax | Execution | Completion | Highlight |
|---|---|---|---|
| `#` comment | ✅ | — | ✅ |
| `@variable` definition | ✅ | ✅ | ✅ |
| `@xxx =>>> ... <<<` | ✅ | ❌ | ✅ |
| `###` separator | ✅ | ✅ | ✅ |
| `@env` block override | ❌ (planned) | ❌ | ✅ |
| `METHOD URL` | ✅ | ✅ | ✅ |
| `Key: Value` header | ✅ | ✅ | ✅ |
| Blank line separator | ✅ | — | — |
| Request body (JSON/form/multipart) | ✅ | — | ✅ |
| `< path` file include/upload | ✅ | — | ✅ |
| `{{var}}` reference | ✅ | ✅ | ✅ |
| `{{$magic}}` | ✅ | ✅ | ✅ |
| `< {% %}` pre-script | ✅ | ✅ | ✅ |
| `< ./path.lua` external script | ✅ | ❌ | ✅ |
| `> {% %}` assertion | ✅ | ✅ | ✅ |
| `> ./path.lua` external assertion | ❌ | ❌ | ✅ |
| `<<name` variable prompt | ✅ | ❌ | ✅ |
| `import` / `run` file refs | ✅ | ❌ | ✅ |
| `SCRIPT` orchestration | ✅ | ✅ | ✅ |
| `GRAPHQL` requests | ✅ | ✅ | ✅ |
| `GRPC` requests (grpcurl) | ✅ | ✅ | ✅ |
| `WEBSOCKET` requests (websocat) | ✅ | ✅ | ✅ |
