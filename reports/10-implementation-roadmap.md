# 10 — Implementation roadmap

> **Status on `585f080` (2026-10-19):** T-01–T-06 and T-13 done in `6f69273`; T-07 not needed (`0640011`); T-08, T-09,
> T-11, T-12, T-14, T-17, T-19, T-20, T-21 done (`9bf048b`…`585f080`, full contract exit `0 0`,
> `.build/evidence/full-contract-batch.log`). T-15/T-16: scripted part done, manual matrix ready. T-22: lavapipe done (36/36 gates). T-10, T-18, T-23 need a Mac: plan and Linux tools in `docs/mac-verification-plan.md`. The completed task
> cards are kept for traceability.

Ordered by prerequisite, then impact. Effort assumes one engineer who knows the compat renderer, working in the Flatpak SDK with the existing contract runner. Estimates exclude review time. No P0 items: the build is green, no crash or data loss was found, and the protected tree is intact.

## P0 — Build, crash, data loss

None found. Keep `scripts/check-upstream-clean.sh` and the override drift check as merge gates.

## P1 — Missing core functionality / incorrect processing

### T-01 Visual regression harness (prerequisite for T-02…T-08) — ✅ done in `6f69273`
- **Current:** no automated look at rendered panels; six UI gaps went unnoticed.
- **Expected:** every upstream panel, header and menu is captured and checked on each PR.
- **Steps:**
  1. Move `.build/evidence/audit/grab.sh` into `scripts/ui-capture.sh`, together with the menu-item list `dialogs.index` and the tool keys.
  2. Add `--ui-audit` to `host/host_run.cpp`. After the capture it walks the widget tree and reports four things:
     - (a) elided text, using `QFontMetrics::horizontalAdvance` versus the widget's content width;
     - (b) visible buttons with no text and no icon;
     - (c) icons equal to the fallback square;
     - (d) vertical empty bands inside a panel.
  3. Store baseline PNGs and diff them with a tolerance.
- **Files:** `scripts/ui-capture.sh` (new), `host/host_run.cpp`, `.github/workflows/linux-swift-tests.yml`.
- **Risk:** low. **Effort:** 2–3 days.
- **Tests:** the harness reports today's GAP-UI-01/02/04/05/06/10 (it must fail on the current build).
- **Done when:** it runs in CI and its findings list equals the open UI gaps.

### T-02 Generic Menu labels (GAP-UI-01) — ✅ done in `6f69273`
- **Current:** the New Canvas ⋯ preset menu is invisible.
- **Root cause:** `host/SwiftUIQtRenderer.cpp:3495-3517` accepts only Text/Image labels.
- **Steps:**
  1. If the label kind is not Text/Image, build it with the renderer's normal node→widget path.
  2. Host it in a `QToolButton` with `setPopupMode(InstantPopup)` and the populated `QMenu`.
  3. Apply `.help` as the tooltip and the accessibility label.
  4. Honor `menuIndicator(hidden)`.
- **Tests:** new `--new-canvas-presets-probe` (report 09); T-01 shows no empty button.
- **Risk:** low. **Effort:** 0.5–1 day.
- **Done when:** a preset sets the fields, and Create makes that size.

### T-03 Proof/gamut pills (GAP-UI-03) — ✅ done in `6f69273`
- **Steps:**
  1. Replace `ensureMaskAloneBadge` with a pill stack. Its inputs come from state JSON: `proofsColors`, `showsGamutWarning`, `viewsMaskAlone`, and a new `proofProfileName` added in `Sources/LinuxBridge/UpstreamEditor.swift` state.
  2. Use upstream's titles, symbols, details and close handlers (`Compositor/UI/LayerMaskMenu.swift:35-51`).
  3. Stack them in upstream order, 8 pt apart, 14 pt above the canvas foot.
- **Files:** `host/SessionWindow.cpp/.h`, `Sources/LinuxBridge/UpstreamEditor.swift`.
- **Tests:** extend `--cmyk-proof-probe`.
- **Effort:** 1 day. **Depends on:** T-05 (printer and triangle icons).

### T-04 Slider title width (GAP-UI-02) — ✅ done in `6f69273`
- **Steps:**
  1. Write a compat unit test that reproduces the FilterSheet pattern (`Text(title).fixedSize().background(GeometryReader { preference }).frame(width: labelWidth)`).
  2. Make the background's GeometryReader measure the fixed-size content before the outer frame. In `Sources/Compat/SwiftUI/Modifiers.swift` (background) and the Background/Geometry widgets of `host/SwiftUIQtRenderer.cpp`, size the background child from the base's natural size.
- **Tests:** the compat test, plus T-01 finds no elided titles in any FilterSheet.
- **Risk:** medium, since this layout change affects every background reader. Run the full contract.
- **Effort:** 1–2 days.

