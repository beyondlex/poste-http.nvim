"""
Poste Test HTTP Server — a local httpbin-like server with detailed request logging.

Provides endpoints for testing Poste's HTTP request execution (curl-based).
Every request is logged verbosely to stdout so you can inspect exactly what
curl sends: method, URL, headers, query params, body, cookies, etc.

Endpoints:
  GET /health                      Health check (always 200)
  GET /get                         Echo query parameters
  POST /post                       Echo POST body
  PUT /put                         Echo PUT body
  PATCH /patch                     Echo PATCH body
  DELETE /delete                   Echo DELETE info
  HEAD /head                       Return headers only (no body)
  OPTIONS /options                 Return allowed methods

  GET /headers                     Echo request headers
  GET /status/{code}               Return a specific status code
  GET /delay/{seconds}             Delay response by N seconds
  GET /sleep/{seconds}             Alias for /delay/{seconds}
  GET /redirect/{count}            Redirect N times (302)
  GET /redirect-to?url=...         302 redirect to given URL

  GET  /anything                   Echo full request details (any method)
  POST /anything                   Echo full request details
  PUT  /anything                   Echo full request details
  PATCH /anything                  Echo full request details
  DELETE /anything                 Echo full request details
  /anything/{path}                 Same, with arbitrary sub-path

  GET /json                        Sample JSON response
  GET /xml                         Sample XML response
  GET /html                        Sample HTML response
  GET /robots.txt                  Sample robots.txt
  GET /stream/{count}              Stream N JSON lines (chunked)
  GET /uuid                        Return a UUID
  GET /bytes/{count}               Return N random bytes
  GET /range/{start}/{end}         Return range of numbers

  GET  /basic-auth/{user}/{pass}   Basic auth challenge
  GET  /bearer                     Bearer token echo
  GET  /cookies                    Echo request cookies
  GET  /cookies/set?name=value     Set a cookie (redirect)
  GET  /cookies/delete?name        Delete a cookie (redirect)

  POST /upload                     File upload test (multipart)
  POST /store                      Upload & store file, returns file_id for download
  GET  /download/{file_id}         Download a previously stored file
  GET  /files                      List all stored files (id, filename, size, content_type)
  DELETE /files/{file_id}          Delete a stored file
  POST /form                       URL-encoded form echo
  POST /anything                   Dump all request info

  GET  /encoding/{code}            Return body with specific charset
  GET  /gzip                       Return gzip-compressed response
  GET  /deflate                    Return deflate-compressed response
  GET  /brotli                     Return brotli-compressed response
  GET  /cacheable                  Return cacheable response (ETag, Last-Modified)
  GET  /cache/{seconds}            Set Cache-Control max-age

  GET  /links/{count}              Return page with N links
  GET  /image/{format}             Return sample image (png/jpeg/webp/svg)
  GET  /drip?numbytes=N&duration=S Drip data over time

  GET  /absolute-redirect/{count}  Absolute URL redirect N times
  GET  /relative-redirect/{count}  Relative URL redirect N times

  GET /response-headers?k=v       Set custom response headers
  GET /cached/{etag}              Return 304 if matching ETag sent

Usage:
  Start:    docker compose up -d
  Logs:     docker compose logs -f
  Stop:     docker compose down
  Test:     curl http://localhost:8888/anything
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import random
import string
import time
import uuid as uuid_mod
from datetime import datetime, timezone
from typing import Any, Optional

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import (
    HTMLResponse,
    JSONResponse,
    PlainTextResponse,
    RedirectResponse,
    StreamingResponse,
)

# ---------------------------------------------------------------------------
# Logging: structured JSON to stdout for easy reading in docker logs
# ---------------------------------------------------------------------------

logger = logging.getLogger("poste-test-server")
logger.setLevel(logging.DEBUG)


class RequestFormatter(logging.Formatter):
    """Custom formatter that adds ANSI colors for readability in docker logs."""

    COLORS = {
        "GET": "\033[36m",     # Cyan
        "POST": "\033[33m",    # Yellow
        "PUT": "\033[34m",     # Blue
        "PATCH": "\033[35m",   # Magenta
        "DELETE": "\033[31m",  # Red
        "HEAD": "\033[37m",     # White
        "OPTIONS": "\033[37m",  # White
        "STATUS_2xx": "\033[32m",
        "STATUS_3xx": "\033[36m",
        "STATUS_4xx": "\033[33m",
        "STATUS_5xx": "\033[31m",
        "RESET": "\033[0m",
        "BOLD": "\033[1m",
        "DIM": "\033[2m",
    }

    def format(self, record: logging.LogRecord) -> str:
        # Strip the default timestamp; we add our own
        msg = super().format(record)
        timestamp = datetime.now().strftime("%H:%M:%S.%f")[:-3]
        return f"[{timestamp}] {msg}"


handler = logging.StreamHandler()
handler.setLevel(logging.DEBUG)
handler.setFormatter(RequestFormatter("%(message)s"))
logger.addHandler(handler)

# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(
    title="Poste Test HTTP Server",
    description="Local httpbin-like server for testing Poste HTTP requests",
    version="1.0.0",
)

# ---------------------------------------------------------------------------
# Request logging middleware
# ---------------------------------------------------------------------------


@app.middleware("http")
async def log_request(request: Request, call_next):
    """Log every incoming request in detail."""
    body_bytes = await request.body()

    # ── Request log header ──────────────────────────────────────────────
    c = RequestFormatter.COLORS
    method_colored = f"{c[request.method]}{c['BOLD']}{request.method}{c['RESET']}"
    logger.info(
        f"{'─' * 72}\n"
        f"  {method_colored} {c['BOLD']}{request.url.path}{c['RESET']}"
    )

    # ── Query parameters ────────────────────────────────────────────────
    if request.query_params:
        logger.info(f"  {c['DIM']}Query Params:{c['RESET']}")
        for key, value in request.query_params.multi_items():
            logger.info(f"    {c['DIM']}{key}{c['RESET']}: {value}")

    # ── Headers ─────────────────────────────────────────────────────────
    logger.info(f"  {c['DIM']}Headers:{c['RESET']}")
    sensitive = {"authorization", "cookie", "set-cookie", "x-api-key"}
    for key, value in request.headers.items():
        display_value = (
            f"{value[:20]}... (truncated)"
            if key.lower() in sensitive and len(value) > 40
            else value
        )
        logger.info(f"    {c['DIM']}{key}{c['RESET']}: {display_value}")

    # ── Cookies (parsed from Cookie header) ─────────────────────────────
    cookies = request.cookies
    if cookies:
        logger.info(f"  {c['DIM']}Cookies:{c['RESET']}")
        for key, value in cookies.items():
            logger.info(f"    {c['DIM']}{key}{c['RESET']}: {value}")

    # ── Body ────────────────────────────────────────────────────────────
    if body_bytes:
        content_type = request.headers.get("content-type", "")
        body_str = body_bytes.decode("utf-8", errors="replace")

        # Truncate very large bodies for logging
        if len(body_str) > 5000:
            body_log = body_str[:5000] + f"\n    ... ({len(body_str)} bytes total)"
        else:
            body_log = body_str

        logger.info(f"  {c['DIM']}Body ({len(body_bytes)} bytes):{c['RESET']}")
        if "application/json" in content_type:
            try:
                pretty = json.dumps(json.loads(body_str), indent=2, ensure_ascii=False)
                for line in pretty.split("\n"):
                    logger.info(f"    {line}")
            except json.JSONDecodeError:
                for line in body_log.split("\n"):
                    logger.info(f"    {line}")
        elif "x-www-form-urlencoded" in content_type:
            from urllib.parse import parse_qs

            parsed = parse_qs(body_str)
            for key, values in parsed.items():
                logger.info(f"    {c['DIM']}{key}{c['RESET']}: {', '.join(values)}")
        else:
            for line in body_log.split("\n"):
                logger.info(f"    {line}")

    # ── Process the request ─────────────────────────────────────────────
    start_time = time.monotonic()
    try:
        response = await call_next(request)
    except Exception as e:
        logger.error(f"  {c['STATUS_5xx']}ERROR: {e}{c['RESET']}")
        raise

    elapsed_ms = (time.monotonic() - start_time) * 1000

    # ── Response status ─────────────────────────────────────────────────
    status = response.status_code
    if 200 <= status < 300:
        status_color = c["STATUS_2xx"]
    elif 300 <= status < 400:
        status_color = c["STATUS_3xx"]
    elif 400 <= status < 500:
        status_color = c["STATUS_4xx"]
    else:
        status_color = c["STATUS_5xx"]

    logger.info(
        f"  {c['DIM']}→ Response:{c['RESET']} {status_color}{status}{c['RESET']} "
        f"({elapsed_ms:.1f}ms)"
    )
    logger.info(f"{'─' * 72}")
    return response


# ---------------------------------------------------------------------------
# Helper: build unified request info dict
# ---------------------------------------------------------------------------


def _build_request_info(request: Request, body_bytes: bytes | None = None) -> dict:
    """Build a comprehensive dict describing the incoming request."""
    info: dict[str, Any] = {
        "method": request.method,
        "url": str(request.url),
        "path": request.url.path,
        "query_string": str(request.url.query),
        "query_params": dict(request.query_params.multi_items()),
        "headers": dict(request.headers.items()),
        "cookies": dict(request.cookies),
        "origin": request.client.host if request.client else "unknown",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

    if body_bytes:
        content_type = request.headers.get("content-type", "")
        body_str = body_bytes.decode("utf-8", errors="replace")
        if "application/json" in content_type:
            try:
                info["json"] = json.loads(body_str)
            except json.JSONDecodeError:
                info["data"] = body_str
        elif "x-www-form-urlencoded" in content_type:
            from urllib.parse import parse_qs

            info["form"] = parse_qs(body_str)
        elif "multipart/form-data" in content_type:
            # FastAPI's request.form() is async and can only be called once.
            # We'll handle multipart in the endpoint directly.
            info["data"] = body_str
        else:
            info["data"] = body_str

    return info


def _make_echo_body(request: Request, body_bytes: bytes) -> dict:
    """Build the full echo response body."""
    info = _build_request_info(request, body_bytes)
    info["server"] = {
        "name": "poste-test-server",
        "version": "1.0.0",
        "powered_by": "FastAPI + Uvicorn",
    }
    return info


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------


@app.get("/health")
async def health():
    return {"status": "ok", "server": "poste-test-server"}


# ---------------------------------------------------------------------------
# Standard HTTP method echoes
# ---------------------------------------------------------------------------


@app.get("/get")
async def get_endpoint(request: Request):
    return JSONResponse(
        {
            "args": dict(request.query_params.multi_items()),
            "headers": dict(request.headers.items()),
            "origin": request.client.host if request.client else "unknown",
            "url": str(request.url),
        }
    )


@app.post("/post")
async def post_endpoint(request: Request):
    body = await request.body()
    return JSONResponse(_make_echo_body(request, body))


@app.put("/put")
async def put_endpoint(request: Request):
    body = await request.body()
    return JSONResponse(_make_echo_body(request, body))


@app.patch("/patch")
async def patch_endpoint(request: Request):
    body = await request.body()
    return JSONResponse(_make_echo_body(request, body))


@app.delete("/delete")
async def delete_endpoint(request: Request):
    body = await request.body()
    return JSONResponse(_make_echo_body(request, body))


@app.head("/head")
async def head_endpoint():
    return Response(headers={"x-poste-test": "head-ok"})


@app.options("/options")
async def options_endpoint():
    return JSONResponse(
        {"methods": ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]}
    )


# ---------------------------------------------------------------------------
# Headers echo
# ---------------------------------------------------------------------------


@app.get("/headers")
async def headers_endpoint(request: Request):
    return JSONResponse({"headers": dict(request.headers.items())})


# ---------------------------------------------------------------------------
# Status codes
# ---------------------------------------------------------------------------


@app.get("/status/{status_code}")
async def status_endpoint(status_code: int):
    if status_code < 100 or status_code > 599:
        raise HTTPException(status_code=400, detail="Invalid status code")
    return Response(
        content=json.dumps({"status": status_code}),
        status_code=status_code,
        media_type="application/json",
    )


# ---------------------------------------------------------------------------
# Delay / Sleep
# ---------------------------------------------------------------------------


@app.get("/delay/{seconds}")
@app.get("/sleep/{seconds}")
async def delay_endpoint(seconds: float):
    if seconds < 0:
        seconds = 0
    if seconds > 30:
        seconds = 30  # cap for safety
    await asyncio.sleep(seconds)
    return JSONResponse(
        {"delay": seconds, "timestamp": datetime.now(timezone.utc).isoformat()}
    )


# ---------------------------------------------------------------------------
# Redirects
# ---------------------------------------------------------------------------


@app.get("/redirect/{count}")
async def redirect_endpoint(count: int, request: Request):
    if count <= 0:
        # Final hop — return info
        return JSONResponse({"redirect_count": abs(count), "final": True})
    if count > 10:
        count = 10  # cap for safety
    # Use 302 for each hop
    target = f"/redirect/{count - 1}"
    return RedirectResponse(url=target, status_code=302)


@app.get("/redirect-to")
async def redirect_to(request: Request, url: str = ""):
    if not url:
        raise HTTPException(status_code=400, detail="Missing 'url' query parameter")
    return RedirectResponse(url=url, status_code=302)


@app.get("/absolute-redirect/{count}")
async def absolute_redirect_endpoint(count: int):
    if count <= 0:
        return JSONResponse({"redirect_count": abs(count), "final": True})
    if count > 10:
        count = 10
    target = f"/absolute-redirect/{count - 1}"
    return RedirectResponse(url=target, status_code=302)


@app.get("/relative-redirect/{count}")
async def relative_redirect_endpoint(count: int):
    if count <= 0:
        return JSONResponse({"redirect_count": abs(count), "final": True})
    if count > 10:
        count = 10
    target = f"/relative-redirect/{count - 1}"
    return RedirectResponse(url=target, status_code=302)


# ---------------------------------------------------------------------------
# Anything — catch-all echo
# ---------------------------------------------------------------------------

# We register specific routes so they show up in /openapi.json
# The catch-all is handled by a fallback below.


@app.api_route("/anything", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])
async def anything(request: Request):
    body = await request.body()
    return JSONResponse(_make_echo_body(request, body))


@app.api_route(
    "/anything/{path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"],
)
async def anything_path(request: Request, path: str):
    body = await request.body()
    return JSONResponse(_make_echo_body(request, body))


# ---------------------------------------------------------------------------
# Content types
# ---------------------------------------------------------------------------


@app.get("/json")
async def json_endpoint():
    return JSONResponse(
        {
            "slideshow": {
                "author": "Poste Test Server",
                "date": datetime.now().strftime("%Y-%m-%d"),
                "slides": [
                    {"title": "Welcome", "type": "all"},
                    {"title": "Testing HTTP", "type": "all"},
                    {
                        "title": "Poste Features",
                        "type": "all",
                        "items": [
                            "Magic Variables",
                            "Script Support",
                            "OpenAPI Import",
                            "Multi-Protocol",
                        ],
                    },
                ],
                "title": "Poste Test Slideshow",
            }
        }
    )


@app.get("/xml")
async def xml_endpoint():
    return PlainTextResponse(
        content='''<?xml version="1.0" encoding="UTF-8"?>
<note>
  <to>Tester</to>
  <from>Poste Server</from>
  <heading>Test Reminder</heading>
  <body>Don't forget to test edge cases!</body>
  <priority>high</priority>
  <tags>
    <tag>testing</tag>
    <tag>http</tag>
    <tag>poste</tag>
  </tags>
</note>''',
        media_type="application/xml",
    )


@app.get("/html")
async def html_endpoint():
    return HTMLResponse(
        content=f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Poste Test Page</title>
  <style>
    body {{ font-family: sans-serif; max-width: 800px; margin: 2em auto; }}
    h1 {{ color: #333; }}
    .box {{ border: 1px solid #ccc; padding: 1em; margin: 1em 0; border-radius: 4px; }}
    .ok {{ color: green; }}
    .info {{ color: #666; font-size: 0.9em; }}
  </style>
</head>
<body>
  <h1>Poste Test Server</h1>
  <div class="box">
    <p class="ok">✓ Server is running</p>
    <p class="info">Generated at: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}</p>
    <p class="info">Request URI: /html</p>
  </div>
  <ul>
    <li><a href="/get?test=1">Test GET</a></li>
    <li><a href="/json">JSON endpoint</a></li>
    <li><a href="/xml">XML endpoint</a></li>
    <li><a href="/anything">Anything endpoint</a></li>
  </ul>
</body>
</html>"""
    )


