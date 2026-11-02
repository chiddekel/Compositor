# 09 — Gap analysis

October 20 update: [independent rendering and optional desktop providers](../docs/render-parity-and-desktop-previews.md)
are implemented. Mac comparisons and real Dolphin GUI acceptance remain pending.
APP-12 passed its independent GIO desktop launch check and no longer shares GAP-VER-02.

Baseline GNU_Linux `a13f27d` vs upstream `365b574`. 22 gaps confirmed by this audit: **7 open**, 15 resolved (each resolved one lists the fix and the check that verifies it). Each open gap lists the symptom, the upstream behavior, the Linux cause, the evidence, the fix and the test that closes it.

## Open

| Gap | Severity | Status | Title | Features |
|---|---|---|---|---|
| GAP-VER-04 | High | IMPLEMENTED_UNVERIFIED | No macOS comparison: color fidelity, visual parity and .comp round trip Mac↔Linux unverified | RND-09 |
| GAP-PERF-01 | Low | LINUX_EQUIVALENT | Canvas composited on the CPU instead of upstream's GPU canvas (within budget) | VIEW-17, VIEW-18 |
| GAP-PLAT-01 | Low | IMPLEMENTED_UNVERIFIED | Object selection / Select Subject / Remove Background use U²-Net instead of Apple Vision | SEL-03, FLT-12, TOOL-05 |
| GAP-PLAT-03 | Low | LINUX_EQUIVALENT | Hide Others / Show All unavailable on Wayland | APP-07 |
| GAP-VER-01 | Low | IMPLEMENTED_UNVERIFIED | Physical desktop drag and drop (between windows and applications) unverified | FILE-15, FILE-16 |
| GAP-VER-02 | Low | IMPLEMENTED_UNVERIFIED | Optional host thumbnail providers implemented; Nautilus and KIO dispatch pass, real Dolphin GUI acceptance pending | FILE-18 |
| GAP-VER-03 | Low | IMPLEMENTED_UNVERIFIED | Physical touch, pen, trackpad and native Wayland input unverified | VIEW-16, KEY-04 |

## Resolved

