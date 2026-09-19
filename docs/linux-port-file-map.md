# Linux port: file-by-file disposition

Baseline: a19db90, 2026-09-19. Derived from the code graph, tracked-source inventory, import audit and detailed inspection of critical boundaries. Disposition is a planning classification, not a claim that every function was ported or proven equivalent. `Keep` means reuse intent and implementation where compatible; indirect Apple dependencies must still be tested. Original macOS files remain supported. Targets describe responsibilities, not one-for-one Apple API emulation.

## Implementation checkpoint — 2026-09-19

**The full file map is not complete.** This document was restored from commit `bbb2b7a` because it was absent on the implementation branch. The original application, test, and distribution inventories below remain the acceptance scope.

Linux acceptance boundary: Swift owns validated document state; Qt owns codecs,
package directories, and desktop event-loop integration. A row is complete only
when its portable behavior has a Swift or host check; macOS-only UI remains in
the original Xcode target.

This checkpoint adds the following portable core responsibilities. Tests establish the stated core behavior; Qt integration and macOS pixel/journey equivalence still need verification.

| Original responsibility | Portable implementation | Current evidence / remaining scope |
|---|---|---|
| `BlurTool.swift`, `PixelInvert.swift` | `Sources/CompositorCore/Document/BlurTool.swift` | Premultiplied invert, mask invert, selection-limited operations, and rotated reveal-mask regression in `FilterExecutionTests`; input/tool wiring remains. |
| `Filters.swift`, `ContentFill.swift`, image-adjustment execution | `Document/PixelFilter.swift`, `Document/FilterEdit.swift` under `Sources/CompositorCore` | Kernel execution, padded blur, deterministic noise, preview revisions, cancel, stale target rejection, one-step undo, and carried masks tested. Qt filter dialogs and scheduling remain; background removal still reports missing model. Motion blur uses a box streak and needs reference parity work. |
| Layer-mask raster adapters | `Sources/CompositorCore/Document/MaskRaster.swift` | Mask validation, solid masks, border tone, and independently placed mask resampling tested. Folder/live-mask renderer integration and placement caches remain. |
| Smooth layer/coverage rendering | `Sources/CompositorCore/Rendering/LayerRenderer.swift` | Corrected pixel-center sampling and requested-center scaling. Exact 1:1 color/alpha and rotated reveal-mask behavior tested; full Skia/blend parity remains. |
| `IO/CanvasResizer.swift` | `Sources/CompositorCore/Document/CanvasResizer.swift` | All nine anchors, odd-size expansion/shrink, unchanged source identity, detached mask placement, colored extension transparency, undo snapshots, and allocation limits tested. UI/persistence journey remains. |
| `IO/ImageResizer.swift` | `Sources/CompositorCore/Document/ImageResizer.swift` | Resolution-only sharing, transformed per-layer resampling, output-budget preflight, area integration for downsampling, hidden layers, alpha, and identity/undo preservation tested. Backend pixel parity, large-document performance, and UI remain. |
| `EditorSession+Projects.swift` manifest mapping | `Sources/CompositorCore/Document/ProjectSnapshotMapping.swift` | Document/snapshot mapping, missing-asset rejection, v7 adjustment/shape/mask-placement JSON round trip tested. Open/save coordination and editor-session lifecycle remain. |
| `docs/project-format.md` | Version 1–7 schema documentation | Describes current mask placement/linking and shape fields; Swift and Qt host round-trip checks cover manifest and filesystem assets. |
| Isolated SwiftPM build output | `.gitignore` | `.build/` excluded alongside CMake and Flatpak build output. |

Verification at this checkpoint: the full Swift suite passed **307 tests** in the installed KDE 6.10 SDK (Swift 6.3.3, Swift 5 language mode). The full-run log is `build/linux-core-tests.log`. The Qt host linked successfully against the expanded Swift archive, and all **3 CTest checks** passed (`CompositorCore.Abi`, `CompositorCore.Kernels`, `CompositorCore.HostJourney`). The CTest ABI check uses the C reference implementation, while Swift's own suite checks the Swift implementation. These tests do not cover the whole original 49-file test inventory or establish full feature parity.

Reproduce the core check from the repository root:

```sh
flatpak run --command=sh --devel --filesystem="$PWD" org.kde.Sdk//6.10 \
  -c 'cd "$1" && /usr/lib/sdk/swift6/bin/swift test' sh "$PWD"
```

Remaining work includes connecting the Swift document/session commands and immutable history to Qt; the complete canvas/tool/layer/tab/dialog interactions; package persistence and codec metadata; complete mask/adjustment/tiled rendering and Skia integration; Vulkan brush compute with CPU fallback; offline segmentation; porting the original test assertions and UI journeys; macOS reference fixtures; performance measurements; and full Flatpak artifact validation. The existing minimal host and CPU-only unit tests are intermediate evidence, not completion of these rows.

### Implementation checkpoint — 2026-09-19 (composition root & session journey)

