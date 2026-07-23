#!/bin/bash
# Build the tree-sitter C parser for Poste HTTP (.so shared library)
set -euo pipefail
cd "$(dirname "$0")/../tree-sitter-poste-http"

echo "Generating parser..."
tree-sitter generate

echo "Compiling C parser..."
SRC="src/parser.c"
OUT="src/parser.o"
SHARED="tree-sitter-poste_http.so"

gcc -c -I"src" -fPIC -O2 -o "$OUT" "$SRC"
gcc -shared -o "$SHARED" "$OUT"

echo "Done: $SHARED"
echo "Install: cp $SHARED \$HOME/.local/share/kickstart/site/parser/poste_http.so"
