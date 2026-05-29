# Form Data Support

Poste supports sending form data in two formats, matching the kulala.nvim syntax.

## URL-Encoded Form Data

For `application/x-www-form-urlencoded` requests, simply write the form data as key-value pairs in the body:

```http
@name=John
@age=30

### Submit Form
POST https://api.example.com/users HTTP/1.1
Content-Type: application/x-www-form-urlencoded
Accept: application/json

name={{name}}&age={{age}}&city=NewYork
```

**Result:**
```
POST /users
Content-Type: application/x-www-form-urlencoded

name=John&age=30&city=NewYork
```

## Multipart Form Data

For `multipart/form-data` requests (used for file uploads), use the standard multipart syntax with boundaries.

### Basic Multipart

```http
### Upload User Data
POST https://api.example.com/upload HTTP/1.1
Content-Type: multipart/form-data; boundary=----MyBoundary{{$timestamp}}

------MyBoundary{{$timestamp}}
Content-Disposition: form-data; name="username"

admin
------MyBoundary{{$timestamp}}
Content-Disposition: form-data; name="email"

admin@example.com
------MyBoundary{{$timestamp}}--
```

### File Upload with `< path`

Use the `< path` syntax to include file contents in the request body:

```http
### Upload Avatar
POST https://api.example.com/avatar HTTP/1.1
Content-Type: multipart/form-data; boundary=----UploadBoundary{{$timestamp}}

------UploadBoundary{{$timestamp}}
Content-Disposition: form-data; name="user_id"

12345
------UploadBoundary{{$timestamp}}
Content-Disposition: form-data; name="avatar"; filename="avatar.png"
Content-Type: image/png

< ~/Pictures/avatar.png
------UploadBoundary{{$timestamp}}--
```

## Magic Variables

### `{{$timestamp}}`

The `{{$timestamp}}` magic variable is automatically replaced with a unique timestamp (e.g., `1704067200123456`) before sending the request. This is useful for:

- **Unique multipart boundaries**: Ensures each request has a unique boundary string
- **Cache busting**: Add to URLs to prevent caching: `GET /api/data?t={{$timestamp}}`

**Example:**
```http
### Upload with Unique Boundary
POST https://httpbin.org/post HTTP/1.1
Content-Type: multipart/form-data; boundary=----WebKitFormBoundary{{$timestamp}}

------WebKitFormBoundary{{$timestamp}}
Content-Disposition: form-data; name="field"

value
------WebKitFormBoundary{{$timestamp}}--
```

**After processing:**
```
Content-Type: multipart/form-data; boundary=----WebKitFormBoundary1704067200123456

------WebKitFormBoundary1704067200123456
Content-Disposition: form-data; name="field"

value
------WebKitFormBoundary1704067200123456--
```

## File Inclusion with `< path`

The `< path` syntax reads a file and inserts its contents into the request body. This is primarily used for file uploads in multipart form data.

### Syntax

```
< /absolute/path/to/file
< ~/relative/to/home/file
< relative/to/buffer/file
```

### Examples

**Absolute path:**
```http
< /Users/john/Documents/photo.jpg
```

**Home directory (tilde expansion):**
```http
< ~/Downloads/document.pdf
```

**Relative to buffer directory:**
```http
< ./images/logo.png
< images/logo.png
```

### Multiple Files

You can include multiple files in a single multipart request:

```http
### Upload Multiple Files
POST https://api.example.com/upload HTTP/1.1
Content-Type: multipart/form-data; boundary=----Multi{{$timestamp}}

------Multi{{$timestamp}}
Content-Disposition: form-data; name="file1"; filename="doc1.txt"
Content-Type: text/plain

< ~/Documents/doc1.txt
------Multi{{$timestamp}}
Content-Disposition: form-data; name="file2"; filename="doc2.txt"
Content-Type: text/plain

< ~/Documents/doc2.txt
------Multi{{$timestamp}}
Content-Disposition: form-data; name="file3"; filename="image.png"
Content-Type: image/png

< ~/Pictures/image.png
------Multi{{$timestamp}}--
```

## Complete Example

Here's a complete example combining variables, multipart form data, and file uploads:

```http
@api_base=https://api.example.com
@user_id=12345

### Upload User Profile
POST {{api_base}}/users/{{user_id}}/profile HTTP/1.1
Content-Type: multipart/form-data; boundary=----ProfileBoundary{{$timestamp}}
Accept: application/json

------ProfileBoundary{{$timestamp}}
Content-Disposition: form-data; name="user_id"

{{user_id}}
------ProfileBoundary{{$timestamp}}
Content-Disposition: form-data; name="display_name"

John Doe
------ProfileBoundary{{$timestamp}}
Content-Disposition: form-data; name="avatar"; filename="avatar.jpg"
Content-Type: image/jpeg

< ~/Pictures/avatar.jpg
------ProfileBoundary{{$timestamp}}
Content-Disposition: form-data; name="bio"

Software developer from New York
------ProfileBoundary{{$timestamp}}--
```

## Technical Details

### How It Works

1. **Magic Variable Processing**: Before sending the request, Poste scans the request body and replaces all `{{$timestamp}}` occurrences with a unique timestamp value.

2. **File Inclusion**: When Poste encounters a line starting with `<` followed by a file path, it:
   - Expands `~` to the home directory
   - Resolves relative paths relative to the buffer's directory
   - Reads the file contents
   - Replaces the `< path` line with the actual file contents

3. **Binary Data Preservation**: The Rust executor uses `curl --data-binary` instead of `curl -d` to ensure binary data (like images) is transmitted correctly without modification.

### Boundary Best Practices

- **Use `{{$timestamp}}`**: Always include `{{$timestamp}}` in your boundary to ensure uniqueness
- **Consistent naming**: Use the same boundary string throughout the request
- **Proper termination**: End the multipart body with `--boundary--` (note the trailing `--`)

### Content-Type Headers

For file uploads, specify the correct `Content-Type` for each part:

```http
------Boundary{{$timestamp}}
Content-Disposition: form-data; name="file"; filename="photo.jpg"
Content-Type: image/jpeg

< ~/Pictures/photo.jpg
```

Common MIME types:
- Images: `image/jpeg`, `image/png`, `image/gif`
- Documents: `application/pdf`, `application/msword`
- Text: `text/plain`, `text/html`, `text/csv`
- Archives: `application/zip`, `application/x-tar`

## Limitations

- **No automatic boundary generation**: You must manually specify the boundary in the `Content-Type` header
- **File size**: Very large files may cause memory issues (the entire file is loaded into memory)
- **No streaming**: File contents are read entirely before sending, not streamed

## Comparison with Other Tools

| Feature | Poste | kulala.nvim | REST Client (VS Code) |
|---------|-------|-------------|----------------------|
| URL-encoded forms | ✅ | ✅ | ✅ |
| Multipart forms | ✅ | ✅ | ✅ |
| File uploads (`< path`) | ✅ | ✅ | ✅ |
| Magic variables | ✅ (`{{$timestamp}}`) | ✅ (`{{$timestamp}}`, `{{$guid}}`) | ❌ |
| Tilde expansion | ✅ | ✅ | ❌ |
| Binary data | ✅ (`--data-binary`) | ✅ | ✅ |
