# 05 — UI/UX audit

> **Re-baselined on GNU_Linux `6f69273`.** The original capture (below, on `959850f`) found 7 UI gaps. All 7 are fixed
> in `6f69273` and verified by the new `--ui-audit-probe` contract gate (host/UIAuditJourney.h). The probe opens the
> welcome sheet, 23 tool states, 22 floating panels, 4 sheets, 12 adjustment layers and both CMYK pills. It checks for
> elided text, empty buttons, unresolved symbols, the preset menu's contents and effect, the Camera Raw scope geometry,
> the eyedropper pictures and the pills' text, order and close buttons. "After" screenshots:
> `.build/evidence/audit/shots/fixA.png` (presets ⋯, CMYK pills), `fixB.png` (Color Balance, Scanlines, Color Range),
> `fixC.png` (Camera Raw scope). Verdicts marked **(fixed `6f69273`)** were gaps on `959850f`.

## Method and limits

- Build: prebuilt release `CompositorHostBootstrap` (`.build/evidence/swift-build/x86_64-unknown-linux-gnu/release`, built 2026-10-18 13:14 from the tree committed as `630172a`; later commits `98dbefc` and `959850f` touch only the version and CI).
- Run: `QT_QPA_PLATFORM=offscreen` inside the Flatpak SDK through `.build/evidence/audit/grab.sh`. Window size 1600×1000. Fixture `docs/references/levels.png` (1048×962). RAW fixture `build/raw-samples/5D3.CR2`.
- Screenshots: `.build/evidence/audit/shots/` (167 files incl. crops). Contact sheets: `headers1.png`, `headers2.png` (every tool header), `menus1.png`, `menus2.png` (every top-level menu), `m1.png`…`m7.png` (28 sheets and panels), `start-empty.png`, `doc-move.png`, `ac.png`, `layermenu.png.menu.png`, `rawsheet.png.sheet.png`, `cmyk2.png.submenu.png`.
- **Not possible here:** comparison with macOS screenshots (no Mac; upstream ships no reference images). Every "matches" below means "matches upstream's SwiftUI/AppKit source", not "pixel-identical to macOS". The offscreen platform draws no window-manager decorations, and HiDPI was not exercised (DPR 1).
- Not captured: Search Commands (modal; the capture timed out, `logs-dlg27.txt`) and the Export As sheet (modal; covered by the existing `--save-smoke` journey, not re-run).

## Window structure

| Element | Upstream source | Linux (observed) | Verdict |
|---|---|---|---|
| Menu bar: Compositor, File, Edit, View, Select, Image, Filter, Layer, Window, Help | `CompositorApp.swift:20-395` | All present, same items, order, separators, disabled states and shortcuts (Linux key names) — `menus1.png`, `menus2.png` | Match |
| Header: New (+), tab strip, Fit, 100%, zoom capsule | `ContentView.swift:180-215` | Present; disabled without a document (`start-empty.png`) | Match (Qt tab bar re-implementation) |
| Tool options bar per tool | `ContentView.swift:27-80` + `UI/*Controls.swift` | Drawn from upstream views; all 16 states captured (`headers1/2.png`); probe checks 23 states | Match **(GAP-UI-10 fixed `6f69273`)** |
| Tool rail: 15 tools + palette, mode-dependent icons | `ContentView.swift:310-340` | 15 tools in upstream order, palette with swap/reset | Match |
| Rulers / guides | `UI/CanvasRulers.swift` | Qt re-implementation; native ruler journey in the contract | Match (not re-checked visually) |
| Canvas: surround, checkerboard, transform box, handles, rotation knob | `Rendering/EditorCanvas.swift`, `TransformOverlay.swift` | Upstream canvas hosted; `doc-move.png` | Match |
| Canvas foot badges: CMYK proof, gamut, mask alone | `ContentView.swift:96-105` | All three, stacked in upstream order, profile name, × | Match **(fixed `6f69273`, GAP-UI-03)** |
| Navigator minimap (≥300%) | `UI/NavigatorMinimap.swift` | Bridged panel | Not observed at 300% |
| Layers panel: title + count, Blend/Opacity, list, footer (+, folder, mask, adjustment, effects, trash) | `UI/LayersPanel.swift` | All present (`doc-move.png`, `start-empty.png` empty state text matches) | Match |
| Layer rows: eye, thumbnail, name, size subtitle, mask thumbnail, link, effect rows | `UI/NativeLayerList.swift` | Present; all 12 adjustment symbols resolve | Match **(fixed `6f69273`, GAP-UI-05)** |
| Layer context menu | `NativeLayerList.swift:127-245` | Same items and enablement (`layermenu.png.menu.png`) | Match |
| Status bar: zoom, size, "sRGB · Transparent", tool hints, busy | `ContentView.swift:348-370` | Same text per tool (`doc-move.png`) | Match |
| Welcome / New canvas | `UI/NewCanvasSheet.swift` | Fields, pills, Open/Import/Create, ⋯ presets (choice sets the size) | Match **(fixed `6f69273`, GAP-UI-01)** |