### T-05 Symbol table and badge composition (GAP-UI-04, GAP-UI-05) — ✅ done in `6f69273`
- **Steps:**
  1. Extend `scripts/gen-lucide-icons.py` with: `plus.circle.fill`, `minus.circle.fill`, `xmark.circle.fill`, `checkmark`, `exclamationmark.triangle`, `printer`, `eye.fill`, `plusminus.circle`, `circle.dotted`, `circle.filled.pattern.diagonalline.rectangle`, `scale.3d`.
  2. Make the generator's input list come from a grep of `Compositor/`, and make it fail when a symbol is unmapped.
  3. In the renderer, compose a ZStack of Images into one icon: the base plus a bottom-trailing badge at its font size.
- **Tests:** a symbol-resolution unit test; the Color Range buttons are three distinct pixmaps; the 12 adjustment thumbnails are non-empty.
- **Effort:** 1 day.

### T-06 Camera Raw scope layout (GAP-UI-06) — ✅ done in `6f69273`
- **Steps:**
  1. Add a compat layout test with a ZStack whose child is `.frame(height: 110)` inside a VStack whose width is `.infinity`.
  2. Fix the ZStack to take the max of its children's heights and to expand to flexible width.
- **Tests:** a native assertion on the scope widget's size.
- **Effort:** 1 day. **Risk:** medium (ZStack is used widely; T-01 guards it).

### T-07 GPU-resident canvas (GAP-PERF-01) — ✅ not needed (`0640011`)
- **Outcome:** measured on the release build, 8000×6000 × 12 layers: full recomposite 44 ms (80 ms worst), stroke frame 4.6 ms (10 ms worst). The real costs were fixed instead: `79c4976` (Vulkan brush readback, tool-rail rebuilds) and `0640011` (lazy layers resolved in the background; first stroke frame 331 → 10 ms). The plan below is kept for documents well beyond that size.
- **Current:** the CG canvas is the default; Vulkan is opt-in and slower at window sizes.
- **Steps:**
  1. Keep layer tiles as Vulkan images and update dirty tiles only.
  2. Sample them in `raster_fused.comp`.
  3. Run the separable GPU blur.
  4. Remove the per-frame CPU float leaves.
  5. Switch `hostMain.swift:50-53` to register `CompositorCPUCanvas=false` when Vulkan is present and the benchmark gate passes. Keep the CG fallback.
- **Files:** `backends/coreimage/*`, `Sources/Compat/CoreImage/*`, `Sources/Overrides/GPUCanvas.swift`, `Sources/CompositorHostBootstrap/hostMain.swift`.
- **Tests:** `GPUCanvasTests`; a pixel diff vs CG ≤ 1/255; a benchmark gate at 1400×900 and 7680×4320.
- **Risk:** high. **Effort:** 2–4 weeks.


### Root causes found while doing T-01–T-06 (for whoever maintains the compat renderer)

| Symptom | Actual root cause | Fix (in `6f69273`) |
|---|---|---|
| Preset ⋯ invisible | `Menu` built only Text/Image labels; bare `Circle`s had no fill (SwiftUI fills shapes with the foreground style) | Any label subtree drawn in the button; `SwiftUIShapeWidget::inheritForeground` |
| Choosing a preset did nothing | Compat `Picker` mapped choices back only for enum/String/Int/Bool; the focused Width field was never refreshed | `PickerTagValues`; untyped focused fields follow the model (`swiftuiTyped`) |
| Titles clipped at 60 pt | All rows' `.background(GeometryReader)` shared one tree path (`nestedPath`), so one size key; readers measured the clipped frame; a size report never re-rendered the panel | Per-occurrence nested paths; natural-size background readers; `GeometrySizes.changedScopes` → `DirtyPanels.mark` |
| Camera Raw scope 80×28 under a band | `SwiftUIZStackWidget` ignored children's minimums/flexibility; `fixedSize(horizontal:vertical:)` fixed both axes | ZStack size hints/policy; per-axis `fixedSize` |
| Empty-square icons | 12 SF Symbols unmapped; ZStack badge labels took the last image | Custom Lucide-style SVGs; `base|badge=` composition; `gen-lucide-icons.py --check` |

## P2 — Incomplete features, state, model compatibility

