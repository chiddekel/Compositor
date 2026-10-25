#!/usr/bin/env bash
# Run inside the manifest's Flatpak build environment, after its dependency modules have been installed.
# Local SDK builds can use build/skia-src instead; the same backend checks apply to both environments.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="/usr/lib/sdk/swift6/bin:$PATH"
NATIVE_BUILD="${COMPOSITOR_CONTRACT_NATIVE_BUILD:-$ROOT/.build/linux-contract-native}"
SWIFT_BUILD="${COMPOSITOR_CONTRACT_SWIFT_BUILD:-$ROOT/.build}"
# Job counts follow the machine (a GitHub-hosted runner, a container or a workstation): every usable core, but one
# compile job per 1.5 GiB of available memory (Swift and C++ compiles peak near that), and one native journey per
# 2 cores and 2 GiB. Cgroup CPU quotas and memory limits count when lower than the host's. A 4-core, 16 GiB
# runner builds with 4 jobs and runs two journeys at a time. COMPOSITOR_CONTRACT_BUILD_JOBS and
# COMPOSITOR_CONTRACT_NATIVE_JOBS override; an explicit --jobs argument wins for Swift.
CORES="$(nproc 2>/dev/null || echo 2)"
if [[ -r /sys/fs/cgroup/cpu.max ]] && read -r quota period < /sys/fs/cgroup/cpu.max && [[ $quota != max ]] && (( period > 0 )); then
    quota_cores=$(( (quota + period - 1) / period )); (( quota_cores < CORES )) && CORES=$quota_cores
fi
AVAILABLE_MIB="$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || echo 4096)"
if [[ -r /sys/fs/cgroup/memory.max ]] && read -r limit < /sys/fs/cgroup/memory.max && [[ $limit != max ]]; then
    used=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)
    cgroup_mib=$(( (limit - used) / 1048576 )); (( cgroup_mib < AVAILABLE_MIB )) && AVAILABLE_MIB=$cgroup_mib
fi
at_least_one() { if (( $1 < 1 )); then echo 1; else echo "$1"; fi; }
smaller() { if (( $1 < $2 )); then echo "$1"; else echo "$2"; fi; }
BUILD_JOBS="${COMPOSITOR_CONTRACT_BUILD_JOBS:-$(at_least_one "$(smaller "$CORES" $(( AVAILABLE_MIB / 1536 )))")}"
NATIVE_JOBS="${COMPOSITOR_CONTRACT_NATIVE_JOBS:-$(at_least_one "$(smaller $(( CORES / 2 )) $(( AVAILABLE_MIB / 2048 )))")}"
SWIFT_JOB_ARGS=(--jobs "$BUILD_JOBS")
for argument in "$@"; do
    if [[ $argument == --jobs || $argument == -j || $argument == --jobs=* ]]; then SWIFT_JOB_ARGS=(); fi
done
echo "Contract jobs: $CORES cores, ${AVAILABLE_MIB} MiB available -> build $BUILD_JOBS, Swift ${SWIFT_JOB_ARGS[*]:-(caller --jobs)}, native journeys $NATIVE_JOBS"
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

cmake -S . -B "$NATIVE_BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$(command -v clang)" -DCMAKE_CXX_COMPILER="$(command -v clang++)" \
    -DCOMPOSITOR_SKIA_ROOT="$SKIA_ROOT" -DCOMPOSITOR_SKIA_LIB="$SKIA_LIB"
cmake --build "$NATIVE_BUILD" --parallel "$BUILD_JOBS" --target CompositorSkiaBridge CompositorQtImageIO CompositorPDFBackend test_dispersion_backend test_pressure_brush test_skia_bridge test_imageio_color test_font_traits test_kernels test_scanlines_initialization test_patch_pixels test_raw_lens test_thumbnailer test_group_rotation test_grid_settings test_native_file_panels test_keyboard_layout test_fitting_layout test_text_field_state
python3 tests/test_dispersion.py "$NATIVE_BUILD/libtest_dispersion_backend.so"
python3 tests/make_artboard_fixture.py --check
"$NATIVE_BUILD/test_pressure_brush"
python3 tests/test_pdf_backend.py "$NATIVE_BUILD/libCompositorPDFBackend.so"
# Call the executable directly: CTest treats a missing Skia backend (77) as a skip, which is a failure here.
"$NATIVE_BUILD/test_patch_pixels"
"$NATIVE_BUILD/test_raw_lens"
"$NATIVE_BUILD/test_kernels"
"$NATIVE_BUILD/test_scanlines_initialization"
"$NATIVE_BUILD/test_skia_bridge"

