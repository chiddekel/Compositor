#!/usr/bin/env bash
# Build the production manifest's Skia module and the two UI bridges inside its SDK.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p build/lib
flatpak-builder --show-manifest com.wonderassembly.Compositor.yaml > build/ui-e2e-full-manifest.json
python3 - <<'PY'
import json
from pathlib import Path
manifest = json.loads(Path('build/ui-e2e-full-manifest.json').read_text())
manifest['modules'] = [m for m in manifest['modules'] if m['name'] == 'skia']
assert len(manifest['modules']) == 1, 'Expected the production Skia module'
Path('build/ui-e2e-deps.json').write_text(json.dumps(manifest, indent=2))
PY
flatpak-builder --build-only --force-clean --jobs=2 build/ui-e2e-sdk build/ui-e2e-deps.json
sdk=$(python3 -c 'import json; print(json.load(open("build/ui-e2e-deps.json"))["runtime-version"])')
flatpak run --command=bash --devel --filesystem="$ROOT" "org.kde.Sdk//$sdk" -c '
    set -euo pipefail
    cd "$1"
    cmake -S . -B build/ui-e2e-cmake -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCOMPOSITOR_SKIA_ROOT="$PWD/build/ui-e2e-sdk/files/include/skia" \
        -DCOMPOSITOR_SKIA_LIB="$PWD/build/ui-e2e-sdk/files/lib/libskia.a" \
        -DCMAKE_LIBRARY_OUTPUT_DIRECTORY="$PWD/build/lib"
    cmake --build build/ui-e2e-cmake --target CompositorSkiaBridge CompositorQtImageIO -j2
' ui-e2e "$ROOT"
