# Tasks: Mac compatibility on GNU/Linux

Current checkpoint: **2026-10-11**, `GNU_Linux` at merge `74dbacf`; protected source `39d1257`. The audited upstream catch-up is merged and adapted.
This list includes Claude's uncommitted work. Checked items mean the stated implementation
exists; verification is recorded separately. Historical results below are not proof that the
current working tree has passed the complete suite or matches all Mac behavior.

## Recent implementations

- [x] Merge current upstream into GNU/Linux (`74dbacf`); protected Mac trees match `upstream/main`.
- [x] Generate AppKit/Objective-C UI adaptations from upstream (`6ae0455`, `57952fd`). Qt renders upstream native views through compat `NativeLowering`.
- [x] Run SliderSnap, CameraRawSlider and CommandPalette suites on Linux (`8af1f52`).
- [x] Run upstream LayerTests through a selector-only mirror, and CursorTests against the upstream layer table (`18369f4`).
- [x] Run FloatingPanelTests using a lazy Swift test-host window (`3d961dd`).
- [x] Use upstream shortcut configuration for Qt menus; render the tool rail from session state. Native combination coverage still needs the task below.
- [x] Complete the outside review. Findings: [October 11 review](docs/reviews/codex-outside-review-2026-10-11.md). Resolving its findings is separate work.
- [x] Extend integrity protection to `CompositorUITests/` and `Compositor.xcodeproj/`; require shader verification in CI. **Uncommitted; local `check-upstream-clean.sh` passed on October 11.**

## In progress

- [ ] **P1: color management.** Import-profile conversion and export tags follow upstream's 8-bit sRGB document contract. **October 11: fixed a rejected BT.709 lookup table (which left HEIF incorrectly linear), and recovered gray PNG ICC profiles that Qt drops when expanding alpha to RGB.** Independent native fixtures verify gray/gray-alpha at 8/16 bits, RGB alpha, P3, truly untagged PNGs, 8/10/12-bit HEIF BT.709/linear/sRGB, ICC precedence and decoded export profiles (PNG/JPEG/TIFF/WebP/HEIF). The contract runner requires these checks, including HEIF support. Gray-alpha TIFF import now uses libtiff before 8-bit reduction: independent fixtures verify 8/16-bit ICC conversion and alpha, byte order, compressed strips/tiles, separate planes, associated/straight alpha, inverted grayscale, BigTIFF, orientation/DPI and truncated-data rejection. The old Qt TIFF path fails the new pixel check. CMake and Swift host links include libtiff (CMake minimum 4.5). HDR/PQ/HLG, floating-point TIFF and actual Mac comparison still need verification.
- [ ] **P1: finger-touch support.** The application-owned input filter has no window captures; enlarged transform hit areas preserve upstream handle drawing. **October 11: geometry and native synthetic-event checks passed**, including Qt/system/application synthesized mouse events after touch and pen, explicit pen metadata, real-mouse restoration and touch in a second window followed by its destruction. The regression check fails with the old filter. Physical touchscreen/tablet and native Wayland verification remain pending.
- [x] **P1: current full-suite baseline.** Final October 11 unfiltered runner at protected `39d1257` passed **869/869 tests, 0 runtime skips** (121 XCTest; 748 Swift Testing in 122 suites), all nine coverage checks and native kernel/backend/editing/RAW/text journeys. Required-shader integrity is clean. The former 856-test checkpoint predates this catch-up. See `docs/upstream-test-baseline.md` and `/tmp/compositor-upstream-catchup-full-contract-verified.log`.
- [x] **P1: upstream initial-canvas history.** Removed the Linux history patch, override and manifest/exclusion entries; generator rejects stale copies. The native Qt journey checks Undo to the welcome screen and immediate Redo, including exact pixels, layer selection and modified state. Both original upstream history failures now pass, followed by the full unfiltered suite and 78-test contract run. Protected Mac sources and tests remain unchanged.
- [ ] **P1: full compatibility inventory.** Audit current adapters, overrides, declared deviations and test exclusions against upstream `39d1257`. Source inclusion is now completely accounted for against evaluated SwiftPM targets; behavioral/API coverage still requires audit. Distinguish implemented, behaviorally verified, necessary platform adaptation and unresolved gaps. Corrected obsolete pinned-menu and canvas-replacement descriptions. Color Range and menu generation read protected tip. The 1.3.1 element inventory is now explicitly marked historical; its statuses still need a current behavior audit.

