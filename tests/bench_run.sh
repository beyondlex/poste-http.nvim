#!/bin/bash
# Dataset benchmark runner
# Usage:
#   ./tests/bench_run.sh                     # → benchmark_output.json
#   ./tests/bench_run.sh output.json         # → output.json
#   ./tests/bench_run.sh compare base.json opt.json   # diff baseline vs optimized

set -e

cd "$(dirname "$0")/.."

if [ "$1" = "compare" ]; then
    if [ $# -lt 3 ]; then
        echo "Usage: $0 compare <baseline.json> <optimized.json>"
        exit 1
    fi
    shift
    BASELINE="$1"
    OPTIMIZED="$2"
    nvim --headless \
        -c "set rtp+=." \
        -c "runtime plugin/poste.lua" \
        -c "lua require('tests.bench_dataset').compare('$BASELINE', '$OPTIMIZED')" \
        -c "qa"
else
    OUTPUT="${1:-benchmark_output.json}"
    echo "Running benchmark → $OUTPUT"
    nvim --headless \
        -c "set rtp+=." \
        -c "runtime plugin/poste.lua" \
        -c "lua require('tests.bench_dataset').run('$OUTPUT')" \
        -c "qa"
    echo "Benchmark complete: $OUTPUT"
fi
