#!/usr/bin/env bash
# Run the graphics package E2E benchmark (reference backend by default).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export PYTHONPATH="$root${PYTHONPATH:+:$PYTHONPATH}"
artifacts="${UI_BENCH_ARTIFACTS:-/tmp/compositor-graphics-bench-$$}"
level="${1:-small}"
backend="${2:-reference}"
workers="${3:-1}"
mkdir -p "$artifacts"
echo "Graphics bench artifacts: $artifacts"
python3 -m tests.bench.runner run \
  --level "$level" \
  --backend "$backend" \
  --workers "$workers" \
  --artifacts "$artifacts"
echo "Report: $artifacts/report.md"
