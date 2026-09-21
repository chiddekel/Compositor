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
