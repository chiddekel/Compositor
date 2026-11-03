# Upstream 1.6.2 catch-up ledger

Branch: `GNU_Linux`. Previous tip: `4bacf5a` (1.6.1). New tip: `0b90cc8` (`upstream/main`, Compositor **1.6.2**, project format **21**).

Range: `git log --no-merges 4bacf5a..0b90cc8` — **11 commits**. Protected trees match tip after merge. Linux gaps stay in `Sources/`, `host/`, generators, and overrides.

## Themes

| Upstream theme | Linux status |
| --- | --- |
| Reduce Noise filter | **Done** — tip `Filters` / `AdjustPixels` nonlocal means (CPU); `MetalNonlocalMeans` compiles, GPU hook falls back when Metal compute cannot run |
| Reduce Noise adjustment layer (format 21) | **Done** — tip `LayerAdjustment` / `GPUReduceNoise`; Overrides `GPUCanvas` / `ProjectStore` / `AdjustmentEditing` / `Filters` regenerated |
| Layers footer menus | **Done** — `Overrides/LayersPanel` (NSSelectorDispatching); Compat `NSMenu.size` |
| Lens Effects keep document-pixel cache | **Inherit** — tip `EditorCanvas` |
| Window fills screen after update | **Done** — tip via generated `ProjectWindowBridge`; Compat `StyleMask.fullScreen` |
| Adjustment panels drop Preview checkbox | **Inherit** — tip Filter/Levels/HSV sheets |

## Commit ledger (`4bacf5a..0b90cc8`)

<!-- ledger-rows:begin -->
Code commits: **9** of 11 (rule: changes a Compositor Swift/C/header file). Docs/meta: 2; test-only: 0.

| # | Upstream | Subject | Files (consumption) | Evidence scope | Linux artifact | Evidence |
|---|---|---|---|---|---|---|
| 1 | `c1c5356` | Reduce Noise: Camera Raw's noise reduction as a filter of its own, beside Sharpen, with Strength, Preserve Details and Color Noise; luminance noise is now smoothed with non-local means, measured against the noise in the picture, so grain goes while edges and texture stay (Camera Raw's Luminance too) | `CompositorApp.swift` (generated override)<br>`Filters.swift` (generated override)<br>`AdjustPixels.c` (compiled as-is)<br>`FilterSheet.swift` (compiled as-is)<br>`ReduceNoiseTests.swift` (test) | test reference; run result required | Tip FilterSheet + AdjustPixels; Compat Accelerate/CoreImage for GPUReduceNoise path | test:ReduceNoiseTests; build:CompositorHostBootstrap |
| 2 | `2c98c1b` | Reduce Noise's non-local means runs on the GPU, about four times faster on a large photo, the C version kept for when Metal can't; Camera Raw's Luminance noise reduction with it | `CameraRawDetailOptics.swift` (compiled as-is)<br>`Filters.swift` (generated override)<br>`AdjustPixels.c` (compiled as-is)<br>`AdjustPixels.h` (compiled as-is)<br>`MetalNonlocalMeans.swift` (compiled as-is) | unverified | Compat Metal (`storageModeShared`, `MTLBuffer.contents`); compute falls through to C | build:CompositorHostBootstrap |
| 3 | `8926ea8` | Reduce Noise as an adjustment layer (project format 21): the canvas smooths what's under it once at the document's pixels, off the main thread, and places that as it pans and zooms | `CompositorApp.swift` (generated override)<br>`AdjustmentEditing.swift` (generated override)<br>`Filters.swift` (generated override)<br>`LayerAdjustment.swift` (compiled as-is)<br>`ProjectStore.swift` (generated override)<br>`EditorCanvas.swift` (compiled as-is)<br>`GPUCanvas.swift` (hand override)<br>`GPUReduceNoise.swift` (compiled as-is)<br>`AdjustmentLayerTests.swift` (test)<br>`FilterLayerTests.swift` (test)<br>`FloatingPanelTests.swift` (test) | test reference; run result required | Compat CIImageProcessor 8-bit `baseAddress` + `vImagePermuteChannels_ARGB8888`; Overrides GPUCanvas `.reduceNoise` | test:FilterLayerTests; build:CompositorHostBootstrap |
| 4 | `4445be9` | Lens Effects layers keep their picture made at the document's pixels as the canvas pans and zooms, as Reduce Noise's do, made off the main thread; a pan benchmark for adjustment layers | `EditorCanvas.swift` (compiled as-is)<br>`AdjustmentPerformanceTests.swift` (test)<br>`GPUCanvasTests.swift` (generated test mirror) | test reference; run result required | Tip EditorCanvas keptExactly | test:AdjustmentPerformanceTests |
| 5 | `b611179` | Layers panel footer: adjustment and filter layers in two menus, as the menu bar has them, the filters' button a ring around a checkered disc; its menus answer anywhere in the plain buttons' hit area; the panel 261–372 pt wide, so the footer always fits; Reduce Noise layers' own icon | `ContentView.swift` (generated override)<br>`LayerAdjustment.swift` (compiled as-is)<br>`LayersPanel.swift` (hand override)<br>`LayersFooterTests.swift` (test) | test reference; run result required | Overrides/LayersPanel; Lucide `circle.dotted.and.circle` | test:LayersFooterTests; build:CompositorHostBootstrap |
| 6 | `21fecb7` | The layers panel's footer menus open just above their icons, rather than over them | `LayersPanel.swift` (hand override) | unverified | Compat `NSMenu.size` | build:CompositorHostBootstrap |
| 7 | `9fa59c3` | The window fills the screen on the first launch after each update, as on the very first launch; within a build it reopens at the size it was left | `ProjectWindowBridge.swift` (generated override) | unverified | Generated ProjectWindowBridge; Compat `StyleMask.fullScreen` | build:CompositorHostBootstrap |
| 8 | `2d44b8d` | Adjustment layer panels have no Preview checkbox, which only put back the settings the layer opened with (a new layer's defaults); the layer's eye shows the picture without it. Levels: Reset at the top, across from Channel, which starts at the histogram's edge | `FilterSheet.swift` (compiled as-is)<br>`HueSaturationSheet.swift` (compiled as-is)<br>`LevelsSheet.swift` (compiled as-is) | unverified | Tip sheets via SwiftUI Qt renderer | build:CompositorHostBootstrap |
| 9 | `19081ff` | Reduce Noise layers draw on the canvas on macOS 26, which refuses a Core Image kernel 8-bit RGBA: the kernel takes BGRA and swaps red and blue around the noise reduction | `GPUReduceNoise.swift` (compiled as-is) | unverified | Compat CIFormat.BGRA8 processor path | build:CompositorHostBootstrap |
| — | `0bc0a8a` | Compositor 1.6.2 | none | not applicable | n/a (docs) | n/a (docs) |
| — | `0b90cc8` | Publish update feed for Compositor 1.6.2 | none | not applicable | n/a (docs) | n/a (docs) |
<!-- ledger-rows:end -->

## Gates

1. `check-upstream-clean.sh` → protected trees match `upstream/main`.
2. `swift build -c release --product CompositorHostBootstrap` green.
3. `host/AppVersion.h` synced to 1.6.2 (61).
