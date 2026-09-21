# Retiring the forked CompositorCore

`Sources/CompositorCore` is the original hand-edited port. The wrap-don't-fork decision replaces it with upstream's
unmodified `Compositor/{Document,IO,Rendering}` (target `Compositor`, built through the Apple-API shims). The shell talks to
the session through a C command interface (`EditorBridge`); the replacement is `Sources/LinuxBridge/UpstreamEditor.swift`,
an adapter that lives inside the `Compositor` module (via `Sources/UpstreamCore/LinuxBridge`) so it can reach upstream's
internal types without editing them. It holds no editing logic: every command calls an upstream method.

## Strangler status

Differential tests (`Tests/LinuxOverrideTests/BridgeParityTests.swift`) send the same command sequences to the fork's bridge
and to `UpstreamEditor`, then compare layer state (ids compared by index) and rendered pixels (<= 1 level; 2 for brush and
blur). Where the fork was wrong or differs from the Mac app, the divergence is documented in a test of its own.

| Area | Commands | Status |
|---|---|---|
| Document, layers, groups | new, addLayer, addGroup, groupSelectedLayers, selectLayer, deleteLayer, renameLayer, setVisible, setOpacity, setBlendMode, setSelectedOpacity, cycleBlendMode, flipLayer, flipCanvas, undo, redo | matches fork |
| Masks, move, selection | addRevealMask, addHideMask, deleteMask, setMaskEnabled, setMaskLinked, moveLayer, selectRectangle/Ellipse/Lasso, deselect, expand/contractSelection | matches fork |
| Pixel edits, clipboard | fillForeground/Background, clearSelection, invert, copy, copyMerged, paste, duplicateLayer, layerViaCopy | matches fork |
| Brush, wand, blur | brushBegin/Move/End/Cancel (paint, erase, mask), magicWand, filterBegin/Preview/Commit/Cancel | brush/erase/wand match; see divergences |
| Import, state, render | import_rgba, state JSON, composite render | matches fork |
| Not yet mapped (return -7) | resizeCanvas, cropCanvas, resizeImage, addShape, transform*/distort*, warp*, adjustment*, contentFill, removeBackground, healing and clone brushes, invertMask, manifest and layer export/import | to do |

Divergences from the fork (upstream is the target, it is what the Mac app does):
- History: finer undo names ("Hide Layer", "Layer Opacity", "New Blank Layer") and File > New is an undoable step.
- `cut` is copy + clear; the fork cropped the layer to the selection.
- Gaussian blur grows the layer by 3 sigma per side (fork: less).
- A soft mask stroke hides only the stroke (the fork hid about 80% of the image).
- Invalid sizes return -1 (invalid argument) where the fork returned -5.

## Threading (verified)
The Qt shell calls from the process main thread. Synchronous commands run there directly; upstream's async operations are
awaited by pumping the main run loop from that plain callback (`awaitOnMain`, checked with a probe: `assumeIsolated` works
on the main thread and a pumped main-actor task completes). This must not run inside a main-actor job, so tests use
`commandAsync`; render blocks on a semaphore because the exporter is an actor that never needs the main thread.

## Switch-over plan
1. Map the remaining commands above (each with a parity or upstream-only test).
2. Export the same C ABI (`compositor_session_*`) from the `Compositor` module, point `CompositorHostBootstrap` and the C++
   host at it, and run the host smoke modes.
3. Delete `Sources/CompositorCore` and the fork-only tests it carried; keep the journey and Vulkan tests.