## Tool options bars (`headers1.png`, `headers2.png`)

| Tool (key) | Upstream controls | Linux | Verdict |
|---|---|---|---|
| Move (V) | Title, Auto Select, Show Controls, X, Y, W, H, link, Scale %, °, Sampling, Flip H, Flip V, (Cancel/Apply when pending) | All present | Match **(Sampling elision fixed `6f69273`)** |
| Marquee (M) | Rectangle/Ellipse, New/Add/Subtract, (Anti-alias only for Ellipse), Expand/Contract/Feather + px | Present; Anti-alias correctly hidden for Rectangle | Match |
| Lasso (L) | Freehand/Polygonal, modes, Anti-alias, Expand/Contract/Feather | Present | Match |
| Magic (W) | Wand/Object, modes, Tolerance, Sample Size, This/All Layers, Contiguous, Anti-alias, modify controls | Present | Match |
| Crop (C) | Ratio, size readout, Cancel, Apply Crop | Present | Match |
| Brush (B) | Paint/Erase, Size, Hardness, Opacity, Smoothing, Color | Present | Match |
| Spot Healing (J) | Content-Aware/Create Texture/Proximity Match, Size, Hardness, Opacity, Color | Present | Match |
| Clone Stamp (S) | Aligned, This/All Layers, Size, Hardness, Opacity, "Option-click to set the source" | Present | Match (hint says Option; Linux key is Alt — wording follows upstream) |
| Smear (R) | Liquify/Blur/Smudge, Size, Hardness, Strength | Present | Match |
| Gradient (G) | Linear/Radial, preview, style, Reverse, Opacity | Present | Match |
| Shape (U) | Rectangle/Ellipse/Line, color, Radius, Smooth Corners (disabled at 0) | Present; Smooth Corners disabled at radius 0 (1.5.3 `9b3f48e`) | Match |
| Type (T) | Font, size, color, alignment ×3, Tracking, Leading (Auto), Edit Text | Present (font shows "Helvetica", upstream's default `fontName`, `Document/TypeTool.swift:9`; which installed face Qt substitutes was not checked) | Match |
| Eyedropper (I) | Sample Ring | Present | Match |
| Hand (H) | "Pan" | Present | Match |
| Zoom (Z) | Zoom % field | Present | Match |
| None (A) | "Select a tool" | Present | Match |

## Sheets and floating panels (`m1.png`–`m7.png`)

| Panel | Verdict | Notes |
|---|---|---|
| Curves | Match | Graph, channel, Remove point, Reset curve, Preview |
| Levels | Match | Histogram, markers, Sample Black/Gray/White, Auto ×3, Reset, Preview |
| Hue/Saturation | Match (Master state) | Range picker, targeted hand, colored tracks; range eyedroppers only appear for non-Master ranges and use the badged icons of GAP-UI-04 |
| Black & White | Match **(fixed `6f69273`)** | was: "Magentas" clipped (GAP-UI-02) |
| Color Balance | Match **(fixed `6f69273`)** | was: "Cyan / Re", "Yellow / B" (GAP-UI-02) |
| Exposure, Gradient Map | Match | |
| Grain | Match **(fixed `6f69273`)** | was: "Roughnes" (GAP-UI-02) |
| Canvas Size, Image Size, Trim, Grid Settings | Match | Anchor grid, units, resample, sampling, Restore Defaults |
| Gaussian / Motion / Progressive Blur, Add Noise, Bloom/Glow, Dither, Tonal Contrast | Match | |
| Vignette | Match **(fixed `6f69273`)** | was: "Roundnes", "Highlight" (GAP-UI-02) |
| Scanlines | Match **(fixed `6f69273`)** | was: 7 of 13 titles clipped (GAP-UI-02) |
| Lens Correction | Match **(fixed `6f69273`)** | was: "Remove I…" (GAP-UI-02) |
| Camera Raw Filter | Match **(fixed `6f69273`)** | was: scope ~80×28 px under an empty band (GAP-UI-06) |
| Remove Background | Match | Basic/Advanced, Preview |
| Color Range | Match **(fixed `6f69273`)** | was: Add/Remove eyedroppers empty squares (GAP-UI-04) |
| Keyboard Shortcuts | Match **(fixed `6f69273`)** | `xmark.circle.fill` now mapped; `gen-lucide-icons.py --check` guards every upstream symbol |
| RAW Develop | Match | Preview keeps aspect; Lens Correction disabled for a file without a lens profile (GAP-PLAT-02) |
| Adjustment layer editors (Levels, Curves) | Match | Same panels as the destructive versions |

## Interaction checklist

The UI was rendered from upstream's own views, and the menus are generated from upstream's command definitions. So *exists / visible / enabled / triggers / updates state* is inherited for every control the renderer draws. The renderer-level failures are the gaps above. The 1,122 tests run today drive the commands those controls call. These earlier contract native journeys exercise the interaction paths with real Qt events: tab, preview, transform, tool combination, text, async save, Camera Raw docking, package, touch and others. They come from the pre-existing log `.build/evidence/full-contract.log`, 2026-10-18 13:48, exit 0, which this audit did not re-run.

| Concern | Finding |
|---|---|
| Focus and keyboard navigation | Accessibility names and the focus chain are covered by contract journeys (six-area audit, 2026-10-13); not re-run here |
| Shortcuts | Linux key names shown everywhere (Ctrl/Alt/Shift/Meta). Upstream's help strings still say ⌘/⌥ in places (e.g. "Option-click to set the source"); this is upstream text, left unchanged on purpose |
| Cursors | Upstream cursor pictures are hosted (`CursorTests` pass); the Option-over-mask eye (`eye.fill`) is mapped since `6f69273` (static: the cursor itself was not captured) |
| Progress | Status-bar "Working…" / "Importing images…" are upstream views |
| Error messages | Upstream alerts are hosted as Qt message boxes (`NativeAlertOwnershipTests` pass) |
| Accessibility | Qt accessible names come from upstream `.help`/labels. Screen-reader use was not tested |
| HiDPI | Not exercised (offscreen DPR 1). Icons are rendered at ≥2× |
| Linux conventions | Global menu where available, XDG file panels, Ctrl-based shortcuts, Window menu reduced (GAP-UI-09, acceptable) |

## UI/UX metrics

Of the 179 catalogued features on `6f69273`:
- 120 are seen working, in this audit's screenshots or the `--ui-audit-probe` gate.
- 0 are visibly wrong. On `959850f`, 13 were (GAP-UI-01…06, 10).
- 21 have no UI.
- 38 were not observed (canvas interactions, drag and drop, the 300% minimap, Export As, Search Commands).

Remaining UI difference: GAP-UI-08 (command palette placeholder, empty state and shortcut column).
