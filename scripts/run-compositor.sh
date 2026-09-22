#!/usr/bin/env bash
# run-compositor.sh — Interactive launcher for Compositor on GNU/Linux.
#
# Runs Compositor under the Flatpak KDE 6.10 SDK with hardware GPU (DRI/Vulkan),
# Wayland / X11 display socket forwarding, and Skia/Qt image bridge backends.
#
# Usage:
#   ./scripts/run-compositor.sh [options] [path/to/image.png | path/to/project.cproject]
#
# Options:
#   --install-desktop    Register Compositor in ~/.local/share/applications and icons
#   --session-smoke      Run Swift composition root session journey self-test
#   --dialog-smoke       Run Qt modal dialogs automated journey
#   --io-smoke           Run Qt/libheif image codecs smoke test
#   --layers-smoke       Run Qt layers dock interactive smoke test
#   --brush-smoke        Run Qt brush engine smoke test
#   --offscreen          Run headless using Qt offscreen platform plugin
#   -h, --help           Show this help message

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIA_BRIDGE="${COMPOSITOR_SKIA_BRIDGE:-"$ROOT/build/lib/libCompositorSkiaBridge.so"}"
IMAGEIO_BACKEND="${COMPOSITOR_IMAGEIO_BACKEND:-"$ROOT/build/lib/libCompositorQtImageIO.so"}"

# Fallback to scratchpad if build/lib does not exist
if [[ ! -f "$SKIA_BRIDGE" ]]; then
    FALLBACK_SKIA=$(find /tmp/claude-1000 -name "libCompositorSkiaBridge.so" 2>/dev/null | head -n 1 || true)
    if [[ -n "$FALLBACK_SKIA" && -f "$FALLBACK_SKIA" ]]; then
        mkdir -p "$ROOT/build/lib"
        cp -p "$FALLBACK_SKIA" "$ROOT/build/lib/"
        SKIA_BRIDGE="$ROOT/build/lib/libCompositorSkiaBridge.so"
    fi
fi

if [[ ! -f "$IMAGEIO_BACKEND" ]]; then
    FALLBACK_IMAGEIO=$(find /tmp/claude-1000 -name "libCompositorQtImageIO.so" 2>/dev/null | head -n 1 || true)
    if [[ -n "$FALLBACK_IMAGEIO" && -f "$FALLBACK_IMAGEIO" ]]; then
        mkdir -p "$ROOT/build/lib"
        cp -p "$FALLBACK_IMAGEIO" "$ROOT/build/lib/"
        IMAGEIO_BACKEND="$ROOT/build/lib/libCompositorQtImageIO.so"
    fi
fi

if [[ "${1:-}" == "--install-desktop" ]]; then
    echo "Installing Compositor desktop integration..."
    APP_DIR="${XDG_DATA_HOME:-"$HOME/.local/share"}/applications"
    ICON_BASE="${XDG_DATA_HOME:-"$HOME/.local/share"}/icons/hicolor"
    mkdir -p "$APP_DIR"

    # Install icons
    for size in 16 32 64 128 256 512 1024; do
        SRC_ICON="$ROOT/Compositor/Assets.xcassets/AppIcon.appiconset/app-icon-${size}.png"
        if [[ -f "$SRC_ICON" ]]; then
            DST_DIR="$ICON_BASE/${size}x${size}/apps"
            mkdir -p "$DST_DIR"
            cp -p "$SRC_ICON" "$DST_DIR/com.wonderassembly.Compositor.png"
        fi
    done

    # Generate desktop entry pointing to this launcher script
    cat > "$APP_DIR/com.wonderassembly.Compositor.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Compositor
GenericName=Image Editor
Comment=A free, open-source, Photoshop-style image editor
Exec=$ROOT/scripts/run-compositor.sh %F
Icon=com.wonderassembly.Compositor
Terminal=false
Categories=Graphics;Photography;2DGraphics;RasterGraphics;
MimeType=application/x-compositor-project;image/png;image/jpeg;image/tiff;image/webp;
Keywords=photo;editor;image;layers;compositing;
EOF

    update-desktop-database "$APP_DIR" 2>/dev/null || true
    gtk-update-icon-cache -f -t "${XDG_DATA_HOME:-"$HOME/.local/share"}/icons/hicolor" 2>/dev/null || true
    echo "Compositor successfully installed to $APP_DIR/com.wonderassembly.Compositor.desktop"
    exit 0
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    head -n 21 "${BASH_SOURCE[0]}" | tail -n 17 | sed 's/^#//;s/^ //'
    exit 0
fi

FLATPAK_ARGS=(
    --command=bash
    --devel
    --filesystem=host
    --filesystem=/tmp
    --share=ipc
    --device=dri
    --socket=session-bus
)

if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    FLATPAK_ARGS+=(--socket=wayland)
fi

if [[ -n "${DISPLAY:-}" ]]; then
    FLATPAK_ARGS+=(--socket=fallback-x11 --env=DISPLAY="$DISPLAY")
fi

if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    FLATPAK_ARGS+=(--filesystem="$XDG_RUNTIME_DIR")
fi

OFFSCREEN=0
PASSTHROUGH_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--offscreen" ]]; then
        OFFSCREEN=1
    else
        PASSTHROUGH_ARGS+=("$arg")
    fi
done

ENV_EXPORTS="export COMPOSITOR_SKIA_BRIDGE='$SKIA_BRIDGE'; export COMPOSITOR_IMAGEIO_BACKEND='$IMAGEIO_BACKEND';"
if [[ "$OFFSCREEN" -eq 1 ]]; then
    ENV_EXPORTS+=" export QT_QPA_PLATFORM=offscreen;"
fi

flatpak run "${FLATPAK_ARGS[@]}" org.kde.Sdk//6.10 -c "
    cd '$ROOT'
    $ENV_EXPORTS
    /usr/lib/sdk/swift6/bin/swift build --target CompositorHostBootstrap
    exec .build/x86_64-unknown-linux-gnu/debug/CompositorHostBootstrap "\$@"
" bash "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"
