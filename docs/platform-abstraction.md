# Platform abstraction (SOLID) — swapping macOS APIs for Linux and back

The editor's domain logic never names a platform API. Everything platform-specific sits
behind a small interface, injected at the composition root, so macOS AppKit/CoreGraphics
and Linux Qt/Skia implementations are interchangeable (and test doubles are trivial).

| Concern | macOS original | Interface | Linux implementation |
|---|---|---|---|
| 2D raster drawing | CoreGraphics `CGContext` | `CoreGraphicsCompat` shim (`CompCanvas` C ABI) | Skia raster / Vulkan |
| Brush coverage GPU | Metal | `BrushCoverageComputing` (Swift) | Vulkan compute, CPU fallback |
| Foreground segmentation | Vision | `ForegroundSegmenter`, `MatteRefiner` (Swift) | OpenCV bridge |
| Image codecs | ImageIO | `IImageExporter` (C++) | Qt image plugins |
| Stylus input | `NSEvent` tablet | `ITabletHandler` (C++) | `QTabletEvent` |
| Open/Save/Export dialogs | `NSOpenPanel`/`NSSavePanel` | `IFileDialogService` | `QFileDialog` (XDG portal in Flatpak) |
| Clipboard | `NSPasteboard` | `IClipboardService` | `QClipboard` |
| Colour choice | `NSColorPanel` | `IColorPickerService` | `ColorPickerDialog` |
| User warnings | `NSAlert` | `IUserNotifier` | `QMessageBox` |
| App data / recovery dir | `FileManager` Application Support | `IStorageLocator` | `QStandardPaths::AppDataLocation` |
| Document editing | `EditorSession` | `LayerManipulating`, `MaskManipulating`, `BrushPainting`, `CanvasOperations`, `SubjectMatteOperations` | same Swift core |

## How the principles are applied

- **S** — one reason to change per interface (files, clipboard, colour, notification, storage).
- **O** — a new platform is a new implementation of the same interfaces; `SessionWindow`,
  `AdjustDialog` and `SizeDialog` are not edited.
- **L** — all implementations share one contract: empty `QString` / null `QImage` / invalid
  `QColor` = cancelled or unavailable.
- **I** — five narrow roles instead of one `Platform` interface. `AdjustDialog` and
  `SizeDialog` receive only `IColorPickerService`.
- **D** — `SessionWindow` takes a `PlatformServices` bundle by constructor injection
  (`host/interfaces/IPlatformServices.h`). The Qt defaults live in `host/QtPlatformServices.h`.
  The interfaces use value types only (`QString`, `QImage`, `QColor`), so no widget parents
  leak through and a non-Qt implementation needs no Qt Widgets.

## Adding another platform (e.g. macOS shell)

1. Implement the five interfaces with AppKit (`NSOpenPanel`, `NSPasteboard`, …).
2. Build a `PlatformServices` with those and pass it to the shell's constructor.
3. Nothing in the editor, dialogs or core changes.

## Verification

`--dialog-smoke` runs a `SessionWindow` against fake file dialog, clipboard, notifier and
storage (see `host/DialogJourney.cpp`): export goes to the injected path, a failed export
reaches the injected notifier, Copy lands in the injected clipboard, autosave writes under
the injected storage root.

## Known remaining debt

- `SessionWindow` is still a large class (window, canvas events, tool logic, layers panel).
  The next SRP step is extracting the layers panel, options bar and tool controllers.
- `MainWindow` (the C++-only build path's shell) still calls `QFileDialog`/`QMessageBox`
  directly.