## Remaining closeout tasks

- [x] **P1: four newly fetched upstream commits.** Merged `9a0ad3e`, `248d4d4`, `23913d3` and `39d1257` as `74dbacf`. Blur alpha APIs/settings, LibRaw noise/highlight capabilities/defaults/reset and PatchMatch SwiftPM/CMake wiring are implemented. Lens correction remains disabled with an honest explanation. Fixed modified SwiftUI Groups dropping all siblings after the first; the actual RAW sheet regression covers every control. Native fixtures cover PatchMatch failures/strides and real RAW pixels; native editing covers transparency and queued warp strokes. LibRaw’s uninitialized OpenMP wavelet allocation count is patched in both dependency build paths. See `docs/current-linux-compatibility-inventory.md`.

- [x] **P1: current source-coverage enforcement.** The SDK runner evaluates actual SwiftPM targets and checks all 151 upstream Swift files (124 unchanged, 20 generated, 5 replaced, 2 platform substitutions), plus 80 unchanged upstream test files and one selector mirror. Nine coverage checks include seven injected omissions/duplicates/false declarations and two valid controls. Removed false canvas/cursor/sampling replacement classifications and clarified the broader Smudge/Liquify transformation. The complete 856-test runner passed with the new gate and native journeys. See `docs/current-linux-compatibility-inventory.md`.
- [x] **P1: latest upstream folder imports.** Merged `0a5c8d9` and `b2a0c45` as `83a8cd5`; regenerated adaptations. The two new folder tests run unchanged. Native import supports mixed file/folder selections, duplicate/removal handling and name-ordered direct-child import through the upstream model. Native preview and the full 856-test runner pass. Real desktop portal directory grants still require verification.
- [x] **P2: latest narrow-panel runtime adaptation.** Qt Layers dock resizes within upstream 222–352-point bounds; its width drives the unchanged LayersPanel body and persists as UI state. Native custom pop-up sizing supplies its minimum width. Three model regressions and 42 focused hosting/scroll/width tests pass. Native preview verifies both endpoints, contained controls and a pointer-driven splitter drag without pixel or Undo changes. The old fixed-width dock fails the new regression. The final full 856-test runner and native journeys pass. Real desktop and Mac screenshot comparison remain unverified.
- [ ] **P2: intermittent native combination timeout.** The initial width-change full run passed all 856 framework tests, then timed out after selection/gradient Undo. The same binary passed a standalone rerun; the full runner passed after adding precise action/session diagnostics. The timeout is unexplained. Evidence: `/tmp/compositor-full-contract-panel-width.log`, `/tmp/compositor-panel-width-combo-recheck.log`, and `/tmp/compositor-full-contract-panel-width-final.log`.
- [x] **P1: confirmed Smudge/Liquify parity failures.** Ordered input segments retain the original interpolation across frame budgets; release drains pending dabs and uses unchanged upstream commit coverage/sampling. All five WarpCommitParityTests methods (14 cases) pass against the generated unchanged upstream oracle, including selection/transforms, canvas edges, changed-target refusal and exact Undo/Redo. The original failure log remains `/tmp/compositor-warp-commit-before.log`; corrected focused evidence is `/tmp/compositor-upstream-catchup-native-contract.log`.
- [x] **P1: pending gradient completion.** Both automatic resolution and explicit Apply reject busy, failed and changed-target commits before dispatching dependent commands. `PendingGradientTests` exercises allocation failure, busy retry, undo order and a held raster worker (including a target changed during rendering). **October 11: release `--no-parallel` run passed 38 tests across PendingGradientTests, ToolCombinationTests and UpstreamEditorTests, with Skia and ImageIO libraries configured.** Slow operations remain awaited to completion, avoiding a late write after timeout.
- [x] **P1: contract CI renderer provisioning.** Both contract and weekly workflows build the manifest's pinned dependency modules, then `scripts/linux-contract-tests.sh` builds Skia/ImageIO, requires a successful native backend smoke, installs Camera Raw resources and runs tests plus `--combo-smoke`. The per-push job includes all HistoryTests; the weekly job has no per-test skips. **October 11: the runner passed locally through `flatpak-builder --run`: 85 Swift Testing tests plus 5 XCTest color/import tests, all 6 native combinations, synthetic touch-device journeys and native color/profile/font cases plus GUI text smoke. The updated runner then passed the full unfiltered 824-test suite and native preview journey locally.** A fresh hosted CI dependency build has not been executed.
- [x] **P1: native tool combinations.** `--combo-smoke` uses visible rail clicks, canvas press/drag/release and Qt's platform key path. It verifies selected-pixel moves, transforms, selected text/local Undo, gradient auto-commit, exact outside-selection pixels, document Undo/Redo and refused switches/recovery. The runner invokes it in Linux CI; existing tests remain unchanged. **October 11: all 6 journeys passed, alongside existing `--transform-smoke` and `--dialog-smoke`.** It exposed and fixed stale menu accelerators by validating on ShortcutOverride before Qt matches a key equivalent.
- [ ] **P2: refusal behavior.** Bridge failures now go to diagnostics rather than status-bar error text. Native active-brush refusal and subsequent recovery passed through both a bridge command and a real shortcut. Audit the remaining busy/import/modal recovery paths before claiming all refusals match upstream.
- [x] **P2: integrity diagnostics.** The guard collects protected-tree, generator, shader, drift and ledger failures and exits nonzero after all checks. **October 11: required-shader clean run passed; injected Python failures reported all 13 failing checks and returned 1.** Missing manifest/reference remains an initial prerequisite error.
- [ ] **P2: truthful ledger evidence.** Ledgers now classify macOS-only UI tests, original tests and selector mirrors correctly; retired format-11 copies no longer count as extra evidence. The gate rejects missing test suites/methods, smoke options and journey anchors; the Evidence scope column distinguishes references and source checks from run results. Manual/screenshot claims and the feature coverage of each referenced test still need review. Generated equality or reference existence is not behavioral proof.
- [x] **P2: retire duplicate test mirrors.** Removed the four legacy format-11 copies; the generator rejects stale adaptations when tip already owns format 11. Original upstream suites and the Linux fixture helper remain. **October 11: all 40 tests across TypeToolTests, GroupTests, LayerMaskTests and LayerAppearanceTests passed in release, followed by native combination/touch journeys.**
- [ ] **P2: hosting measurements.** Fitting covers frames, padding, stack spacing/priority, native intrinsic/custom sizing and renderer-backed text/control sizes. Ideal metrics honor sizing options; enabled minimum/maximum metrics generate required dimension bounds before parent layout, including unbounded responses and root/option updates. The compatibility window model applies hosting content limits, restores explicit limits on unknown/disabled axes, enforces `setContentSize`, fills content on explicit frame changes, and cleans up ownership when content is replaced or moved. **October 11: all 33 hosting tests passed in the full 856/856 run**, plus native Qt measurement/generated-limit/window-model probes and all existing native journeys. Four dimension-bound regressions also pass. Protected Mac trees remain unchanged. Native scroll views now synchronize Qt viewport/document sizes and offsets, preserve manual positions across updates, reveal selections and defer reveals until a usable viewport exists. Six regressions pass; the native preview verifies short-table viewport filling and a 25-layer selection/manual-scroll journey without document edits. Window-manager forwarding of compat limits, positional/soft constraints, broader scroll fitting/wheel/autoscroll/keyboard behavior and SwiftUI/Qt text-layout parity remain open. Details: `docs/upstream-test-baseline.md`; latest log: `/tmp/compositor-full-contract-panel-width-final.log`.
- [x] **P2: system-font traits.** System factories retain all nine weights, fixed pitch and tabular digits through native text callbacks and SwiftUI lowering. Native text and Qt controls share the corrected weight mapping (semibold before bold; ultraLight/thin in increasing order). Three Swift checks include the actual upstream mask badge font; independent native metadata checks cover all weights/features. The GUI text smoke verifies regular/semibold glyph pixels differ and measurement matches drawing. Both native checks run in CI. The old Qt parser fails the regression; the final exact unfiltered runner passed **819/819** framework tests and all native journeys. Evidence: `/tmp/compositor-full-contract-system-fonts.log` and `/tmp/compositor-font-traits-regression.log`.
- [x] **P2: named/bundled font forwarding.** Named AppKit fonts carry their full names through lowering; native text, custom text and picker faces resolve aliases from installed font metadata. Swift accepts bundled Inter and reopened monospaced factory names. App/native journeys share UI-font setup, and system-text measurement uses the selected UI font. Three new Swift checks passed, along with actual Inter alias glyph/bounds equivalence and a regression that rejects the old regular-only full-name resolver. The final complete CI runner passed **822/822** framework tests and all its native checks; protected Mac trees remain unchanged. The native preview journey now also passes mixed-font picker changes, Unicode selection, formatting Undo/Redo and save/reopen.
- [ ] **P2: native view completeness.** Audit upstream-used AppKit text, layer, focus, keyboard and accessibility behavior. Implement observed missing paths; do not treat a compiled no-op API as verified compatibility. Named/custom-font lowering is implemented below. Reused layer cells lost internal constraints when detached from their table; subtree removal now preserves those constraints. The reused-mask regression and actual native layer/folder Shift-click, mask transforms, pixel drags and text/font-picker journey pass. The CI runner includes `--preview-smoke`; default Up/Down row selection now sends notifications and reveals rows; Shift-arrows extend/contract and reset stale anchors after selection changes or row removal. Five keyboard regressions pass, including three original failures and native-discovered plain-to-Shift navigation. The native Qt platform-key journey verifies selection without an Undo step and the upstream Move-tool override's exact one-pixel nudge. Native API coverage, remaining table keys/type selection, disjoint-selection semantics and broader focus/accessibility behavior still need auditing. Log: `/tmp/compositor-full-contract-table-keyboard-bounds.log`.
- [ ] **P3: broader historical acceptance claims.** Current catch-up inventory, baseline, ledgers and parity manifest are reconciled with the final 869-test/native run. Earlier closeout-plan and platform-abstraction claims still need a broader behavior audit.

