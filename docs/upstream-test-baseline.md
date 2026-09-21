# Upstream test baseline — verified 2026-09-21 after Brush fix

Reference: macOS 1.1.8, `upstream/main` at `c39da13b5db11bc8678ec04a7a748e1e0a589244`.
Linux working tree: `7b4241c` plus Claude's compatibility work and this continuation's CGContext opacity fix.

| Lane | Fresh result |
|---|---|
| Linux/core XCTest | 478 tests, 0 failures, 0 skips; 31.302 s |
| Original upstream Swift Testing | 232 tests in 41 suites, 214 passed, 18 failed, 30 failed assertions; 471.361 s |
| Upstream Brush cluster | All 19 tests pass, including hosted-view focus routing and masked live/committed painting |
| Focused CGContext compatibility | All 15 tests pass, including 2 new regression tests |

The full run included `tiledLayersDrawLikeOneImage`; it passed all three cases in 122.448 s.
The ten source-file exclusions in [UPSTREAM_TEST_EXCLUSIONS.md](../linux/UPSTREAM_TEST_EXCLUSIONS.md) still apply.
All 18 failing test names were already present in Claude's preceding session; no new failing test name appeared.
This is not a claim of full macOS parity or physical-GPU qualification.

Brush's historical 12 failed assertions split into 4 keyboard assertions already fixed by Claude's final edits and
8 masked-opacity assertions fixed here. `CGContext.draw` passed an already alpha-scaled opacity to Skia, whose canvas
applied the same alpha again. The wrapper now passes only per-draw opacity to Skia and combines alpha once on the
software path. The original macOS source and tests were not changed.

Both new regression tests failed before the fix (10 assertions, including masked alpha 32 instead of 64), then passed.
They cover Linux/y-up bitmap contexts, per-draw opacity, restored graphics state and mask coverage.

## Reproduction

Inside the installed KDE 6.10 SDK, using Swift 6.3.3:

```sh
export QT_QPA_PLATFORM=offscreen
export COMPOSITOR_SKIA_BRIDGE="$COMPOSITOR_TEST_LIB_DIR/libCompositorSkiaBridge.so"
export COMPOSITOR_IMAGEIO_BACKEND="$COMPOSITOR_TEST_LIB_DIR/libCompositorQtImageIO.so"
/usr/lib/sdk/swift6/bin/swift test --no-parallel
```

Set `COMPOSITOR_TEST_LIB_DIR` to a CMake build containing both libraries. This run used Claude's existing
`/tmp/claude-1000/-home-developer-Projekty-Compositor/e464928d-e1b1-498e-9929-0a393dbfe173/scratchpad/cmake-b`.
That session-specific path is verification evidence, not a release dependency. The Vulkan brush device reported
`llvmpipe (LLVM 21.1.8, 256 bits)`, type 4 (software Vulkan), driver 109060098.

Focused command: `swift test --no-parallel --filter 'BrushTests|CoreGraphicsCompatTests'`.
Raw logs from this continuation: `.brush-regression-before.log`, `.brush-after.log`, `.catchup-full-tests.log`.

## Remaining failure clusters

| Suite | Failed assertions |
|---|---:|
| BlendShortcutTests | 1 |
| DistortTests | 2 |
| FilterTests | 2 |
| HueSaturationTests | 7 |
| LayerAppearanceTests | 3 |
| SelectionEditTests | 1 |
| TiledLayerTests | 4 |
| TransformPressTests | 2 |
| TransformTests | 6 |
| TypeToolTests | 2 |

The selection-invert failure is a debug-build timing assertion. Suspected stale upstream expectations must be
checked on macOS at the same SHA before classifying them as Linux wrapper defects.

Failed tests:

