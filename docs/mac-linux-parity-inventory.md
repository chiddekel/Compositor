# Compositor — macOS vs GNU/Linux, element by element

Baseline: upstream **1.3.1** (merged `ce8cba6`), branch `GNU_Linux`. The Linux app runs upstream's own Swift
(`Compositor/{Document,IO,Rendering,UI}`, unmodified) on Apple-API compat modules, inside a Qt shell.

Legend — **✅ same** upstream's code runs and its upstream tests pass on Linux · **🟡 differs** works, but not
identically (reason given) · **❌ missing** not available on Linux yet · **n/a** macOS-only by nature.

Evidence: 378 tests green (upstream `CompositorTests` compiled unmodified except the 13 files listed in
`linux/UPSTREAM_TEST_EXCLUSIONS.md`, plus Linux compat/override tests), 5 Qt smoke journeys, headless screenshots.

## 1. Tools (15) — upstream `NavigationTool`, all driven by upstream's hosted `CanvasView`

| Tool | Modes / options | Linux | Evidence |
|---|---|---|---|
| Move / Transform | auto-select, show controls, X/Y/W/H/link/scale/angle, handles, rotate, distort (Ctrl) | ✅ | TransformTests, DistortTests, smoke |
| Marquee | rectangle / ellipse; new / add / subtract; expand, contract, feather | ✅ | SelectionEditTests, SelectionFeatherTests |
| Lasso | freehand / polygonal; anti-alias | ✅ | SelectionEditTests |
| Magic (wand / object) | tolerance, contiguous, subject | ✅ | MagicWandTests; *object/subject* through U²-Net-small behind the Vision API |
| Crop | ratio, apply/cancel, oversized layers | ✅ | CropTests, CropToCanvasImportTests |
| Brush | paint / erase, size, hardness, opacity, smoothing, colour | ✅ | BrushTests (19), BrushIntersectionTests |
| Spot Healing | modes | ✅ | SpotHealingTests |
| Clone Stamp | source, aligned | ✅ | CloneStampTests |
| Blur / Smudge / Liquify | modes | ✅ | BrushTests, SmartEditTests |
| Gradient | linear / radial, presets, reverse, opacity | ✅ | GradientTests |
| Shape | rectangle / ellipse / line, radius, fill | ✅ | ShapeToolTests |
| Type | font, size, colour, alignment, tracking, leading, edit/done, label scrubbing | ✅ | TypeToolTests (13, incl. close/quit while editing) |
| Eyedropper | sample ring | ✅ | smoke |
| Hand | drag, Space | ✅ | bench |
| Zoom | click / Alt-click, % field | ✅ | NavigationToolHeader |

## 2. Layers

