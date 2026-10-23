# 06 — Data models, persistence and architecture

## Data models

GNU_Linux compiles the protected upstream tree byte for byte (report 01: the protected-tree diff is empty). Every model type is therefore upstream's own code, with the same properties, defaults, relationships, `Codable` conformances and validation. This covers `CanvasDocument`, `ImageLayer`, `LayerMask`, `LayerAdjustment`, `LayerEffects`, `LayerTransform`, `DocumentSelection`, `Guides`, `DocumentHistory`, `ProjectManifest` and the Camera Raw settings. The only model-adjacent files compiled from generated copies are the following, all checked against tip by their generators' `--check` in `scripts/check-upstream-clean.sh`:

| File | Change | Effect on data |
|---|---|---|
| `Sources/Overrides/EditorSession.swift` | Color Range gates | none: preview worker gating only |
| `Sources/Overrides/ColorRangeSelection.swift` | serialized preview worker | none: same selection result (upstream `ColorRangeTests` pass) |
| `Sources/Overrides/SmudgeLiquify.swift` | exact radial cache, resumable dabs | none: commit path unchanged (`WarpCommitParityTests`, `WarpTipCacheTests` pass) |

Model parity: **identical by construction**. No data-model divergence was found.

## Persistence and document compatibility

| Concern | Upstream | Linux | Evidence |
|---|---|---|---|
| Format | `.comp` package: `manifest.json` + PNG/EXR assets, `ProjectManifest.current = 14`, `supported = 1...14` (`Compositor/IO/ProjectStore.swift:20-23`) | Same code | protected tree |
| Save | `ProjectStore.save` | `Sources/LinuxBridge/ProjectSaveSnapshot.swift:99` calls `ProjectStore.shared.save` with a frozen snapshot | `ProjectSaveSnapshotTests` pass today |
| Load | `ProjectStore.load` | `Sources/LinuxBridge/SessionABI.swift:732` calls `ProjectStore.shared.load` | `ProjectTests` pass today |
| Validation | in `ProjectStore` | `Sources/LinuxBridge/LinuxProjectValidation.swift`, generated from `ProjectStore.swift` by `scripts/gen-project-validation.py` (`--check` after merges); handles v14 `shape.smoothing` | generator check |
| Package directory replacement | NSFileCoordinator | compat file coordination (`Sources/Compat/FoundationCompat/FoundationCompat.swift:100`): no cross-process coordination service on Linux | `StagedAssetRecoveryTests` pass |
| External changes | `ProjectWatcher` (kqueue/vnode) | compat vnode source on one shared inotify instance | `FileSystemObjectSourceTests`, `ExternalChangeTests` pass |
| Quick Look preview | `QuickLook/Preview.jpg` written by `ImageExporter.quickLookImages` | same writer; XDG thumbnailer reads it | thumbnailer tests (CTest) exist; desktop use unverified (GAP-VER-02) |
| Preferences | `UserDefaults` | `SQLiteUserDefaults` (`Sources/Compat/FoundationCompat/SQLiteUserDefaults.swift`), per-user database in XDG config | `KeyboardShortcutTests` mirror passes |
| Autosave / crash recovery | none upstream | **Linux-only** autosave timer and recovery (`host/SessionWindow.h:110-116,508`) | async save journey in the contract |

Interchange with macOS: one manifest code path, one asset codec set (PNG through Qt with straight alpha preserved, OpenEXR for HDR). A Linux-written package should therefore open on macOS, and the reverse. This is **not verified**, because no Mac is available (GAP-VER-04).

Proposed compatibility corpus, to be generated on macOS and committed as fixtures:
1. One package per manifest version 1–14.
2. A 16-bit and an HDR layer.
3. Masks: linked, unlinked and moved.
4. Clipping stacks and nested folders with opacity.
5. Every adjustment kind and every effect kind.
6. Live text with per-letter styling, and live shapes with smooth corners.
7. Guides and grid settings.
8. A CMYK-sourced PSD.

Each fixture is opened on Linux, its manifest and asset hashes are compared, it is re-saved, and it is reopened on macOS.

## Import/export conversions

| Path | Upstream | Linux substitute | Risk |
|---|---|---|---|
| JPEG/PNG/TIFF/WebP/HEIC decode | ImageIO | Qt image plugins + libheif + libtiff behind compat `CGImageSource` (`host/QtImageIO.cpp`) | Color: ICC handled through LittleCMS; gray-PNG ICC recovery added; Mac comparison open |
| PSD/PSB | upstream reader (pure Swift) | unchanged | none |
| RAW | Core Image `CIRAWFilter` | LibRaw 0.22.2 + RawSpeed-v3 (`Sources/Compat/CompatSupport/RawDecoding.swift`) | Lens correction only from embedded profiles (GAP-PLAT-02); demosaic and tone look differ from Apple's RAW engine (no Mac comparison) |
| EXR/HDR | ImageIO | OpenEXR (`scripts/build-openexr.sh`) | none known |
| SVG | ImageIO/AppKit | Qt SVG | Qt SVG is SVG Tiny 1.2: filters and some CSS are unsupported, so complex SVGs can rasterize differently |
| PDF export | Core Graphics PDF | compat CG → Skia PDF backend | not compared with Mac output |
| CMYK export / proof | ColorSync | LittleCMS | no bundled default CMYK profile (GAP-PLAT-05) |