**Composition-root constraint (discovered, blocking the file map's first workstream).** The file map's ENG-2 composition root assumed a C++ Qt `main` that embeds the Swift core via the `@_cdecl` C ABI. On the Freedesktop Swift 6.3 SDK this does not work, and there is no documented in-process entry point to fix it:

- *Static* stdlib embedded in a C++ binary: the SDK ships no `swift_initSwiftRuntime`. The static archives' `.init_array` constructors are registered in the linked binary's `.init_array` but do not bootstrap generic class metadata. The first `Dictionary` insertion (`_DictionaryStorage.allocate`) SEGVs with an uninitialized metadata pointer. This blocks `compositor_session_create` itself.
- *Shared* stdlib (`libswiftCore.so` + Foundation `.so`s, rpath-linked): stdlib `Dictionary` works, but Foundation's `JSONDecoder` / `Data.withUnsafeBytes` (`__DataStorage`) traps (`UnsafeRawBufferPointer.swift:229` / `malloc_usable_size` on an invalid storage pointer) even on pure-Swift `Data` with no foreign pointer. So the JSON command path used by `compositor_session_command` is unusable from a C++ `main`.

The only supported way to use Foundation is a **Swift entry point** that SwiftPM bootstraps. The composition root must therefore change to a Swift `@main` that initializes the Swift runtime and Foundation, then drives the Qt host through a C ABI (the inverse of the current `host/main.cpp`), or otherwise guarantees a Swift entry runs before any Foundation use. The C++ `tests/test_session_journey.cpp` is gated out of the default build for this reason; its header documents the blocker.

**Composition-root wiring verified end-to-end.** `Sources/CompositorHostBootstrap/hostMain.swift` is a Swift `@main` that imports the `HostRun` C++ target (host/host_run.cpp, moc-free Qt entry) and runs the create→new→paint→render→undo→redo→close journey through the real `compositor_session_*` ABI, then calls `compositor_host_run` to initialize Qt. Verified in-sandbox against the KDE SDK's Qt6: `swift run CompositorHostBootstrap` prints both "session journey OK" and "Qt host entry OK" (exit 0), and the release `--static-swift-stdlib` build (Flatpak-style, runtime bundled) runs identically — because the main IS Swift, the runtime bootstraps where a C++ `main` cannot. CMake also builds the Qt-side `CompositorHostRun` static lib (host/host_run.cpp + host/include/compositor_host_run.h) for the full-MainWindow Flatpak build. The minimal Flatpak manifest (`com.wonderassembly.Compositor.minimal.yaml`) now installs this Swift `@main` binary as the app command (it previously installed the C++ `compositor` target, which would segfault at the first Swift call). Default CMake/CTest stays 3/3; the Swift suite stays 324/0. Remaining for the first workstream: swap the bootstrap's plain-QWidget `host_run` for the real `MainWindow` + `app.exec()` (needs AUTOMOC, so built via CMake and linked in the Flatpak manifest), wire the canvas/tool/layer interactions to `compositor_session_*`, and the save/reopen/export legs (see the IO/codec mapping below).

**Session journey verified (host-verifiable slice of the first workstream).** Because the journey can run under `swift test` (where SwiftPM bootstraps the runtime and Foundation), the same create→new→paint→render→undo→redo→state→close journey is verified end-to-end through the real `compositor_session_*` ABI in `Tests/CompositorCoreTests/SessionJourneyTests.swift`: a 4×4 canvas, a solid red brush stroke, render-byte and red-pixel assertions, undo-to-blank, redo-to-red, state JSON fields (`width`, `height`, `busy`, `canUndo`, `canRedo`), and closed-handle rejection (`-6`). This is real progress on the "First packaged open/paint/undo/save/reopen/export journey" workstream; the remaining save/reopen/export legs and the Qt-driven host journey still need the Swift-`@main` composition root above.

**Test-tier ports begun (host-verifiable slice).** The macOS `CompositorTests/CompositorTests.swift` viewport-geometry assertions are ported to `Tests/CompositorCoreTests/ViewportGeometryTests.swift`: `dimensionValidation`, `actualPixelsAndRoundTrip` (backing 1/2), `zoomKeepsCursorPixelFixed`, `fitAndResizeModes` — assertions kept verbatim against the portable `CanvasViewport`. The fifth original test (`limitsAndNewDocumentReset`) is not portable here: it drives `session.viewport` / `session.zoom(to:)`, macOS UI-layer EditorSession extensions owned by the "Rewrite Linux UI" tier. `CompositorTests/GroupingSelectionTests.swift` is also ported to `Tests/CompositorCoreTests/GroupingSelectionTests.swift` (all 3 assertions) — this required porting the macOS grouping/selection EditorSession extensions (below). Two of the 49 test files ported under `swift test`; the bulk remain AppKit/SwiftUI-coupled and need the raster/UI milestone.

**Grouping/selection ported (file-map "Keep/adapt" tier advanced).** The macOS `LayerGroups.swift` `EditorSession` extensions are now ported onto the Linux `EditorSession`: `selectLayers(_:primary:)`, `selectLayer(_:)`, `groupSelectedLayers()`, `addGroup()`, `descendantIDs(of:)`, `layerRows`, `canTransform`/`transformsAsGroup`/`groupTransformMembers`, `canEditLayers`, `beginEdit`/`endEdit` (and `commitTransform`/`resolveGradient` as headless no-op hooks). `CanvasDocument.hierarchyEntries`/`effectiveVisibleIDs`/`renderLayers` are ported. Selection state (`selectedLayerIDs`) is restored on undo/redo via the `activeLayerID` `didSet` (history stores only `activeLayerID`, exactly as on macOS — `DocumentHistory` needed no change). The interactive place/toggle/expand/move methods (`toggleGroupExpansion`, `placeLayer`, `moveActiveLayerOutOfGroup`, `canPlaceLayer`) are now ported in the operations batch (they need drag/drop presentation for the Qt tier). A port-correctness fix surfaced: macOS `createDocument(emptyLayer:)` defaults to an *empty* document (zero layers); the Linux port unconditionally created a "Layer 1". The Linux `createDocument` now matches macOS (default `emptyLayer: false` → zero layers), with no regression to the existing suite.

**Verification:** full Swift suite **332 tests, 0 failures** (was 329; the 3 grouping/selection assertions add three); default CMake build **4/4 CTest** pass (`CompositorCore.Abi`, `.Kernels`, `.HostJourney`, `.PngCodec` — was 3/3; the PNG codec test is new) — and now also builds `CompositorHostRun` with the AUTOMOC'd `SessionWindow`; the Swift `@main` composition root still runs (session journey OK + Qt host entry OK under `QT_QPA_PLATFORM=offscreen`), now creating the `SessionWindow` and painting the C-ABI-rendered `QImage`. The C++ session-journey test is not in CTest (gated on `CompositorCore_SWIFT_STATIC_LIB`, which is not set for the default build).

**Save/reopen leg verified (host-verifiable slice).** The create→paint→undo→redo leg above now extends through a save/reopen round-trip in `SessionJourneyTests.testRenderImportRoundTripReopensCompositedImage`: a painted document is flattened to composited RGBA via `compositor_session_render` (the "export"/"save" bytes), then a *fresh* session reopens it via `compositor_session_import_rgba` (replacing) and renders it back — byte-identical to the saved render. This is the ABI foundation that the PNG/JPEG export (`ImageExporter`→`QImageWriter`, see the IO/codec mapping) and the project-file save (`ProjectStore` Codable) legs both build on; those still need Qt codecs / the Codable persistence layer, but the round-trip itself is proven under `swift test`.

**Qt UI tier unblocked — moc'd Q_OBJECT window drives the Swift core (host-verifiable slice).** The first workstream's remaining "swap the bootstrap's plain-QWidget `host_run` for a real Qt window" leg is now done: `host/SessionWindow.{h,cpp}` is a `QMainWindow` (`Q_OBJECT`) created from `compositor_host_run` that drives the Swift core through `compositor_session_*` (create → new → brush → render → close) and paints the composited RGBA via `QImage`. The blocker for a real `Q_OBJECT` window under SwiftPM was that SwiftPM cannot run `moc`; the workaround is to pre-generate the moc output with `/usr/lib/libexec/moc` (Qt 6.10.3, in the KDE SDK) and commit `host/moc_SessionWindow.cpp` as a SwiftPM source. CMake uses `AUTOMOC` instead (the committed moc is excluded from the CMake `CompositorHostRun` target to avoid duplicate symbols). This proves the architecture the Flatpak build ships — a moc'd Qt window built via SwiftPM and linked into the Swift `@main`, calling the Swift core through the C ABI and rendering to a `QImage` — with no external toolchain: Qt6 + moc are in the KDE 6.10 SDK. `SessionWindow` is distinct from `MainWindow` (the richer C++-main, C-kernels Qt shell for the C++-only build path); as the Qt UI tier grows, `MainWindow`'s shell rewires to drive `compositor_session_*` through this same link. The 28 "Rewrite Linux UI" widget rows are still unported — this slice proves the architectural core (moc'd Qt → Swift `@main` → C ABI → render → `QImage`), not the widget counterparts themselves.

**IO codec round-trip verified (host-verifiable slice, "IO / codec mapping" tier).** `tests/test_png_codec.cpp` (Qt-only, no Swift static lib) proves the export/import codec foundation: a 4×4 `QImage::Format_RGBA8888` buffer — including semi-transparent pixels (alpha 1/128/254) that a premultiplying codec would alter — round-trips through `QImageWriter`/`QImageReader` (PNG) **byte-identical**. This confirms Qt's PNG codec preserves straight (non-premultiplied) alpha, which is what `compositor_session_render` emits and what the `ImageExporter`→`QImageWriter` / `ImageImporter`→`QImageReader` legs rely on (macOS uses `CGImageDestination`/`CGImageSource`; the mapping in the "IO / codec mapping" section above replaces them). The test also probes `QImageReader::supportedImageFormats`/`supportedMimeTypes` (the `CGImageSourceCopyTypeIdentifiers` mapping) and the JPEG lossy leg (dimensions + opaque alpha; `QImageWriter::setQuality` is the `kCGImageDestinationLossyCompressionQuality` mapping). Qt codec coverage is complete for direct path IO; portal chooser integration remains UI work.

**IO package persistence verified.** `SessionWindow::saveProject` exports every
manifest image and mask through the Swift ABI, writes PNGs under `images/`, and
replaces the destination only after staged package completion. `loadProject`
validates into a fresh session, restores assets by UUID, renders before swapping
the live session, and leaves the current document unchanged on failure.
`CompositorHostBootstrap --io-smoke` verifies this path under Swift runtime.
Portal file chooser integration remains outside direct path persistence.

**Current verification.** SwiftPM under KDE SDK 6.10 passes **390 tests, 0
failures**. Host CMake/CTest passes **4/4** checks. Release static Swift build,
Swift composition-root launch, Qt brush/menu host build, and Qt IO smoke all pass.
Flatpak source download validation passes for pinned Skia/OpenCV archives.

Reproduce:

```sh
# Swift suite (includes SessionJourneyTests):
flatpak run --command=sh --devel --filesystem="$PWD" org.kde.Sdk//6.10 \
  -c 'cd "$1" && /usr/lib/sdk/swift6/bin/swift test' sh "$PWD"
# Default CMake + CTest (C-ref stand-in; no Swift static lib):
cmake -S . -B build-cmake -G Ninja && cmake --build build-cmake \
  && (cd build-cmake && ctest --output-on-failure)
```

### Qt sizing and filter transactions — current implementation

The required Linux platform remains the Freedesktop-based KDE SDK, Qt, Skia,
OpenCV, and Vulkan. Apply SOLID boundaries: document/session commands own state;
Qt components own presentation and codecs; rendering, image operations, and brush
compute belong behind dedicated backend interfaces. Vulkan replaces the Metal
compute path and must retain a working CPU fallback. The CPU implementations and
minimal manifest are intermediate verification paths, not the final platform.

`SizeDialog` and `FilterDialog` are separate Qt components in
`host/EditorDialogs.h`, `host/SizeDialog.cpp`, and `host/FilterDialog.cpp`.
`host/SessionDialogs.cpp` adapts their command callbacks to the Swift session.
The dialogs do not depend on the Swift ABI or implement pixel operations.

- Canvas sizing now exposes units, relative dimensions, aspect lock, all nine
  anchors, and transparent/black/white/custom extension colors. Cancel does not
  edit the document. Foreground/background palette choices remain unwired.
- Image sizing exposes units, aspect lock, resolution, resampling toggle, and
  sampling choice. The session now calls the shared `ImageResizer` implementation,
  including rotated-layer rasterization and allocation preflight. Resolution-only
  edits share pixel storage. Both resize commands preserve selection geometry.
- Gaussian blur, motion blur, noise, lens correction, grain, and exposure have
  editable Qt controls, live previews, a Preview toggle, Cancel/window-close
  rollback, and one-step commit/undo. Preview requests are debounced; execution is
  still synchronous. Worker scheduling and the other adjustment dialogs remain.
- Rendering refresh reads current session dimensions after resize/undo. PNG/JPEG
  exports use document resolution, including after reopening a project.

Verification: the full Swift suite passed **341 tests, 0 failures** and KDE SDK
CMake/CTest passed **4/4** checks. `CompositorHostBootstrap --dialog-smoke` drives
actual Qt menu actions and modal controls through the Swift composition root,
checking resize, cancellation, print resolution, preview visibility, commit,
undo, and project save/reopen. New session regressions cover resolution-only
pixel sharing, invalid resolution rejection, rotated resizing/selection geometry,
and canvas-extension undo. Logs are `build/linux-core-tests.log`,
`build/linux-dialog-tests.log`, and `build/linux-cmake-tests.log`. The release
`--static-swift-stdlib` build and its Qt dialog journey also pass; evidence is
`build/linux-release-build.log` and `build/linux-release-dialog-tests.log`.

```sh
flatpak run --command=sh --devel --filesystem="$PWD" org.kde.Sdk//6.10 \
  -c 'cd "$1" && QT_QPA_PLATFORM=offscreen /usr/lib/sdk/swift6/bin/swift run CompositorHostBootstrap --dialog-smoke' sh "$PWD"
```

These checks do not establish Skia/OpenCV/Vulkan integration, macOS reference
parity, complete UI behavior, or completion of the full file map.

### Adjustment editing, affected-region semantics

`AdjustmentEditing.swift` is now ported onto `EditorSession`: `addAdjustment(_:)`,
`beginAdjustmentEditing(_:)`, `previewAdjustmentEditing(_:)`,
`finishAdjustmentEditing(commit:)`, the `adjustmentEditingID`/`adjustmentOriginal`/
`adjustmentDraft` state, and the `canEditLayers`/`requireIdle` gating. `EditorBridge`
gains `addAdjustment` + `adjustmentBegin`/`adjustmentPreview`/
`adjustmentCommit`/`adjustmentCancel` JSON commands and the `adjustment` decode
field; the busy state includes `adjustmentEditingID`. `AdjustmentEditingTests`
covers create/preview-commit/cancel/undo/concurrency/bridge round-trip (9 tests).

The model keeps the macOS rule "an adjustment changes color, never the underlying
coverage." The CGContext-only `AdjustmentSurface.draw(in:)` is replaced on Linux by
`DocumentRenderer.adjust`, which applies the adjustment only inside the layer's
placed mask region (`maskCoverage`) and never writes outside alpha. `AdjustmentTests.testAdjustmentChangesOnlyMaskedRegionAndNeverAlpha` pins
both properties (color changes in masked half; alpha and unmasked color untouched).

Verification: full Swift suite **358 tests, 0 failures** in KDE 6.10 SDK. CTest 4/4.

### Transform handles, rotation and hit geometry

`TransformOverlay.swift`'s `TransformOverlayGeometry` is ported
(`Sources/CompositorCore/Rendering/TransformOverlay.swift`): the 8 handles on a
layer box or distortion's corner/edge midpoints, the 28pt rotation handle, and
`hit(_:)` (10pt radius; corners, edge midpoints, sides, rotation). Pure
`LayerTransform`/`CanvasViewport`/`TransformDrag.Mode` geometry, no AppKit. The
`resizeCursor(for:)` (`NSCursor`) and the `OverlayView` painting stay in the Qt
tier. `TransformOverlayGeometryTests` covers handle placement, corner/edge/
rotation hits, the distortion handle layout, and pan/zoom scaling (5 tests).

Verification: full Swift suite **363 tests, 0 failures** in KDE 6.10 SDK. CTest 4/4.

### Portable operations batch — crop/flip/warp/selection/shape/transform/appearance

A broad set of "Keep logic; replace Apple operations" rows is now ported onto
`EditorSession` with bridge commands and session tests. Verified at this
checkpoint: **390 tests, 0 failures** in the KDE 6.10 SDK; **4/4 CTest**.

| Original responsibility | Portable implementation | Current evidence / remaining scope |
|---|---|---|
| `Crop.swift` canvas cropping | `EditorSession.cropCanvas(to:)` (EditorSession.swift) | Contents cropped to the rect via the resampler with undo; bridge `cropCanvas`. Selection-rect interaction and margins remain UI. |
| `LayerFlip.swift` | `Document/LayerFlip.swift` | `flipLayers(horizontally:)` (flips group members together), `flipCanvas(horizontally:)`; bridge `flipLayer`/`flipCanvas`. |
| `SmudgeLiquify.swift` (warp/smudge) | `EditorSession.beginWarp/continueWarp/finishWarp` (EditorSession.swift) | Warp/smudge stroke runs on the active layer, resamples with the shared coverage backend, finishes to a valid document; `PortedOperationsTests` pins the journey. Liquify mode fidelity is backend parity work. |
| `SelectionClipboard.swift` | `Document/SelectionClipboard.swift` | `copySelection`/`copyMergedSelection`/`paste`/`cutSelection`/`duplicateActiveLayer`/`layerViaCopy` with a `pixelClipboard`; bridge `copy`/`copyMerged`/`paste`/`cut`/`duplicateLayer`/`layerViaCopy`. Floating-selection drag presentation remains UI. |
| `SelectionEdits.swift` | `Document/SelectionEditsLinux.swift` | `fillSelection(fore/background)` and `clearSelectedPixels` rasterized inside the selection's placed bounds; bridge `fillForeground`/`fillBackground`/`clearSelection`. |
| `ShapeTool.swift` | `Document/ShapeToolLinux.swift` | `addShape(kind:rect:color:cornerRadius:)` rasterizes rectangle/ellipse (rounded corners, canonical pixels) as a new layer; bridge `addShape`. |
| `EditorSession.swift`/`LayerTransform.swift` transform editing | `Document/TransformEditLinux.swift` | `beginTransform` (preflight + undo snapshot)/`previewTransform` (history-suppressed)/`commitTransform` (one-step undo)/`cancelTransform`, `isMaskSelected` switches the target to the layer mask, mask-alone and group-member cases; `TransformEditTests`. Distortion is ported: `beginDistort`/`previewCorners` (twisted or collapsed shapes refused)/`commitDistort` (one undo step, layers + linked/placed masks warped with the carried placement), pinned by the 12 `DistortWarp` raster tests in `CropWandDistortTests`. Floating-selection transforms are ported (see `FloatingSelection.swift` row): begin/commit/cancel, region-relative lift with the selection clip's soft edge multiplier, merge-into-source with layer growth, and the Option-drag duplicate copy, all one undo step, pinned by `SelectionTransformTests`. The interactive preview cache remains (raster milestone). |
| `LayerAppearance.swift` | `Document/LayerAppearance.swift` | `setLayerOpacity`/`setLayerBlendMode`/`cycleBlendMode` with one edit+undo; bridge `setSelectedOpacity`/`cycleBlendMode`. |
| `LayerMask.swift` add/remove | `Document/LayerMaskOperations.swift` | `addLayerMask(revealing:)` (solid reveal/hide) and removal with mask-selected state; bridge `addRevealMask`/`addHideMask`/`setMaskSelected`. Placed/linked mask rendering is covered by the mask-raster tier. |
| `LayerGroups.swift` interactive methods | `Document/LayerGroupsInteractive.swift` | `toggleGroupExpansion`, `placeLayer(_:in:above:atBottom:)`, `moveActiveLayerOutOfGroup` — previously deferred to the Qt tier, now session-level with `collapsedGroupIDs`; bridge `placeLayer`/`toggleGroupExpansion`/`moveActiveLayerOutOfGroup`. Drag/drop presentation remains UI. |
| `ProjectWorkspace.swift` | `Document/ProjectWorkspace.swift` | `ProjectTab` identity (url, manifest, title) + `ProjectWorkspace` tab/selection state with `canSwitch` gating; `ProjectWorkspaceTests`. Host window/tab ownership remains UI. |
| `MetalBrushCoverage.swift` stroke path | `Rendering/BrushCenterline.swift`, `Rendering/BrushCoverage.swift`, `Rendering/NativeBrushCoverage.swift`, `backends/brush/{BrushCoverageCPU,VulkanBrushCoverage}.cpp` | Shared centerline (adaptive chord subdivision, 0.2px tolerance) + coverage request/result split; CPU and Vulkan compute backends behind one ABI. `VulkanBrushCoverageTests` matches Vulkan against CPU for hard/soft/transformed/clipped/odd tiles on a real llvmpipe device and verifies execute-failure falls back to CPU with unchanged input (7 tests). The `continuous_brush.comp` shader is excluded from the SwiftPM build; the release Flatpak build generates it via `scripts/build-brush-shader.py`. |

New `EditorBridge` commands at this checkpoint: `resizeImage`, `cropCanvas`,
`setSelectedOpacity`, `cycleBlendMode`, `flipLayer`, `flipCanvas`, `addShape`,
`transformBegin`/`transformPreview`/`transformCommit`/`transformCancel`,
`setMaskSelected`, `copy`/`copyMerged`/`paste`/`cut`/`duplicateLayer`/
`layerViaCopy`, `fillForeground`/`fillBackground`/`clearSelection`,
`addRevealMask`/`addHideMask`. `PortedOperationsTests` drives
appearance+shape+flip+merged-copy+paste and a warp stroke completing to a valid
document.

These checks do not establish Skia/OpenCV parity, macOS reference equivalence, or
completion of the full file map.

## Application

| Source | Lines* | Direct imports | Disposition | Linux responsibility |
|---|---:|---|---|---|
| `Compositor/Compositor-Bridging-Header.h` | 9 | C/header | Apple replacement / adaptation | Replace Linux build boundary with module maps and narrow C ABI; keep Xcode header |
| `Compositor/CompositorApp.swift` | 271 | SwiftUI, Sparkle | Apple replacement / adaptation | Rewrite entry point and actions in Qt; retain macOS app |
| `Compositor/ContentView.swift` | 387 | SwiftUI, UniformTypeIdentifiers | Apple replacement / adaptation | Rewrite workspace layout in Qt Widgets |
| `Compositor/Document/AdjustmentEditing.swift` | 111 | AppKit | Keep logic; replace Apple operations | Ported onto `EditorSession` (add/preview/commit/cancel + `adjustmentEditingID` gating) — see checkpoint |
| `Compositor/Document/BlurTool.swift` | 42 | AppKit, CoreImage | Keep logic; replace Apple operations | Ported (`Document/BlurTool.swift`): premultiplied invert, mask invert, selection-limited blur, rotated reveal-mask regression — pinned by `FilterExecutionTests`. Input/tool wiring stays on the Qt tier |
| `Compositor/Document/BrushStroke.swift` | 900 | AppKit | Apple replacement / adaptation | Keep sampling/smoothing and tile algorithm; replace CGContext/CGImage storage and paint operations. Centerline/coverage split in the brush batch (`BrushCenterline`/`BrushCoverage`/`NativeBrushCoverage`) — see checkpoint |
| `Compositor/Document/CanvasSize.swift` | 83 | Foundation, CoreGraphics | Keep logic; replace Apple operations | Ported onto `EditorSession` + `Document/CanvasSize.swift`/`CanvasResizer.swift`: all nine anchors, odd-size expansion/shrink, transparent/black/white/custom extension colors, undo snapshots, allocation limits — see checkpoint; unit/relative UI lives in the Qt sizing dialog |
| `Compositor/Document/CloneStamp.swift` | 50 | AppKit | Keep logic; replace Apple operations | Ported (`Document/CloneStamp.swift`): stroke offset alignment and source sample-point math, pinned by `CloneStampTests` (8 tests); pressing the stamp into the stroke stays in the brush path |
| `Compositor/Document/ColorPalette.swift` | 217 | AppKit, Observation | Keep logic; replace Apple operations | Ported (`Document/ColorPalette.swift`): palette/`AdjustmentColor` values, HSB conversion, hex round trip, quantization, engine colors; pinned by `ColorPickerAndAutoTests`. The SwiftUI picker sheet remains UI |
| `Compositor/Document/ContentFill.swift` | 28 | AppKit | Keep logic; replace Apple operations | Ported: the `ContentFill.c` kernel is kept/compiled (see its rows below), the Swift selection-gated entry runs in `PixelFilter` (content fill needs a selection, masked-area behavior), pinned by `FilterExecutionTests`; interactive inpainting results remain backend-parity work |
| `Compositor/Document/Crop.swift` | 200 | Foundation, CoreGraphics | Keep logic; replace Apple operations | Canvas crop (`cropCanvas(to:)`) + flip (`flipCanvas`) ported onto `EditorSession` — see checkpoint; selection-rect/margin UI remains |
| `Compositor/Document/Curves.swift` | 43 | AppKit | Keep logic; replace Apple operations | Ported (`Document/Curves.swift` + `Levels.swift` channel math): spline evaluation, monotonic-endpoint validation, per-channel curve application; pinned by `SettingsTests` (`testCurvesValueIdentityCurve`, `testCurvesIsValidRequiresMonotonicEndpoints`, channel map tests). Curve UI remains |
| `Compositor/Document/Distort.swift` | 292 | AppKit, CoreImage | Ported | `DistortWarp` (`Document/Distort.swift`): corners/homography/imageCorners/carried/isUsable plus `warp`/`warpTrimmed`/`warpMask` on `RasterImage` — perspective resampling with CG-style pixel coverage at the quad edges, mask background fill, trim-to-visible; `commitDistort` warps layer and mask in one undo step. `mapPath` and the interactive preview cache remain Apple-replaced in TODOs. |
| `Compositor/Document/DocumentHistory.swift` | 120 | Foundation, CoreGraphics, Observation | Apple replacement / adaptation | Keep immutable history semantics; replace snapshot image/geometry dependencies |
| `Compositor/Document/EditorSession+Brush.swift` | 202 | AppKit | Apple replacement / adaptation | Keep stroke orchestration; port image/mask handoff |
| `Compositor/Document/EditorSession+Projects.swift` | 56 | Foundation | Apple replacement / adaptation | Keep manifest mapping; replace image asset adapters |
| `Compositor/Document/EditorSession.swift` | 690 | SwiftUI | Apple replacement / adaptation | Extract Swift commands/state; remove SwiftUI and platform image types. Portable session now carries crop/flip/warp/adjustment/transform-editing/selection state — see checkpoints |
| `Compositor/Document/Filters.swift` | 474 | AppKit, CoreImage, Observation | Apple replacement / adaptation | Keep settings/validation/preview transactions; replace named CoreImage filters with Skia/OpenCV/custom kernels |
| `Compositor/Document/FloatingSelection.swift` | 160 | AppKit | Keep logic; replace Apple operations | Ported onto `EditorSession` (`Document/SelectionTransform.swift`): `TransformEdit.floating`, `beginSelectionTransform`/`previewTransform`/`commitTransform`/`cancelTransform`, `renderSelectedPixels` (region-relative lift; the clip's soft edges multiply the premultiplied alpha exactly as a CG clip does), `FloatingMerge.merge` (source drawn axis-aligned, floating pixels via their placed transform, layer grid grows past its edge, mask grow branch), and `beginDuplicateTransform` (Option-drag copy in one undo step). Floating-selection drag presentation remains UI |
| `Compositor/Document/Gradient.swift` | 110 | AppKit | Keep logic; replace Apple operations | Partially ported (`Document/Gradient.swift`): `GradientStyle`/`GradientShape`/`GradientSettings` values pinned by `HistoryAndOpsTests` (`testGradientSettingsDefaults`). The gradient edit's raster drawing (a `BrushStroke` on macOS) and its tool/UI remain on the Qt tier |
| `Compositor/Document/GuidedMatte.swift` | 119 | CoreGraphics, Foundation | Apple replacement / adaptation | Partially ported (`Document/GuidedMatte.swift`): the refinement settings/parameters. The guided-mat refinement raster walk (CoreGraphics buffers on macOS) still needs a portable kernel and a pixel check — no Swift/host test pins it yet |
| `Compositor/Document/HueSaturation.swift` | 575 | AppKit, CoreImage | Keep logic; replace Apple operations | Ported (`Document/HueSaturation.swift`): `ColorRange` hue bands, range/weight math, settings normalization, HSL round trip, `HueSaturationFilter.adjust`/`hueResponse`/`shiftedHue` (the CoreImage `CIColorCube` replacement) — pinned by `SettingsTests` (band weights, identity, colorize, cube dimension, shifted-hue) and `AdjustmentEditingTests` preview gating. HueSampleMode help strings remain UI |
| `Compositor/Document/ImageAdjustments.swift` | 135 | AppKit | Keep logic; replace Apple operations | Ported (`Document/ImageAdjustments.swift`): `AdjustmentClamp`, `AdjustmentColor`, and the exposure/gradient-map/grain normalized settings — pinned by `SettingsTests`; their kernels execute in `PixelFilter`, pinned by `FilterExecutionTests` (`testExposureApplyStopsToWhiteAndKeepsAlpha`, `testGradientMapEndsApplyInOrder`, `testGrainIsDeterministicPerSeedAndKeepsAlpha`) |
| `Compositor/Document/LayerAdjustment.swift` | 113 | AppKit, CoreImage | Keep logic; replace Apple operations | Ported: adjustment-layer add/preview/commit/cancel through `EditorSession.adjustmentEditingID` gating (`AdjustmentEditing.swift` row), pinned by `AdjustmentEditingTests` (9 tests); preview shows the adjustment slot so cancelling restores the pre-edit document. The adjustment slot and picker UI remain on the Qt tier |
| `Compositor/Document/LayerAppearance.swift` | 89 | Foundation, CoreGraphics | Keep logic; replace Apple operations | Ported onto `EditorSession` (`setLayerOpacity`/`setLayerBlendMode`/`cycleBlendMode`, one edit+undo) — see checkpoint |
| `Compositor/Document/LayerFlip.swift` | 80 | AppKit | Keep logic; replace Apple operations | Ported onto `EditorSession` (`flipLayers`/`flipCanvas`, group-aware) — see checkpoint |
| `Compositor/Document/LayerGroups.swift` | 191 | Foundation | Keep/adapt | Keep hierarchy validation/traversal (`LayerHierarchy`) and grouping/selection logic — ported onto the Linux `EditorSession`/`CanvasDocument`; interactive methods (`toggleGroupExpansion`/`placeLayer`/`moveActiveLayerOutOfGroup`) now also ported (LayerGroupsInteractive.swift); drag/drop presentation remains Qt UI |
| `Compositor/Document/LayerMask.swift` | 420 | Foundation, CoreGraphics | Keep logic; replace Apple operations | Add/remove mask (`addLayerMask(revealing:)`) ported; mask raster/tone/placement covered by MaskRaster + placed-resampling — see checkpoint; interactive mask-draw remains |
| `Compositor/Document/LayerMerge.swift` | 73 | AppKit | Keep logic; replace Apple operations | Ported (`Document/LayerMerge.swift`): merge plans — merge down (leaf/group blockers), merge layers incl. multi-select descendants — pinned by `LayerMergeTests` (11 tests); merging raster itself runs in the documented reduce/merge path |
| `Compositor/Document/LayerTransform.swift` | 236 | CoreGraphics, Foundation | Apple replacement / adaptation | Keep transformation math and serialization; transform-edit state machine (`beginTransform`/`previewTransform`/`commitTransform`/`cancelTransform`, mask-alone + group) ported in TransformEditLinux.swift — see checkpoint |
| `Compositor/Document/Levels.swift` | 229 | AppKit, Observation | Keep logic; replace Apple operations | Ported (`Document/Levels.swift`): per-channel level ranges, apply/gamma normalization, histogram-display scaling — pinned by `SettingsTests` (`testLevelRangeIdentityApplyIsLinear`, `testLevelsSettingsIsIdentity`, channel index, clamped normalization); auto-levels (contrast/color/neutral) pinned by `ColorPickerAndAutoTests` (`testLevelsAuto*`) |
| `Compositor/Document/LevelsAutomatic.swift` | 85 | AppKit | Keep logic; replace Apple operations | Ported (`Document/LevelsAutomatic.swift`): auto-contrast (shared range), auto-color (per-channel ranges), neutral gamma, and the black/white/gray point samplers — pinned by `ColorPickerAndAutoTests` (`testLevelsAutoContrastSetsSharedRange`, `testLevelsAutoColorSetsPerChannelRanges`, `testLevelsAutoNeutralAppliesGamma`, `testLevelsSampling*`) |
| `Compositor/Document/LiveLayerMask.swift` | 231 | AppKit | Keep logic; replace Apple operations | Ported (`Document/LiveLayerMask.swift`): `LiveMaskGraph.validate` (cycle/duplicate/missing clipping checks), `adoptClipping`/`releaseDetachedClipping` for folder/live-mask structure — pinned by `HierarchyMaskSelectionTests`. Renderer integration of live masks remains (raster milestone) |
| `Compositor/Document/MagicWand.swift` | 139 | AppKit | Keep logic; replace Apple operations | Ported (`Document/MagicWand.swift`): `WandSampleSize`, `WandSettings`, `MagicWand.Failure`, plus `MagicWand.select` (Swift port of the `wand_mask` matching kernel + `MaskTracing.outline` tracing) and `EditorSession.magicWand`/`wandSample`/`applySelection` (replace/add/subtract via coverage combine) — pinned by `MagicWandTests` (10 tests) and exercised through the `wand_mask` CTest pixel check |
| `Compositor/Document/MaskTracing.swift` | 93 | AppKit | Keep logic; replace Apple operations | Ported (`Document/MaskTracing.swift`): contour outline (empty/single-pixel/full-grid/hole/dropped vertices/alpha offset) plus `darkOutline`/`opaqueOutline` masks — pinned by `MaskTracingTests` (9 tests) |
| `Compositor/Document/PixelAdjust.swift` | 66 | AppKit, CoreImage | Apple replacement / adaptation | Replace CoreImage rendering/context with named imaging operations |
| `Compositor/Document/PixelInvert.swift` | 47 | AppKit, Accelerate, CoreImage | Apple replacement / adaptation | Keep numerical intent; replace Accelerate/CoreImage image operations |
| `Compositor/Document/ProjectWorkspace.swift` | 211 | AppKit, Observation, UniformTypeIdentifiers | Apple replacement / adaptation | Ported (`ProjectTab` identity/manifest/title + tab/selection state) — see checkpoint; dirty-state and window ownership remain Qt UI |
| `Compositor/Document/Selection.swift` | 311 | AppKit | Keep logic; replace Apple operations | Ported (`Document/Selection.swift`): `PortablePath` (rect/ellipse/polygon outlines, transforms), `DocumentSelection`/`SelectionClip` (clip/canvas/soft-edge coverage), `LassoKind`, `SelectionMode`, `SelectionBackground` — pinned by `GroupingSelectionTests`, `SelectionTransformTests`, and the selection-region tests |
| `Compositor/Document/SelectionClipboard.swift` | 205 | AppKit | Keep logic; replace Apple operations | Ported onto `EditorSession` (`copySelection`/`copyMergedSelection`/`paste`/`cutSelection`/`duplicateActiveLayer`/`layerViaCopy`) — see checkpoint; floating-selection drag remains UI |
| `Compositor/Document/SelectionEdits.swift` | 206 | AppKit | Keep logic; replace Apple operations | Ported onto `EditorSession` (`fillSelection`/`clearSelectedPixels`, selection-bounded) — see checkpoint; marching-ants/selection edges remain UI |
| `Compositor/Document/ShapeTool.swift` | 158 | AppKit | Keep logic; replace Apple operations | Ported onto `EditorSession` (`addShape`, rectangle/ellipse + rounded corners) — see checkpoint; interactive shape drag/resize remains UI |
| `Compositor/Document/SmudgeLiquify.swift` | 211 | AppKit | Keep logic; replace Apple operations | Warp/smudge stroke ported (`beginWarp`/`continueWarp`/`finishWarp`) — see checkpoint; liquify-mode fidelity remains backend parity work |
| `Compositor/Document/SubjectRemoval.swift` | 111 | Vision, CoreImage | Apple replacement / adaptation | Replace Vision inference with validated offline segmentation model/runtime; preserve refinement workflow |
| `Compositor/IO/CanvasResizer.swift` | 73 | Foundation, CoreGraphics | Apple replacement / adaptation | Keep placement semantics; replace raster construction |
| `Compositor/IO/CompositorApplicationDelegate.swift` | 44 | AppKit, Sparkle | Apple replacement / adaptation | Keep macOS-only; Qt entry and Flatpak updates replace Linux responsibilities |
| `Compositor/IO/ImageExporter.swift` | 147 | Foundation, CoreGraphics, ImageIO, UniformTypeIdentifiers | Apple replacement / adaptation | Replace ImageIO encoder; keep flattened export and resolution behavior |
| `Compositor/IO/ImageFileDrop.swift` | 56 | SwiftUI, UniformTypeIdentifiers | Apple replacement / adaptation | Rewrite with Qt MIME/drop events and scoped document access |
| `Compositor/IO/ImageImporter.swift` | 64 | Foundation, CoreGraphics, CoreImage, ImageIO, UniformTypeIdentifiers | Apple replacement / adaptation | Replace Apple decoding/color conversion; bounded codec adapter to canonical pixels |
| `Compositor/IO/ImageResizer.swift` | 118 | Foundation, CoreGraphics | Apple replacement / adaptation | Keep sizing semantics; replace resampling backend |
| `Compositor/IO/ProjectController.swift` | 300 | AppKit, UniformTypeIdentifiers, SwiftUI | Apple replacement / adaptation | Rewrite dialogs, close/save coordination and open-file integration through Qt/portals |
| `Compositor/IO/ProjectStore.swift` | 226 | Foundation, CoreGraphics, ImageIO, UniformTypeIdentifiers | Apple replacement / adaptation | Keep Codable schema and validation; replace PNG and coordinated directory persistence |
| `Compositor/Rendering/AdjustPixels.c` | 97 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/AdjustPixels.h` | 20 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/AdjustmentSurface.swift` | 18 | CoreGraphics | Apple replacement / adaptation | Affected-region semantics: covered by `DocumentRenderer.adjust` + `AdjustmentTests.testAdjustmentChangesOnlyMaskedRegionAndNeverAlpha` (mask-bounded, coverage-preserving) — see checkpoint |
| `Compositor/Rendering/BrushCursorOverlay.swift` | 96 | AppKit | Apple replacement / adaptation | Rewrite using Qt cursor/overlay painting |
| `Compositor/Rendering/BrushPixels.c` | 51 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/BrushPixels.h` | 11 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/CanvasViewport.swift` | 73 | Foundation, CoreGraphics | Apple replacement / adaptation | Keep geometry; remove CoreGraphics import/use portable value types |
| `Compositor/Rendering/ContentFill.c` | 94 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/ContentFill.h` | 5 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/DownsampleCache.swift` | 113 | Accelerate, CoreGraphics, Foundation | Apple replacement / adaptation | Sharp-halving cache is a CGContext/Skia display-tier concern; Linux `DocumentRenderer` resamples at the draw itself, so the cache policy folds into the Skia integration tier |
| `Compositor/Rendering/EditorCanvas.swift` | 1815 | AppKit, SwiftUI | Apple replacement / adaptation | Rewrite AppKit canvas/event bridge with Qt; preserve interaction behavior via journey tests |
| `Compositor/Rendering/HealPixels.c` | 260 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/HealPixels.h` | 20 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/LayerRenderer.swift` | 174 | CoreGraphics | Apple replacement / adaptation | Replace CoreGraphics compositing with Skia and exact custom blend kernels |
| `Compositor/Rendering/LensPixels.c` | 38 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/LensPixels.h` | 13 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/LevelsPixels.c` | 29 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/LevelsPixels.h` | 5 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/LiveMaskRenderer.swift` | 146 | Foundation, CoreGraphics, CoreImage | Apple replacement / adaptation | Mask graph + per-render cache semantics: covered by `DocumentRenderer` (mask/folder coverage cache, adjustment region clip) — see checkpoint |
| `Compositor/Rendering/MetalBrushCoverage.swift` | 163 | AppKit, Metal | Metal→Vulkan | Metal→Vulkan Compute on Linux; retain Metal on macOS and implement portable CPU fallback. Vulkan compute + CPU fallback + parity tests now in `backends/brush` — see checkpoint; macOS Metal path and shader parity remain |
| `Compositor/Rendering/NoisePixels.c` | 42 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/NoisePixels.h` | 13 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/RasterSnapshot.swift` | 177 | AppKit | Apple replacement / adaptation | Keep immutable tile replacement/lazy materialization; implement portable buffers |
| `Compositor/Rendering/SampleRingOverlay.swift` | 30 | AppKit | Apple replacement / adaptation | Rewrite using Qt overlay painting |
| `Compositor/Rendering/SeparableBlend.swift` | 43 | CoreGraphics, CoreImage | Apple replacement / adaptation | Keep blend formulas; replace CoreImage/CoreGraphics integration |
| `Compositor/Rendering/TiledLayerRenderer.swift` | 420 | CoreGraphics, Foundation | Apple replacement / adaptation | Tile selection/alignment + piece cache are CGContext/Skia display-tier; portable geometry lives in `RasterSnapshot` and moves with the Skia integration tier |
| `Compositor/Rendering/TransformOverlay.swift` | 328 | AppKit | Apple replacement / adaptation | Geometry ported (`TransformOverlayGeometry`: handles, rotation, distortion, `hit`) + pinned tests; Qt handles/guides/`resizeCursor` NSView paint remains |
| `Compositor/Rendering/WandPixels.c` | 175 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/Rendering/WandPixels.h` | 22 | C/header | Keep | Reuse C kernel/interface; run cross-platform pixel tests and sanitizer checks |
| `Compositor/UI/BlendModePicker.swift` | 58 | SwiftUI, AppKit | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/BrushControls.swift` | 121 | SwiftUI, AppKit | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/CanvasSizeSheet.swift` | 114 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/CanvasThumbnail.swift` | 80 | AppKit | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/ColorPaletteControls.swift` | 80 | SwiftUI, AppKit | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/ColorPickerSheet.swift` | 186 | SwiftUI, AppKit | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/CropControls.swift` | 25 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/CurvesControls.swift` | 70 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/FilterSheet.swift` | 164 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/FloatingPanel.swift` | 102 | AppKit, SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/GradientControls.swift` | 104 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/HueSaturationSheet.swift` | 194 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/ImageSizeSheet.swift` | 121 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/JPEGExportSheet.swift` | 88 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/LassoControls.swift` | 129 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/LayerAppearanceControls.swift` | 55 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/LayerMaskMenu.swift` | 15 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/LayersPanel.swift` | 77 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/LevelsSheet.swift` | 145 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/NativeLayerList.swift` | 897 | AppKit, SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/NavigationToolHeader.swift` | 65 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/NewCanvasSheet.swift` | 88 | SwiftUI, AppKit, ImageIO | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/ProjectTabs.swift` | 179 | SwiftUI, UniformTypeIdentifiers, AppKit, Combine | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/ProjectWindowBridge.swift` | 63 | AppKit, SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/ShapeControls.swift` | 50 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/SliderSnap.swift` | 43 | AppKit, ObjectiveC | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/ToolHeaderStyle.swift` | 27 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |
| `Compositor/UI/TransformInspector.swift` | 113 | SwiftUI | Rewrite Linux UI | Qt Widgets counterpart; preserve controls, shortcuts, cancel/commit and accessibility; keep macOS view |

## IO / codec mapping (ImageIO → Qt)

The IO-tier rows below (`ImageExporter`, `ImageImporter`, `ProjectStore`, `ImageFileDrop`, `ProjectController`) replace Apple `ImageIO`/`UniformTypeIdentifiers`/`FileCoordinator`. Qt6 ships the codecs via the KDE Platform runtime (no vendored codec libs for PNG/JPEG). The mapping:

| Apple ImageIO | Qt / Freedesktop alternative |
|---|---|
| `CGImageSource` / `CGImageSourceCreateWithURL` | `QImageReader(QString path)` |
| `CGImageSourceCreateWithData` | `QBuffer` + `QImageReader(QIODevice*)` |
| `CGImageSourceGetType` | `QImageReader::format()` / `imageFormat()` |
| `CGImageSourceCopyTypeIdentifiers()` | `QImageReader::supportedImageFormats()` / `supportedMimeTypes()` |
| `CGImageSourceGetCount()` / `CreateImageAtIndex()` | `imageCount()` / `jumpToImage(index)` → `read()` |
| `CGImageSourceCreateThumbnailAtIndex()` | `setScaledSize()` → `read()` |
| `CGImageSourceCopyPropertiesAtIndex()` | `QImageReader` properties + `text()`; `libexif`/Exiv2 for full EXIF/IPTC/XMP |
| `CGImageSourceCreateIncremental()` / `UpdateData()` | `GdkPixbufLoader` / `gdk_pixbuf_loader_write()` |
| `CGImageDestination` / `CreateWithURL` | `QImageWriter(QString path)` |
| `CGImageDestinationCreateWithData` | `QBuffer` + `QImageWriter` |
| `CGImageDestinationAddImage()` / `Finalize()` | `QImageWriter::write()` |
| `kCGImageDestinationLossyCompressionQuality` | `QImageWriter::setQuality()` |
| EXIF orientation | `QImageReader::transformation()` / auto-transform |
| ICC / color profile | `QColorSpace`; lower-level `lcms2` |
| custom codecs | `QImageIOHandler` + `QImageIOPlugin` |
| `UTType` (UniformTypeIdentifiers) | `QMimeDatabase` / `QMimeType` |
| `NSFileCoordinator` | Flatpak portals (`xdg-desktop-portal` OpenFile/SaveFile) via Qt |

## Tests

| Source | Lines* | Direct imports | Disposition | Linux responsibility |
|---|---:|---|---|---|
| `CompositorTests/AdjustmentLayerTests.swift` | 215 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/BlendShortcutTests.swift` | 43 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/BrushIntersectionTests.swift` | 108 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/BrushPerformanceTests.swift` | 61 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/BrushTests.swift` | 457 | AppKit, SwiftUI, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/CanvasEntryTests.swift` | 52 | AppKit, Testing, UniformTypeIdentifiers | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/CanvasSizeTests.swift` | 108 | AppKit, Testing, UniformTypeIdentifiers | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/CanvasThumbnailTests.swift` | 67 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/CloneStampTests.swift` | 79 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/ColorPickerTests.swift` | 87 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/CompositorTests.swift` | 84 | Testing, CoreGraphics | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/CropTests.swift` | 167 | AppKit, Testing, UniformTypeIdentifiers | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/CursorTests.swift` | 200 | AppKit, SwiftUI, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/DistortTests.swift` | 89 | AppKit, Testing | Keep assertions; port fixtures | Ported to Swift Testing: the 12 `testDistortWarp*` cases in `CropWandDistortTests` cover corners/homography/imageCorners/isUsable plus raster warp identity, quadrant resampling, mask background, trim, and one-undo-step commit; Qt Test adds interaction cases |
| `CompositorTests/DownsampleTests.swift` | 82 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/ExportTests.swift` | 77 | AppKit, ImageIO, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/FilterTests.swift` | 118 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/FloatingPanelTests.swift` | 78 | AppKit, SwiftUI, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/GradientTests.swift` | 154 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/GroupTests.swift` | 110 | AppKit, Testing, UniformTypeIdentifiers | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/GroupingSelectionTests.swift` | 71 | Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/HistoryTests.swift` | 160 | AppKit, UniformTypeIdentifiers, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/HueSaturationTests.swift` | 274 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/ImageAdjustmentTests.swift` | 192 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/ImageImportTests.swift` | 144 | Foundation, CoreGraphics, ImageIO, UniformTypeIdentifiers, AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/ImageSizeTests.swift` | 83 | AppKit, ImageIO, UniformTypeIdentifiers, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/JPEGExportTests.swift` | 64 | AppKit, ImageIO, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/LayerAppearanceTests.swift` | 134 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/LayerMaskTests.swift` | 305 | AppKit, ImageIO, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/LayerTests.swift` | 244 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/LevelsTests.swift` | 200 | AppKit, SwiftUI, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/LiveMaskTests.swift` | 131 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/MagicWandTests.swift` | 148 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/MaskTransformTests.swift` | 135 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/ProjectTests.swift` | 182 | AppKit, UniformTypeIdentifiers, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/ProjectWorkspaceTests.swift` | 106 | AppKit, UniformTypeIdentifiers, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/RasterSnapshotTests.swift` | 136 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/SelectionClipboardTests.swift` | 218 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/SelectionEditTests.swift` | 411 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/SelectionTests.swift` | 468 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/ShapeToolTests.swift` | 106 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/SliderSnapTests.swift` | 68 | AppKit, Combine, SwiftUI, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/SmartEditTests.swift` | 82 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/SpotHealingTests.swift` | 62 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/TiledLayerTests.swift` | 297 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/TransformPressTests.swift` | 60 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorTests/TransformTests.swift` | 305 | AppKit, Testing | Keep assertions; port fixtures | Swift Testing for core; Qt Test for interactions; replace Apple image/window fixtures |
| `CompositorUITests/CompositorUITests.swift` | 54 | XCTest | Rewrite harness | Qt UI automation; preserve launch/journey intentions |
| `CompositorUITests/CompositorUITestsLaunchTests.swift` | 36 | XCTest | Rewrite harness | Qt UI automation; preserve launch/journey intentions |

*Line counts use newline-delimited segments, including the trailing empty segment where present. All 158 tracked Swift/C/header files are listed: 109 application files and 49 test files. Application source is approximately 17,751 such lines. Counts are scale indicators, not rewrite estimates.

## Build, distribution and resources

| Existing artifact | Disposition |
|---|---|
| Compositor.xcodeproj and Config/Info.plist/Compositor.entitlements | Keep macOS build; add independent Linux CMake + Swift package and Flatpak manifest |
| Assets.xcassets PNG icons | Reuse source images; install Linux icon sizes and desktop/AppStream metadata |
| scripts/release.sh, scripts/publish.sh, scripts/ExportOptions.plist, scripts/dmg/, appcast.xml | Keep macOS release route; add Linux bundle build and artifact validation, not Sparkle on Linux |
| docs/project-format.md | Update to actual v7 plus mask-placement and shape fields; derive schema from code and round-trip fixtures |
| docs/brush-performance.md | Keep macOS baseline history; append Linux hardware-specific CPU/Vulkan measurements |
| docs/references/ | Use existing adjustment/canvas-size visuals as behavioral references |
| README.md, LICENSE, .gitignore | Add Linux build/run instructions, dependency notices and isolated build outputs; preserve MIT project license |

## Effort shape

These are preliminary engineering ranges, not measured delivery promises. Human estimates assume one experienced graphics/desktop engineer; assisted ranges assume sustained agent work plus that engineer's review and access to macOS reference execution. Parallel work overlaps; totals are not sums.

| Workstream | Human effort | Agent-assisted active engineering | Main uncertainty |
|---|---|---|---|
| First packaged open/paint/undo/save/reopen/export journey | 2–4 weeks | 4–10 days | Swift/Qt event loop, C ABI and directory permissions. **Composition-root constraint:** the entry point must be Swift (`@main`) — a C++ Qt `main` cannot bootstrap the Swift runtime + Foundation on the Freedesktop Swift 6.3 SDK (no `swift_initSwiftRuntime`; Foundation `JSONDecoder` traps from a non-Swift main). The create/paint/undo/redo leg is verified under `swift test` (SessionJourneyTests), and the save/reopen leg is verified as a render→import_rgba round-trip (byte-identical); the Qt-driven host journey, PNG/JPEG export and project-file save still need the Swift-`@main` root + Qt codecs. |
| Portable model/history/schema and raster contracts | 2–5 weeks | 5–12 days | Indirect Apple dependencies and isolation semantics |
| Qt shell and complete interaction parity | 3–6 weeks | 1–3 weeks | Canvas gestures, shortcut conflicts, layers drag/drop |
| Skia compositing, masks, color, filters, codecs | 5–10 weeks | 2–5 weeks | Pixel parity, resampling and codec metadata |
| Vulkan brush with portable CPU fallback | 1–3 weeks | 3–8 days | Synchronization, opacity integration and device loss |
| Offline background removal | 1–3 weeks | 3–10 days | Model redistribution, inference and quality acceptance |
| Cross-platform fixtures, QA, performance and packaging | 3–6 weeks | 1–3 weeks | macOS access, diverse drivers and large documents |

Overall order of magnitude: 3–6 engineer-months for a dependable full port, or roughly 5–10 calendar weeks of closely supervised assisted work with continuous verification. Re-estimate after the first working journey. Vulkan is not the dominant workstream. No runtime integration, pixel equivalence or release timing has been demonstrated yet.