| Element | Linux | Notes |
|---|---|---|
| Raster layers, folders (nested), folder opacity | ✅ | GroupTests, GroupingSelectionTests |
| Opacity, 24 blend modes (Normal … Luminosity), blend hover preview | ✅ | LayerAppearanceTests |
| Visibility, eye swipe | ✅ | |
| Rename (double-click), duplicate (Alt-drag), delete, reorder by drag, into folder | ✅ | Linux list is `NativeLayerListOverride` (upstream's `NSTableView` list needs ObjC target-action); LayerTests excluded |
| Layer masks: reveal/hide, paint anywhere, link/unlink, invert, blur/feather, thumbnails white/black | ✅ | LayerMaskTests, LiveMaskTests, MaskTransformTests |
| Adjustment layers (12 kinds) | ✅ | AdjustmentLayerTests |
| Text layers (live text) | ✅ | TypeToolTests |
| Layer effects (6 kinds) | ✅ | InnerGlowTests, OuterGlowTests; rendered by CPU/Skia/OpenCV/Vulkan backends instead of Metal |
| Right-click menu | ✅ | mirrored item for item |
| Layer thumbnails | ✅ | CanvasThumbnailTests excluded (SwiftUI host) — drawn by the Linux list |

## 3. Filters (16) and adjustments

| Kind | Linux |
|---|---|
| Gaussian Blur, Motion Blur, Add Noise, Vignette, Bloom/Glow, Tonal Contrast, Lens Correction, Grain, Exposure, Gradient Map, Black & White, Color Balance, Curves, Levels, Hue/Saturation, Invert | ✅ (FilterTests, FinishingFilterTests, ImageAdjustmentTests, HueSaturationTests; CoreImage graph evaluated on CPU) |
| Camera Raw Filter (light, colour, detail, optics, geometry, calibration) | ✅ (CameraRawTests 20) — sliders are SwiftUI sliders (CameraRawSliderTests excluded) |
| Content-Aware Fill | ✅ (C kernel) |
| Remove Background | ✅ U²-Net-small (Apache-2.0) behind the Vision API, soft edges like Vision's |

## 4. Selection menu

All, Deselect, Inverse, Layer's Pixels, Mask's Black Areas, Expand/Contract/Feather, Copy/Cut/Paste, Copy Merged,
Clear, Fill with Foreground/Background — ✅ (SelectionClipboardTests, SelectionEditTests).
Subject — ✅ (U²-Net-small).

## 5. Image menu

Canvas Size, Image Size, Trim, Flip Canvas H/V, Crop — ✅ (CanvasSizeTests, ImageSizeTests, ImageTrimTests).

## 6. Files and projects

| Element | Linux | Notes |
|---|---|---|
| `.cproject` new / open / save / save as / close, digest, keep editing while saving | ✅ | ProjectTests, ProjectWorkspaceTests |
| Reload when the package changes on disk | ✅ | ExternalChangeTests — inotify behind Dispatch's vnode source API |
| Import PNG, JPEG, TIFF, HEIC | ✅ | Qt codecs + libheif |
| Import PSD / PSB (layers, masks, text, vectors) | ✅ | PSDRoundTripTests (31), PSBImportTests |
| Import SVG | ✅ | Qt SVG plugin draws at the target size |
| Camera RAW develop sheet | ✅ | LibRaw |
| Export PNG / JPEG | ✅ | ExportTests, JPEGExportTests |
| Tabs, drag files in, drop on tab bar for a new canvas | ✅ | |
| Recent documents (`noteNewRecentDocumentURL`) | 🟡 | recorded in-app; the sandbox (no host filesystem) cannot write the desktop's recently-used list — files opened through the file-chooser portal are recorded by the desktop itself |

## 7. View menu and canvas

Fit, Actual Pixels, Zoom In/Out, rulers, grid, guides (add/drag/clear), snapping (guides, layers, document bounds),
transform controls, marching ants, pixel grid, checkerboard — ✅. Rulers are drawn by the Qt shell to upstream's
metrics (GuideTests excluded).

## 8. Application

| Element | Linux | Notes |
|---|---|---|
| Menus (upstream `CompositorApp.commands`) with shortcuts | ✅ | Ctrl/Alt/Shift in labels instead of ⌘⌥⇧ |
| Keyboard Shortcuts editor | ✅ | click a shortcut, press the new chord; Esc records as a key, as upstream's recorder does |
| About, version | ✅ | |
| Check for Updates | 🟡 | Flatpak instead of Sparkle |
| Quit / close with unsaved changes | ✅ | alert sheet flow (TypeToolTests close/quit) |
| Hide / Hide Others / Show All | n/a | window-manager business |
| Floating panels (Levels, Curves, Hue/Sat, Filters, Effects, Colour picker) | ✅ | Qt tool windows (FloatingPanelTests, ColorPickerTests excluded) |

## 9. Platform integration — the gaps

| Element | macOS | Linux |
|---|---|---|
| System clipboard (copy to / paste from other apps) | ✅ | ✅ `NSPasteboard.general` over `QClipboard` (c9a45a7) |
| Trackpad pinch to zoom (`magnify(with:)`) | ✅ | ✅ Qt zoom gesture → upstream `CanvasView.magnify(with:)` |
| New canvas from clipboard size (`NewCanvasSheet.clipboardDimensions`) | ✅ | ✅ |
| Canvas compositing | CPU (Core Graphics in `EditorCanvas.draw`, cached downscales) | ✅ CPU (Skia) into a cached display image; zoom re-renders in the background, the canvas never waits. GPU is used where the Mac uses Metal: brush coverage and layer effects (Vulkan). `COMPOSITOR_UPSTREAM_DRAW=1` paints through upstream's own `draw(_:)` as a parity reference |
| Subject / Remove Background model | Vision | ✅ U²-Net-small through OpenCV DNN |
| Window chrome | native title bar | 🟡 drawn traffic lights + header by the Qt shell |
| Services, Quick Look, Dock menu | ✅ | n/a |

## Order of work (one by one)

1. ~~System clipboard both ways~~ — done.
2. ~~Trackpad pinch zoom~~ — done.
3. ~~New canvas from clipboard size~~ — done.
4. ~~Keyboard Shortcuts recorder parity~~ — done.
5. ~~Recent documents~~ — covered by the file-chooser portal (sandbox).
6. ~~Subject / Remove Background model~~ — done (U²-Net-small).
7. ~~Canvas compositing~~ — the Mac composites on the CPU too; the zoom hitch is gone (background display renders).