| Gap | Was | Title | Fixed in | Verified by |
|---|---|---|---|---|
| GAP-ARCH-01 | Medium PARTIAL | Compat SwiftUI silently accepts unsupported API | `352f5c0` | `scripts/check-compat-noops.py` (in check-upstream-clean.sh) lists the 13 compat no-op overloads and fails on any upstream use without a recorded reason (`linux/compat-noop-allow.json`, 8 uses). It found `.scrollPosition` / `.onScrollGeometryChange` (Export As preview) doing nothing; both implemented, ScrollGeometryCompatTests |
| GAP-PLAT-02 | Medium PARTIAL | RAW Lens Correction only for files with an embedded lens profile | `b215842` | lensfun 0.3.4 database by camera and lens when the file carries no profile, sampled into the same radial profile the maker-note sources use (`host/RawLensfun.h`); a file's own profile still wins. Samples: 5D3 + EF 70-200 f/2.8L IS II, 5DS R + EF 100 Macro, A7R IV + FE 24-70 found; D850 names no lens, Phase One not in lensfun. `--raw-lens-smoke` checks a DNG naming the 5D Mark III and that lens: offered, on by default, corners 105 → 141; unknown lens not offered. Full contract `.build/evidence/full-contract-batch.log` (exit 0 0) |
| GAP-PLAT-04 | Medium IMPLEMENTED_UNVERIFIED | Updates through Flatpak; installed update + relaunch unverified | `585f080` | `scripts/test-flatpak-update-e2e.sh`: installed commit published as a throwaway branch in a local repo, installed, newer commit published; inside that sandbox the app's own FlatpakUpdateService (Check and Update) reaches ReadyToRestart through the real portal with the newer commit installed (`.build/evidence/t17/e2e.log`). Relaunch is covered by `scripts/test-flatpak-updates.sh` (0 failures) |
| GAP-PLAT-05 | Medium PARTIAL | No CMYK profile ships with the Linux build | `43f3112` | colord's SWOP TR005 Coated (CC0) ships in `third_party/color` and is installed as Generic CMYK Profile.icc on first run (`ColorSyncGenericProfiles.installBundledDefault`); first-run install verified with an empty profile folder (`.build/evidence/t11-cmyk-firstrun.txt`); upstream CMYKTests, CMYKProofDisplayTests, new DefaultCMYKProfileTests and `--cmyk-proof-probe` pass against it in `.build/evidence/full-contract-batch.log` (exit 0 0) |
| GAP-TEST-01 | Medium BROKEN | Parallel Swift Testing run deadlocks | `9bf048b, d9fea91` | Cause (gdb stacks, `.build/evidence/t19-stacks.txt`): a main-queue render waited on a semaphore for a Task.detached while every concurrency-pool thread waited in DispatchQueue.main.sync; previews now render on the calling thread (9bf048b). The contract then runs Swift tests in parallel and 8 shared-state or self-timing suites serially after (d9fea91): three runs in a row pass 937 + 45 tests and 154 XCTests, 87 s vs 95 s serial (`.build/evidence/t19-3x.txt`); full contract `.build/evidence/full-contract-split.log` exit 0 0 |
| GAP-TEST-02 | Low PARTIAL | No visual regression testing of upstream panels on Linux | `d00f506` | LinuxGoldenImageTests: 88 Linux baselines (blend modes, adjustments, filters, effects, transforms, text and shapes) compared within one level a channel, identical on RADV and lavapipe; with the --ui-audit-probe gate (6f69273) and the HiDPI audit runs. Baselines against macOS remain part of GAP-VER-04. |
| GAP-UI-01 | Medium BROKEN | New Canvas preset-size menu (⋯) is invisible | `6f69273` | Menu labels of any kind drawn in the button; bare shapes inherit `.foregroundStyle`; compat `PickerTagValues` maps non-enum tags; untyped focused fields follow the model. Probe checks the ⋯ button is visible and drawn, lists upstream's presets, and that Instagram Square sets 1080 × 1080. New compat test `UIAuditCompatTests.testStructTagsSelectTheTaggedValue`. `--ui-audit-probe` passes on the fix build (`.build/evidence/audit/ui-audit.log`, exit 0) and in the full contract run (`.build/evidence/full-contract-uifix.log`) |
| GAP-UI-02 | Medium BEHAVIOR_MISMATCH | Filter/adjustment slider titles are clipped at 60 pt | `6f69273` | Unique nested paths per occurrence (`ViewResolver.nestedPath`), background readers of fixed-size content measure the natural size (`BackgroundPlacer`), a changed reader size marks the panel dirty (`GeometrySizes.changedScopes`). Probe: no elided label in any FilterSheet. New compat test `testBackgroundReadersInOneBodyHaveTheirOwnPlace`. `--ui-audit-probe` passes on the fix build (`.build/evidence/audit/ui-audit.log`, exit 0) and in the full contract run (`.build/evidence/full-contract-uifix.log`) |
| GAP-UI-03 | Medium MISSING | CMYK Proof / Gamut Warning pills are not shown on the canvas | `6f69273` | `SessionWindow::makeCanvasPill` + `updateMaskAloneBadge` stack Proof, Gamut and mask pills; bridge state `proofProfileName`, commands `stopProofing` / `hideGamutWarning`. Probe checks titles, profile name, order and both × buttons. `--ui-audit-probe` passes on the fix build (`.build/evidence/audit/ui-audit.log`, exit 0) and in the full contract run (`.build/evidence/full-contract-uifix.log`) |
| GAP-UI-04 | Medium BROKEN | Badged and unmapped SF Symbols render as empty squares in panels | `6f69273` | 12 symbols drawn in `third_party/lucide/custom/`; `renderToolVectorIcon` composes `base/badge=`; `gen-lucide-icons.py --check` (in `check-upstream-clean.sh`) fails on any unmapped upstream symbol. Probe: Color Range eyedroppers draw three different pictures; no unresolved symbol recorded. `--ui-audit-probe` passes on the fix build (`.build/evidence/audit/ui-audit.log`, exit 0) and in the full contract run (`.build/evidence/full-contract-uifix.log`) |
| GAP-UI-05 | Low PARTIAL | AppKit symbol images missing in the Layers list | `6f69273` | Same symbol additions; the probe adds every adjustment kind and records no unresolved AppKit symbol. `--ui-audit-probe` passes on the fix build (`.build/evidence/audit/ui-audit.log`, exit 0) and in the full contract run (`.build/evidence/full-contract-uifix.log`) |
| GAP-UI-06 | Medium BEHAVIOR_MISMATCH | Camera Raw histogram/vectorscope is drawn tiny with a large empty band above | `6f69273` | `SwiftUIZStackWidget` honors children's minimums and flexibility; `fixedSize(horizontal:vertical:)` fixes only the requested axes. Probe: scope ≥ ¾ column width, ≥ 100 pt tall, no band above it. `--ui-audit-probe` passes on the fix build (`.build/evidence/audit/ui-audit.log`, exit 0) and in the full contract run (`.build/evidence/full-contract-uifix.log`) |
| GAP-UI-08 | Low BEHAVIOR_MISMATCH | Command palette is a Qt re-implementation with small UX differences | `c5ed205` | Palette drawn as upstream's view: placeholder, `No commands match` overlay, right-aligned shortcut column, checkmark column, accent selection, click runs. `--preview-smoke` asserts placeholder, empty state and shortcut column; passes in `.build/evidence/full-contract-batch.log` (exit 0 0) |
| GAP-UI-09 | Low LINUX_EQUIVALENT | Window menu has Minimize and Zoom only | `9e21ce2` | Window menu: Minimize, Zoom, Bring All to Front, then the checked window entry, as AppKit completes it; `--app-visibility-probe` checks the items and that Bring All to Front restores a minimized window; passes in `.build/evidence/full-contract-batch.log` (exit 0 0) |
| GAP-UI-10 | Low BEHAVIOR_MISMATCH | Transform bar Sampling picker text truncated (“High qual”) | `6f69273` | Combo right padding no longer double-counts the drop-down. Probe: no elided pop-up text. `--ui-audit-probe` passes on the fix build (`.build/evidence/audit/ui-audit.log`, exit 0) and in the full contract run (`.build/evidence/full-contract-uifix.log`) |

## GAP-VER-04 — No macOS comparison: color fidelity, visual parity and .comp round trip Mac↔Linux unverified

- **Severity / status / confidence:** High / IMPLEMENTED_UNVERIFIED / High (no Mac available)
- **Features:** RND-09
- **What is wrong:** Every pixel test compares Linux with upstream's own assertions or with Linux's own baselines, not with macOS output. Linux-only guards now exist (2026-10-19): the .comp corpus round trip (ProjectCorpusRoundTripTests), 88 golden images (LinuxGoldenImageTests), reference-mask scoring. macOS parity itself stays UNVERIFIED: no Mac available (user, 2026-10-13); steps in docs/mac-verification-plan.md.(user, 2026-10-13).
- **Upstream:** -
- **Linux:** -
- **Evidence:** TODOS.md items 156.
- **Root cause:** Hardware.
- **Required change:** Golden images rendered on macOS for a fixed fixture set (blend modes, filters, adjustments, effects, text, export), compared on Linux with ΔE/PSNR tolerances; a .comp round trip both ways.
- **Files:** Tests (new fixtures)
- **Acceptance test:** ΔE2000 mean ≤ 1, max ≤ 3; PSNR ≥ 45 dB for geometry; round trip identical manifests.

