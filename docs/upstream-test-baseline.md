# Upstream test baseline (unmodified `CompositorTests` on Linux)

Run: `COMPOSITOR_SKIA_BRIDGE=<cmake-b>/libCompositorSkiaBridge.so COMPOSITOR_IMAGEIO_BACKEND=<cmake-b>/libCompositorQtImageIO.so QT_QPA_PLATFORM=offscreen swift test --no-parallel --skip CompositorCoreTests --skip tiledLayersDrawLikeOneImage`
(`tiledLayersDrawLikeOneImage` passes but takes ~110 s on the software path. Build the libraries with
`ninja CompositorSkiaBridge CompositorQtImageIO`.)

Progress (230 tests, no crashes): 49 failing on the first run -> 27 (masks) -> 22 (codecs) -> 12 (brush/key routing).
Key routing now works: the hierarchy gets `viewDidMoveToWindow` down the subtree (so `CanvasView` installs its key
monitor), `NSEvent(cgEvent:)` carries modifiers and US-layout characters, `NSHostingView` hosts a stand-in's native
view, and focusing a text field puts a field editor (`NSText`) in the responder chain.
`BlendShortcutTests` is excluded as a stale upstream test (see `linux/UPSTREAM_TEST_EXCLUSIONS.md`).

Remaining by area: Transform (rendering flips/rotation, option-drag duplicate, layer-list keys), Distort (corner order),
TypeTool text raster (2 tests), gaussian blur edges, perspective mapping, tiled scaled-down painting shift, folder
opacity keys, one debug-build speed test.

Failing tests:

- clippingToTextExportsColoredGlyphsOnTransparency()
- distortingWarpsTheLayerIntoTheShapeAsOneUndoStep()
- draggingOutsideTheLayerMovesIt()
- gaussianBlurSoftensAHardEdgeWithoutFadingTheBordersAsOneUndoStep()
- invertIsFastOnLargeImagesAndHandlesUniformMasksWithASelection()
- layerListToolKeysAndTransformNudge()
- moveToolNumberKeysSetSelectedLayersOpacityAsOneUndo()
- optionDraggingOutsideTheLayerDuplicatesIt()
- paintingAScaledDownLayerDoesNotShiftItsPixels()
- perspectiveMappingHitsTheCornersAndTwistedShapesAreRefused()
- rasterHasTransparentBackgroundAndColoredGlyphs()
- renderingRotatesScalesAndFlipsWithoutReplacingPixels()