## Architecture

```
Swift @main (Sources/CompositorHostBootstrap) ── bootstraps runtime, defaults ──► compositor_host_run (C ABI)
        │                                                                       │
        ▼                                                                       ▼
upstream EditorSession / Document / IO / Rendering (unchanged)          Qt shell (host/*.cpp)
        ▲   ▲                                                            │   ├─ QMenuBar  ◄── AppMenus.swift (tip .commands)
        │   └── Sources/Overrides (generated tip files, GPU replacements)│   ├─ canvas widget ◄── UpstreamCanvas.swift (EditorCanvas)
        │                                                                │   ├─ SwiftUIQtRenderer ◄── SwiftUIBridge.swift (tip views)
        └── Sources/Compat/* (AppKit, SwiftUI, CG, CI, ImageIO, Vision…)  │   └─ re-implemented chrome: tab bar, rulers, palette,
             backed by Skia, Vulkan, OpenCV, Qt, LittleCMS, LibRaw        │      canvas badges, file panels, alerts
                                                                         ▼
                                                              Sources/LinuxBridge (C ABI: session, state JSON, commands)
```

Assessment:

| Area | Finding | Recommendation |
|---|---|---|
| Module boundaries | Clear: protected upstream, generated overrides (drift-checked), compat, bridge, Qt shell. Every override has a declared mode (`linux/upstream-parity.json`); `scripts/upstream-override-drift.py` reports **OVERRIDE DRIFT CLEAN** over `a1bd74c..365b574` (run today) | Keep |
| Faithfulness | Upstream logic is never re-implemented: menus, tool headers, sheets, layer list and canvas run tip code. The remaining hand-built chrome is where every UI gap of this audit sits: proof pills, palette, tab bar, rulers. The renderer's pattern-matched controls (Menu labels, icon composition) cause the others | Prefer hosting tip views over re-implementing (GAP-UI-08 still open). Done in `6f69273`: generic Menu labels, badge composition, shape foreground inheritance, per-axis `fixedSize`, ZStack sizing (report 10 § Root causes) |
| Silent no-ops | Compat accepts unsupported SwiftUI API without warning (GAP-ARCH-01). Current upstream uses are harmless, as verified: non-drag `gesture` is only `SpatialTapGesture`/`TapGesture`, which have handlers; `aspectRatio` appears once, where the RAW preview already fits; `zIndex` once (tab drag) | Add a tip-usage audit that fails on new uses |
| Concurrency | Upstream is `@MainActor` by default; compat pumps the Swift main queue under Qt. C-ABI calls off the main thread are gated (`Thread.isMainThread`, 2 sites in `Sources/LinuxBridge`) because isolated `NSViewRepresentable` conformances cannot be cast there (memory note on off-main resolve). The parallel test deadlock (GAP-TEST-01) suggests a remaining main-actor wait that only shows under concurrency | Bisect GAP-TEST-01 before enabling parallel CI |
| Ownership and lifetimes | Session close releases canvases and watchers (`NativeSessionLifetimeTests` pass). Representables are dismantled (`RepresentableDismantleTests` pass). The stepper-callback cycle is released (`content-view-linux.patch`) | Keep |
| Error propagation | Bridge returns coded results (`UpstreamEditor.swift:245`: −5 failed … −7 unsupported); refusals are logged (`Compositor command refused: …`) | Surface −7 "not supported by this bridge" in a test that enumerates all upstream commands, so none is left unmapped |
| Duplication | Two Levels/Adjust dialogs exist in `host/` (`AdjustDialog.cpp`, `ColorPickerDialog.h`) from the pre-upstream shell; the memory notes say they are reachable only from hidden legacy buttons and grab hooks | Remove dead legacy dialogs once no journey depends on them |
| Size | Linux layer ≈ 34.6k lines in `Sources/LinuxBridge/*.swift` + `host/*.cpp`, plus ≈ 18.8k lines of compat Swift (top two directory levels only) | — |
| Technical debt | Pre-generated `host/moc_*.cpp` because SwiftPM cannot run moc (header-only Q_OBJECT-free widgets otherwise) | Keep generation scripted |

No rewrite of working code is recommended. Where Linux approximates rather than ports, the cause is a framework gap, and each case is listed in report 09: the GPU canvas, the Vision model, lens profiles and the CMYK profile.
