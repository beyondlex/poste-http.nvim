#!/usr/bin/env bash
# Grammar test: verify parser correctly handles key structures
set -euo pipefail

PARSER_DIR="$(cd "$(dirname "$0")/.." && pwd)/tree-sitter-poste-http"
TEST_DIR="$(mktemp -d)"

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# Rebuild parser
cd "$PARSER_DIR"
tree-sitter generate 2>&1
cc -shared -fPIC -o "$TEST_DIR/poste_http.so" src/parser.c -I src/tree_sitter

parse() {
  echo "$1" > "$TEST_DIR/input.http"
  tree-sitter parse "$TEST_DIR/input.http" 2>/dev/null
}

pass=0
fail=0

check() {
  local name="$1"; shift
  local input="$1"; shift
  local expected="$1"; shift
  local result=$(parse "$input" 2>&1)
  if echo "$result" | grep -q "$expected"; then
    echo "  PASS: $name"
    pass=$((pass+1))
  else
    echo "  FAIL: $name"
    echo "    expected: $expected"
    echo "    got: $(echo "$result" | head -5)"
    fail=$((fail+1))
  fi
}

echo "=== Grammar Tests ==="

check "request_line with method" \
  "GET /test" \
  "request_line"

check "request_line with POST and {{var}} in URL" \
  "POST {{base_url}}/post" \
  "request_line"

check "header line" \
  "Content-Type: application/json" \
  "header"

check "request_block with ###" \
  "### Request name" \
  "request_block"

check "multi-line JSON body" \
$'### Create\nPOST /users\nContent-Type: application/json\n\n{\n"name": "John"\n}\n\n### Next\nGET /test' \
  "request_body"

check "JSON body stops at ###" \
$'### A\nPOST /a\n\n{"x":1}\n\n### B\nGET /b' \
  "request_block"

check "{{var}} in URL" \
  "GET {{base_url}}/api/{{version}}/test" \
  "url"

check "multiple headers" \
  "GET /test\nContent-Type: app/json\nAccept: */*" \
  "header"

check "pre_script inline" \
  "< {% print('hello') %}" \
  "pre_script"

check "post_script inline" \
  "> {% assert(status == 200) %}" \
  "post_script"

check "pre_script multi-line" \
  $'< {%\n  print("hello")\n%}' \
  "pre_script"

check "pre_script and post_script are separate" \
  $'< {% print("hello") %}\n> {% assert(status == 200) %}' \
  "post_script"

check "JSON body does not consume post-script" \
  $'POST /test\nContent-Type: application/json\n\n{\n  "key": "value"\n}\n\n> {% assert(status == 200) %}' \
  "post_script"

echo "=== Results: $pass passed, $fail failed ==="
exit $fail