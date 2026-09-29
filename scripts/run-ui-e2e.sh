#!/usr/bin/env bash
# Build and drive the Linux host with native desktop input. See docs/linux-ui-e2e.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
build=1
if [[ "${1:-}" == --no-build ]]; then build=0; shift; fi
artifacts="${UI_E2E_ARTIFACTS:-$(mktemp -d /tmp/compositor-ui-e2e.XXXXXX)}"
mkdir -p "$artifacts"
echo "UI E2E artifacts: $artifacts"
visible=0
for arg in "$@"; do
    if [[ "$arg" == --visible ]]; then visible=1; fi
done
deps=(flatpak python3 dbus-run-session Xvfb)
(( visible )) && deps+=(Xephyr)
for command in "${deps[@]}"; do
    command -v "$command" >/dev/null || { echo "Missing dependency: $command" >&2; exit 1; }
done
python3 -c 'from PIL import Image; import ctypes; ctypes.CDLL("libX11.so.6"); ctypes.CDLL("libXtst.so.6")'
for library in libCompositorSkiaBridge.so libCompositorQtImageIO.so; do
    [[ -s "build/lib/$library" ]] || { echo "Missing build/lib/$library; see docs/linux-ui-e2e.md" >&2; exit 1; }
done
sdk=$(sed -n "s/^runtime-version: *['\"]\?\([0-9.]*\)['\"]\?.*/\1/p" com.compositor.Client.yaml)
[[ -n "$sdk" ]] || { echo "Missing manifest SDK version" >&2; exit 1; }
if (( build )); then
    flatpak run --command=bash --devel --filesystem="$ROOT" "org.kde.Sdk//$sdk" -c \
        'cd "$1" && /usr/lib/sdk/swift6/bin/swift build -c release --product CompositorHostBootstrap' \
        ui-e2e "$ROOT" 2>&1 | tee "$artifacts/build.log"
fi
git rev-parse HEAD > "$artifacts/revision.txt"
git diff --stat > "$artifacts/worktree.txt"
sha256sum .build/release/CompositorHostBootstrap build/lib/*.so > "$artifacts/binaries.sha256"
if (( visible )); then
    echo "UI E2E visible mode: nested Xephyr window (watch Compositor UI E2E on your desktop)"
    export COMPOSITOR_XEPHYR="${COMPOSITOR_XEPHYR:-$(command -v Xephyr)}"
fi
exec python3 tests/ui_e2e/run.py --artifacts "$artifacts" --check-input-regression "$@"
