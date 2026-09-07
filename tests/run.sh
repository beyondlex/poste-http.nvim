#!/bin/bash
# Run tests with plenary
# Usage: ./tests/run.sh [plenary_path]

set -e

cd "$(dirname "$0")/.."

PLENARY_PATH="${1:-$HOME/.local/share/nvim/lazy/plenary.nvim}"
if [ ! -d "$PLENARY_PATH" ]; then
    echo "Error: plenary.nvim not found at $PLENARY_PATH"
    echo "Usage: $0 [path-to-plenary.nvim]"
    exit 1
fi

echo "Running tests (plenary: $PLENARY_PATH)..."

echo "--- tree-sitter grammar tests ---"
bash tests/grammar_spec.sh

echo "--- tree-sitter injection tests ---"
bash tests/injection_spec.sh

echo "--- Lua unit tests ---"
TEST_OUTPUT=$(nvim --headless -u NONE \
  -c "set rtp+=$PLENARY_PATH" \
  -c "set rtp+=." \
  -c "runtime plugin/plenary.vim" \
  -c "runtime plugin/poste.lua" \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}" \
  -c "qa" 2>&1) && TEST_EXIT=0 || TEST_EXIT=$?
echo "$TEST_OUTPUT"

if [ "$TEST_EXIT" -ne 0 ]; then
    echo "FAIL: unit tests exited with $TEST_EXIT"
    exit "$TEST_EXIT"
fi

# The headless runner can exit before async spec output flushes on slow
# machines, ending the run early with exit 0. Every discovered spec file
# must have printed its "Testing: <file>" banner.
SPEC_RUN=$(printf '%s\n' "$TEST_OUTPUT" | grep -c "^Testing:" || true)
SPEC_TOTAL=$(find tests -name '*_spec.lua' | wc -l | tr -d ' ')
echo "Spec files run: $SPEC_RUN/$SPEC_TOTAL"
if [ "$SPEC_RUN" -ne "$SPEC_TOTAL" ]; then
    echo "FAIL: expected $SPEC_TOTAL spec files, saw $SPEC_RUN (truncated run?)"
    exit 1
fi
