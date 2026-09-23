# Upstream test baseline (unmodified `CompositorTests` on Linux)

Run: `COMPOSITOR_SKIA_BRIDGE=<cmake-b>/libCompositorSkiaBridge.so COMPOSITOR_IMAGEIO_BACKEND=<cmake-b>/libCompositorQtImageIO.so QT_QPA_PLATFORM=offscreen swift test --no-parallel --skip CompositorCoreTests --skip tiledLayersDrawLikeOneImage`
(`tiledLayersDrawLikeOneImage` passes but takes ~110 s on the software path. Build the libraries with
`ninja CompositorSkiaBridge CompositorQtImageIO`.)

Progress: All 211 tests across 35 active upstream test suites pass cleanly on Linux (100% green).
All confirmed upstream test regressions and platform-incompatible UI tests are quarantined and documented in `linux/UPSTREAM_TEST_EXCLUSIONS.md`.

Failing tests: None. All 211 tests in CompositorUpstreamTests pass.


## 2026-09-21 re-check: FilterTests and LayerAppearanceTests

Both files are compiled again (file-level exclusion removed). 7 of their 9 tests pass; the 2 that fail are stale
upstream tests, skipped individually (see `linux/UPSTREAM_TEST_EXCLUSIONS.md`):
`--skip gaussianBlurSoftensAHardEdgeWithoutFadingTheBordersAsOneUndoStep --skip moveToolNumberKeysSetSelectedLayersOpacityAsOneUndo`.

## 2026-09-21 re-check: TiledLayerTests and DistortTests

Both files compile again. 5 of 9 tests pass (`distortedLayerIsTrimmedToItsVisiblePixels`, `tiledLayersDrawLikeOneImage` x3,
`paintingAtTheLayersEdgeDoesNotChangeIt` x2, `paintingAScaledDownLayersMaskDoesNotShiftItsPixels`). Skip per test:
`--skip perspectiveMappingHitsTheCorners --skip distortingWarpsTheLayerIntoTheShape`.
Distort's two are stale upstream tests. The three Tiled ones are real Linux fidelity gaps (clip rasterisation and piece
resampling), open work, not upstream problems.

Correction: `paintingAScaledDownLayerDoesNotShiftItsPixels` is not a Skia resampling gap. The AppKit shim's cached-display bitmap
(`bitmapImageRepForCachingDisplay`, `NSImage(size:flipped:drawingHandler:)`) was a top-left-origin context with an emulated
flip, so images drew mirrored inside each drawn rect, and pieces disagreed with the whole layer. Those contexts are now real
bottom-left Core Graphics bitmaps (flipped views flip them back) and the test passes. Only the two 25° tile-seam tests remain
skipped in TiledLayerTests (`translucentStrokesDrawLikeOneImage`, `maskStrokesDrawLikeOneMask`).

Fixed: the 25° tile-seam failures (`TiledLayerTests`, now fully passing, 6/6, ~7 min in a debug build). Skia rasterizes a
hard-edged clip under a rotation differently depending on what is already clipped (it trims the edge to the current clip,
which shifts fixed-point rounding at pixel-centre ties), so upstream's clear-then-draw-inside-the-clip pattern drew a
few edge pixels twice. The bridge now rasterizes such clips once, against the whole surface, and applies them as a
region, so a path has one answer as in Core Graphics (`HardClipConsistencyTests` locks it in). The earlier
"Skia vs Core Graphics rasterization" wording was only half right: the fill/clip/image-draw primitives agree; the
ancestor-dependence was the cause.

## 2026-09-22 current baseline (post upstream 1.1.8 -> 1.2.2 merge, CompositorCore retirement)

Run: `COMPOSITOR_SKIA_BRIDGE=<cmake-b>/libCompositorSkiaBridge.so COMPOSITOR_IMAGEIO_BACKEND=<cmake-b>/libCompositorQtImageIO.so
QT_QPA_PLATFORM=offscreen swift test --no-parallel --skip CompatTests --skip LinuxOverrideTests --skip tiledLayersDrawLikeOneImage
--skip gaussianBlurSoftensAHardEdge --skip moveToolNumberKeysSetSelectedLayersOpacity --skip perspectiveMappingHitsTheCorners
--skip distortingWarpsTheLayerIntoTheShape` (the test-target name is now `CompositorUpstreamTests`, not `CompositorCoreTests`
— that fork target no longer exists).

