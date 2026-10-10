# Upstream tests not run on Linux

Upstream's `CompositorTests/*.swift` are compiled **unmodified** (target `CompositorUpstreamTests`). A test file may only be
excluded here, with a reason; individual tests are never edited.

| File | Reason |
|---|---|
| `LayerTests.swift` | Drives `NativeLayerList`/`LayerTableView` (`NSTableView` subclass counting delegate calls) |
| `CursorTests.swift` | Builds `LayersPanel` + `LayerTableView` to check cursor routing through the AppKit responder chain |

## Per-test skips (files stay compiled; pass these to `swift test --skip`)

| Test | Reason |
|---|---|
| `everyLayerEditRoundTripsWithSelection` and `historyBlockedDuringImportsAndDialogs` (`HistoryTests`) | Deliberate GNU/Linux behavior: undo stops at the initially created canvas. These upstream tests expect undoing New Canvas to remove the document. Linux coverage is `UpstreamEditorTests.historyStopsAtNewCanvas` and `newCanvasKeepsItsInitialLayerAndUnsavedState`; replacement-canvas and import history tests still run unchanged. |

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