@app.get("/robots.txt")
async def robots_endpoint():
    return PlainTextResponse(
        content="User-agent: *\nDisallow: /admin\nAllow: /get\nAllow: /post\n",
        media_type="text/plain",
    )


# ---------------------------------------------------------------------------
# Streaming
# ---------------------------------------------------------------------------


@app.get("/stream/{count}")
async def stream_endpoint(count: int):
    if count < 0:
        count = 0
    if count > 100:
        count = 100  # cap

    async def generate():
        for i in range(count):
            yield json.dumps({"id": i, "value": random.randint(1, 1000)}) + "\n"
            await asyncio.sleep(0.01)

    return StreamingResponse(
        generate(),
        media_type="application/json",
        headers={"X-Stream-Count": str(count)},
    )


# ---------------------------------------------------------------------------
# UUID
# ---------------------------------------------------------------------------


@app.get("/uuid")
async def uuid_endpoint():
    return JSONResponse({"uuid": str(uuid_mod.uuid4())})


# ---------------------------------------------------------------------------
# Session init — for testing post-script → global var → next request flow
# ---------------------------------------------------------------------------


@app.post("/session/init")
async def session_init_endpoint(request: Request):
    """Initialize a session and return a session token + user info.

    The response body contains fields that a post-script can extract
    and store as global variables for subsequent requests:
      {
        "session_token": "sess_<random>",
        "user": { "id": "<random>", "role": "<random>" },
        "expires_in": 3600
      }
    """
    body = await request.body()
    body_str = body.decode("utf-8", errors="replace") if body else ""

    # Parse credentials from body if provided
    try:
        creds = json.loads(body_str) if body_str else {}
    except json.JSONDecodeError:
        creds = {}

    username = creds.get("username", "test_user")
    role = creds.get("role", random.choice(["admin", "editor", "viewer"]))

    session_id = str(uuid_mod.uuid4())
    session_token = f"sess_{uuid_mod.uuid4().hex[:16]}"
    user_id = f"user_{random.randint(1000, 9999)}"

    resp = {
        "ok": True,
        "session_token": session_token,
        "session_id": session_id,
        "user": {
            "id": user_id,
            "username": username,
            "role": role,
        },
        "permissions": ["read", "write"] if role == "admin" else ["read"],
        "expires_in": 3600,
        "server_time": datetime.now(timezone.utc).isoformat(),
    }

    return JSONResponse(
        content=resp,
        headers={
            "X-Session-Token": session_token,
            "X-User-Id": user_id,
            "X-User-Role": role,
            "Cache-Control": "no-store",
        },
    )