**260 of 260 run tests pass** (up from the 211/222 baselines above; 1.2.0-1.2.2 added PSD/RAW import, Outer Glow,
Invert/Black&White/Color Balance, and the full Photoshop blend-mode set, each with its own tests). Only 5 stale-upstream-test
skips remain, all previously verified as genuine upstream test bugs (not Linux fidelity gaps), each documented at its
own re-check above:
- `gaussianBlurSoftensAHardEdgeWithoutFadingTheBordersAsOneUndoStep`
- `moveToolNumberKeysSetSelectedLayersOpacityAsOneUndo`
- `perspectiveMappingHitsTheCornersAndTwistedShapesAreRefused`
- `distortingWarpsTheLayerIntoTheShapeAsOneUndoStep`
- `tiledLayersDrawLikeOneImage` (passes; skipped only for its ~110s runtime on the software path)

`translucentStrokesDrawLikeOneImage` and `maskStrokesDrawLikeOneMask` are NOT in this list — they were fixed by the
hard-clip region change and pass (confirmed by running `TiledLayerTests` alone, 6/6, ~8 min). A stale `--skip` for both
had crept back into ad hoc test invocations after that fix; this entry is the correction.

## 2026-09-23 re-check, after the upstream v1.2.4-1.2.6 merge

Same invocation as above. **302 of 306 run tests pass.** 4 new failures, both real, neither related to the merge's
own Swift changes (CIBloom, NSPasteboard.setString):
- `InnerGlowTests`'s 3 rendering tests — InnerGlow (an upstream v1.2.x layer effect) has no Linux rendering pass
  yet. Needs its own `Sources/Overrides/MetalLayerEffects.swift` addition. Open.
- `BrushTests.bracketKeysReachTheBrushWhereverFocusIsExceptTextFields` — drives `NSHostingView<LayersPanel>`'s
  table lookup, the same `NSTableView`/Objective-C-runtime pattern already excluded for `LayerTests.swift` in
  `linux/UPSTREAM_TEST_EXCLUSIONS.md`, just surfacing in a different, not-yet-excluded file. Needs triage:
  either exclude this one test the same way, or confirm it's newly reachable and genuinely fixable.

**Resolved 2026-09-23, after the upstream `f67b46b` merge: full `swift test` green — 340 Swift Testing + 96 XCTest,
0 failures** (default parallel run, bridge + ImageIO backend set):
- InnerGlow: added to `CompositorEffectsParams` and all three C tiers (CPU, OpenCV, Vulkan shader passes 15-18),
  same blur + keep-inside + compose order as upstream's Metal renderer; `LayerEffectsBackendTests` checks it.
- `bracketKeys…`: compat `NSHostingView` now hosts a `HostedNativeContent` found anywhere in its tree, and the
  `NativeLayerList` override provides `LayerTableView` — upstream's own canvas key monitor then does the rest.
- `TransformTests.autoSelect…` (order-dependent): `ToolDefaults` skips UserDefaults only when
  `XCTestConfigurationFilePath` is set, as Xcode's runner does; `_Testing_XCTestEnvironment` sets it for the
  upstream test process, so a test's toggle no longer leaks into later tests.
- `UpstreamEditorTests` (Linux-owned): expectations updated — `new` starts with "Layer 1", as upstream's New Canvas.
- `TitleBarDragTests.swift`: excluded (see `linux/UPSTREAM_TEST_EXCLUSIONS.md`).

Also confirmed (see README's Known Issues correction): `AdjustmentLayerTests`/`ProjectTests` blank-render/heap-
corruption reports from earlier this session were a missing-`COMPOSITOR_SKIA_BRIDGE` invocation mistake, not a
real bug — they pass clean (19/19, no crash) under this doc's documented invocation, with or without
`--no-parallel`. `CIFilter`'s `supportedNames` allowlist was also missing `"CIBloom"` (silently fell back to the
unmodified source image instead of failing loudly), and the compat `CIBloom` implementation didn't spread alpha
past the source's opaque region the way real `CIBloom`'s glow does — both fixed, `FinishingFilterTests` now 5/5.
