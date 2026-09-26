# Upstream catch-up: 1.3.1 → 1.3.3 (+1), on GNU/Linux

26 upstream commits merged unmodified (`scripts/check-upstream-clean.sh`: protected trees match `upstream/main`, 2309a85).
Everything below runs upstream's own code; the Linux column says what the Linux layer had to add for it.

| New in upstream | Linux | What the Linux layer does |
|---|---|---|
| **Filter › Dither** (styles incl. Atkinson "Classic Mac", pixel size/shape, tones, diffusion, density, contrast, colors) | ✅ | `DitherPixels.c` joins the shared C kernels; the sheet is upstream's |
| Dither **ASCII as readable text** | ✅ | new `CoreText` compat module: `CTLineCreateWithAttributedString` / `CTLineGetTypographicBounds` / `CTLineDraw` over the Qt text engine; `NSFont.monospacedSystemFont` = the desktop's fixed-pitch face; `CGContext.textPosition` |
| **File › Open Recent** (+ Clear Menu) | ✅ | the list persists across launches (compat `NSDocumentController`, app defaults); projects the shell opens or saves are noted through upstream's `RecentProjects.note`; choosing one opens it directly (`ShellProjects.open(url)`); `NSApplication.didBecomeActiveNotification` posted on activation so the list re-checks moved files |
| **Colored slider tracks with double-click reset** — Hue/Saturation, Black & White, Color Balance, Camera Raw | ✅ | the Linux `CameraRawSlider` now carries upstream's `CameraRawSliderTrack` verbatim and draws its colors across the whole bar (`compatSliderTrack`), double-click resets — both were missing before this merge |
| Filters: sliders **line up to the widest title** | ✅ | SwiftUI `PreferenceKey`, `.preference(key:value:)`, `onPreferenceChange` added to the compat SwiftUI (values settle over the bridge's re-resolve passes, as SwiftUI's arrive after layout); `Font.monospaced()` |
| Camera Raw: **Color Grading** under Color, open by default | ✅ | upstream view, no Linux change |
| Type: **color only the selected letters**; the swatch follows the caret; selection stays see-through under the picker | ✅ | text renders with per-letter color runs (`compositor_qt_text_render_runs`, `QTextLayout` formats; the headless fallback colors each letter too); compat `NSLayoutManager.fillBackgroundRectArray`, `NSTextContainer.replaceLayoutManager` |
| Sampling for a panel keeps its focus; text editing gets the keys back | ✅ | compat `NSEvent.EventTypeMask.leftMouseDragged`, `NSView.isDescendant(of:)` |
| Filters, adjustments and Invert **wait for text editing to finish** | ✅ | upstream logic |
| Image Size: **keep print sizes through an invalid resolution** | ✅ | upstream logic |
| Guide: an unchanged manifest doesn't trigger a reload | ✅ | upstream logic (inotify watcher from 1.3.1) |
| **Always dark**, alerts and open/save panels included | ✅ | the Linux shell is dark throughout (Qt dialogs styled dark) |
| Opening a project while Compositor is quit shows its window | n/a | macOS launch-by-document; on Linux a project path on the command line opens it |

Also fixed while verifying: `build/lib/libCompositorQtImageIO.so` is not built by SwiftPM and had gone stale, so the SVG
renderer, real font metrics and the monospace face never reached the app. `scripts/build-qt-imageio.sh` rebuilds it,
and its font and SVG entry points now refuse politely without a `QGuiApplication` (headless test processes) instead of
aborting.

Tests: 383 passing (upstream's updated Type, Group, Layer appearance, Mask and Image adjustment tests included).
