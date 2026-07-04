# Request Variables

Poste supports cross-request variable references, allowing you to use the response from one request in another request.

## Syntax

```
{{RequestName.response.body.field.subfield}}
{{RequestName.response.headers.HeaderName}}
{{RequestName.request.body.field}}
{{RequestName.request.headers.HeaderName}}
```

## Examples

### Basic Usage

```http
### Login
POST https://api.example.com/login
Content-Type: application/json

{
  "username": "admin",
  "password": "secret"
}

### Get User Profile
# Use the username from Login response
GET https://api.example.com/users/{{Login.response.body.username}}
```

### Nested JSON Fields

```http
### Login
POST https://api.example.com/login
Content-Type: application/json

{
  "user": "admin"
}

### Get Profile
# Access nested fields: response.body.data.user.name
GET https://api.example.com/profile/{{Login.response.body.data.user.name}}
```

### Array Indexing

```http
### Get Users
GET https://api.example.com/users

### Get First User
# Access array elements: response.body.users[0].id
GET https://api.example.com/users/{{Get Users.response.body.users[0].id}}
```

### Response Headers

```http
### Login
POST https://api.example.com/login

### Use Token
# Extract token from response header
GET https://api.example.com/protected
Authorization: Bearer {{Login.response.headers.x-auth-token}}
```

### Chained References

```http
### Step 1
POST https://api.example.com/step1

### Step 2
# References Step 1
GET https://api.example.com/step2?id={{Step 1.response.body.id}}

### Step 3
# References Step 2 (which itself references Step 1)
GET https://api.example.com/step3?token={{Step 2.response.body.token}}
```

## How It Works

1. **Automatic Execution**: When you execute a request with variable references, Poste automatically executes the referenced requests first (if not already cached).

2. **Response Caching**: Executed responses are cached in memory. Subsequent requests referencing the same request will use the cached response.

3. **Variable Substitution**: Variables are substituted before the request is sent to the CLI.

4. **JSON Navigation**: For JSON response bodies, you can navigate nested structures using dot notation (`body.user.name`) or array indexing (`body.items[0].id`).

## Supported Patterns

- `{{RequestName.response.body}}` - Entire response body
- `{{RequestName.response.body.field}}` - Top-level field
- `{{RequestName.response.body.field.subfield}}` - Nested field
- `{{RequestName.response.body.array[0]}}` - Array element
- `{{RequestName.response.body.array[0].field}}` - Field in array element
- `{{RequestName.response.headers.HeaderName}}` - Response header (case-insensitive)
- `{{RequestName.request.body.field}}` - Field from request body
- `{{RequestName.request.headers.HeaderName}}` - Request header

## Notes

- Request names are case-sensitive and must match exactly
- If a referenced request hasn't been executed, it will be executed automatically
- Responses are cached for the current Neovim session
- If a variable cannot be resolved (e.g., field doesn't exist), the original `{{...}}` placeholder is left unchanged
- Request variables work alongside file-level variables (`@var = value`) and prompt variables (`<<var`)

## Variable Priority

When multiple variable types exist with the same name, the priority is:

1. **Request variables** (e.g., `{{Login.response.body.token}}`)
2. **Request-level variables** (`@var = value` in request block)
3. **File-level variables** (`@var = value` before first `###`)
4. **Environment variables** (from `env.json`)