export COMPOSITOR_SKIA_BRIDGE="$NATIVE_BUILD/libCompositorSkiaBridge.so"
export COMPOSITOR_IMAGEIO_BACKEND="$NATIVE_BUILD/libCompositorQtImageIO.so"
export COMPOSITOR_PDF_BACKEND="$NATIVE_BUILD/libCompositorPDFBackend.so"
export QT_QPA_PLATFORM=offscreen
# The default CMYK profile the app installs on first run (third_party/color): upstream's CMYK tests proof and export
# through "Generic CMYK Profile", which macOS always has. A profile already in place (a developer's own) is kept.
CMYK_FOLDER="${XDG_DATA_HOME:-$HOME/.local/share}/CMYK Profiles"
if [[ ! -f "$CMYK_FOLDER/Generic CMYK Profile.icc" ]]; then
    install -D -m644 third_party/color/SWOP_TR005_coated_5.icc "$CMYK_FOLDER/Generic CMYK Profile.icc"
fi
export COMPOSITOR_REQUIRE_SUBJECT_MODEL=1
"$NATIVE_BUILD/test_imageio_color" --require-heif
python3 tests/test_straight_png.py "$NATIVE_BUILD/libCompositorQtImageIO.so"
python3 tests/test_gif_backend.py "$NATIVE_BUILD/libCompositorQtImageIO.so"
"$NATIVE_BUILD/test_font_traits"
"$NATIVE_BUILD/test_native_file_panels"
"$NATIVE_BUILD/test_fitting_layout"
"$NATIVE_BUILD/test_text_field_state"
"$NATIVE_BUILD/test_thumbnailer" "$NATIVE_BUILD/compositor-thumbnailer"
export PATH="/usr/lib/sdk/swift6/bin:$PATH"
swift package --manifest-cache none describe --type json > "$NATIVE_BUILD/package-description.json"
python3 scripts/check-linux-source-coverage.py --package-description "$NATIVE_BUILD/package-description.json" \
    --report "$NATIVE_BUILD/source-coverage.json"
python3 tests/test_linux_source_coverage.py "$NATIVE_BUILD/package-description.json"
SWIFT_BIN="$(swift build -c release --scratch-path "$SWIFT_BUILD" --show-bin-path)"
mkdir -p "$SWIFT_BIN"
install -m644 Compositor/Resources/CameraRawTables.bin Compositor/Resources/CameraRawShadows.bin "$SWIFT_BIN/"
# Swift tests in two passes. The suites below share process-wide state the shell has one of (the shell request
# queue, the pop-up menu being shown, the alert and file-panel presenters they record), or time themselves (a tool
# matrix against a budget; upstream's file-watch reloads after a fixed 900 ms wait; Color Range waits for its worker
# behind the one main actor). Alongside others they see each
# other's requests and sheets, or run late under load, so they run one test at a time after the rest. Everything else runs in parallel. (The parallel run used to deadlock: a main-queue preview render
# waited for a thread of the concurrency pool that was itself waiting for the main queue; fixed in 9bf048b.)
# A caller's own --filter/--skip (CI's subset) keeps the single serial run.
SHARED_STATE_SUITES='ShellRequestOwnershipTests|PopUpRequestOwnershipTests|PopUpMenuTests|NativeAlertOwnershipTests|NativeFilePanelTests|UpstreamPost154Tests|ToolCombinationTests|ExternalChangeTests|ColorRangeTests'
selects_tests=0
for argument in "$@"; do [[ $argument == --filter* || $argument == --skip* ]] && selects_tests=1; done
if (( selects_tests )); then
    swift test -c release --scratch-path "$SWIFT_BUILD" --manifest-cache none --no-parallel "${SWIFT_JOB_ARGS[@]}" "$@"
else
    swift test -c release --scratch-path "$SWIFT_BUILD" --manifest-cache none --parallel "${SWIFT_JOB_ARGS[@]}" \
        --skip "$SHARED_STATE_SUITES" "$@"
    swift test -c release --scratch-path "$SWIFT_BUILD" --manifest-cache none --no-parallel --skip-build "${SWIFT_JOB_ARGS[@]}" \
        --filter "$SHARED_STATE_SUITES" "$@"
