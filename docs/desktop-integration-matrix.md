# Desktop integration and physical input (T-15, T-16)

**October 20 follow-up:** optional host Nautilus/Dolphin providers now exist;
[installation and current evidence](render-parity-and-desktop-previews.md).
The historical Flatpak-only failure below remains accurate without that optional
integration. Real Nautilus preview/refresh/removal and KIO worker dispatch pass;
real Dolphin GUI acceptance remains pending. APP-12 now has its own GIO desktop
launch regression instead of sharing the thumbnail acceptance criterion.

What a script can check runs in `scripts/desktop-integration-check.sh` against the installed Flatpak. What needs a
person at the machine — a pointer dragging between windows, a trackpad, a pen — is listed below, with a column per
desktop to fill in. Record `pass`, `fail: <what happened>` or `n/a` and the app version tested.

## Automated (scripts/desktop-integration-check.sh)

Last run: 2026-10-19, `1.5.3-linux-alpha.1` (user install), GNOME on Wayland, Flatpak 1.16.0.

| Check | Result |
|---|---|
| Desktop entry exported, validates, `Exec` takes files | pass |
| Registered for `.comp` and PNG, JPEG, TIFF, WebP, HEIC | pass |
| `.comp` opens in Compositor by default | pass |
| `*.comp` recognized as `application/x-compositor-project` (shared-mime glob exported) | pass |
| Thumbnailer inside the app turns `QuickLook/Preview` into a 128 px thumbnail | pass |
| Thumbnailer exported to the desktop | **fail**: Flatpak exports no `share/thumbnailers`, so file managers show no `.comp` previews. This is a Flatpak limitation (flatpak/flatpak#1083); a distribution package would install the thumbnailer normally. |
| Icons 128/256/512 exported; AppStream metainfo installed | pass |

## Automated on a private X server (scripts/test-desktop-dnd.sh)

Last run: 2026-10-19, release build, Xvfb with xdotool and xclip as the other X clients (the user's display is not
touched).

| Check | Result |
|---|---|
| The app runs as an X client (Qt xcb) | pass |
| An image another client put on the clipboard (xclip, image/png) pastes as a layer | pass |
| Copy Merged reaches other clients as image/png | pass |
| A drop from another client on the canvas reaches it, is accepted, and stays in its document | pass |
| A drop on the header's empty area opens a new tab | pass |
| The dropped files' contents become layers / the new tab's image | **limit**: on Xvfb with synthetic XTEST input the XDND data arrives empty, even between two plain Qt programs (the script's control check), so this needs a real session: rows 1–4 below |

## Automated input (--input-probe, a contract gate) and HiDPI

Events go in through Qt's platform layer (`QWindowSystemInterface`), as the xcb and Wayland plugins deliver real
devices, with Qt making mouse events from pen and touch as it does on those platforms.

| Check | Result |
|---|---|
| Pen (tablet events) paints with the Brush | pass |
| One finger (touch) paints with the Brush | pass |
| Trackpad two-finger scroll pans at the same zoom | pass |
| Trackpad pinch zooms in | pass |
| Ctrl + mouse wheel zooms out | pass |
| `]` and `[` resize the brush | pass |
| UI audit at 125 %, 150 % and 200 % (`QT_SCALE_FACTOR`): no elided text, empty buttons or missing symbols | pass |
| Text and icons at 200 % are sharp (screenshot `.build/evidence/audit/shots/hidpi2.png`) | pass |

Upstream has no pen pressure, so a pen draws as the mouse does, on the Mac too. What none of this shows is a real
device and its driver: the table below still needs them.

## By hand (T-15): drag and drop and the file manager

Run each on GNOME and KDE Plasma, each on Wayland and on X11 (or Xwayland with `QT_QPA_PLATFORM=xcb`).

| # | Steps | Expected (as on the Mac) | GNOME Wayland | GNOME X11 | KDE Wayland | KDE X11 |
|---|---|---|---|---|---|---|
| 1 | Drag a PNG from the file manager onto the canvas of an open document | Placed as a new layer where it was dropped | | | | |
| 2 | Drag a PNG onto the tab bar (empty area) | Opens as a new document tab | | | | |
| 3 | Drag a `.comp` package onto the window | Opens the project in a tab | | | | |
| 4 | Drag several images at once onto the canvas | One layer each, in order | | | | |
| 5 | Drag a layer row from one Compositor window's Layers panel to another window's canvas | Copied there as a layer | | | | |
| 6 | Drag the canvas image (Move tool + modifier) out to the file manager | Not supported upstream either: nothing happens | | | | |
| 7 | Double-click a `.comp` in the file manager while Compositor is closed | Starts and opens it | | | | |
| 8 | Same, while Compositor is open | Opens in a new tab of the running app, no second instance | | | | |
| 9 | Open With → Compositor on a JPEG | Opens it as a new document | | | | |
| 10 | Recent files: open a project, then check File › Open Recent and the desktop's recent list | Listed in both | | | | |
| 11 | Copy an image in a browser, then Edit › Paste in Compositor | Pasted as a layer | | | | |
| 12 | Copy a selection in Compositor, then paste in GIMP or LibreOffice | Pastes the pixels | | | | |
| 13 | View › Enter Full Screen, then Esc; then Window › Minimize and Bring All to Front | Full screen and back; minimized and back | | | | |

## By hand (T-16): physical input

| # | Device | Steps | Expected | Result (device, desktop) |
|---|---|---|---|---|
| 1 | Mouse wheel | Scroll the canvas; Ctrl+wheel | Pans; zooms at the pointer | |
| 2 | Trackpad | Two-finger scroll; pinch | Pans smoothly; zooms at the fingers (Wayland sends pinch gestures; X11 may not) | |
| 3 | Trackpad | Two-finger scroll in the Layers panel and in sliders' panels | Scrolls the list, not the canvas | |
| 4 | Touchscreen | One finger on the canvas with the Hand tool; two-finger pinch | Pans; zooms | |
| 5 | Pen tablet (Wacom or similar) | Paint with the Brush at varying pressure | Stroke width or opacity follows pressure where the brush uses it | |
| 6 | Pen tablet | Use the eraser end | Erases, as the Eraser | |
| 7 | Pen tablet | Hover, then press: cursor and brush outline | Outline follows the pen without lag | |
| 8 | High-resolution mouse (1000 Hz) | Fast brush strokes on a 8000 × 6000 document | Continuous stroke, no gaps; frames keep up | |
| 9 | Keyboard | Tool letters, [ and ] for brush size, Space-drag to pan | As on the Mac | |
| 10 | HiDPI (200 % scaling) | Canvas, rulers, panels and icons | Sharp; nothing half-size or clipped | |