## GAP-PERF-01 — Canvas composited on the CPU instead of upstream's GPU canvas (within budget)

- **Severity / status / confidence:** Low / LINUX_EQUIVALENT / High (measured, COMPOSITOR_BENCH + timing inside the exporter)
- **Features:** VIEW-17, VIEW-18
- **What is wrong:** Upstream draws canvas frames on the GPU since 1.4. The Qt shell composites through upstream's own exporter (`compositor_session_render*`, CPU, dirty regions, display resolution for big documents) and paints with QPainter. Measured on the release build, 8000x6000 x 12 layers: full display recomposite 44 ms average, 80 ms worst (the earlier ~0.9 s figure came from a stale build); pan 4.0 ms, Move 13.6 ms, brush 4.6 ms average / 10 ms worst per stroke frame. Fixed on the way: Vulkan brush readback and per-tile submissions, tool-rail rebuilds mid-drag (`79c4976`), and the first stroke frame materializing every lazily committed layer (331 ms -> 10 ms; `CGImage.prefetch`, `0640011`). 16-bit layers show through their dithered 8-bit copy, which is what an 8-bit display shows on the Mac too.
- **Upstream:** `Compositor/Rendering/GPUCanvas.swift`, `EditorCanvas.drawOnGPU`.
- **Linux:** `Sources/LinuxBridge/SessionABI.swift` (`compositor_session_render*`), `host/SessionWindow.cpp` (`renderDisplayImage`, `scheduleStrokeRefresh`); `Sources/Overrides/GPUCanvas.swift` is not on the shell's display path.
- **Evidence:** `.build/evidence/audit/clean-big4-bench.txt`, `prof-brush-bench.txt` (after), `bench-big.txt` (before); contracts `full-contract-perf.log`, `full-contract-prefetch.log`.
- **Root cause:** Display composites are evaluated by the compat Core Graphics/Skia raster on the CPU; fast enough at the measured sizes.
- **Required change:** None needed for the budget. A GPU-resident compositor would only matter for documents well beyond 8000x6000 x 12 layers; keep the bench as the regression check.
- **Files:** —
- **Acceptance test:** 8000x6000 x 12 layers: full recomposite <= 100 ms (met: 44/80 ms); stroke frame <= 16 ms (met: 4.6/10 ms).

## GAP-PLAT-01 — Object selection / Select Subject / Remove Background use U²-Net instead of Apple Vision

- **Severity / status / confidence:** Low / IMPLEMENTED_UNVERIFIED / Medium
- **Features:** SEL-03, FLT-12, TOOL-05
- **What is wrong:** Linux uses U²-Net-small (OpenCV DNN) where macOS uses Apple Vision. Measured on Linux against 28 reference cut-outs (scripts/fetch-segmentation-references.py): median IoU 0.917, worst 0.537 after the guided edge refinement of e10239d (0.885 before). How close that is to Vision on the same photos stays unverified (needs a Mac).`VNGenerateForegroundInstanceMaskRequest` is unmeasured.
- **Upstream:** `VNGenerateForegroundInstanceMaskRequest` (2 call sites in Compositor/).
- **Linux:** Sources/Compat/Vision (U²-Net-small via OpenCV dnn).
- **Evidence:** Contract evidence `COMPOSITOR_REQUIRE_SUBJECT_MODEL=1`; today's test run passes the model tests.
- **Root cause:** Apple Vision unavailable.
- **Required change:** Build a labelled photo set; measure IoU vs Mac output.
- **Files:** Sources/Compat/Vision
- **Acceptance test:** IoU ≥ agreed threshold (e.g. 0.9) on ≥ 30 photos vs macOS masks.

## GAP-PLAT-03 — Hide Others / Show All unavailable on Wayland