- `shiftPlusAndMinusStepTheActiveLayersBlendModeWhereverFocusIsExceptTextFields()`
- `perspectiveMappingHitsTheCornersAndTwistedShapesAreRefused()`
- `distortingWarpsTheLayerIntoTheShapeAsOneUndoStep()`
- `gaussianBlurSoftensAHardEdgeWithoutFadingTheBordersAsOneUndoStep()`
- `eyedroppersRecenterWidenAndNarrowTheBand()`
- `targetedAdjustmentPicksTheRangeUnderTheCursor()`
- `moveToolNumberKeysSetSelectedLayersOpacityAsOneUndo()`
- `blendModesAndOpacityMatchKnownPixels()`
- `invertIsFastOnLargeImagesAndHandlesUniformMasksWithASelection()`
- `maskStrokesDrawLikeOneMask(scale:rotation:)`
- `translucentStrokesDrawLikeOneImage(scale:rotation:)`
- `paintingAScaledDownLayerDoesNotShiftItsPixels()`
- `draggingOutsideTheLayerMovesIt()`
- `optionDraggingOutsideTheLayerDuplicatesIt()`
- `renderingRotatesScalesAndFlipsWithoutReplacingPixels()`
- `layerListToolKeysAndTransformNudge()`
- `rasterHasTransparentBackgroundAndColoredGlyphs()`
- `clippingToTextExportsColoredGlyphsOnTransparency()`

Implementation order and the comparison with Claude are in [the catch-up plan](upstream-catch-up-plan-2026-09-21.md).

---

## Historical baseline from Claude before final keyboard/opacity fixes

Run: `COMPOSITOR_SKIA_BRIDGE=<cmake-b>/libCompositorSkiaBridge.so COMPOSITOR_IMAGEIO_BACKEND=<cmake-b>/libCompositorQtImageIO.so QT_QPA_PLATFORM=offscreen swift test --no-parallel --skip CompositorCoreTests --skip tiledLayersDrawLikeOneImage`
(`tiledLayersDrawLikeOneImage` passes but takes ~110 s on the software path. Build the two libraries with
`ninja CompositorSkiaBridge CompositorQtImageIO`.)

Progress (231 tests, no crashes): 49 failing on the first run -> 27 after the mask fixes -> 22 after the codecs.
ImageIO is now backed by `libCompositorQtImageIO.so` (Qt JPEG/TIFF/WebP/..., libheif for HEIC/AVIF, EXIF orientation on
write) which the Swift shim dlopens on first use; GIF is written by a portable Swift encoder. Where only an AV1 encoder
is installed (no x265), `.heic` files carry AV1 in the HEIF container.

Remaining by area (issue counts): Brush 12 (key routing through NSHostingView, masked opacity), HueSaturation 7,
Transform 6 + TransformPress 2, LayerAppearance 5 (blend modes/opacity), TiledLayer 4, BlendShortcut 4 (NSEvent),
TypeTool 2 (text raster), Filter 2 (gaussian blur edges), Distort 2, one each SelectionEdit (debug-build speed), LiveMask.

Failing tests:

- appearancePersistsThroughSaveResizeAndTransparentExport()
- blendModesAndOpacityMatchKnownPixels()
- bracketKeysReachTheBrushWhereverFocusIsExceptTextFields()
- clippingToTextExportsColoredGlyphsOnTransparency()
- coverageOpacityAndDisabledMasksRenderCorrectly()
- distortingWarpsTheLayerIntoTheShapeAsOneUndoStep()
- draggingOutsideTheLayerMovesIt()
- eyedroppersRecenterWidenAndNarrowTheBand()
- gaussianBlurSoftensAHardEdgeWithoutFadingTheBordersAsOneUndoStep()
- hiddenBlackSourceSuppliesAlphaAndRasterMasksMultiply()
- invertIsFastOnLargeImagesAndHandlesUniformMasksWithASelection()
- layerListToolKeysAndTransformNudge()
- maskedImagePaintingUsesCoverageAndOpacityOnlyOnce()
- moveToolNumberKeysSetSelectedLayersOpacityAsOneUndo()
- optionDraggingOutsideTheLayerDuplicatesIt()
- paintingAScaledDownLayerDoesNotShiftItsPixels()
- perspectiveMappingHitsTheCornersAndTwistedShapesAreRefused()
- rasterHasTransparentBackgroundAndColoredGlyphs()
- renderingRotatesScalesAndFlipsWithoutReplacingPixels()
- shiftBracketsStepHardnessFromTheCanvas()
- shiftPlusAndMinusStepTheActiveLayersBlendModeWhereverFocusIsExceptTextFields()
- targetedAdjustmentPicksTheRangeUnderTheCursor()
