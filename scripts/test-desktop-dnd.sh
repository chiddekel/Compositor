#!/usr/bin/env bash
# T-15 on a private X server: drag and drop between X clients, and the clipboard, with the release build.
#   scripts/test-desktop-dnd.sh [work-dir]      (host tools: Xvfb, xdotool, xclip; the KDE SDK through flatpak-builder)
#
# Nothing touches the user's own display: everything runs on its own Xvfb (DISPLAY :93 by default). The app, a drag
# source (tests/xdnd_source.cpp) and xclip are separate X clients, so drops arrive over XDND and the clipboard over X
# selections. The app runs as the app does (no test environment: under XCTestConfigurationFilePath upstream copies to
# a private pasteboard).
#
# Checks: Copy Merged is offered to other clients as image/png; an image another client puts on the clipboard pastes
# as a layer; a drop on the canvas reaches it and is accepted; on the header's empty area it opens a new tab; and the
# dropped files become layers. A control drop onto a plain Qt window (tests/xdnd_target.cpp) first shows whether this
# X server carries drop data at all: where it does not (Xvfb with synthetic XTEST input has returned empty XDND data
# even between two plain Qt programs), the drops' content checks are reported as LIMIT, not as failures, and delivery,
# acceptance and routing are still checked.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(realpath -m "${1:-$ROOT/.build/evidence/t15}")
SCREEN=${COMPOSITOR_TEST_DISPLAY:-:93}
B=$ROOT/.build/evidence/swift-build/x86_64-unknown-linux-gnu/release/CompositorHostBootstrap
rm -rf "$WORK"; mkdir -p "$WORK"
failures=0 limits=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
limit() { echo "LIMIT: $1"; limits=$((limits + 1)); }
# flatpak-builder --run forwards no X11 and mounts its own /tmp/.X11-unix: the sandbox reaches the private display
# through the X server's abstract socket, which needs the host network namespace (nothing is reached beyond it).
sdk() { flatpak-builder --run --filesystem="$ROOT" --share=network --share=ipc --device=dri "$ROOT/build-flatpak" "$ROOT/com.compositor.Client.yaml" env DISPLAY="$SCREEN" QT_QPA_PLATFORM=xcb "$@"; }

Xvfb "$SCREEN" -screen 0 1600x900x24 -nolisten tcp > "$WORK/xvfb.log" 2>&1 &
xvfb=$!
pids=()
cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done; kill $xvfb 2>/dev/null; }
trap cleanup EXIT
sleep 1
export DISPLAY=$SCREEN

python3 -I - "$WORK" <<'PY'
import struct, sys, zlib
def png(path, w, h, rgb):
    rows = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    chunk = lambda k, b: struct.pack(">I", len(b)) + k + b + struct.pack(">I", zlib.crc32(k + b))
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
for name, rgb in [("red", (220, 30, 30)), ("green", (30, 200, 60)), ("blue", (30, 60, 220)), ("paste", (240, 200, 20))]:
    png(f"{sys.argv[1]}/{name}.png", 120, 80, rgb)
PY
sdk bash -c "for tool in xdnd_source xdnd_target; do c++ -std=c++17 -fPIC \$(pkg-config --cflags Qt6Widgets) '$ROOT/tests/'\$tool.cpp \$(pkg-config --libs Qt6Widgets) -o '$WORK/'\$tool || exit 1; done" \
    || { echo "FAIL: drag source or control target did not build"; exit 1; }

drag() {  # drag X Y FILE...: from the source window to (X, Y), through intermediate pointer positions
    local tx=$1 ty=$2; shift 2
    rm -f "$WORK/source.log"
    sdk "$WORK/xdnd_source" 1300 600 "$@" > "$WORK/source.log" 2>&1 &
    local source=$!
    for _ in $(seq 1 150); do grep -q "source ready" "$WORK/source.log" 2>/dev/null && break; sleep 0.1; done
    sleep 0.5
    xdotool mousemove 1380 680; sleep 0.2
    xdotool mousedown 1; sleep 0.3
    for step in 1 2 3 4 5 6 7 8; do
        xdotool mousemove $(( 1380 + (tx - 1380) * step / 8 )) $(( 680 + (ty - 680) * step / 8 )); sleep 0.1
    done
    xdotool mousemove $((tx + 3)) $((ty + 3)); sleep 0.3
    xdotool mouseup 1
    for _ in $(seq 1 50); do grep -q "drop result" "$WORK/source.log" && break; sleep 0.1; done
    kill $source 2>/dev/null
    grep -o "drop result: .*" "$WORK/source.log" || echo "drop result: none"
}

# Control: two plain Qt clients on this server.
sdk "$WORK/xdnd_target" > "$WORK/control.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 150); do grep -q "target ready" "$WORK/control.log" 2>/dev/null && break; sleep 0.1; done
sleep 0.5
drag 300 250 "$WORK/red.png" > /dev/null
sleep 0.5
kill "${pids[-1]}" 2>/dev/null
if grep -q "urls 1" "$WORK/control.log"; then carries=1; pass "control: this X server carries XDND data between two Qt clients"
else carries=0; echo "NOTE: control: a plain Qt window received $(grep -o 'formats [0-9]* urls [0-9]*' "$WORK/control.log" || echo 'nothing'): this X server carries no XDND data"; fi