- **Severity / status / confidence:** Low / LINUX_EQUIVALENT / High
- **Features:** APP-07
- **What is wrong:** Works on X11/EWMH; disabled on Wayland (no client access to other clients' windows).
- **Upstream:** `CompositorApp.swift:197-201`.
- **Linux:** Sources/Compat/AppKit (X11 path), TODOS.md.
- **Evidence:** TODOS.md, `.build/evidence/hide-others-x11-pass.log`.
- **Root cause:** Wayland security model.
- **Required change:** None possible; keep disabled with tooltip.
- **Files:** -
- **Acceptance test:** Existing `--app-visibility-probe`.

## GAP-VER-01 — Physical desktop drag and drop (between windows and applications) unverified

- **Severity / status / confidence:** Low / IMPLEMENTED_UNVERIFIED / Medium
- **Features:** FILE-15, FILE-16
- **What is wrong:** On a private X server (scripts/test-desktop-dnd.sh): clipboard both ways with other X clients, drop delivery and acceptance on the canvas, and header drops opening a tab pass. Drop contents could not be checked there: Xvfb with synthetic input carries no XDND data even between two plain Qt programs (the script's control). Real-session rows remain in docs/desktop-integration-matrix.md.
- **Upstream:** IO/ImageFileDrop.swift; ProjectWorkspace.
- **Linux:** host (Qt DnD), XDG portal.
- **Evidence:** TODOS.md P1 item.
- **Root cause:** Needs a real session.
- **Required change:** Manual + scripted (ydotool/xdotool) runs.
- **Files:** -
- **Acceptance test:** Drag a PNG from the file manager onto canvas/tab bar; drag a layer between two windows.

## GAP-VER-02 — Desktop integration: .comp thumbnails absent in file managers (Flatpak exports no thumbnailers)

- **Severity / status / confidence:** Low / PARTIAL / High (scripted check, 2026-10-19)
- **Features:** APP-12, FILE-18
- **What is wrong:** `scripts/desktop-integration-check.sh` on the installed alpha (GNOME, Wayland): desktop entry, MIME registration and default handler, the .comp glob, icons, metainfo and the thumbnailer itself pass. Flatpak exports no share/thumbnailers, so file managers show no .comp previews (Flatpak limitation). Opening from the file manager is in the manual matrix (docs/desktop-integration-matrix.md).
- **Upstream:** 14aad18, e70da06.
- **Linux:** flatpak/com.compositor.Client.thumbnailer, build/compositor-thumbnailer
- **Evidence:** TODOS.md.
- **Root cause:** Needs installed Flatpak + file manager.
- **Required change:** Manual test on GNOME/KDE.
- **Files:** -
- **Acceptance test:** Nautilus/Dolphin show .comp thumbnails; double-click opens the project.

## GAP-VER-03 — Physical touch, pen, trackpad and native Wayland input unverified

- **Severity / status / confidence:** Low / IMPLEMENTED_UNVERIFIED / Medium
- **Features:** VIEW-16, KEY-04
- **What is wrong:** --input-probe (contract gate) feeds pen, touch, trackpad scroll and pinch, Ctrl+wheel and brush keys through QWindowSystemInterface as the xcb and Wayland plugins deliver devices: all pass; the UI audit passes at 125/150/200 % scale. Physical devices and their drivers are unverified (none attached); checklist in docs/desktop-integration-matrix.md.
- **Upstream:** EditorCanvas input handling.
- **Linux:** host input filter
- **Evidence:** TODOS.md P1 finger-touch.
- **Root cause:** No devices in CI.
- **Required change:** Manual device matrix.
- **Files:** -
- **Acceptance test:** Pinch zoom, two-finger pan, pen pressure-free strokes on Wayland.

## GAP-ARCH-01 — Compat SwiftUI silently accepts unsupported API (resolved `352f5c0`)

- **Severity / status / confidence:** Medium / PARTIAL / High (source)
- **Features:** process-level
- **What is wrong:** `gesture<G>` (non-drag), `animation`, `aspectRatio`, `zIndex`, `onMove`, `onDelete`, `toolbar`, `preferredColorScheme`, `scrollBounceBehavior`, `sharedBackgroundVisibility` return `self` (`Sources/Compat/SwiftUI/Modifiers.swift:346,462-466,524,545-551,574`; `ViewBuilder.swift:66-67`). Today only harmless uses exist upstream, but a future upstream use would compile and silently do nothing.
- **Upstream:** -
- **Linux:** Sources/Compat/SwiftUI
- **Evidence:** grep of upstream uses (report 06).
- **Root cause:** Compile-first strategy.
- **Required change:** Make each no-op log once (debug) and add an upstream-usage audit to `scripts/check-upstream-clean.sh` that fails when tip starts using a no-op modifier.
- **Files:** Sources/Compat/SwiftUI, scripts/check-upstream-clean.sh
- **Acceptance test:** The audit script.
- **Resolution:** fixed in `352f5c0`. `scripts/check-compat-noops.py` (in check-upstream-clean.sh) lists the 13 compat no-op overloads and fails on any upstream use without a recorded reason (`linux/compat-noop-allow.json`, 8 uses). It found `.scrollPosition` / `.onScrollGeometryChange` (Export As preview) doing nothing; both implemented, ScrollGeometryCompatTests

## GAP-PLAT-02 — RAW Lens Correction only for files with an embedded lens profile (resolved `b215842`)

- **Severity / status / confidence:** Medium / PARTIAL / High (runtime)
- **Features:** FILE-22
- **What is wrong:** macOS uses Core Image's camera/lens database; Linux enables the checkbox only when LibRaw finds a profile in the file. `5D3.CR2` shows Lens Correction disabled.
- **Upstream:** `IO/RawImporter.swift` (`isLensCorrectionSupported`).
- **Linux:** `Sources/Overrides/RawDevelopSheet.swift:56`, `Sources/Compat/CoreImage/CoreImage.swift:1077`.
- **Evidence:** `.build/evidence/audit/shots/rawsheet.png.sheet.png`.
- **Root cause:** No lens database on Linux.
- **Required change:** Integrate lensfun (LGPL) as a profile source; map camera/lens IDs; same capability flags.
- **Files:** Sources/Compat/CompatSupport/RawDecoding.swift, flatpak manifest
- **Acceptance test:** CR2/NEF/ARW samples: Lens Correction enabled; distortion/vignette corrected within tolerance of Mac.
- **Resolution:** fixed in `b215842`. lensfun 0.3.4 database by camera and lens when the file carries no profile, sampled into the same radial profile the maker-note sources use (`host/RawLensfun.h`); a file's own profile still wins. Samples: 5D3 + EF 70-200 f/2.8L IS II, 5DS R + EF 100 Macro, A7R IV + FE 24-70 found; D850 names no lens, Phase One not in lensfun. `--raw-lens-smoke` checks a DNG naming the 5D Mark III and that lens: offered, on by default, corners 105 → 141; unknown lens not offered. Full contract `.build/evidence/full-contract-batch.log` (exit 0 0)

## GAP-PLAT-04 — Updates through Flatpak; installed update + relaunch unverified (resolved `585f080`)

- **Severity / status / confidence:** Medium / IMPLEMENTED_UNVERIFIED / Medium
- **Features:** APP-05
- **What is wrong:** Sparkle replaced by `host/FlatpakUpdateService.cpp`; the end-to-end update of an installed release has no recorded pass.
- **Upstream:** `IO/UpdateDriver.swift`, Sparkle.
- **Linux:** host/FlatpakUpdateService.cpp
- **Evidence:** docs/upstream-1.5.2-feature-status.md, TODOS.md.
- **Root cause:** Needs a published older + newer release.
- **Required change:** Scripted test: install alpha N, publish N+1 to a local repo, run Check for Updates, verify relaunch.
- **Files:** scripts/test-flatpak-updates.sh
- **Acceptance test:** That script passing in CI.
- **Resolution:** fixed in `585f080`. `scripts/test-flatpak-update-e2e.sh`: installed commit published as a throwaway branch in a local repo, installed, newer commit published; inside that sandbox the app's own FlatpakUpdateService (Check and Update) reaches ReadyToRestart through the real portal with the newer commit installed (`.build/evidence/t17/e2e.log`). Relaunch is covered by `scripts/test-flatpak-updates.sh` (0 failures)

## GAP-PLAT-05 — No CMYK profile ships with the Linux build (resolved `43f3112`)

- **Severity / status / confidence:** Medium / PARTIAL / High
- **Features:** VIEW-08
- **What is wrong:** macOS proofs with Apple's Generic CMYK profile out of the box; on Linux Proof Colors/CMYK export need the user to load an ICC profile first.
- **Upstream:** `IO/CMYK.swift` (`CMYK.installed()`).
- **Linux:** XDG `CMYK Profiles` folder; tests use Ghostscript's `default_cmyk.icc` as a fixture.
- **Evidence:** docs/upstream-1.5.2-feature-status.md; TODOS.md (lost /tmp item).
- **Root cause:** Apple profile is not redistributable.
- **Required change:** Bundle a redistributable CMYK profile (e.g. Ghostscript default_cmyk.icc, AGPL/permissive variants, or ECI profiles if licence allows) as the default.
- **Files:** flatpak manifest, IO profile search path
- **Acceptance test:** Fresh install: View › CMYK › Profile lists a default; Proof Colors works without loading a file.
- **Resolution:** fixed in `43f3112`. colord's SWOP TR005 Coated (CC0) ships in `third_party/color` and is installed as Generic CMYK Profile.icc on first run (`ColorSyncGenericProfiles.installBundledDefault`); first-run install verified with an empty profile folder (`.build/evidence/t11-cmyk-firstrun.txt`); upstream CMYKTests, CMYKProofDisplayTests, new DefaultCMYKProfileTests and `--cmyk-proof-probe` pass against it in `.build/evidence/full-contract-batch.log` (exit 0 0)

## GAP-TEST-01 — Parallel Swift Testing run deadlocks (resolved `9bf048b, d9fea91`)

- **Severity / status / confidence:** Medium / BROKEN / High (reproduced today)
- **Features:** process-level
- **What is wrong:** Without `--no-parallel` the bundle stopped after 84 tests and made no progress for >10 minutes (`.build/evidence/audit/tests-swift-testing-parallel-stalled.log`); the serial run passes (974/974).
- **Upstream:** -
- **Linux:** Tests/*, upstream suites under the compat main-actor model.
- **Evidence:** This audit, and TODOS.md (run4 deadlock).
- **Root cause:** Unknown: suites waiting synchronously on the main actor and sharing the GPU device are suspected.
- **Required change:** Bisect with `--filter`; mark offenders `.serialized` or fix the main-actor wait.
- **Files:** Tests/, Sources/Compat (main queue pump)
- **Acceptance test:** Parallel run completes within 2× serial time three times in a row.
- **Resolution:** fixed in `9bf048b, d9fea91`. Cause (gdb stacks, `.build/evidence/t19-stacks.txt`): a main-queue render waited on a semaphore for a Task.detached while every concurrency-pool thread waited in DispatchQueue.main.sync; previews now render on the calling thread (9bf048b). The contract then runs Swift tests in parallel and 8 shared-state or self-timing suites serially after (d9fea91): three runs in a row pass 937 + 45 tests and 154 XCTests, 87 s vs 95 s serial (`.build/evidence/t19-3x.txt`); full contract `.build/evidence/full-contract-split.log` exit 0 0

## GAP-TEST-02 — No visual regression testing of upstream panels on Linux (resolved `d00f506`)

- **Severity / status / confidence:** Low / PARTIAL / High
- **Features:** process-level
- **What is wrong:** Upstream's `CompositorUITests/ScreenshotTests.swift` (XCUITest) cannot run on Linux, and no Linux job screenshots every panel. GAP-UI-01…06 were all invisible to the existing 1,122 tests and the native journeys.
- **Upstream:** CompositorUITests/ScreenshotTests.swift
- **Linux:** -
- **Evidence:** This audit.
- **Root cause:** Tests assert behavior through the bridge, not what the renderer draws.
- **Required change:** Done in 6f69273: the `--ui-audit-probe` contract gate runs generic checks (elided text, empty buttons, unresolved symbols) over every tool header, floating panel, sheet and adjustment layer. Remaining: baseline PNG diffs (none yet) and Export As / Search Commands, which the probe does not open.
- **Files:** host/UIAuditJourney.h
- **Acceptance test:** Baseline screenshot diff job.
- **Resolution:** fixed in `d00f506`. LinuxGoldenImageTests: 88 Linux baselines (blend modes, adjustments, filters, effects, transforms, text and shapes) compared within one level a channel, identical on RADV and lavapipe; with the --ui-audit-probe gate (6f69273) and the HiDPI audit runs. Baselines against macOS remain part of GAP-VER-04.

## GAP-UI-01 — New Canvas preset-size menu (⋯) is invisible (resolved `6f69273`)

- **Severity / status / confidence:** Medium / BROKEN / High (runtime screenshot + source)
- **Features:** APP-01, FILE-02
- **What is wrong:** The welcome / New Canvas screen shows no ⋯ button, so the preset sizes (screens and common formats) cannot be reached.
- **Upstream:** `Compositor/UI/NewCanvasSheet.swift:99-125`: `Menu { Picker("Size", …) } label: { VStack { 3 × Circle() } }` (commit `aaf3dc0`).
- **Linux:** `host/SwiftUIQtRenderer.cpp:3495-3517` builds a `QPushButton` for a `Menu` and only takes its label from a first child of kind `Text` or `Image`. A `VStack` of `Circle`s yields no text and no icon, so the button is empty and borderless.
- **Evidence:** `.build/evidence/audit/shots/start-empty.png`, `.build/evidence/audit/shots/welcome-zoom.png` (nothing right of the title); no test or journey references `Preset sizes` / `CanvasPreset` (grep of host/, Sources/, Tests/).
- **Root cause:** Qt renderer recognises label patterns instead of rendering an arbitrary label subtree.
- **Required change:** In the `Menu` branch, when the label is not plain Text/Image, build the label subtree with the existing `buildWidget` path, put it inside a `QToolButton` (or a clickable container) that pops the `QMenu`, and carry the label's `.help`/accessibility label. Respect `.menuIndicator(.hidden)`.
- **Files:** host/SwiftUIQtRenderer.cpp (Menu branch, ~3495)
- **Acceptance test:** New native journey `--new-canvas-presets-probe`: the button with accessible name `Preset sizes` is visible and ≥ 20×20 px; opening it lists every `CanvasPreset.groups` title with Custom checked; choosing one sets Width/Height to its pixels in the current unit; Create canvas produces that size.
- **Resolution:** fixed in `6f69273`. Menu labels of any kind drawn in the button; bare shapes inherit `.foregroundStyle`; compat `PickerTagValues` maps non-enum tags; untyped focused fields follow the model. Probe checks the ⋯ button is visible and drawn, lists upstream's presets, and that Instagram Square sets 1080 × 1080. New compat test `UIAuditCompatTests.testStructTagsSelectTheTaggedValue`. `--ui-audit-probe` passes on the fix build (`.build/evidence/audit/ui-audit.log`, exit 0) and in the full contract run (`.build/evidence/full-contract-uifix.log`)

## GAP-UI-02 — Filter/adjustment slider titles are clipped at 60 pt (resolved `6f69273`)

- **Severity / status / confidence:** Medium / BEHAVIOR_MISMATCH / High for the symptom (screenshots); Medium for the cause
- **Features:** IMG-04, IMG-05, IMG-08, FLT-05, FLT-08, FLT-10
- **What is wrong:** Titles longer than ~60 pt are cut: Color Balance (“Cyan / Re”, “Yellow / B”), Black & White (“Magentas”), Grain (“Roughnes”), Vignette (“Roundnes”, “Highlight”), Scanlines (Line Spacing, Thickness, Displacement, Smoothness, Threshold, Color Split, Black Level), Lens Correction (“Remove I…”).
- **Upstream:** `Compositor/UI/FilterSheet.swift:16-17,191,353-355,423`: every title publishes its natural width through `LabelWidthKey`; the panel uses the widest (commit `0c969af`).
- **Linux:** Hypothesis (not proven by a probe): the compat layout applies the outer `.frame(width: labelWidth)` to the Text before its `.background(GeometryReader…)` is measured, so the reader reports the clipped 60 pt and the preference settles at its own starting value (`max(60, 60)`). Preferences themselves work (`Sources/Compat/SwiftUI/State.swift:229-266`).
- **Evidence:** `.build/evidence/audit/shots/m2.png` (dlg05, dlg08), `.build/evidence/audit/shots/m4.png` (dlg16), `.build/evidence/audit/shots/m5.png` (dlg19), `.build/evidence/audit/shots/m6.png` (dlg21), `.build/evidence/audit/shots/m1.png` (dlg04).
- **Root cause:** Compat layout order for `.fixedSize()` + `.background(GeometryReader)` + `.frame(width:)`.
- **Required change:** Measure a background's GeometryReader against the view it is attached to *before* outer frames (the fixed-size Text's natural width), report that size, re-resolve. Add a compat unit test with the `FilterSheet` label pattern.
- **Files:** Sources/Compat/SwiftUI/Layout.swift, Sources/Compat/SwiftUI/Modifiers.swift (background), host/SwiftUIQtRenderer.cpp (Background/GeometryReader widgets)
- **Acceptance test:** Compat test: three titles of 40/80/120 pt in the FilterSheet pattern resolve `labelWidth` to 120. Native probe: every FilterSheet title label's text width ≤ its widget width (no elision) for all FilterKind panels.
- **Resolution:** fixed in `6f69273`. Unique nested paths per occurrence (`ViewResolver.nestedPath`), background readers of fixed-size content measure the natural size (`BackgroundPlacer`), a changed reader size marks the panel dirty (`GeometrySizes.changedScopes`). Probe: no elided label in any FilterSheet. New compat test `testBackgroundReadersInOneBodyHaveTheirOwnPlace`. `--ui-audit-probe` passes on the fix build (`.build/evidence/audit/ui-audit.log`, exit 0) and in the full contract run (`.build/evidence/full-contract-uifix.log`)

## GAP-UI-03 — CMYK Proof / Gamut Warning pills are not shown on the canvas (resolved `6f69273`)

- **Severity / status / confidence:** Medium / MISSING / High (runtime + source)
- **Features:** VIEW-07
- **What is wrong:** With View › CMYK › Proof Colors (or Gamut Warning) on, upstream shows a pill at the canvas foot naming the mode and profile with a close (×) button. Linux shows nothing; the only way back is the menu.
- **Upstream:** `Compositor/ContentView.swift:96-105` (badges in the canvas ZStack); `Compositor/UI/LayerMaskMenu.swift:35-51` `ProofBadge` → `CanvasPillView`.
- **Linux:** The Qt shell draws the canvas itself and re-creates only the mask-alone pill (`host/SessionWindow.cpp:4241-4300`); there is no counterpart for `ProofBadge` (grep: no `ProofBadge` / `CMYK Proof` in host/ or Sources/LinuxBridge).
- **Evidence:** `.build/evidence/audit/shots/cmyk.png` (both toggles on, no pill), `.build/evidence/audit/shots/cmyk2.png.submenu.png` (Proof Colors checked).
- **Root cause:** Canvas overlays from upstream ContentView are re-implemented one by one in the shell; this one was missed.
- **Required change:** Generalise `ensureMaskAloneBadge` into a stacked pill column fed by `proofsColors`, `showsGamutWarning` and `viewsMaskAlone`, in upstream order (proof, gamut, mask). Title/detail from upstream strings and `proofProfile.name`; close sets the flag false through a bridge command. Or host upstream `ProofBadge` through NativeLowering.
- **Files:** host/SessionWindow.cpp/.h, Sources/LinuxBridge/UpstreamEditor.swift (state: profile name)
- **Acceptance test:** Native: toggle Proof Colors → pill `CMYK Proof · <profile>` visible above the canvas foot; × turns `proofsColors` off and restores unproofed pixels; both on → two pills stacked; with mask-alone → three.
- **Resolution:** fixed in `6f69273`. `SessionWindow::makeCanvasPill` + `updateMaskAloneBadge` stack Proof, Gamut and mask pills; bridge state `proofProfileName`, commands `stopProofing` / `hideGamutWarning`. Probe checks titles, profile name, order and both × buttons. `--ui-audit-probe` passes on the fix build (`.build/evidence/audit/ui-audit.log`, exit 0) and in the full contract run (`.build/evidence/full-contract-uifix.log`)

## GAP-UI-04 — Badged and unmapped SF Symbols render as empty squares in panels (resolved `6f69273`)

- **Severity / status / confidence:** Medium / BROKEN / High for Color Range (screenshot); Medium for the clear button (static)
- **Features:** EDIT-08, SEL-04, IMG-03
- **What is wrong:** Color Range's (and Hue/Saturation's) Add/Remove eyedroppers render as plain squares, indistinguishable from each other. The Keyboard Shortcuts “⊗ remove this shortcut” button (`xmark.circle.fill`) has no mapping either, so it renders as a square.
- **Upstream:** `Compositor/UI/ColorRangeSheet.swift:81-90`, `HueSaturationSheet.swift:111-120` (ZStack of `eyedropper` + `plus.circle.fill`/`minus.circle.fill` badge); `KeyboardShortcuts.swift` (`xmark.circle.fill`).
- **Linux:** `host/LucideIcons.h` has no entry for `plus.circle.fill`, `minus.circle.fill`, `xmark.circle.fill`, `checkmark`, `exclamationmark.triangle`, `printer`; `renderToolVectorIcon` falls back to a 12×12 square outline (`host/SwiftUIQtRenderer.cpp` end of `renderToolVectorIcon`). For a ZStack label the button takes the last Image (the badge), not the composition.
- **Evidence:** `.build/evidence/audit/shots/m6.png` (dlg24 Color Range: eyedropper, □, □).
- **Root cause:** Icon table generated for a fixed symbol list; badge composition not supported.
- **Required change:** Add Lucide equivalents in `scripts/gen-lucide-icons.py` (circle-plus, circle-minus, circle-x, check, triangle-alert, printer, eye) and regenerate. In the Button/Menu label path, compose a ZStack of Images (base icon + offset badge at the badge's font size). Add a check that every symbol literal in `Compositor/` resolves (fail the build otherwise).
- **Files:** scripts/gen-lucide-icons.py, host/LucideIcons.h (generated), host/SwiftUIQtRenderer.cpp
- **Acceptance test:** Unit: all SF Symbol literals under Compositor/ resolve in `lucideIconSVG`. Native: Color Range buttons render three different pixmaps; Keyboard Shortcuts while recording shows a visible remove button that clears the chord.
- **Resolution:** fixed in `6f69273`. 12 symbols drawn in `third_party/lucide/custom/`; `renderToolVectorIcon` composes `base|badge=`; `gen-lucide-icons.py --check` (in `check-upstream-clean.sh`) fails on any unmapped upstream symbol. Probe: Color Range eyedroppers draw three different pictures; no unresolved symbol recorded. `--ui-audit-probe` passes on the fix build (`.build/evidence/audit/ui-audit.log`, exit 0) and in the full contract run (`.build/evidence/full-contract-uifix.log`)

## GAP-UI-05 — AppKit symbol images missing in the Layers list (resolved `6f69273`)

- **Severity / status / confidence:** Low / PARTIAL / High for adjustment thumbnails (screenshot); Medium for cursor (static)
- **Features:** LAY-15, LAY-18, ADJ-01
- **What is wrong:** Adjustment-layer thumbnails are blank for Exposure (`plusminus.circle`), Add Noise (`circle.dotted`), Black & White (`circle.filled.pattern.diagonalline.rectangle`) and Color Balance (`scale.3d`). The Option-over-mask duplicate cursor loses its eye (`eye.fill`).
- **Upstream:** `Compositor/Document/LayerAdjustment.swift:10-25`; `Compositor/UI/NativeLayerList.swift:624,1181`.
- **Linux:** Compat `NSImage(systemSymbolName:)` (`Sources/Compat/AppKit/Image.swift:82`) resolves through the same Lucide table; unmapped names draw nothing.
- **Evidence:** `.build/evidence/audit/shots/ac.png` (Exposure row: empty thumbnail frame).
- **Root cause:** Same symbol table gap as GAP-UI-04.
- **Required change:** Same table additions (plus-minus circle, circle-dashed/dotted, contrast/half-pattern, scale), regenerate.
- **Files:** scripts/gen-lucide-icons.py, host/LucideIcons.h
- **Acceptance test:** Native: add each of the 12 adjustment kinds; every row thumbnail has non-transparent pixels.
- **Resolution:** fixed in `6f69273`. Same symbol additions; the probe adds every adjustment kind and records no unresolved AppKit symbol. `--ui-audit-probe` passes on the fix build (`.build/evidence/audit/ui-audit.log`, exit 0) and in the full contract run (`.build/evidence/full-contract-uifix.log`)

## GAP-UI-06 — Camera Raw histogram/vectorscope is drawn tiny with a large empty band above (resolved `6f69273`)

- **Severity / status / confidence:** Medium / BEHAVIOR_MISMATCH / High (screenshot + source)
- **Features:** FLT-11
- **What is wrong:** The scope at the top of the Camera Raw column is ~80×28 px under ~240 px of empty space; upstream draws it the column's full width and 110 pt tall, with the clipping triangles at its corners.
- **Upstream:** `Compositor/UI/CameraRawControls.swift:34-60` (`graph(...).frame(height: 110)` in a ZStack).
- **Linux:** Compat layout of the ZStack (fixed-height graph + HStack of clip buttons) inside the scroll column.
- **Evidence:** `.build/evidence/audit/shots/m7.png` (dlg22, floating Camera Raw panel). The `Qt Camera Raw docking smoke` journey checks panel geometry, not the scope.
- **Root cause:** Compat ZStack sizing: the fixed-height child does not set the stack's height / width is not expanded.
- **Required change:** Fix ZStack sizing (max of children, `.frame(height:)` honored, flexible width) and add a compat layout test.
- **Files:** Sources/Compat/SwiftUI/Layout.swift, host/SwiftUIQtRenderer.cpp (ZStack)
- **Acceptance test:** Native: Camera Raw open on a RAW layer → scope widget width ≥ column width − 2·padding, height 110 ± 1; no empty band > 8 px above it.
- **Resolution:** fixed in `6f69273`. `SwiftUIZStackWidget` honors children's minimums and flexibility; `fixedSize(horizontal:vertical:)` fixes only the requested axes. Probe: scope ≥ ¾ column width, ≥ 100 pt tall, no band above it. `--ui-audit-probe` passes on the fix build (`.build/evidence/audit/ui-audit.log`, exit 0) and in the full contract run (`.build/evidence/full-contract-uifix.log`)

## GAP-UI-08 — Command palette is a Qt re-implementation with small UX differences (resolved `c5ed205`)

- **Severity / status / confidence:** Low / BEHAVIOR_MISMATCH / High (source)
- **Features:** VIEW-01
- **What is wrong:** Placeholder “Type a command to run...” instead of “Search commands and tools”; shortcuts appended inline instead of right-aligned; no “No commands match” empty state. Entries, ranking and toggles come from upstream (`CommandPaletteTests` pass).
- **Upstream:** `Compositor/UI/CommandPaletteView.swift:13,36,54-60`.
- **Linux:** `host/SessionDialogs.cpp` `CommandPaletteDialog` (lines ~3-70 of its constructor).
- **Evidence:** Source comparison; capture via menu timed out because the dialog is modal (`logs-dlg27.txt`).
- **Root cause:** Palette drawn by Qt rather than by upstream's view.
- **Required change:** Render upstream `CommandPaletteView` through the SwiftUI bridge, or match its text, empty state and two-column row layout in the Qt dialog.
- **Files:** host/SessionDialogs.cpp, host/EditorDialogs.h
- **Acceptance test:** Native: palette with query `zzzz` shows `No commands match`; a row with a shortcut renders it in a right-aligned column.
- **Resolution:** fixed in `c5ed205`. Palette drawn as upstream's view: placeholder, `No commands match` overlay, right-aligned shortcut column, checkmark column, accent selection, click runs. `--preview-smoke` asserts placeholder, empty state and shortcut column; passes in `.build/evidence/full-contract-batch.log` (exit 0 0)

## GAP-UI-09 — Window menu has Minimize and Zoom only (resolved `9e21ce2`)

- **Severity / status / confidence:** Low / LINUX_EQUIVALENT / High
- **Features:** APP-10
- **What is wrong:** macOS adds Fill/Center/Bring All to Front and the window list automatically; Linux shows two items. Window switching is the desktop's job on Linux; acceptable unless multi-window projects need a list.
- **Upstream:** AppKit default Window menu (no upstream code).
- **Linux:** Sources/LinuxBridge/AppMenus.swift
- **Evidence:** `.build/evidence/audit/shots/menus2.png`.
- **Root cause:** Platform convention.
- **Required change:** Optional: add the project windows list.
- **Files:** Sources/LinuxBridge/AppMenus.swift
- **Acceptance test:** -
- **Resolution:** fixed in `9e21ce2`. Window menu: Minimize, Zoom, Bring All to Front, then the checked window entry, as AppKit completes it; `--app-visibility-probe` checks the items and that Bring All to Front restores a minimized window; passes in `.build/evidence/full-contract-batch.log` (exit 0 0)

## GAP-UI-10 — Transform bar Sampling picker text truncated (“High qual”) (resolved `6f69273`)

- **Severity / status / confidence:** Low / BEHAVIOR_MISMATCH / High (screenshot)
- **Features:** TRF-06
- **What is wrong:** The pop-up is 170 pt wide upstream and shows “High quality”; Linux elides it.
- **Upstream:** `Compositor/UI/TransformInspector.swift` (`Picker("Sampling"…).frame(width: 170)`).
- **Linux:** Qt combo inside the frame: label + popup share the 170 pt, the label takes part of it.
- **Evidence:** `.build/evidence/audit/shots/headers1.png` (v).
- **Root cause:** Labelled Picker width split.
- **Required change:** Give the popup the frame width minus the label's natural width, as AppKit does.
- **Files:** host/SwiftUIQtRenderer.cpp (Picker)
- **Acceptance test:** Native: no elided text in any tool header combo.
- **Resolution:** fixed in `6f69273`. Combo right padding no longer double-counts the drop-down. Probe: no elided pop-up text. `--ui-audit-probe` passes on the fix build (`.build/evidence/audit/ui-audit.log`, exit 0) and in the full contract run (`.build/evidence/full-contract-uifix.log`)
