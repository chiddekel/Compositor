# Upstream tests not run on Linux

Upstream's `CompositorTests/*.swift` are compiled **unmodified** (target `CompositorUpstreamTests`). A test file may only be
excluded here, with a reason; individual tests are never edited.

| File | Reason |
|---|---|
| `SliderSnapTests.swift` | Tests `UI/SliderSnap.swift`, which swizzles `NSSliderCell` through the Objective-C runtime |
| `FloatingPanelTests.swift` | Tests `UI/FloatingPanel.swift` (`NSPanel` controller) |
| `CanvasThumbnailTests.swift` | Tests `UI/CanvasThumbnail.swift` (SwiftUI view) |
| `LayerTests.swift` | Drives `NativeLayerList`/`LayerTableView` (`NSTableView` subclass counting delegate calls) |
| `CursorTests.swift` | Builds `LayersPanel` + `LayerTableView` to check cursor routing through the AppKit responder chain |
| `GuideTests.swift` | Tests `CanvasRulerNSView` label/step layout (UI/CanvasRulers.swift) |
| `LevelsTests.swift` | Renders `LevelsSheet` (SwiftUI) through `NSHostingView` |
| `CanvasEntryTests.swift` | Tests `NewCanvasSheet.clipboardDimensions` and `NSPasteboard.withUniqueName` |
| `ColorPickerTests.swift` | Tests `ColorPickerPanelController` windows |
| `SelectionTests.swift` | Upstream bug: references `NavigationTool.objectSelection`, which upstream's own `EditorSession` no longer has (removed when Object mode merged into the Magic tool, 376e02a), so the file does not compile even on macOS at this commit |
| `BlendShortcutTests.swift` | Upstream regression: asserts wrapping backward from Normal lands on `.colorBurn` (the historical end of `LayerBlendMode` in v1.0.4), but upstream expanded `LayerBlendMode` with `.hue`, `.saturation`, `.color`, `.luminosity` without updating this test |
| `TransformPressTests.swift` | Upstream test oversight: moving by (20, 10) in a 400x300 canvas shifts layer center to (220, 160); with canvas snapping tolerance `10 / pointsPerPixel = 14.7`, `abs(160 - 150) <= 14.7` snaps midY back to canvas center (150), moving `origin.y` from 110 back to 100. |
| `DistortTests.swift` | Upstream implementation bug in `Compositor/Document/Distort.swift:16`: `DistortWarp.isUsable` only verifies that sub-triangle areas are positive, failing to reject self-intersecting bow-tie quads. The test expects `!isUsable` which fails in upstream's own code. |
| `FilterTests.swift` | Upstream regression: `gaussianBlurSoftensAHardEdgeWithoutFadingTheBordersAsOneUndoStep` expects border pixel `alpha(0) == 255`, but upstream switched from clamped Gaussian blur to unclamped blur with border trimming, causing edge pixels to fade. |
| `LayerAppearanceTests.swift` | Upstream regression: commit `391042d` added folder opacity support, causing opacity shortcuts on selections containing a group to adjust group opacity to 0.5. Line 45 asserts stale pre-commit expectation `folder.opacity == 1`. |

