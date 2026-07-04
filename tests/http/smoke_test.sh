#!/usr/bin/env bash
# Smoke test for the Poste Test HTTP Server
# Usage: ./smoke_test.sh [host]
#   host defaults to http://localhost:8888

set -euo pipefail

HOST="${1:-http://localhost:8888}"
PASS=0
FAIL=0

green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }
bold()  { printf "\033[1m%s\033[0m" "$1"; }

check() {
    local desc="$1"
    local method="$2"
    local url="$3"
    shift 3
    local expected_code="${1:-200}"
    shift 1

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$url" "$@")
    if [ "$status" = "$expected_code" ]; then
        green "  ✓ $desc ($status)"
        PASS=$((PASS + 1))
    else
        red "  ✗ $desc (expected $expected_code, got $status)"
        FAIL=$((FAIL + 1))
    fi
}

check_json() {
    local desc="$1"
    local url="$2"
    local jq_filter="$3"

    if curl -sf "$url" | jq -e "$jq_filter" > /dev/null 2>&1; then
        green "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        red "  ✗ $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo
bold "Poste Test HTTP Server — Smoke Test"
echo
bold "Server: $HOST"
echo
echo

# ── Basic endpoints ──────────────────────────────────────────────
echo "━━━ Basic Endpoints ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check "Health"          GET  "$HOST/health"
check "GET /get"        GET  "$HOST/get?foo=bar"
check "POST /post"      POST "$HOST/post" -H "Content-Type: application/json" -d '{"a":1}'
check "PUT /put"        PUT  "$HOST/put"  -H "Content-Type: application/json" -d '{"a":1}'
check "PATCH /patch"    PATCH "$HOST/patch" -H "Content-Type: application/json" -d '{"a":1}'
check "DELETE /delete"  DELETE "$HOST/delete"
check "HEAD /head"      HEAD "$HOST/head"
check "OPTIONS /options" OPTIONS "$HOST/options"

# ── Headers echo ──────────────────────────────────────────────────
echo
echo "━━━ Headers / Status / Delay ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check "Headers echo"    GET "$HOST/headers"
check "Status 200"      GET "$HOST/status/200"
check "Status 404"      GET "$HOST/status/404" "" 404
check "Status 500"      GET "$HOST/status/500" "" 500
check "Status 401"      GET "$HOST/status/401" "" 401
check "Delay 0.5s"      GET "$HOST/delay/0.5"

# ── Redirects ─────────────────────────────────────────────────────
echo
echo "━━━ Redirects ───────────────────────────────────────────────"
check "Redirect /2"     GET "$HOST/redirect/2" -L "" 200

# ── Anything ──────────────────────────────────────────────────────
echo
echo "━━━ Anything / Echo ─────────────────────────────────────────"
check "GET /anything"   GET "$HOST/anything?x=1"
check "POST /anything"  POST "$HOST/anything" -H "Content-Type: application/json" -d '{"x":1}'

# ── Content types ─────────────────────────────────────────────────
echo
echo "━━━ Content Types ───────────────────────────────────────────"
check "JSON endpoint"   GET "$HOST/json"
check "XML endpoint"    GET "$HOST/xml"
check "HTML endpoint"   GET "$HOST/html"
check "robots.txt"      GET "$HOST/robots.txt"
check "UUID"            GET "$HOST/uuid"
check "Bytes 100"       GET "$HOST/bytes/100"

# ── Auth ──────────────────────────────────────────────────────────
echo
echo "━━━ Authentication ──────────────────────────────────────────"
check "Basic auth (valid)" GET "$HOST/basic-auth/admin/secret" -u "admin:secret"
check "Basic auth (invalid)" GET "$HOST/basic-auth/admin/wrong" "" 401
check "Bearer token"    GET "$HOST/bearer" -H "Authorization: Bearer testtoken123"

# ── Cookies ──────────────────────────────────────────────────────
echo
echo "━━━ Cookies ─────────────────────────────────────────────────"
check "Set cookie"      GET "$HOST/cookies/set?test=value" -L "" 200
check "Read cookies"    GET "$HOST/cookies" -b "test=value"

# ── Form / Upload ─────────────────────────────────────────────────
echo
echo "━━━ Form / Upload ───────────────────────────────────────────"
check "Form post"       POST "$HOST/form" -H "Content-Type: application/x-www-form-urlencoded" -d "name=test&value=1"
check "Upload"          POST "$HOST/upload" -F "file=@test_data.txt"

# ── Compression ──────────────────────────────────────────────────
echo
echo "━━━ Compression / Encoding ──────────────────────────────────"
check "Gzip"            GET "$HOST/gzip" -H "Accept-Encoding: gzip"
check "Deflate"         GET "$HOST/deflate" -H "Accept-Encoding: deflate"

# ── JSON correctness checks ──────────────────────────────────────
echo
echo "━━━ JSON Correctness ────────────────────────────────────────"
check_json "Health JSON has status=ok"       "$HOST/health" '.status == "ok"'
check_json "UUID is valid format"            "$HOST/uuid"   '.uuid | test("^[0-9a-f-]+$")'
check_json "JSON has slideshow"             "$HOST/json"   '.slideshow.author == "Poste Test Server"'

# ── Summary ──────────────────────────────────────────────────────
echo
echo "━━━ Results ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
total=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    green "  All $PASS/$total tests passed!"
else
    red "  $PASS/$total passed, $FAIL failed"
    exit 1
fi
echo
