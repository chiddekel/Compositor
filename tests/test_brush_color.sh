#!/usr/bin/env bash
# Run inside the Flatpak SDK with the same Skia/ImageIO environment as scripts/run-compositor.sh.
# Usage: bash tests/test_brush_color.sh [path/to/CompositorHostBootstrap]
set -euo pipefail

binary="${1:-.build/debug/CompositorHostBootstrap}"
artifacts="$(mktemp -d /tmp/compositor-brush-color.XXXXXX)"
setup='{"version":1,"action":"new","width":640,"height":480,"emptyLayer":true};{"version":1,"action":"setPaletteColor","kind":"foreground","parameters":{"red":1,"green":0,"blue":0}};{"version":1,"action":"setBrushSettings","parameters":{"diameter":40,"hardness":1,"opacity":1,"smoothing":0}}'

run_case() {
    local name="$1" color="$2" expected="$3"
    shift 3
    local log="$artifacts/$name.log"
    if ! env -u COMPOSITOR_GRAB_BRUSH_COLOR_CANCEL -u COMPOSITOR_GRAB_BRUSH_COLOR_SUBMIT \
        QT_QPA_PLATFORM=offscreen COMPOSITOR_GRAB_PATH="$artifacts/$name.png" \
        COMPOSITOR_GRAB_TOOL=brush COMPOSITOR_GRAB_COMMAND="$setup" \
        COMPOSITOR_GRAB_BRUSH_COLOR="$color" COMPOSITOR_GRAB_DRAG=160,240,480,240 \
        "$@" "$binary" >"$log" 2>&1; then
        cat "$log"
        echo "FAIL: $name (artifacts: $artifacts)" >&2
        exit 1
    fi
    local output
    output="$(cat "$log")"
    if [[ "$output" != *"BRUSHCOLOR via options -> "*" PASS"* ||
          "$output" != *"BRUSHPIXEL 320,240 $expected alpha=255"* ||
          "$output" != *"undo=Brush Stroke"* ]]; then
        cat "$log"
        echo "FAIL: $name (artifacts: $artifacts)" >&2
        exit 1
    fi
    echo "PASS: $name paints $expected"
}

run_case click_ok '#2fa573' '#2fa573'
run_case return_then_ok '#237bd4' '#237bd4' COMPOSITOR_GRAB_BRUSH_COLOR_SUBMIT=1
run_case cancel '#00ff00' '#ff0000' COMPOSITOR_GRAB_BRUSH_COLOR_CANCEL=1
echo "Brush color screenshots and pixel exports: $artifacts"
