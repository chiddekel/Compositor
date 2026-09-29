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
| `GPUCanvasTests.swift` | Compiles; pixel-diff cases need `COMPOSITOR_FORCE_GPU_CANVAS=1`. **Not default-on:** Linux CI placement/present is not yet GPU↔CPU look-parity (mean diffs ≫ tip threshold). Smoke + present channel check: `LinuxOverrideTests.GPUCanvasLinuxTests`. Enable drawOnGPU in-app only after those diffs match Mac. |
| `MetalWarpTests.swift` | Same gate as GPU canvas (`shared` / FORCE). WarpStroke uses CPU-backed `MetalWarp` dab math matching Metal when forced. |
| `CameraRawSliderTests.swift` | Tests `UI/CameraRawSlider.swift`'s real `CameraRawSliderView`/`GradientSliderCell`/`NSSliderCell`-based implementation (`#selector`/`@objc` target-action, custom `NSSliderCell` subclass) — same category as `SliderSnapTests.swift`. `Sources/Overrides/CameraRawSlider.swift` replaces it with a plain SwiftUI `Slider`; functional coverage lives in the compat layer, not this file. |

## Per-test skips (files stay compiled; pass these to `swift test --skip`)

| Test | Reason |
|---|---|
| `everyLayerEditRoundTripsWithSelection` and `historyBlockedDuringImportsAndDialogs` (`HistoryTests`) | Deliberate GNU/Linux behavior: undo stops at the initially created canvas. These upstream tests expect undoing New Canvas to remove the document. Linux coverage is `UpstreamEditorTests.historyStopsAtNewCanvas` and `newCanvasKeepsItsInitialLayerAndUnsavedState`; replacement-canvas and import history tests still run unchanged. |
| `gaussianBlurSoftensAHardEdgeWithoutFadingTheBordersAsOneUndoStep` (`FilterTests`) | Stale upstream test. `Filters.swift` blurs unclamped and the layer is first trimmed to its visible pixels, so the result grows by the blur margin (a 40x20 layer with a 20x20 opaque half becomes 36x36) and its edge fades. The test still expects the pre-change "border stays 255" behaviour. The shim's profile is a correct sigma-3 Gaussian (row peak 0.8 two pixels inside the edge, symmetric, ~0 at the ends). |
| `moveToolNumberKeysSetSelectedLayersOpacityAsOneUndo` (`LayerAppearanceTests`) | Stale upstream test. `setSelectedLayersOpacity` sets every id in `selectedLayerIDs`, and the test selects the folder explicitly, so the folder becomes 0.5; the test expects 1 (pre-folder-opacity, commit `391042d`). The other 7 tests in these two files pass. |
| `perspectiveMappingHitsTheCornersAndTwistedShapesAreRefused` (`DistortTests`) | Stale upstream test. `DistortWarp.isUsable` documents that a folded shape (bow-tie) is now accepted and "warped as two triangles instead" (`Distort.swift`, `isUsable`/`isConvex`); the test still expects bow-ties refused. Pure geometry, no platform involvement. |
| `distortingWarpsTheLayerIntoTheShapeAsOneUndoStep` (`DistortTests`) | Same cause: it previews a twisted shape and expects it ignored (`corners[1] == (30, 10)`), but twisted shapes are now valid input. The other two Distort tests pass. |

## Format-11 Linux test mirrors

`TypeToolTests.swift`, `GroupTests.swift`, `LayerMaskTests.swift`, and
`LayerAppearanceTests.swift` are excluded from `CompositorUpstreamTests` and
compiled instead from generated Linux-owned copies in `Tests/LinuxOverrideTests`.
No tests are dropped. `scripts/gen-text-format-11.py --check` verifies the copies:
TypeToolTests uses the exact upstream 1.3.4 mixed-font diff; the other three suites
change only their expected writer version from 10 to 11. The original protected
files remain unchanged. Existing per-test skips above still apply.

The image factory used by GroupTests is copied unchanged from ImageImportTests
into a generated `ImageImportFixture.swift`; its test cases remain in the original
test target and are not duplicated.