| Task | Gap | Steps | Effort |
|---|---|---|---|
| T-08 Lens profiles — ✅ `b215842` | GAP-PLAT-02 | Vendor lensfun into the Flatpak; map LibRaw camera/lens IDs to lensfun profiles; feed `supportsLensCorrection`; apply distortion/TCA/vignetting in the develop path | 1–2 weeks |
| T-09 Default CMYK profile — ✅ `43f3112` (colord SWOP TR005, CC0) | GAP-PLAT-05 | Pick a redistributable CMYK ICC (check the licence), install it to the app's `CMYK Profiles`, select it as default like Apple's Generic CMYK | 1–2 days |
| T-10 Document corpus — Linux round trip ✅ `8cad036`; Mac-written packages unverified (needs a Mac) | GAP-VER-04 | Report 06 list; needs Mac access (borrowed machine or macOS CI runner) | 2–3 days with a Mac |
| T-11 Command palette parity — ✅ `c5ed205` | GAP-UI-08 | Host upstream `CommandPaletteView` through the bridge (preferred), or match placeholder, empty state and right-aligned shortcut column | 0.5–2 days |
| T-12 Bridge completeness test — ✅ `16e3fbf` (found and fixed `clearGuides`) | regression | Enumerate upstream commands; assert no −7 result | 1 day |

## P3 — UI/UX, integration, workflow

| Task | Gap | Steps | Effort |
|---|---|---|---|
| T-13 Sampling picker width — ✅ done in `6f69273` | GAP-UI-10 | Combo padding no longer double-counts the drop-down | — |
| T-14 Window menu list — ✅ `9e21ce2` | GAP-UI-09 | Add the open project windows | 0.5 day |
| T-15 Desktop integration — scripted ✅ `585f080`; X11 clipboard and drop delivery ✅ `a13f27d`; drop contents and real sessions by hand | GAP-VER-01/02 | Manual + `xdotool`/`ydotool` scripts on GNOME and KDE (X11 + Wayland): DnD file→canvas/tab, layer→other window, thumbnails, open while quit | 2 days |
| T-16 Physical input — `--input-probe` and HiDPI audit ✅ `a13f27d`; real devices by hand | GAP-VER-03 | Mouse, trackpad pinch/pan, touch, pen; record results in `docs/` | 1–2 days |
| T-17 Updater end-to-end — ✅ `585f080` (real portal, `scripts/test-flatpak-update-e2e.sh`) | GAP-PLAT-04 | Run `scripts/test-flatpak-updates.sh` against a local repo with N and N+1; add it to the release checklist | 1 day |
| T-18 Subject-mask quality — reference set and guided refinement ✅ `e10239d` (median IoU 0.917); Vision comparison needs a Mac | GAP-PLAT-01 | 30+ photo set, macOS masks as reference, IoU report; tune threshold/edge | 3–5 days with a Mac |

## P4 — Performance, reliability, regression hardening

| Task | Gap | Steps | Effort |
|---|---|---|---|
| T-19 Parallel test deadlock — ✅ `9bf048b` (pool starvation) + `d9fea91` (contract runs in parallel; 8 shared-state suites after, serially; 3× clean) | GAP-TEST-01 | Bisect suites with `--filter` under parallel; find the synchronous main-actor wait; fix it or mark it `.serialized` | 2–4 days |
| T-20 No-op API audit — ✅ `352f5c0` (found the Export As scroll no-ops) | GAP-ARCH-01 | Script: list compat modifiers that return `self`, grep tip for uses, fail on new ones; debug-log once at runtime | 1 day |
| T-21 Remove legacy dialogs — ✅ `79a767b` (AdjustDialog; ColorPickerDialog still backs the color service) | report 06 | Delete `host/AdjustDialog.cpp` / `ColorPickerDialog.h` paths that only hidden buttons and grab hooks reach | 1 day |
| T-22 GPU vendor spread — ✅ llvmpipe (lavapipe): 36/36 native gates pass; Swift suites pass except the 95 assertions that require a hardware GPU (the Vulkan backends skip CPU devices by design and fall back to CPU paths). Intel ANV / NVIDIA need that hardware | report 07 | Run the contract on Intel ANV and llvmpipe (CI), and on NVIDIA if available | 1–2 days |

## P5 — Final parity certification

| Task | Steps | Done when |
|---|---|---|
| T-23 Golden images — 88 Linux baselines ✅ `d00f506`; macOS baselines need a Mac | Report 07 table, generated on macOS | All cases within tolerance, or a documented accepted deviation |
| T-24 Full contract + UI audit + goldens — ✅ on Linux (`a13f27d`, exit `0 0`; lavapipe; X11; HiDPI) | Run on a clean checkout of the release commit | Exit 0, UI audit clean, goldens pass |
| T-25 Recompute report 11 metrics — ✅ 2026-10-19 (re-run after the Mac steps) | `gen_reports.py` with refreshed evidence | Every feature is VERIFIED_PARITY or has a justified LINUX_EQUIVALENT / NOT_APPLICABLE |

Dependency graph:
- Done: T-01 → T-02, T-03, T-04, T-05, T-06, T-13 (T-05 → T-03).
- T-10, T-18, T-23 need a Mac.
- T-07 is independent but long.
- T-24 needs everything else.