@app.get("/session/verify")
async def session_verify_endpoint(request: Request):
    """Verify a session token passed via Authorization header.

    Used by subsequent requests to test that global vars from
    a previous request's post-script are correctly resolved.
    """
    auth = request.headers.get("authorization", "")
    token = auth.replace("Bearer ", "") if auth.startswith("Bearer ") else ""

    if not token:
        return JSONResponse(
            {"ok": False, "error": "Missing session token"},
            status_code=401,
        )

    return JSONResponse(
        {
            "ok": True,
            "verified": True,
            "via_var": "{{session_token}} was resolved",
            "token_preview": token[:20] + "..." if len(token) > 20 else token,
        }
    )


# ---------------------------------------------------------------------------
# Random bytes
# ---------------------------------------------------------------------------


@app.get("/bytes/{count}")
async def bytes_endpoint(count: int):
    if count < 0:
        count = 0
    if count > 1024 * 1024:  # cap at 1MB
        count = 1024 * 1024
    data = bytes(random.randint(0, 255) for _ in range(count))
    return Response(content=data, media_type="application/octet-stream")


@app.get("/range/{start}/{end}")
async def range_endpoint(start: int, end: int):
    if start > end:
        start, end = end, start
    if end - start > 10000:
        end = start + 10000
    numbers = list(range(start, end + 1))
    return PlainTextResponse(
        content="\n".join(str(n) for n in numbers) + "\n",
        media_type="text/plain",
    )


# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------


@app.get("/basic-auth/{user}/{passwd}")
async def basic_auth_endpoint(request: Request, user: str, passwd: str):
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Basic "):
        raise HTTPException(
            status_code=401,
            detail="Unauthorized",
            headers={"WWW-Authenticate": f'Basic realm="poste-test"'},
        )

    import base64

    try:
        decoded = base64.b64decode(auth[6:]).decode("utf-8")
        provided_user, provided_pass = decoded.split(":", 1)
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid authorization header")

    if provided_user == user and provided_pass == passwd:
        return JSONResponse(
            {
                "authenticated": True,
                "user": user,
            }
        )
    else:
        raise HTTPException(
            status_code=401,
            detail="Unauthorized",
            headers={"WWW-Authenticate": f'Basic realm="poste-test"'},
        )


@app.get("/bearer")
async def bearer_endpoint(request: Request):
    auth = request.headers.get("authorization", "")
    if auth.startswith("Bearer "):
        token = auth[7:]
        return JSONResponse(
            {
                "authenticated": True,
                "token": token,
                "token_preview": token[:20] + "..." if len(token) > 20 else token,
            }
        )
    else:
        return JSONResponse({"authenticated": False, "error": "Missing Bearer token"})


# ---------------------------------------------------------------------------
# Cookies
# ---------------------------------------------------------------------------


