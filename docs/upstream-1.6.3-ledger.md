# Upstream 1.6.3 catch-up ledger

Branch: `GNU_Linux`. Previous tip: `0b90cc8` (1.6.2). New tip: `7f703b4` (1.6.3), project format 21.

Seven upstream commits are integrated. Protected upstream sources and tests remain unchanged.

| Theme | Linux integration |
| --- | --- |
| Move tool distances | Upstream LayerDistances and EditorCanvas; regenerated EditorSession, CompositorApp and TransformOverlay; Compat NSColor.systemPink |
| Drag-size labels | Upstream ShapeTool; regenerated ContentView and TransformOverlay |
| Magic Wand Deselect invalidation | Regenerated EditorSession inherits quick-operation observation |
| Volumetric Light color sampling | Upstream EditorCanvas prioritizes the open color picker |
| Sparkle update checkbox | Platform-specific UpdateDriver remains excluded; Linux updates through Flatpak |
| Version | host/AppVersion.h synchronized to 1.6.3 |

<!-- ledger-rows:begin -->
Code commits: **5** of 7 (rule: changes a Compositor Swift/C/header file). Docs/meta: 2; test-only: 0.

| # | Upstream | Subject | Files (consumption) | Evidence scope | Linux artifact | Evidence |
|---|---|---|---|---|---|---|
| 1 | `9d70c0d` | The update alert's "Automatically download and install updates" checkbox can be checked: an empty view NSAlert keeps the accessory's full height sat over it, taking its clicks, and is hidden | `UpdateDriver.swift` (excluded (adapter)) | not applicable | Excluded UpdateDriver; Flatpak updater retained | n/a (Sparkle-only update alert) |
| 2 | `8fb163e` | View › Show › Distances, off by default: with the Move tool, pixel gaps from a dragged layer to the canvas edges and the nearest layers level with it, and with Command held, from the selected layers to the layer under the pointer or to the canvas (#332) | `CompositorApp.swift` (generated override)<br>`EditorSession.swift` (generated override)<br>`LayerDistances.swift` (compiled as-is)<br>`EditorCanvas.swift` (compiled as-is)<br>`TransformOverlay.swift` (generated override)<br>`LayerDistancesTests.swift` (test) | test reference; run result required; source/generation only | Tip LayerDistances/EditorCanvas; generated overlays; Compat systemPink | generator checks; test:LayerDistancesTests |
| 3 | `3940d3b` | Deselect (⌘D) works after a Magic Wand click that selects what was already selected: the menu, drawn while the wand worked, read the project as busy, and nothing after told it to look again | `EditorSession.swift` (generated override)<br>`MagicWandTests.swift` (test) | test reference; run result required; source/generation only | Generated EditorSession quick-operation observation | generator checks; test:MagicWandTests |
| 4 | `de6837b` | Sizes beside the pointer as things are dragged out: a Marquee's or shape's width and height, a line's length, and a layer's size as the Move tool resizes it; the status bar shows a shape's or line's too | `ContentView.swift` (generated override)<br>`EditorSession.swift` (generated override)<br>`ShapeTool.swift` (compiled as-is)<br>`EditorCanvas.swift` (compiled as-is)<br>`TransformOverlay.swift` (generated override)<br>`ShapeToolTests.swift` (test) | test reference; run result required; source/generation only | Tip ShapeTool/EditorCanvas; generated ContentView/TransformOverlay | generator checks; test:ShapeToolTests |
| 5 | `5c3489e` | Volumetric Light: with the light's color picker open, a click on the canvas samples its color rather than moving the light (#330) | `EditorCanvas.swift` (compiled as-is) | source/generation only | Tip EditorCanvas color-picker precedence | compiled as-is; interactive sampling not verified |
| — | `9b47497` | Compositor 1.6.3 | none | not applicable | n/a (docs) | n/a (docs) |
| — | `7f703b4` | Publish update feed for Compositor 1.6.3 | none | not applicable | n/a (docs) | n/a (docs) |
<!-- ledger-rows:end -->

## Verification

Results are recorded after the upstream parity gate and unmodified LayerDistancesTests, MagicWandTests and ShapeToolTests complete.
