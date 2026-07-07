# Poste HTTP File Syntax Reference

> This document defines all supported syntax elements for `.http` / `.rest` files,
> used as a unified reference for completion, highlighting, formatting, and the Rust CLI parser.

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

**Supported METHODS** (from `completion.lua`):

```
GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, TRACE, CONNECT
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

**File include/upload syntax** (unified `< path` format):

```
POST /api/upload
Content-Type: multipart/form-data; boundary=----boundary

< /path/to/file.txt
```

```
POST /api/data
Content-Type: application/json

< /path/to/payload.json
```

**Rules**:
- `<` followed by a space, then the file path
- Path supports absolute paths, `./` relative paths, `~/` home directory
- **Content-Type contains `json`**: file content is embedded directly into the body
- **Content-Type contains `multipart/form-data`**: treated as file upload
- If file is not found, the original line is preserved with a warning
- This syntax is NOT `</path>` — that's the old deprecated design

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

See [Variable Resolution in Detail](./variables.md) for complete documentation on all variable sources, magic variables, prompt variables, transitive resolution, and the CLI `poste resolve` command.

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

**Implementation status**: Completion (Lua) ❌, Highlight ❌

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

**Implementation status**: All not yet implemented

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

| Syntax | Parser (Rust) | Completion (Lua) | Highlight (Lua) | Format (todo) |
|---|---|---|---|---|
| `#` comment | ✅ skip | — | ❌ | — |
| `@variable` definition | ✅ | ✅ | ❌ | ✅ todo |
| `@xxx =>>> ... <<<` | ✅ | ❌ | ❌ | ❌ |
| `###` separator | ✅ | ✅ | ❌ | ✅ todo |
| `@env` block variable | ❌ | ❌ | ❌ | ✅ todo |
| `METHOD URL` | ✅ | ✅ | ❌ | — |
| `Key: Value` header | ✅ | ✅ | ❌ | ✅ todo |
| Blank line separator | ✅ | ✅ | — | ✅ todo |
| Request body | ✅ | — | ❌ | ✅ todo |
| `< path` file include/upload | ✅ Lua | — | ✅ `PosteFileUpload` | ✅ todo |
| `{{var}}` reference | ✅ | ✅ | ❌ | — |
| `{{$magic}}` | ❌ Rust-side | ✅ | ❌ | — |
| `< {% %} ` | ✅ skip | ✅ | ❌ | ✅ todo |
| `< ./path.lua` | ✅ skip | ❌ | ❌ | — |
| `> {% %} ` | ✅ skip | ✅ | ❌ | ✅ todo |
| `> ./path.lua` | ❌ skip | ❌ | ❌ | — |
| `<<name` variable prompt | — | ❌ | ❌ | — |
| `import` / `run` file refs | ❌ | ❌ | ❌ | ❌ |