@app.get("/cookies")
async def cookies_endpoint(request: Request):
    return JSONResponse(
        {
            "cookies": dict(request.cookies),
            "cookie_header": request.headers.get("cookie", ""),
        }
    )


@app.get("/cookies/set")
async def cookies_set_endpoint(request: Request):
    params = dict(request.query_params.items())
    resp = RedirectResponse(url="/cookies", status_code=302)
    for key, value in params.items():
        resp.set_cookie(key=key, value=value)
    return resp


@app.get("/cookies/delete")
async def cookies_delete_endpoint(request: Request):
    names = list(request.query_params.keys())
    resp = RedirectResponse(url="/cookies", status_code=302)
    for name in names:
        resp.delete_cookie(key=name)
    return resp


# ---------------------------------------------------------------------------
# File upload
# ---------------------------------------------------------------------------


@app.post("/upload")
async def upload_endpoint(request: Request):
    """Accept multipart file upload and echo file info."""
    content_type = request.headers.get("content-type", "")
    if "multipart/form-data" not in content_type:
        body = await request.body()
        return JSONResponse(
            {
                "error": "Expected multipart/form-data",
                "content_type": content_type,
                "body": body.decode("utf-8", errors="replace")[:1000],
            },
            status_code=400,
        )

    try:
        form = await request.form()
    except Exception as e:
        return JSONResponse({"error": f"Failed to parse form: {e}"}, status_code=400)

    result: dict[str, Any] = {
        "files": {},
        "form": {},
        "headers": dict(request.headers.items()),
    }

    for field_name, field_value in form.items():
        if hasattr(field_value, "read"):
            # It's a file
            content = await field_value.read()
            result["files"][field_name] = {
                "filename": field_value.filename,
                "content_type": field_value.content_type,
                "size": len(content),
                "content_preview": content.decode("utf-8", errors="replace")[:500],
            }
        else:
            result["form"][field_name] = field_value

    return JSONResponse(result)


# ---------------------------------------------------------------------------
# File store / download — for testing upload-then-download flows
# ---------------------------------------------------------------------------

import shutil

# File store — files are written to disk at {POSTE_FILE_STORE:-/tmp/poste_test_store}/{file_id}/
_FILE_STORE_ROOT = os.environ.get("POSTE_FILE_STORE", "/tmp/poste_test_store")

# Metadata kept in memory; actual file content lives on disk
_file_store: dict[str, dict[str, Any]] = {}
_file_store_lock = asyncio.Lock()


def _ensure_storage() -> str:
    os.makedirs(_FILE_STORE_ROOT, exist_ok=True)
    return _FILE_STORE_ROOT


def _file_disk_path(file_id: str) -> str:
    return os.path.join(_FILE_STORE_ROOT, file_id)


@app.on_event("startup")
async def _init_file_store():
    store_root = _ensure_storage()
    if not os.listdir(store_root):
        return
    for fid in os.listdir(store_root):
        meta_path = os.path.join(store_root, fid, "metadata.json")
        if os.path.isfile(meta_path):
            try:
                with open(meta_path) as f:
                    _file_store[fid] = json.load(f)
            except Exception:
                pass


@app.post("/store")
async def store_endpoint(request: Request):
    """Upload a file and store it server-side.

    Returns a file_id that can be used with GET /download/{file_id} to
    retrieve the file.  Accepts both multipart/form-data and raw body upload.

    Multipart form:  curl -F "file=@photo.jpg" http://localhost:8888/store
    Raw body:        curl -T photo.jpg http://localhost:8888/store
                     curl -X POST -H "Content-Type: image/png" \\
                       --data-binary @photo.png http://localhost:8888/store
    """
    file_id = str(uuid_mod.uuid4())
    filename = "uploaded_file"
    content_type = "application/octet-stream"
    raw = b""

    ct_header = request.headers.get("content-type", "")

    if "multipart/form-data" in ct_header:
        # Multipart upload — extract the file part
        raw_body = await request.body()
        normalized = raw_body.replace(b"\n", b"\r\n").replace(b"\r\r\n", b"\r\n")

        boundary = ""
        for part in ct_header.split(";"):
            part = part.strip()
            if part.startswith("boundary="):
                boundary = part[9:].strip('"').strip("'")
                break

        if boundary:
            parts = _parse_multipart(normalized, boundary.encode())
            for name, _, fname, fct, data in parts:
                if fname:
                    filename = fname
                    content_type = fct or "application/octet-stream"
                    raw = data
                    break
            if not raw and parts:
                # Treat first field as file if no filename present
                name, _, fname, fct, data = parts[0]
                if data:
                    filename = fname or f"{name}.bin"
                    content_type = fct or "application/octet-stream"
                    raw = data
        else:
            raw = normalized
    else:
        # Raw body upload (e.g. curl -T or --data-binary)
        raw = await request.body()
        # Infer filename from Content-Disposition or URL-encoded form
        disp = request.headers.get("content-disposition", "")
        if 'filename="' in disp:
            filename = disp.split('filename="')[1].split('"')[0]
        filename = request.headers.get(
            "x-filename",
            request.query_params.get("filename", filename),
        )
        content_type = request.headers.get(
            "content-type",
            request.query_params.get("content_type", content_type),
        )

    if not raw:
        return JSONResponse({"error": "No file data received"}, status_code=400)

    # ── Write to disk ──────────────────────────────────────────────
    store_root = _ensure_storage()
    file_dir = _file_disk_path(file_id)
    os.makedirs(file_dir, exist_ok=True)

    file_path = os.path.join(file_dir, filename)
    with open(file_path, "wb") as f:
        f.write(raw)

    meta = {
        "file_id": file_id,
        "filename": filename,
        "content_type": content_type,
        "size": len(raw),
        "file_path": file_path,
        "uploaded_at": datetime.now(timezone.utc).isoformat(),
    }
    meta_path = os.path.join(file_dir, "metadata.json")
    with open(meta_path, "w") as f:
        json.dump(meta, f)

    async with _file_store_lock:
        _file_store[file_id] = meta

    return JSONResponse(
        {
            "file_id": file_id,
            "filename": filename,
            "content_type": content_type,
            "size": len(raw),
            "disk_path": file_path,
            "download_url": f"/download/{file_id}",
        },
        status_code=201,
    )


