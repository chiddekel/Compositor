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

set --
for root in Compositor CompositorTests; do
  while IFS= read -r path; do
    [ -n "$path" ] && set -- "$@" "$path"
  done <<EOF
$(git -C "$ROOT" diff --name-only "$REF" -- "$root")
$(git -C "$ROOT" ls-files --others --exclude-standard -- "$root")
EOF
done

if [ "$#" -eq 0 ]; then
  python3 "$ROOT/scripts/gen-smudge-liquify-override.py" --check
  python3 "$ROOT/scripts/gen-text-format-11.py" --check
  python3 "$ROOT/scripts/gen-color-range.py" --check
  bash "$ROOT/scripts/gen-compositorapp-override.sh" --check
  python3 "$ROOT/scripts/gen-project-validation.py" --check
  python3 "$ROOT/scripts/gen-preview-renderer.py" --check
  # Vulkan shader headers match their .comp sources (effects recolor, brush coverage, composite).
  if command -v glslangValidator >/dev/null 2>&1; then python3 "$ROOT/scripts/build-brush-shader.py" --check
  else echo "note: glslangValidator not found; Vulkan shader headers NOT checked" >&2; fi
  # Hand-kept overrides have taken every upstream change in the ledger range; the ledger matches git.
  python3 "$ROOT/scripts/upstream-override-drift.py" --check
  python3 "$ROOT/scripts/upstream-ledger-rows.py" --check docs/upstream-1.4.6-1.4.8-ledger.md --from 11d8d7a --to 22c7b8d
  python3 "$ROOT/scripts/upstream-ledger-rows.py" --check docs/upstream-1.4.9-ledger.md
  echo "UPSTREAM CLEAN: protected trees match $REF"
  exit 0
fi

echo "UPSTREAM DRIFT: protected trees differ from $REF" >&2
printf '%s\n' "$@" | sort -u >&2
echo "Move Linux-only changes behind Sources/Compat, Sources/Overrides, Sources/UpstreamCore/LinuxSupport, or host adapters." >&2
exit 1