fi
# Native journeys. Each gate is independent; NATIVE_JOBS (above) of them run at a time,
# each with its own XDG config/data copy and log, printed in order afterwards. Any failing gate fails the run.
NATIVE_GATES=(
    "test --combo-smoke --wand-repeat"
    "test --combo-smoke --levels-controls-probe"
    "test --combo-smoke --levels-handles-probe"
    "test --combo-smoke --curves-points-probe"
    "test --combo-smoke --effects-controls-probe --effects-autosave-overlap"
    "test --combo-smoke --filter-controls-probe"
    "test --combo-smoke --image-adjustment-controls-probe"
    "test --combo-smoke --hue-range-handles-probe"
    "app --combo-smoke --image-clipboard-probe"
    "test --combo-smoke --selection-outline-probe"
    "test --combo-smoke --selection-clear-probe"
    "test --combo-smoke --app-visibility-probe"
    "test --combo-smoke --canvas-size-controls-probe"
    "test --combo-smoke --layer-search-probe"
    "test --combo-smoke --gif-probe"
    "test --combo-smoke --image-size-controls-probe"
    "test --combo-smoke --transform-gestures-probe"
    "test --combo-smoke --transform-snap-probe"
    "test --combo-smoke --upstream-153-probe"
    "test --combo-smoke --upstream-154-probe"
    "test --combo-smoke --font-history-probe"
    "test --combo-smoke --channel-pack-probe"
    "test --combo-smoke --dispersion-probe"
    "solo test --combo-smoke --psd-artboard-probe"
    "solo test --combo-smoke --psd-artboard-conversion-probe"
    "test --combo-smoke --zoom-cursor-probe"
    "test --combo-smoke --keyboard-cursor-probe"
    "test --combo-smoke --layer-disjoint-probe"
    "solo test --combo-smoke --layer-nesting-probe"
    "test --combo-smoke --thumbnail-selection-probe"
    "test --combo-smoke --modern-adjustment-probe"
    "test --combo-smoke --autosave-crash-probe"
    "test --combo-smoke --transform-fields-probe"
    "test --combo-smoke --scrub-probe"
    "test --combo-smoke --cmyk-proof-probe"
    "test --combo-smoke --svg-import-probe"
    "test --combo-smoke --ui-audit-probe"
    "test --combo-smoke --input-probe"
    "app --dialog-smoke"
    "solo test --preview-smoke"
    "test --save-smoke"
    "test --package-smoke"
    "solo test --transform-smoke"
    "solo test --tab-smoke"
)
# "solo" gates time real pointer sequences or file-watch reloads (a drag released by a 20 ms timer, held scrolls,
# a 4 s package-reload deadline); they run alone,
# after the parallel ones, so CPU contention from other journeys cannot delay their events.
run_native_gate() {  # run_native_gate "[solo] <test|app> <arguments...>"
    local gate=${1#solo }
    local mode=${gate%% *} args=${gate#* }
    # shellcheck disable=SC2086 # the gate's arguments are words
    if [[ $mode == app ]]; then env -u XCTestConfigurationFilePath "$SWIFT_BIN/CompositorHostBootstrap" $args
    else XCTestConfigurationFilePath=linux-contract-tests "$SWIFT_BIN/CompositorHostBootstrap" $args; fi
}
if [[ $NATIVE_JOBS -le 1 ]]; then
    for gate in "${NATIVE_GATES[@]}"; do run_native_gate "$gate"; done
else
    GATE_ROOT="$(mktemp -d "$NATIVE_BUILD/native-gates.XXXXXX")"
    # Each journey's output appears as soon as it finishes (whole, never interleaved), so a CI log shows progress.
    run_gate_in_background() {
        local index=$1
        (
            dir="$GATE_ROOT/$index"; mkdir -p "$dir/config" "$dir/data"
            [[ -d ${XDG_CONFIG_HOME:-} ]] && cp -a "$XDG_CONFIG_HOME/." "$dir/config/"
            [[ -d ${XDG_DATA_HOME:-} ]] && cp -a "$XDG_DATA_HOME/." "$dir/data/"
            status=0
            XDG_CONFIG_HOME="$dir/config" XDG_DATA_HOME="$dir/data" run_native_gate "${NATIVE_GATES[$index]}" > "$dir/log" 2>&1 || status=$?
            echo "$status" > "$dir/exit"
            {
                flock 9
                echo "== native gate $((index + 1))/${#NATIVE_GATES[@]} (exit $status): ${NATIVE_GATES[$index]}"
                cat "$dir/log"
            } 9> "$GATE_ROOT/output.lock"
        ) &
    }
    for index in "${!NATIVE_GATES[@]}"; do
        [[ ${NATIVE_GATES[$index]} == solo\ * ]] && continue
        while (( $(jobs -rp | wc -l) >= NATIVE_JOBS )); do wait -n || true; done
        run_gate_in_background "$index"
    done
    wait
    for index in "${!NATIVE_GATES[@]}"; do
        [[ ${NATIVE_GATES[$index]} == solo\ * ]] || continue
        run_gate_in_background "$index"; wait
    done
    failed=0
    for index in "${!NATIVE_GATES[@]}"; do
        status=$(cat "$GATE_ROOT/$index/exit" 2>/dev/null || echo 1)
        if [[ $status != 0 ]]; then
            echo "NATIVE GATE FAILED (exit $status): ${NATIVE_GATES[$index]}"
            [[ ${GITHUB_ACTIONS:-} == true ]] && echo "::error title=Native journey failed::${NATIVE_GATES[$index]} exited $status"
            failed=1
        fi
    done
    [[ $failed == 0 ]] || exit 1
fi
"$SWIFT_BIN/CompositorHostBootstrap" --raw-lens-smoke

"$SWIFT_BIN/CompositorHostBootstrap" --text-backend-smoke

"$NATIVE_BUILD/test_group_rotation" "$SWIFT_BIN/CompositorHostBootstrap"
"$NATIVE_BUILD/test_grid_settings" "$SWIFT_BIN/CompositorHostBootstrap"