@app.get("/download/{file_id}")
@app.head("/download/{file_id}")
async def download_endpoint(file_id: str, request: Request):
    """Download a previously stored file by file_id.

    Returns the file with original filename and content-type, or 404 if
    the file_id does not exist.

    Query parameters:
      disposition=attachment    — force download dialog (default)
      disposition=inline        — display in browser if possible
      filename=report.pdf       — override the download filename

    Supports:
      GET /download/{file_id}            — download the file
      GET /download/{file_id}?disposition=inline  — inline display
      HEAD /download/{file_id}           — check existence + headers only
      Range requests via Range header
    """
    async with _file_store_lock:
        entry = _file_store.get(file_id)

    if not entry:
        raise HTTPException(status_code=404, detail="File not found")

    file_path = entry.get("file_path", "")
    content_type = entry["content_type"]
    filename = entry["filename"]
    file_size = entry["size"]
    etag = f'"{file_id}"'

    # Override disposition/filename via query params (for testing)
    disposition = request.query_params.get("disposition", "attachment")
    if disposition not in ("inline", "attachment"):
        disposition = "attachment"
    disp_filename = request.query_params.get("filename", filename)

    # Read from disk
    try:
        with open(file_path, "rb") as f:
            data = f.read()
    except (FileNotFoundError, OSError):
        async with _file_store_lock:
            _file_store.pop(file_id, None)
        raise HTTPException(status_code=404, detail="File not found on disk")

    # Handle Range requests
    range_header = request.headers.get("range", "")
    if range_header and range_header.startswith("bytes="):
        return _handle_range_request(data, content_type, disp_filename, etag, range_header)

    common_headers = {
        "Content-Disposition": f'{disposition}; filename="{disp_filename}"',
        "Content-Length": str(file_size),
        "ETag": etag,
        "Accept-Ranges": "bytes",
        "X-File-Id": file_id,
        "X-Disk-Path": file_path,
    }

    if request.method == "HEAD":
        return Response(
            headers={
                "Content-Type": content_type,
                **common_headers,
            }
        )

    return Response(
        content=data,
        media_type=content_type,
        headers=common_headers,
    )


@app.get("/files")
async def list_files_endpoint():
    """List all stored files with metadata (no file data)."""
    async with _file_store_lock:
        entries = list(_file_store.items())

    result = []
    for file_id, entry in sorted(entries, key=lambda x: x[1].get("uploaded_at", "")):
        result.append(
            {
                "file_id": file_id,
                "filename": entry["filename"],
                "content_type": entry["content_type"],
                "size": entry["size"],
                "disk_path": entry.get("file_path", ""),
                "uploaded_at": entry["uploaded_at"],
                "download_url": f"/download/{file_id}",
            }
        )

    return JSONResponse({"files": result, "count": len(result)})


@app.delete("/files/{file_id}")
async def delete_file_endpoint(file_id: str):
    """Delete a stored file by file_id.

    Removes both the file from disk and its metadata from the store.
    Returns 200 on success, 404 if file_id does not exist.
    """
    async with _file_store_lock:
        entry = _file_store.pop(file_id, None)

    if not entry:
        raise HTTPException(status_code=404, detail="File not found")

    file_dir = _file_disk_path(file_id)
    if os.path.isdir(file_dir):
        shutil.rmtree(file_dir)

    return JSONResponse(
        {
            "deleted": True,
            "file_id": file_id,
            "filename": entry["filename"],
            "size": entry["size"],
            "disk_path": entry.get("file_path", ""),
        }
    )


def _handle_range_request(
    data: bytes,
    content_type: str,
    filename: str,
    etag: str,
    range_header: str,
) -> Response:
    """Handle HTTP Range requests (partial content)."""
    try:
        range_val = range_header.replace("bytes=", "").strip()
        if "-" in range_val:
            start_str, end_str = range_val.split("-", 1)
            start = int(start_str) if start_str else 0
            end = int(end_str) if end_str else len(data) - 1
        else:
            start = int(range_val)
            end = len(data) - 1

        if start < 0:
            start = 0
        if end >= len(data):
            end = len(data) - 1
        if start > end:
            raise ValueError("Invalid range")

        chunk = data[start : end + 1]
        return Response(
            content=chunk,
            status_code=206,
            media_type=content_type,
            headers={
                "Content-Range": f"bytes {start}-{end}/{len(data)}",
                "Content-Length": str(len(chunk)),
                "Content-Disposition": f'attachment; filename="{filename}"',
                "ETag": etag,
                "Accept-Ranges": "bytes",
            },
        )
    except (ValueError, IndexError):
        return Response(
            status_code=416,
            headers={"Content-Range": f"bytes */{len(data)}"},
        )


