# Platform abstraction (SOLID) — swapping macOS APIs for Linux and back

The editor's domain logic never names a platform API. Everything platform-specific sits
behind a small interface, injected at the composition root, so macOS AppKit/CoreGraphics
and Linux Qt/Skia implementations are interchangeable (and test doubles are trivial).

| Concern | macOS original | Interface | Linux implementation |
|---|---|---|---|
| 2D raster drawing | CoreGraphics `CGContext` | `CanvasBackend` / `CanvasBackendFactory` (`CanvasBackends.factories`, tried in order, pure-Swift fallback last) | `SkiaCanvasBackend` (Skia C ABI); Vulkan / OpenCV / test doubles plug in the same way |
| Layer effects (stroke / shadow / overlay / inner shadow) | Metal (`MetalLayerEffects`) | `LayerEffectsBackend` chain behind the same-signature override | Vulkan compute (`backends/effects/shaders/effects.comp`) -> portable C++ tier (`EffectsCPU.cpp`); Skia and OpenCV tiers slot in between |
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

## Replaceable services inside the Apple-API layer (`CompatSupport.ServiceSlot`)

Upstream's unmodified code cannot take a service through an initialiser, so each compat module keeps its seam in a
`ServiceSlot<Interface>` instead of a bare global: the host `install`s an implementation at start-up, tests use
`withOverride` (restored afterwards, even on throw), and an optional fallback supplies the built-in one.

| Seam | Interface | Slot accessors |
|---|---|---|
| 2D rasterizer | `CanvasBackend` / `CanvasBackendFactory` | `CanvasBackends.factories`, `withFactories` |
| Image codecs (ImageIO) | `ImageCodecBackend` | `ImageCodecRegistry.host`, `withHost` |
| Clipboard | `NSPasteboard.Backend` | `NSPasteboard.backend`, `withBackend` |
| Foreground segmentation (Vision) | `ForegroundSegmentationBackend` | `ForegroundSegmentationRegistry.backend`, `withBackend` |

`CompCanvasBridge` (the Skia dlopen binding) is internal to `SkiaCanvasBackend`. Event-style hooks (alert and panel
handlers, `onBeep`, cursor changes) stay closures: they are one-way notifications, not services with a lifetime.

## Layer effects chain

`Sources/Overrides/MetalLayerEffects.swift` keeps upstream's surface (`MetalLayerEffects.shared`, `render(_:effects:)`) and
runs `LayerEffectsBackends.chain`: Vulkan first, the C++ tier last, each failing over to the next.
`COMPOSITOR_EFFECTS=auto|vulkan|cpu` narrows it; `auto` skips a software Vulkan device (llvmpipe) because the direct C++
tier is faster there. Both tiers run the same nine passes as the Metal kernels. Checks (`Tests/LinuxOverrideTests`): the C++
tier against upstream's own CoreImage renderer (largest difference 10 of 255, mean under 0.4), and Vulkan against the C++
tier (bit-identical on llvmpipe). SPIR-V is bundled (`scripts/build-brush-shader.py --check` detects stale words).
Not done yet: the Skia and OpenCV tiers, and device-local staging buffers for discrete GPUs.
