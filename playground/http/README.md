# Poste Test HTTP Server

A local [httpbin.org](https://httpbin.org/)-like server for testing Poste's HTTP
request execution. Logs every request in detail to stdout so you can see
exactly what `curl` sends.

## Quick Start

```bash
# Start the server
docker compose up -d

# Tail the logs
docker compose logs -f

# Test it
curl http://localhost:8888/anything
curl http://localhost:8888/get?foo=bar
curl -X POST http://localhost:8888/post -H "Content-Type: application/json" -d '{"hello":"world"}'
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |
| GET | `/get` | Echo query parameters |
| POST | `/post` | Echo POST body |
| PUT | `/put` | Echo PUT body |
| PATCH | `/patch` | Echo PATCH body |
| DELETE | `/delete` | Echo DELETE info |
| HEAD | `/head` | Response headers only |
| OPTIONS | `/options` | Allowed methods |
| GET | `/headers` | Echo request headers |
| GET | `/status/{code}` | Return specific status code |
| GET | `/delay/{sec}` | Delay response |
| GET | `/redirect/{n}` | Redirect N times |
| GET | `/anything[/{path}]` | Echo full request (any method) |
| GET | `/json` | Sample JSON |
| GET | `/xml` | Sample XML |
| GET | `/html` | Sample HTML |
| GET | `/uuid` | Return UUID |
| GET | `/bytes/{n}` | Return N random bytes |
| GET | `/stream/{n}` | Stream N JSON lines |
| GET | `/basic-auth/{u}/{p}` | Basic auth |
| GET | `/bearer` | Bearer token echo |
| GET | `/cookies` | Echo cookies |
| POST | `/upload` | File upload (multipart) |
| POST | `/form` | Form data echo |
| GET | `/gzip` | Gzip response |
| GET | `/deflate` | Deflate response |
| GET | `/cache/{sec}` | Cache-control test |
| GET | `/response-headers?k=v` | Custom response headers |
| GET | `/drip?numbytes=N&duration=S` | Drip data over time |
| GET | `/image/{format}` | Sample image (png/jpeg/webp/svg) |

## Example: Using from Poste .http files

```http
@test_server = http://localhost:8888

### Test GET with query params
GET {{test_server}}/get?name=test&page=1

### Test POST with JSON body
POST {{test_server}}/post
Content-Type: application/json

{"key": "value", "number": 42}

### Test basic auth
GET {{test_server}}/basic-auth/admin/secret
Authorization: Basic admin:secret

### Test file upload
POST {{test_server}}/upload
Content-Type: multipart/form-data; boundary=----Boundary

------Boundary
Content-Disposition: form-data; name="file"; filename="test.txt"
Content-Type: text/plain

< ./test_data.txt
------Boundary--

### Test redirect following
GET {{test_server}}/redirect/3
```

## Log Output

Each request produces structured logs like:

```
┌─────────────────────────────────────────────────────────────────────────
│  POST /post
│  Query Params:
│    foo: bar
│  Headers:
│    host: localhost:8888
│    content-type: application/json
│    user-agent: curl/8.4.0
│  Body (27 bytes):
│    {"hello": "world", "test": true}
│  → Response: 200 (12.3ms)
└─────────────────────────────────────────────────────────────────────────
```

## Using with Poste Tests

The server runs on port **8888** to avoid conflicts. Reference it in test
fixtures and Poste `.http` files as `http://localhost:8888`.

To run the server in CI:

```bash
docker compose up -d
# Wait for health
docker compose exec poste-test-server curl -sf http://localhost:8888/health
# Run tests...
docker compose down
```