def _parse_multipart(
    body: bytes, boundary: bytes
) -> list[tuple[str, str, str | None, str | None, bytes]]:
    """Simple multipart/form-data parser that accepts LF or CRLF line endings."""
    delim = b"--" + boundary
    parts_raw = body.split(delim)
    results: list[tuple[str, str, str | None, str | None, bytes]] = []

    for part in parts_raw:
        part = part.strip(b"\r\n").strip(b"\n")
        if not part or part.startswith(b"--"):
            continue

        part_normalized = part.replace(b"\r\n", b"\n")
        blank_idx = part_normalized.find(b"\n\n")
        if blank_idx == -1:
            header_section = part_normalized
            body_data = b""
        else:
            header_section = part_normalized[:blank_idx]
            body_data = part_normalized[blank_idx + 2 :]

        name = ""
        filename: str | None = None
        file_content_type: str | None = None

        for hline in header_section.split(b"\n"):
            hline = hline.strip()
            if not hline:
                continue
            hline_lower = hline.lower()
            if hline_lower.startswith(b"content-disposition:"):
                disp = hline[len(b"content-disposition:"):].strip()
                for attr in disp.split(b";"):
                    attr = attr.strip()
                    if attr.startswith(b"name="):
                        name = _unquote_multipart(attr[5:])
                    elif attr.startswith(b"filename="):
                        filename = _unquote_multipart(attr[9:])
            elif hline_lower.startswith(b"content-type:"):
                file_content_type = (
                    hline[len(b"content-type:"):].strip().decode("utf-8", errors="replace")
                )

        if name:
            results.append((name, name, filename, file_content_type, body_data))

    return results


def _unquote_multipart(value: bytes) -> str:
    """Remove surrounding quotes from a multipart parameter value."""
    s = value.decode("utf-8", errors="replace")
    if len(s) >= 2 and s[0] in ('"', "'") and s[0] == s[-1]:
        s = s[1:-1]
    return s


# ---------------------------------------------------------------------------
# URL-encoded form echo
# ---------------------------------------------------------------------------


@app.post("/form")
async def form_endpoint(request: Request):
    body = await request.body()
    body_str = body.decode("utf-8", errors="replace")

    from urllib.parse import parse_qs

    parsed = parse_qs(body_str)
    # Flatten single-value lists
    flat = {k: v[0] if len(v) == 1 else v for k, v in parsed.items()}

    return JSONResponse(
        {
            "form": flat,
            "raw": body_str,
            "headers": dict(request.headers.items()),
        }
    )


# ---------------------------------------------------------------------------
# Encoding / Compression
# ---------------------------------------------------------------------------


@app.get("/encoding/{code}")
async def encoding_endpoint(code: str):
    """Return a body with specific charset encoding."""
    text = f"Hello, this is a {code} encoded response.\n"
    if code.lower() in ("utf-8", "utf8"):
        return PlainTextResponse(content=text, media_type=f"text/plain; charset=utf-8")
    elif code.lower() in ("iso-8859-1", "latin1"):
        encoded = text.encode("iso-8859-1", errors="replace")
        return Response(content=encoded, media_type="text/plain; charset=iso-8859-1")
    elif code.lower() in ("shift_jis", "shift-jis"):
        encoded = text.encode("shift_jis", errors="replace")
        return Response(content=encoded, media_type="text/plain; charset=shift_jis")
    else:
        return PlainTextResponse(content=text, media_type=f"text/plain; charset={code}")


@app.get("/gzip")
async def gzip_endpoint():
    import gzip

    data = json.dumps(
        {
            "gzipped": True,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "method": "gzip",
        }
    ).encode()
    compressed = gzip.compress(data)
    return Response(content=compressed, media_type="application/json", headers={"Content-Encoding": "gzip"})


@app.get("/deflate")
async def deflate_endpoint():
    import zlib

    data = json.dumps(
        {
            "deflated": True,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "method": "deflate",
        }
    ).encode()
    compressed = zlib.compress(data)
    return Response(content=compressed, media_type="application/json", headers={"Content-Encoding": "deflate"})


# ---------------------------------------------------------------------------
# Caching
# ---------------------------------------------------------------------------


@app.get("/cacheable")
async def cacheable_endpoint():
    etag = f'"{hash(datetime.now().strftime("%Y-%m-%d"))}"'
    return JSONResponse(
        content={
            "cached": True,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "etag": etag,
        },
        headers={
            "ETag": etag,
            "Last-Modified": datetime.now(timezone.utc).strftime(
                "%a, %d %b %Y %H:%M:%S GMT"
            ),
            "Cache-Control": "public, max-age=3600",
        },
    )


@app.get("/cache/{seconds}")
async def cache_endpoint(seconds: int):
    return JSONResponse(
        content={
            "cached": True,
            "max_age": seconds,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        },
        headers={"Cache-Control": f"public, max-age={seconds}"},
    )


@app.get("/cached/{etag}")
async def cached_etag_endpoint(request: Request, etag: str):
    if_none_match = request.headers.get("if-none-match", "")
    if if_none_match == f'"{etag}"' or if_none_match == etag:
        return Response(status_code=304)
    return JSONResponse(
        content={"etag": etag, "timestamp": datetime.now(timezone.utc).isoformat()},
        headers={"ETag": f'"{etag}"'},
    )