## Validation requiring another platform or device

- [ ] Real macOS → Linux → macOS project round trip and corresponding screenshot comparisons. Linux fixture generation/comparison exists; actual Mac execution remains required.
- [ ] Physical touchscreen/tablet and native Wayland input checks. Automated/offscreen journeys do not certify physical-device behavior.

## Historical tasks and evidence

- **Color management**: in progress; see the current list above. Upstream importer/exporter establish the 8-bit sRGB contract.
- **Command palette**: Qt host Command Palette (`Ctrl+Shift+P` / `F1`) implemented with fuzzy action search, keyboard navigation, and smoke verification. (DONE)
- **Finger-touch large-target mode**: in progress; see the current list above.
- **Crash-recovery autosave implementation (R61)**: Periodic background autosave snapshot (`autosave.comp` + `autosave.info`), startup recovery check, recovery restore, and clean shutdown clearing implemented and smoke verified. (DONE)
- **HEIC and TIFF import**: TIFF through Qt's image plugin, HEIC/HEIF/AVIF through libheif (`host/QtImageIO.cpp`), both read by the ImageIO compat layer an import goes through; `Tests/CompatTests/HeicTiffImportTests.swift` checks size, orientation and pixels. (DONE)
- **Research-risk features** (Content-Aware Fill, Remove Background, Liquify, Lens Correction, Healing): upstream ships all five and Linux compiles them from tip (PatchPixels/HealPixels/LensPixels kernels, SmudgeLiquify, U²-Net for Remove Background). (DONE)
- **Cancelled new adjustment sheet discard (R26)**: Discard/undo newly created adjustment layer on dialog rejection implemented and smoke verified. (DONE)
- **Layers tree multi-selection (R22)**: `ExtendedSelection` in `m_layersView` + multi-layer selection deletion implemented and smoke verified. (DONE)
- **Stage 4 & 5 (CoreGraphicsCompat Shim & Skia Raster Backend)**: historical implementation checkpoint (`3d617c7`, `39f1d88`, `02a8178`, `835a7f0`). 22 canvas ops mapped to Skia C ABI, dynamic `.so` loader, parity tests and `COMPOSITOR_RENDERER=skia|swift` switch verified at that checkpoint. This is not a current all-compatibility completion claim.
- **README / Manifest alignment**: Resolved (updated README to KDE 6.11 and swift6//26.08 matching `com.compositor.Client.yaml`).
- **Stages 0–12 verification**: historical result was 426/426 Swift tests, 6/6 CTest tests and 5/5 Qt smoke modes. Current upstream and working-tree verification are tracked above.

## Linux port: upstream catch-up and tool combinations (from /autoplan 2026-10-09)

### Linux `swift test` CI job (DONE: `.github/workflows/linux-swift-tests.yml`, every push to GNU_Linux; the effects parity suite is `LayerEffectsBackendTests`)
**What:** Add a workflow next to `.github/workflows/ci-guard.yml` that runs `ToolCombinationTests`, `EffectsRecolorParityTests` and `UpstreamEditorTests` in the Flatpak Swift SDK.
**Why:** The tool-combination contract only holds if something runs it on every push; today no workflow runs Linux Swift tests.
**Context:** ci-guard runs only `check-upstream-clean.sh` and the audit. Swift builds only in the Flatpak SDK (see memory linux-port-swift-sandbox-verify).
**Effort:** M
**Priority:** P2
**Depends on:** commits 1 and 4 of docs/upstream-1.4.8-catchup-and-tool-combos-2026-10-09.md

### Table-driven Qt accelerators (DONE)
**Resolution:** the menu bar is upstream's commands (`syncAppMenus`), whose shortcuts come from `configuredKeyboardShortcut`, i.e. the
shortcut table; the shell's own menus are hidden and stripped of their shortcuts at install, and single keys go to the
canvas through `ShortcutSettings.canvasEvent`. Saving in Keyboard Shortcuts now re-reads the menu bar at once.
**What:** Build Qt `QAction` shortcuts from the generated `KeyboardShortcuts` table instead of hard-coded `QKeySequence`s in `host/SessionWindow.cpp`.
**Why:** Shortcuts re-recorded in Settings don't change Qt accelerators; the key-parity smoke only catches defaults.
**Context:** ~77 hard-coded sites. Recorded as a deviation in `linux/upstream-parity.json`.
**Effort:** L
**Priority:** P3
**Depends on:** gen-keyboard-shortcuts.py

### Tool rail as a pure view of session state (DONE)
**Resolution:** the rail is upstream's ToolRail (SwiftUI), drawn from the session. `m_tool` is a documented mirror, written only
by `applyToolLocally` with the session's reported tool; `requestTool` decides from the session's tool, not the mirror.
**What:** Make the Qt rail render only from `sessionState().tool` with no local tool state.
**Why:** Structurally prevents "rail shows X, session in Y".
**Context:** Trigger: the first `--combo-smoke` rail/session mismatch. `applyToolLocally` already mirrors; the rewrite removes `m_tool` as authority.
**Effort:** L
**Priority:** P3
**Depends on:** --combo-smoke

### Retire remaining hand overrides behind AppKit/Metal (DONE 2026-10-11)
**Resolution:** every Compositor/UI file is tip-generated (scripts/gen-objc-overrides.py, scripts/gen-patched-overrides.py);
the Qt shell draws AppKit representables through compat SwiftUI NativeLowering. MetalBrushCoverage, MetalLayerEffects,
MetalWarp, GPUCanvas and GPUNoise stay replaced: their job is Metal itself, done on Linux by the CPU/Vulkan backends.
**What:** Convert NativeLayerListOverride, UIStandIns, CameraRawSlider, MetalBrushCoverage to generated or tip-compiled forms where the compat layer allows.
**Why:** Every hand override needs drift policing; generated ones don't.
**Context:** ContentView, LayerMaskMenu and KeyboardShortcuts move to generators in this plan.
**Effort:** XL
**Priority:** P4
**Depends on:** compat-layer AppKit coverage

### Codex outside review for this plan (DONE 2026-10-11; findings remain open)
**What:** Outside review of the CEO, design, DX and engineering angles completed after quota became available.
**Why:** The October 9 review lacked an outside voice. The completed review found six acceptance/correctness gaps.
**Context:** [Review](docs/reviews/codex-outside-review-2026-10-11.md); remaining findings are listed above.
**Effort:** S
**Priority:** P3
**Depends on:** no quota blocker; resolving findings requires implementation and runtime evidence.