# The app, as an ordinary X client.
sdk env -u XCTestConfigurationFilePath \
    COMPOSITOR_SKIA_BRIDGE="$ROOT/.build/linux-contract-native/libCompositorSkiaBridge.so" \
    COMPOSITOR_IMAGEIO_BACKEND="$ROOT/.build/linux-contract-native/libCompositorQtImageIO.so" \
    XDG_CONFIG_HOME="$WORK/config" XDG_DATA_HOME="$WORK/data" \
    "$B" --combo-smoke --desktop-probe "$WORK" > "$WORK/app.log" 2>&1 &
app=$!
pids+=($app)
for _ in $(seq 1 300); do [[ -f $WORK/ready ]] && break; sleep 0.2; done
[[ -f $WORK/ready ]] || { echo "FAIL: the app did not start on $SCREEN"; tail -20 "$WORK/app.log"; exit 1; }
target() { python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))[sys.argv[2]]; print(t["x"], t["y"])' "$WORK/targets.json" "$1"; }
state() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$WORK/state.json" "$1"; }
platform=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["platform"])' "$WORK/targets.json")
[[ $platform == xcb ]] && pass "the app runs as an X client (Qt platform $platform)" || fail "the app runs on $platform, not xcb"
sleep 2

# Clipboard, in: an image another client copied pastes as a layer.
xclip -selection clipboard -t image/png -i "$WORK/paste.png" &
pids+=($!)
sleep 0.5
touch "$WORK/paste-request"
for _ in $(seq 1 100); do [[ -f $WORK/paste-done ]] && break; sleep 0.1; done
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["layersAfter"] == d["layersBefore"] + 1 else 1)' "$WORK/paste-done" 2>/dev/null; then
    pass "an image another client put on the clipboard pasted as a layer"
else
    fail "paste from another client did not add a layer ($(cat "$WORK/paste-done" 2>/dev/null))"
fi

# Clipboard, out: Copy Merged (now there are pixels: upstream disables it on an empty document), read by another client.
touch "$WORK/copy-request"
for _ in $(seq 1 100); do [[ -f $WORK/copy-done ]] && break; sleep 0.1; done
targets=$(xclip -selection clipboard -t TARGETS -o 2>/dev/null | tr '\n' ' ')
xclip -selection clipboard -t image/png -o > "$WORK/copied.png" 2>/dev/null
if [[ $targets == *image/png* ]] && python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); sys.exit(0 if d[:8]==b"\x89PNG\r\n\x1a\n" and len(d)>100 else 1)' "$WORK/copied.png"; then
    pass "Copy Merged is on the X clipboard as image/png for other clients ($(stat -c %s "$WORK/copied.png") bytes)"
else
    fail "Copy Merged: clipboard targets '${targets:-none}' ($(cat "$WORK/copy-done" 2>/dev/null))"
fi

# Drops.
content() {  # content OK MESSAGE: the drop's data check, LIMIT where the server carries none
    if [[ $1 == 1 ]]; then pass "$2"; elif (( carries )); then fail "$2"; else limit "$2 (no XDND data on this server)"; fi
}
read -r cx cy < <(target canvas)
layers=$(state layers); tabs=$(state tabs)
result=$(drag "$cx" "$cy" "$WORK/red.png"); sleep 1.5
[[ $result == *copy* ]] && pass "a drop on the canvas from another client reached it and was accepted" || fail "canvas drop: $result"
[[ $(state tabs) == "$tabs" ]] && pass "the canvas drop stayed in its document" || fail "the canvas drop opened a tab"
content $([[ $(state layers) -eq $((layers + 1)) ]] && echo 1 || echo 0) "the dropped PNG became a layer (layers $layers -> $(state layers))"

layers=$(state layers)
result=$(drag "$cx" "$cy" "$WORK/green.png" "$WORK/blue.png"); sleep 1.5
content $([[ $(state layers) -eq $((layers + 2)) ]] && echo 1 || echo 0) "two files dropped together became two layers (layers $layers -> $(state layers), $result)"

read -r hx hy < <(target header)
tabs=$(state tabs)
result=$(drag "$hx" "$hy" "$WORK/red.png"); sleep 2
[[ $(state tabs) -eq $((tabs + 1)) ]] && pass "a drop on the header's empty area opened a new tab ($result)" || fail "header drop: tabs $tabs -> $(state tabs), $result"
content $([[ $(state width) == 120 ]] && echo 1 || echo 0) "the new tab holds the dropped image (width $(state width))"

touch "$WORK/finish"
wait $app
echo "$failures failure(s), $limits limited by the X server"
exit $((failures > 0))
