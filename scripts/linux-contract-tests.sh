#!/usr/bin/env bash
# Run inside the manifest's Flatpak build environment, after its dependency modules have been installed.
# Local SDK builds can use build/skia-src instead; the same backend checks apply to both environments.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="/usr/lib/sdk/swift6/bin:$PATH"
NATIVE_BUILD="${COMPOSITOR_CONTRACT_NATIVE_BUILD:-$ROOT/.build/linux-contract-native}"
if [[ -f /app/lib/libskia.a ]]; then
    SKIA_ROOT="${COMPOSITOR_SKIA_ROOT:-/app/include/skia}"
    SKIA_LIB="${COMPOSITOR_SKIA_LIB:-/app/lib/libskia.a}"
else
    SKIA_ROOT="${COMPOSITOR_SKIA_ROOT:-$ROOT/build/skia-src}"
    SKIA_LIB="${COMPOSITOR_SKIA_LIB:-$SKIA_ROOT/out/Raster/libskia.a}"
fi
for input in "$SKIA_ROOT/include/core/SkCanvas.h" "$SKIA_LIB" "$(dirname "$SKIA_LIB")/libskia_pathops.a"; do
    if [[ ! -f "$input" ]]; then
        echo "Missing renderer dependency: $input. Build the manifest's dependency modules first." >&2
        exit 1
    fi
done

cmake -S . -B "$NATIVE_BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang \
    -DCOMPOSITOR_SKIA_ROOT="$SKIA_ROOT" -DCOMPOSITOR_SKIA_LIB="$SKIA_LIB"
cmake --build "$NATIVE_BUILD" --parallel 2 --target CompositorSkiaBridge CompositorQtImageIO test_skia_bridge test_imageio_color test_font_traits test_kernels test_patch_pixels test_raw_lens
# Call the executable directly: CTest treats a missing Skia backend (77) as a skip, which is a failure here.
"$NATIVE_BUILD/test_patch_pixels"
"$NATIVE_BUILD/test_raw_lens"
"$NATIVE_BUILD/test_kernels"
"$NATIVE_BUILD/test_skia_bridge"

export COMPOSITOR_SKIA_BRIDGE="$NATIVE_BUILD/libCompositorSkiaBridge.so"
export COMPOSITOR_IMAGEIO_BACKEND="$NATIVE_BUILD/libCompositorQtImageIO.so"
export QT_QPA_PLATFORM=offscreen
"$NATIVE_BUILD/test_imageio_color" --require-heif
"$NATIVE_BUILD/test_font_traits"
export PATH="/usr/lib/sdk/swift6/bin:$PATH"
swift package --manifest-cache none describe --type json > "$NATIVE_BUILD/package-description.json"
python3 scripts/check-linux-source-coverage.py --package-description "$NATIVE_BUILD/package-description.json" \
    --report "$NATIVE_BUILD/source-coverage.json"
python3 tests/test_linux_source_coverage.py "$NATIVE_BUILD/package-description.json"
SWIFT_BIN="$(swift build -c release --show-bin-path)"
mkdir -p "$SWIFT_BIN"
install -m644 Compositor/Resources/CameraRawTables.bin "$SWIFT_BIN/"
swift test -c release --manifest-cache none --no-parallel "$@"
XCTestConfigurationFilePath=linux-contract-tests "$SWIFT_BIN/CompositorHostBootstrap" --combo-smoke
XCTestConfigurationFilePath=linux-contract-tests "$SWIFT_BIN/CompositorHostBootstrap" --preview-smoke
"$SWIFT_BIN/CompositorHostBootstrap" --raw-lens-smoke

"$SWIFT_BIN/CompositorHostBootstrap" --text-backend-smoke
