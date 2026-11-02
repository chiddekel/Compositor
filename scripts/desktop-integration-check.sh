#!/usr/bin/env bash
# Desktop integration of the installed Flatpak (T-15), the parts a script can check without driving the desktop:
# the desktop entry, MIME registration and default handler for .comp packages and images, the shared-mime glob, the
# thumbnailer the file manager runs, and the exported D-Bus/desktop files. Pointer work (drag and drop between
# windows, file manager to canvas or tab) is in docs/desktop-integration-matrix.md, recorded by hand.
#   scripts/desktop-integration-check.sh [app-id]      (default com.compositor.Client, --user or --system install)
set -uo pipefail
APP=${1:-com.compositor.Client}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/compositor-desktop.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
note() { echo "NOTE: $1"; }

installation=$(flatpak info --show-location "$APP" 2>/dev/null) || { echo "FAIL: $APP is not installed"; exit 1; }
version=$(flatpak info "$APP" 2>/dev/null | awk -F': *' '/Version|Wersja/ {print $2; exit}')
echo "Checking $APP ${version:-} at $installation on ${XDG_CURRENT_DESKTOP:-unknown} (${XDG_SESSION_TYPE:-unknown})"
export_dir="$installation/export/share"

desktop="$export_dir/applications/$APP.desktop"
[[ -f $desktop ]] && pass "desktop entry exported ($desktop)" || fail "desktop entry not exported"
if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$desktop" >/dev/null 2>&1 && pass "desktop entry validates" || fail "desktop-file-validate: $(desktop-file-validate "$desktop" 2>&1 | head -3)"
else
    note "desktop-file-validate not installed; entry not validated"
fi
grep -q '^Exec=.*%F' "$desktop" && pass "Exec takes files (%F)" || fail "Exec does not take files"

for type in application/x-compositor-project image/png image/jpeg image/tiff image/webp image/heic; do
    handlers=$(gio mime "$type" 2>/dev/null)
    if grep -q "$APP.desktop" <<<"$handlers"; then pass "registered for $type"; else fail "not registered for $type"; fi
done
default=$(xdg-mime query default application/x-compositor-project 2>/dev/null)
[[ $default == "$APP.desktop" ]] && pass ".comp opens in Compositor by default" || fail ".comp default handler is '${default:-none}'"

[[ -f $export_dir/mime/packages/$APP.xml ]] && pass "shared-mime package exported" || fail "shared-mime package not exported"
printf "{}" > "$WORK/glob.comp"
type=$(gio info -a standard::content-type "$WORK/glob.comp" 2>/dev/null | awk '/content-type/ {print $2}')
[[ $type == application/x-compositor-project ]] && pass "*.comp is application/x-compositor-project" || fail "*.comp is '${type:-unknown}'"

# Flatpak exports applications, icons, MIME, metainfo and D-Bus services, not share/thumbnailers: the file manager's
# thumbnail factory never learns of the app's thumbnailer. Checked here so a Flatpak that starts exporting it shows.
if [[ -f $export_dir/thumbnailers/$APP.thumbnailer ]]; then pass "thumbnailer exported to the desktop"
else fail "thumbnailer not exported to the desktop (Flatpak $(flatpak --version | awk '{print $2}') exports no share/thumbnailers): .comp files show no preview in the file manager"; fi
if flatpak run --command=sh "$APP" -c "test -f /app/share/thumbnailers/$APP.thumbnailer" 2>/dev/null; then
    pass "thumbnailer installed in the app"
    # A package as Compositor saves it: the flattened preview under QuickLook (PNG is read when there is no JPEG).
    mkdir -p "$WORK/Sample.comp/QuickLook"
    python3 - "$WORK/Sample.comp/QuickLook/Preview.png" <<'PY'
import struct, sys, zlib
w, h = 320, 200
rows = b"".join(b"\x00" + bytes((250, 117, 39) * w) for _ in range(h))
def chunk(kind, data): return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                              + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
PY
    if flatpak run --filesystem="$WORK" --command=compositor-thumbnailer "$APP" "$WORK/Sample.comp" "$WORK/thumb.png" 128 2>/dev/null \
        && python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(24); w,h=struct.unpack(">II",d[16:24]); sys.exit(0 if (w,h)==(128,80) else 1)' "$WORK/thumb.png"; then
        pass "thumbnailer turns QuickLook/Preview into a 128 px thumbnail (128 x 80)"
    else
        fail "thumbnailer did not write a 128 x 80 thumbnail"
    fi
else
    fail "thumbnailer not installed in the app"
fi

for icon in 128x128 256x256 512x512; do
    [[ -f $export_dir/icons/hicolor/$icon/apps/$APP.png ]] && pass "icon $icon exported" || fail "icon $icon not exported"
done
metainfo=$(flatpak run --command=sh "$APP" -c "ls /app/share/metainfo/$APP.metainfo.xml" 2>/dev/null)
[[ -n $metainfo ]] && pass "AppStream metainfo installed" || fail "AppStream metainfo missing"

echo "$failures failure(s)"
exit $((failures > 0))
