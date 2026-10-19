#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST="$ROOT/linux/upstream-parity.json"
REF=${UPSTREAM_REF:-upstream/main}

if [ ! -f "$MANIFEST" ]; then
  echo "missing parity manifest: $MANIFEST" >&2
  exit 2
fi

if ! git -C "$ROOT" rev-parse --verify "$REF^{commit}" >/dev/null 2>&1; then
  echo "cannot resolve upstream reference: $REF" >&2
  exit 2
fi

failures=0
if ! python3 "$ROOT/scripts/check-upstream-content.py" --ref "$REF"; then
  failures=$((failures + 1))
fi

# Run every independent check even after a failure, retaining each command's diagnostics and exit status.
check() {
  label=$1
  shift
  if "$@"; then
    echo "PASS: $label"
  else
    status=$?
    echo "FAIL: $label (exit $status)" >&2
    failures=$((failures + 1))
  fi
}

check "protected-content fault tests" python3 "$ROOT/tests/test_upstream_content.py"
check "checked adjustment kernel" python3 "$ROOT/scripts/gen-checked-adjust-kernel.py" --check
check "Smudge/Liquify generator" python3 "$ROOT/scripts/gen-smudge-liquify-override.py" --check
check "text format generator" python3 "$ROOT/scripts/gen-text-format-11.py" --check
check "Color Range generator" python3 "$ROOT/scripts/gen-color-range.py" --check
check "app generator" bash "$ROOT/scripts/gen-compositorapp-override.sh" --check
check "project validation generator" python3 "$ROOT/scripts/gen-project-validation.py" --check
check "preview renderer generator" python3 "$ROOT/scripts/gen-preview-renderer.py" --check
check "Objective-C generator" python3 "$ROOT/scripts/gen-objc-overrides.py" --check
check "patched overrides generator" python3 "$ROOT/scripts/gen-patched-overrides.py" --check
check "test mirrors generator" python3 "$ROOT/scripts/gen-linux-test-mirrors.py" --check
check "SF Symbol icons (every upstream symbol drawn)" python3 "$ROOT/scripts/gen-lucide-icons.py" --check
check "About version (host/AppVersion.h)" bash "$ROOT/scripts/sync-version.sh" --check
check "Compat SwiftUI no-ops (every upstream use explained)" python3 "$ROOT/scripts/check-compat-noops.py"
# Vulkan shader headers match their .comp sources (effects recolor, brush coverage, composite).
# REQUIRE_SHADER_CHECK=1 (CI) makes a missing glslangValidator a failure rather than a note.
if command -v glslangValidator >/dev/null 2>&1; then
  check "Vulkan shader headers" python3 "$ROOT/scripts/build-brush-shader.py" --check
elif [ "${REQUIRE_SHADER_CHECK:-0}" = 1 ]; then
  echo "FAIL: Vulkan shader headers (glslangValidator not found)" >&2
  failures=$((failures + 1))
else
  echo "note: glslangValidator not found; Vulkan shader headers NOT checked" >&2
fi
check "override drift" python3 "$ROOT/scripts/upstream-override-drift.py" --check
check "1.4.6–1.4.8 ledger" python3 "$ROOT/scripts/upstream-ledger-rows.py" --check docs/upstream-1.4.6-1.4.8-ledger.md --from 11d8d7a --to 22c7b8d
check "1.4.9 ledger" python3 "$ROOT/scripts/upstream-ledger-rows.py" --check docs/upstream-1.4.9-ledger.md --from 22c7b8d --to b4bfdea
check "post-1.4.9 ledger" python3 "$ROOT/scripts/upstream-ledger-rows.py" --check docs/upstream-after-1.4.9-ledger.md --from b4bfdea --to 39d1257 --include-kernels
check "1.4.10 ledger" python3 "$ROOT/scripts/upstream-ledger-rows.py" --check docs/upstream-1.4.10-ledger.md --from 39d1257 --to a1bd74c --include-kernels
check "post-1.4.10 ledger" python3 "$ROOT/scripts/upstream-ledger-rows.py" --check docs/upstream-after-1.4.10-ledger.md --include-kernels

if [ "$failures" -ne 0 ]; then
  echo "UPSTREAM CHECK FAILED: $failures checks failed" >&2
  exit 1
fi
echo "UPSTREAM CLEAN: protected trees match $REF"