# ---------------------------------------------------------------------------
# Response headers echo
# ---------------------------------------------------------------------------


@app.get("/response-headers")
async def response_headers_endpoint(request: Request):
    """Set custom response headers from query parameters."""
    headers = {}
    for key, value in request.query_params.multi_items():
        headers[key] = value
    return JSONResponse(
        content={"headers": headers},
        headers=headers,
    )


# ---------------------------------------------------------------------------
# Links page
# ---------------------------------------------------------------------------


@app.get("/links/{count}")
async def links_endpoint(count: int):
    if count < 0:
        count = 0
    if count > 100:
        count = 100
    links_html = "\n".join(
        f'  <li><a href="/links/{i}">link {i}</a></li>' for i in range(count)
    )
    return HTMLResponse(
        content=f"""<!DOCTYPE html>
<html><body>
  <h1>{count} Links</h1>
  <ul>
{links_html}
  </ul>
</body></html>"""
    )


# ---------------------------------------------------------------------------
# Image generation
# ---------------------------------------------------------------------------


SAMPLE_SVG = """<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">
  <rect width="200" height="200" fill="#f0f0f0"/>
  <circle cx="100" cy="80" r="40" fill="#4A90D9"/>
  <rect x="60" y="130" width="80" height="60" fill="#50C878" rx="5"/>
</svg>"""


@app.get("/image/png")
@app.get("/image/jpeg")
@app.get("/image/webp")
@app.get("/image/svg")
async def image_endpoint(request: Request):
    """Return a sample image."""
    # Extract format from path
    path = request.url.path
    fmt = path.rsplit("/", 1)[-1].lower()

    if fmt == "svg":
        return Response(content=SAMPLE_SVG, media_type="image/svg+xml")

    # For raster formats, return a minimal valid PNG
    # (A 1x1 pixel PNG is tiny and universally viewable)
    # This works for png, and most browsers/clients will accept it for
    # jpeg/webp too since we're just testing HTTP, not rendering.
    minimal_png = bytes(
        [
            0x89,
            0x50,
            0x4E,
            0x47,  # PNG signature
            0x0D,
            0x0A,
            0x1A,
            0x0A,
            0x00,
            0x00,
            0x00,
            0x0D,  # IHDR chunk
            0x49,
            0x48,
            0x44,
            0x52,
            0x00,
            0x00,
            0x00,
            0x01,
            0x00,
            0x00,
            0x00,
            0x01,
            0x08,
            0x02,
            0x00,
            0x00,
            0x00,
            0x90,
            0x77,
            0x53,
            0xDE,
            0x00,
            0x00,
            0x00,
            0x0C,  # IDAT chunk
            0x49,
            0x44,
            0x41,
            0x54,
            0x08,
            0xD7,
            0x63,
            0xF8,
            0xCF,
            0xC0,
            0x00,
            0x00,
            0x00,
            0x03,
            0x00,
            0x01,
            0x26,
            0xE0,
            0xFE,
            0x0E,
            0x00,
            0x00,
            0x00,
            0x00,  # IEND chunk
            0x49,
            0x45,
            0x4E,
            0x44,
            0xAE,
            0x42,
            0x60,
            0x82,
        ]
    )  # yapf: disable

    media_type = f"image/{fmt}" if fmt != "jpeg" else "image/jpeg"
    return Response(content=minimal_png, media_type=media_type)


# ---------------------------------------------------------------------------
# Drip endpoint — stream data slowly
# ---------------------------------------------------------------------------


@app.get("/drip")
async def drip_endpoint(numbytes: int = 100, duration: float = 2.0, code: int = 200):
    if numbytes < 0:
        numbytes = 0
    if numbytes > 10240:
        numbytes = 10240
    if duration < 0:
        duration = 0
    if duration > 30:
        duration = 30

    chunk_size = max(1, numbytes // max(1, int(duration * 10)))
    total_chunks = max(1, numbytes // chunk_size)
    sleep_time = duration / total_chunks if total_chunks > 0 else 0

    async def generate():
        for i in range(total_chunks):
            chunk = "*" * min(chunk_size, numbytes - i * chunk_size)
            yield chunk
            if sleep_time > 0:
                await asyncio.sleep(sleep_time)

    return StreamingResponse(
        generate(),
        status_code=code,
        media_type="application/octet-stream",
        headers={
            "X-Drip-NumBytes": str(numbytes),
            "X-Drip-Duration": str(duration),
        },
    )


# ---------------------------------------------------------------------------
# Catch-all 404
# ---------------------------------------------------------------------------


@app.get("/api")
@app.get("/api/{path:path}")
async def api_catchall(request: Request, path: str = ""):
    """Mock API endpoint — returns JSON regardless."""
    body = await request.body()
    return JSONResponse(
        {
            "method": request.method,
            "path": f"/api/{path}",
            "params": dict(request.query_params.multi_items()),
            "headers": dict(request.headers.items()),
            "body": body.decode("utf-8", errors="replace")[:2000] if body else None,
        }
    )


# ---------------------------------------------------------------------------
# Main entry point (also runnable directly for testing)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    host = os.environ.get("POSTE_TEST_HOST", "127.0.0.1")
    port = int(os.environ.get("POSTE_TEST_PORT", "8888"))

    print(
        f"\n  Poste Test HTTP Server"
        f"\n  {'─' * 40}"
        f"\n  URL:  http://{host}:{port}"
        f"\n  Docs: http://{host}:{port}/docs"
        f"\n  {'─' * 40}\n"
    )
    uvicorn.run(app, host=host, port=port, log_level="info")