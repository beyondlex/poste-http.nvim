#!/usr/bin/env bash
# Grammar test: verify parser correctly handles key structures
set -euo pipefail

PARSER_DIR="$(cd "$(dirname "$0")/.." && pwd)/tree-sitter-poste-http"
REPO_ROOT="$(dirname "$PARSER_DIR")"
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

check_not() {
  local name="$1"; shift
  local input="$1"; shift
  local unexpected="$1"; shift
  local result=$(parse "$input" 2>&1)
  if echo "$result" | grep -q "$unexpected"; then
    echo "  FAIL: $name"
    echo "    must NOT contain: $unexpected"
    echo "    got: $(echo "$result" | head -5)"
    fail=$((fail+1))
  else
    echo "  PASS: $name"
    pass=$((pass+1))
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
  "json_body"

check "JSON body stops at ###" \
$'### A\nPOST /a\n\n{"x":1}\n\n### B\nGET /b' \
  "request_block"

check "{{var}} in URL" \
  "GET {{base_url}}/api/{{version}}/test" \
  "url"

check "multiple headers" \
  $'GET /test\nContent-Type: app/json\nAccept: */*' \
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

check "run directive with ./path" \
  "run ./helper_batch.http" \
  "run_target_name"

check "run directive with alias.name" \
  "run #auth.LoginWithToken (@token=abc)" \
  "run_target_prefix"

check "GRAPHQL request line" \
  "GRAPHQL https://api.example.com/graphql" \
  "method_graphql"

check "GRPC request line" \
  "GRPC localhost:50051/pkg.Service/Method" \
  "method_grpc"

check "WEBSOCKET request line" \
  "WEBSOCKET wss://stream.example.com/feed" \
  "method_websocket"

check "GRAPHQL query body" \
$'GRAPHQL https://api.example.com/graphql\n\nquery User($id: ID!) {\n  user(id: $id) { id name email }\n}' \
  "graphql_body"

check "GRAPHQL mutation body" \
$'GRAPHQL https://api.example.com/graphql\n\nmutation {\n  add(a: 19, b: 23)\n}' \
  "graphql_body"

# Regression: without graphql_body the query text was error-recovered into
# header nodes (Request Headers got "mutation: 19, b: 23)").
check_not "GRAPHQL mutation text is not parsed as a header" \
$'GRAPHQL https://api.example.com/graphql\n\nmutation {\n  add(a: 19, b: 23)\n}' \
  "(header"

check_not "GRAPHQL query text is not parsed as a header" \
$'GRAPHQL https://api.example.com/graphql\n\nquery User($id: ID!) {\n  user(id: $id) { id name email }\n}' \
  "(header"

# ─── Query file sync ─────────────────────────────
# The grammar package (queries/ here) is authoritative; the nvim-facing
# copies (../queries/poste_http/) must stay identical. When they drifted,
# Neovim silently lost captures for new nodes (GRAPHQL/GRPC/WEBSOCKET
# methods never highlighted despite a correct parse tree).
echo "=== Query file sync (grammar package <-> nvim rtp) ==="
for f in "$PARSER_DIR"/queries/*.scm; do
  name="$(basename "$f")"
  nvim_copy="$REPO_ROOT/queries/poste_http/$name"
  if [ ! -f "$nvim_copy" ]; then
    echo "  FAIL: $name missing from queries/poste_http/"
    fail=$((fail+1))
  elif diff -q "$f" "$nvim_copy" >/dev/null; then
    echo "  PASS: $name in sync"
    pass=$((pass+1))
  else
    echo "  FAIL: $name drifted from the grammar package (authoritative copy: tree-sitter-poste-http/queries/)"
    diff "$f" "$nvim_copy" | head -10
    fail=$((fail+1))
  fi
done

echo "=== Results: $pass passed, $fail failed ==="
exit $fail