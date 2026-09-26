#!/usr/bin/env bash
# Run inside the Flatpak SDK with the Skia/ImageIO environment from scripts/run-compositor.sh.
set -euo pipefail

binary="${1:-.build/debug/CompositorHostBootstrap}"
artifacts="$(mktemp -d /tmp/compositor-layer-rename.XXXXXX)"
setup='{"version":1,"action":"new","width":640,"height":480,"emptyLayer":true}'

run_case() {
    local name="$1" keys="$2" expected="$3" undo="$4"
    shift 4
    local log="$artifacts/$name.log"
    if ! env -u COMPOSITOR_GRAB_RENAME_BLUR \
        QT_QPA_PLATFORM=offscreen COMPOSITOR_GRAB_PATH="$artifacts/$name.png" \
        COMPOSITOR_GRAB_COMMAND="$setup" COMPOSITOR_GRAB_LAYER_POINT=0,0.3,double \
        COMPOSITOR_GRAB_FOCUS_KEYS="$keys" "$@" "$binary" >"$log" 2>&1; then
        cat "$log"
        exit 1
    fi
    local output
    output="$(cat "$log")"
    if [[ "$output" != *"RENAME field visible enabled=1 focused=1 selected=Layer 1"* ||
          "$output" != *"RENAME final editors=0 addEnabled=1 names=[$expected] undo=$undo"* ]]; then
        cat "$log"
        echo "FAIL: $name (artifacts: $artifacts)" >&2
        exit 1
    fi
    echo "PASS: $name exits rename with layer '$expected'"
}

run_case return n,e,w,return new 'Rename Layer'
run_case escape n,e,w,escape 'Layer 1' 'New Canvas'
run_case blur n,e,w new 'Rename Layer' COMPOSITOR_GRAB_RENAME_BLUR=1
run_case empty delete,return 'Layer 1' 'New Canvas'
echo "Layer rename screenshots and logs: $artifacts"
