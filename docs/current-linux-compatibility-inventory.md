# Current Linux compatibility inventory

Current source inventory: **2026-10-16**, `GNU_Linux` HEAD `94cf71e`, merging
protected `upstream/main` **`365b574`** (1.5.3). Linux adaptations remain
uncommitted, including untracked files. The latest complete canonical checkpoint
passes **147 XCTest + 956 Swift Testing tests (1,103 total)**, all 34 host-native
commands and both standalone gates (36 total), required backends and coverage:
`/tmp/compositor-deep-size-full-contract.{log,exit}` (session 87491, exit 0).
Protected-source/generator/shader/ledger integrity passes in its companion log.
It includes Image Size/deep-sizing and explicit menu ownership, and predates the
common-entry/popup and Wayland clipboard corrections. The entry/popup build
separately passes 1,108 framework tests and affected native regression journeys;
its 36-gate session 25384 later exits 139 in transform smoke; the crash log is retained. The fresh clipboard contract (84680)
stopped during compilation because the ownership test changed while building.
The lifecycle follow-up now pins all close-time callbacks and deferred requests
to the closing handle. All 17 focused checks and integrity pass in session 47641;
all 1,109 framework tests, four native journeys and integrity also pass in
session 54499 (exit 0). A fresh complete current-source run is session 61973 in
`/tmp/compositor-crash-recovery-build`, with logs at
`/tmp/compositor-close-owner-full-contract.{log,exit}` (pending, predating the newer alert correction). The alert audit separately
reproduces an explicit background-project sheet appearing on the active window.
Its session-aware presenter and missing visibility/mask synchronization guards
pass 29 focused checks and integrity in isolated sessions 7169/31538. Native
project-close passes both window directions and reuse after newer-window close
in session 91888 (exit 0), and native Wayland also passes all three cases with
correct transient parents (83228, exit 0). Full regression passes all 1,113
framework tests, four native journeys and integrity in session 51706 (exit 0).
The complete alert-build contract, session 45852, now exits 0 at
`/tmp/compositor-alert-owner-full-contract.{log,exit}`: all 36 gates, 1,113
framework tests and required integrity pass. It predates the file-panel adapter.
See [the baseline](upstream-test-baseline.md).
The newer file-panel adapter fixes wrong Open parenting and Save/Save As silently
cancelling without a chooser. The `.comp` type registration, legacy callback,
path/options transport and ownership pass 35 focused checks; all 1,119 framework
tests, four native regression journeys, actual 14-case file workflow and integrity
also pass. Real Save As/replace/reopen retain exact pixels and layer records.
The final 16-case producer workflow also opens two distinct projects selected as
package rows, with exact independent pixels/records; it passes offscreen/native
Wayland with correct transient parents. The permanent Qt chooser test passes
seven visible scenarios. Fresh full 37-gate session 83638 is pending; the three
older 36-gate runs predate this work. Alert-build session 45852 now passes all
36 gates and integrity; entry/popup session 25384 exits 139 in transform smoke;
teardown session 61973 remains pending. A later native-only preview fails after
Home leaves rows 2/8 outside the viewport; that failure is retained for isolation.
See the newest baseline for passing and failing scopes.
This combined checkpoint includes pointer/cursor, transform-snapping, Motion
Blur, Image adjustment controls, native panel lifecycle, all 54 effect-control
cases and all 26 nesting/Alt-copy cases, including collapsed folders,
cross-folder selection and stationary-pointer autoscroll at both edges.

Later Hide and popup follow-ups pass all 1,100 framework tests, four Hide cases
on each of Qt offscreen/native Wayland, Grid Settings controls/forced popup
refresh/restart, eight Clear cases, native preview and required integrity:
`/tmp/compositor-grid-popup-fixed.exit` is 0 (session 48896). Floating tools retain
their edits across minimize/activation even when Wayland clears the minimized
state bit; open combo popups retain their owning controls without a mouse grab.
The later 34-gate contract completed in session 94463 (exit 0) at
`/tmp/compositor-hide-panels-full-contract.log`; its required integrity also
passes. It includes Hide/popup fixes and predates the numeric-field change. See the newest baseline sections
for scope and evidence.

The later Canvas Size correction adds live numeric validation and linked-field
refresh, 36 visible unit/anchor cases and nine retained-crop cases. All 1,100
framework tests and native Grid/transform/scrub/dialog/preview regressions pass;
`/tmp/compositor-canvas-size-regression.exit` is 0. The preceding 35-gate contract
completed in session 66977 at `/tmp/compositor-canvas-size-full-contract.log`
(exit 0, including integrity).
The older session 94463 predates this numeric-field change.

Image Size now passes six print-only edits, eight unit/aspect resampling cases,
two print-unit DPI resizes and Cancel/validation through its visible upstream
sheet. Independent every-pixel oracles, retained records/identity and single
Undo/Redo pass in `/tmp/compositor-image-size-native.log` and the native Wayland
companion `/tmp/compositor-image-size-wayland.log` (both exit 0). The owned
headless compositor is stopped afterwards. Required integrity passes. The canonical runner now has 36 gates; session 66977 remains
the preceding 35-gate run and has passed all 1,100 framework tests. The separate
Image Size probe uses an isolated executable and leaves both live contract
binaries untouched. See the latest baseline for exact scope.

Deep sizing now adds 16-bit PNG and HDR EXR print-only/resample/crop-retention
checks, with partial alpha and saved deep-channel oracles. This exposes and fixes
queued menu requests being consumed by another window and losing their owner
across asynchronous tasks. Explicit Qt session dispatch, task-local ownership,
scoped queues and live session-to-window sheet/repaint routing pass both window
directions and older-window reuse after newer-window destruction. All 41 focused
tests and integrity pass; two offscreen profiles and native Wayland each pass
all 24 sizing/ownership markers, and Wayland passes four Hide cases. The full
framework/six-native regression wrapper exits 0 in session 34499 (1,103 tests
and integrity pass). The 36-gate contract completes in session 87491 (exit 0)
at `/tmp/compositor-deep-size-full-contract.log`, including integrity. The completed 35-gate session
66977 predates this fix; the baseline records failing and passing scopes.

The common-input/popup follow-up reproduces unowned SwiftUI requests, stale popup
choices after owner close, wrong replacement/dismissal context and main-queue
reentry crashes. `withEntry` now binds the supplied handle, `onMain` recognizes
the main dispatch queue even on a Linux worker, and popup validation/choice/
completion retain the presentation owner. Owner close cancels its popup first.
All 12 focused tests, all 1,108 framework tests, seven affected offscreen native
journeys and required integrity pass across the recorded checks. Grid controls
and persistence use the actual enabled validation state and the normal-startup
helper. Native Wayland sizing passes all 24 markers. Full preview and normal-startup
dialog now pass with a private input-capable Weston/Xvfb setup. A separate image
clipboard probe exposes delayed own-write notifications invalidating retained
selection origin; MIME-object ownership now passes the real-input Wayland image
journey and replacement-image regression (see the newest baseline).
The current full 36-gate contract is running as session 25384 at
`/tmp/compositor-entry-owner-full-contract.log`; older session 87491 predates
this common-entry/popup correction. See the latest baseline for failed and
passing scopes, including corrected driver assumptions.

The close-time lifecycle follow-up reproduces disappearance callbacks and their
deferred requests being attributed to a surviving caller. Complete teardown now
binds the closing handle; requests created after entry removal are rejected and
the caller context is restored. All 17 focused ownership/lifetime/popup checks
and required integrity pass, followed by all 1,109 framework tests and native
preview, tabs, dialogs and clipboard/replacement journeys (session 54499, exit 0).
This verifies the lifecycle boundary, not a claim that an upstream disappearance
callback currently invokes Save/Export. The current complete run is session 61973;
see the newest baseline.

The table has **90 rows: 3 Implemented / 87 Adapted**, each limited to its stated
scope. The Canvas/Image Size row records visible sizing and live-field
evidence; earlier follow-up notes retain the row counts of their checkpoints.
Native panel UUID scopes/close cleanup prevent reopened sessions from
using old coordinators; stepper callback release breaks a view retention cycle.
The current nesting probe additionally reproduces stale rows within a live
session before first paint: ordinary left/right presses now synchronize the
native coordinator before hit testing, as keys/accessibility already do. The
same stale pre-press cache and pointer sequence now pass. Nesting/copy checks
cover exact records/parents/IDs/order, source isolation, independently calculated
translucent pixels and one-step Undo/Redo. The complete contract also passes all
16 two-window disjoint-selection rounds and the full preview/mask journey.

The precise cause of the older intermittent Command-click and valid-target mask
failures remains unproven; the reproduced stale-row drag defect is recorded
separately. A later focused run passes 26 nesting/copy cases, adding collapsed
sources/targets, cross-folder selections and stationary-pointer autoscroll in
both directions for Move/Copy. Symbol accessibility metadata and drag-session
autoscroll are corrected. The original full regression stopped without an exit
result during Wand repetition 5; host process inspection confirms it is no
longer running. The October 16 restart passes 147 XCTest + 950 Swift Testing
cases (1,097 total), all configured native journeys and required source/generator/
shader/ledger integrity. Its `.exit` file is 0. This is the complete combined
checkpoint above, preceding the later Invert correction. Focused evidence:
`/tmp/compositor-layer-nesting-both-edges-{build,native}.log`, exit 0.
Effect stacks, masks/clipping/transforms/HDR combinations, continuous controls,
physical input, desktop portal/screen-reader delivery and Mac appearance/color/
project equivalence remain open. Automated passes do not establish those scopes.

## Thumbnail selection modifiers, 2026-10-16

Historical row 31 now has native evidence for Shift-add and Alt-subtract as
well as replacement. Twelve actual Qt window-pointer cases cover image,
layer-mask and folder-mask thumbnails, including Alt-over-Shift precedence.
Independent all-pixel fills prove coverage after selection Undo and Redo;
source pixels/records and each gesture's immediate edit target remain exact.
The isolated release build and native probe pass in
`/tmp/compositor-thumbnail-selection-{build,native}.log` (native exit 0).
The initial failure was a stale target snapshot in the coverage-proof harness;
upstream history intentionally clears the mask target across layer switches.
This probe needed no production change. The contract now invokes it; the earlier
complete contract used its previous script/executable and did not include this
test-only addition. The current Invert-corrected runner includes it. Transformed/HDR/partial-alpha variants and physical/
Mac input remain open. The inventory stays at 3 Implemented / 86 Adapted.

## Invert adjustment editor refusal, 2026-10-16

A newly reproduced unsupported-editor path could trap a session without a
visible sheet and prevent subsequent layer edits. It could also commit an
unrelated pending gradient before trapping the session. The bridge now refuses
adjustments without editable settings before changing editor state or resolving
that draft. The generated menu disables Edit Adjustment for those kinds; the
generator and parity manifest declare the correction. Protected upstream source
is unchanged.

All 1,099 framework tests pass (147 XCTest + 952 Swift Testing), including three
regression cases that failed before the fix. The native modern-adjustment phase
passes all six kinds, including disabled Invert Edit and bridge refusal with
exact document/history/target/switchability. Native backend/codec/font/thumbnailer,
eleven source-coverage checks and required source/generator/shader/ledger integrity
also pass. Evidence: `/tmp/compositor-invert-editor-{framework,native-contract,backends-coverage,integrity}.log`
and their phase `.exit` files; see the baseline for exact phase names. The new
29-command native run is still live; the earlier autoscroll run uses a previous
executable and does not verify this fix. The complete combined checkpoint above
therefore remains historical. Wider combinations and physical/Mac acceptance
remain open; statuses stay at 3 Implemented / 86 Adapted.

## Source coverage

The SDK-evaluated SwiftPM target contains 176 Swift files. Resolving every source symlink against the protected checkout gives the following partition of all 156 upstream Swift files:

| Consumption | Files | What this proves |
|---|---:|---|
| Unchanged upstream source | 128 | The actual target includes the protected file. |
| Generated adaptation | 20 | The target includes its declared override; separate generator checks verify the output against tip. |
| Backend replacement | 6 | The target includes a declared Linux implementation. Pixel/behavior parity requires its own tests. |
| Platform substitution | 2 | The app delegate and Sparkle user driver are deliberately supplied by Qt/LinuxBridge and Flatpak. |

The remaining 22 target files are Linux additions: 20 bridge/support/rendering files and two override additions (`Sheets.swift`, `LayerRenameField.swift`). The upstream canvas, brush cursor and sampling overlay compile unchanged; Qt hosting and event forwarding are adapters around that code. They are not replaced source files.

The C targets compile eight protected pixel-kernel files directly. The ninth, `DitherPixels.c`, is included by `linux/kernels/DitherPixelsLinux.c`, which supplies serial `dispatch_apply` and zero-initialized scratch allocation using standard `calloc`. The latter prevents unwritten Scanlines beam colors containing NaN from changing unlit screen pixels; a poisoned-allocator C regression proves the defect and correction. This C inventory comes from the evaluated targets and wrapper source; the automated coverage check below covers Swift sources.

## Generated adaptations and replacements

Each row is included in the evaluated `Compositor` target. Generator equality establishes the documented source transformation, not every runtime behavior.

| Upstream file | Mode | Adaptation |
|---|---|---|
| `UI/BlendModePicker.swift` | generated | Objective-C selectors by name |
| `UI/CameraRawSlider.swift` | generated | Objective-C selectors by name |
| `Document/ColorRangeSelection.swift` | generated | serialized preview worker |
| `UI/ColorRangeSheet.swift` | generated | Linux Alt labels |
| `UI/CommandPaletteView.swift` | generated | toggle presents the Qt dialog; original menu catalog, tool/mask commands and search ranking supply its entries |
| `CompositorApp.swift` | generated | Objective-C selectors/Linux entry; Edit Adjustment requires a kind with editable settings |
| `ContentView.swift` | generated | Linux patch: shell-rendered pieces, Color Range panel, body split, stepper callback release |
| `Document/EditorSession.swift` | generated | Color Range gates |
| `Rendering/GPUCanvas.swift` | replaced | Metal renderer replaced by the Vulkan present path (opt-in); Core Graphics canvas by default |
| `Rendering/GPUNoise.swift` | replaced | Metal compute replaced by the NoisePixels.c kernels |
| `UI/IndicatorlessScrollView.swift` | generated | Linux patch: nonisolated deinit (Swift 6.3.3 SILGen crash) |
| `Rendering/InlineTextEditor.swift` | generated | Objective-C selectors by name |
| `UI/KeyboardShortcuts.swift` | generated | Linux key names (patch); selectors by name |
| `UI/LayerMaskMenu.swift` | generated | Objective-C selectors by name |
| `Rendering/MetalBrushCoverage.swift` | replaced | Metal coverage replaced by backends/brush (CPU/Vulkan); parity in BrushCoverageBackendTests |
| `Rendering/MetalCameraRawLookup.swift` | replaced | Vulkan composed-table lookup and unchanged upstream CPU rounding repair; exhaustive original GPU tests, explicit hardware submissions and the original 2–48 MP benchmark pass. [Measurements](camera-raw-linux-performance.md). |
| `Rendering/MetalLayerEffects.swift` | replaced | Metal kernels replaced by backends/effects (CPU/OpenCV/Vulkan); parity in LayerEffectsBackendTests |
| `Rendering/MetalWarp.swift` | replaced | Metal kernels adapted to CPU/Vulkan working copies; parity in WarpStroke/Smudge tests |
| `UI/NativeLayerList.swift` | generated | Objective-C selectors by name |
| `UI/ProjectTabs.swift` | generated | Objective-C selectors by name |
| `UI/ProjectWindowBridge.swift` | generated | delegate forwarding written out per callback |
| `UI/SliderSnap.swift` | generated | Objective-C swizzle replaced by a compat cell hook |
| `Document/SmudgeLiquify.swift` | generated | Exact radial-falloff cache and deferred live snapshots; queued segments retain upstream interpolation across frame budgets. Final commit uses upstream coverage and sampling unchanged. |
| `UI/RawDevelopSheet.swift` | generated | Embedded RAW lens profiles through LibRaw; controls reflect actual per-file capabilities |
| `Rendering/TransformOverlay.swift` | generated | Linux patch: wider handle hit slop |
| `UI/TypeControls.swift` | generated | Objective-C selectors by name |

The Smudge/Liquify adaptation keeps bounded live dab work and small dirty snapshots. New pointer samples wait in order; resumed segments retain their original starting point, step count and interpolation. Finalization drains pending work and uses upstream’s full-image sampling and 0.05 commit spacing. `WarpTipCacheTests` compares the working stroke with unchanged upstream source. `WarpCommitParityTests` also compares committed rendering, stored assets, exact points and Undo/Redo across both modes, synchronous/sliced input, fractional tips, selection/transformed layers, repeated continuation and canvas edges. It verifies that changed targets refuse commits. All five methods (14 parameter cases) pass. The earlier eight-case, 19-issue failure remains recorded in `/tmp/compositor-warp-commit-before.log` as the regression baseline.

## Tests and native evidence

All 89 upstream test files are accounted for: 87 compile unchanged in `CompositorUpstreamTests`; `LayerTests.swift` uses a generated selector mirror and `KeyboardShortcutTests.swift` uses a generated `SQLiteUserDefaults` type-name mirror in `LinuxOverrideTests`. The generator checks that all test bodies and assertions remain unchanged. No per-test runtime skips are declared. The one `CompositorUITests` Swift file uses macOS UI automation and is not a Linux SwiftPM test target.

Native pointer hit testing now uses the incoming event for both left and right
clicks. The actual-mask regression and context-sensitive-menu regression fail
before their respective fixes and pass afterward. The latter checks the chosen
menu, type/modifiers/location, shared event identity through presentation and
restoration of the enclosing event. See the right-click follow-up in
[the baseline](upstream-test-baseline.md) for focused, full-framework and native
preview evidence. Broader native API coverage remains open.

The later button-state regressions additionally verify both left/middle release
orders, current masks during hit testing and callbacks, and a left release
consumed by `NSWindow.nextEvent` while middle remains held. The mouse-event
factory supplies right-button identity 1 and default other-button identity 2.
The overlap and hit-test assertions reproduce failures before their respective
fixes; all three NativePointerContextTests now pass. Physical multi-button input
remains unverified.

The historical unfiltered runner at protected `39d1257` passed **869/869 framework tests** (121 XCTest; 748 Swift Testing across 122 suites), all nine source-coverage checks, native kernel/backend checks and the complete combination, preview and text journeys. No runtime tests were skipped. Required-shader integrity and protected-tree equality also pass. See [the test baseline](upstream-test-baseline.md) for scope and logs.

Before the new warp oracle checks were added, the complete release runner at protected `b2a0c45` passed **856 framework tests** (121 XCTest and 735 Swift Testing in 120 suites), then the native combination, preview and text journeys. Details and the run log are recorded in [the test baseline](upstream-test-baseline.md). The source-inventory integration separately runs nine Python coverage checks and the existing native journeys. Those nine checks are not included in the 856 framework count.

## Automated enforcement

`scripts/linux-contract-tests.sh` evaluates `swift package describe --type json` inside the SDK, then runs `scripts/check-linux-source-coverage.py` and `tests/test_linux_source_coverage.py`. Reports are retained at `.build/linux-contract-native/package-description.json` and `source-coverage.json` (or the directory selected by `COMPOSITOR_CONTRACT_NATIVE_BUILD`).

Nine injected faults and two valid controls verify the source-coverage gate. Seven additional fault/control tests verify protected content independently of index state. The coverage check rejects missing originals, missing/undeclared overrides, original-plus-override duplicates, unaccounted platform substitutions, and missing or duplicate selector test mirrors. It uses the union of the protected checkout and upstream reference paths, and the actual target description; `scripts/check-upstream-clean.sh` separately verifies that protected trees match upstream and that generators, drift and ledgers are clean.

The prior catch-up merged two upstream commits at `83a8cd5`: narrow Layers panel bounds/custom pop-up sizing and direct-child folder image imports. The 44-test import/hosting run includes both new upstream folder tests unchanged. Native mixed file/folder selection and import ordering passed in the complete runner. Native portal directory grants remain unverified. The Qt Layers dock now resizes across 222–352 points, persists its width, and feeds the unchanged upstream body. Three width-model regressions pass; the native preview verifies endpoint control containment and a pointer-driven splitter drag without document edits. Real desktop/Mac visual comparison remains unverified.

Earlier audit inputs: `/tmp/compositor-package-inventory.json` and `/tmp/compositor-source-coverage.json`. Fault-injection log: `/tmp/compositor-source-coverage-faults.log`. SDK integration log: `/tmp/compositor-source-inventory-contract.log`; all nine final checks: `/tmp/compositor-source-coverage-sdk-final.log`.


## Exposure, Gradient Map and Grain controls follow-up, 2026-10-15

Historical row 50 has 30 passing native visible Image-menu cases, half with
pixel-proven pointer selections. Exposure's stops, Offset and Gamma, including
combined edits, match independent linear-light equations. Gradient Map's two
visible endpoint pickers, submitted Hex/RGB, Cancel/OK and Reverse match
luminance interpolation. Grain's same-seed Amount, Size and Roughness changes
verify amplitude, particle scale, added fine detail and pattern restoration.
Home/End checks all six numeric slider ranges, including logarithmic Gamma/Size.
Preview Off/On, source/target/palette/history isolation, exact alpha/outside
pixels and exact Undo/Redo pass; identity Exposure/Grain preserve history.

All 18 focused original adjustment/editor tests pass. The existing upstream and
Linux implementations supply the behavior; this follow-up adds native
acceptance to the contract runner. Initial Hex submission and retired-widget
assertions were harness errors, resolved against the source and live field
state. [The baseline](upstream-test-baseline.md) records exact parameters,
tolerances and logs. Transformed/masked/HDR cases, larger images, continuous
slider/pointer gestures and physical/Mac appearance remain unverified. The
89-row inventory is unchanged; these are expanded passing scopes.

## Filter controls and Motion Blur spread follow-up, 2026-10-15

Motion Blur now uses normalized Gaussian line weights and a matching three-sigma
sampling margin. A floating-point impulse regression first demonstrated the
old spread error (variance 6.6667 instead of 16 at radius 4); corrected moments,
SIMD/scalar comparisons, regional/full rendering and the Full HD performance
guard pass. The full follow-up passes 1,092 framework tests with required Vulkan
CI/warp hardware and the subject model; protected-source/generator/shader checks
pass. Raw 1920×1080 kernel timings are approximately 13–16 ms, not UI latency.

Historical row 52 also has 42 passing native visible-menu/control cases for
Motion Blur, Add Noise and Lens Correction, split between whole-image and
pixel-proven pointer selections. Absolute blur spread/direction, noise amount/
distribution/channel/alpha behavior and radial lens pixels are checked, along
with Preview Off/On, Cancel/OK, source/history isolation and exact Undo/Redo.
Zero lens distortion retains history as upstream requires. The contract runner
includes the probe. [The baseline](upstream-test-baseline.md) records parameters,
tolerances, logs and the initial harness failures. Extreme values, transformed/
masked/HDR combinations, physical input and Mac kernel/appearance comparison
remain unverified. This adds no feature row or status promotion.

## Window initialization and Layers selection follow-up, 2026-10-15

A second Qt window registered the current workspace tab, then reset that
session's tool to Move and foreground to black. This changed the first window's
Shift-arrow behavior from layer selection to a nudge. Window construction now
reads the existing session tool and palette after creating its controls. The
native `--layer-disjoint-probe` passes 16 Command/Shift-click and Shift-arrow
rounds, including eight second-window lifecycles, exact selection, retained
tool/palette and no document/history edits. The full corrected Swift run passes
1,090 tests; [the baseline](upstream-test-baseline.md) records the initial missing
ICC fixture and exact logs. The contract runner includes this regression.

This closes the reproduced window-construction reset, without explaining the
earlier intermittent Command-click or valid-target mask failures. Wider window/
edit combinations, physical input and Mac comparison remain unverified. No
feature rows are added or promoted by this follow-up.

## Earlier catch-up implementations

| Commit | Upstream change | Linux implementation |
|---|---|---|
| `9a0ad3e` | Gaussian Blur Preserve Transparency, solid canvas edges, default radius 5 | Unchanged filters and sheet; compat alpha normalization and numeric bridge setting. Original FilterTests and native transparent-image toggle/commit/Undo/Redo checks. |
| `248d4d4` | RAW Noise Reduction, Lens Correction and Highlight Recovery; capabilities/defaults/reset | LibRaw noise/highlight controls reach preview and full processing. Engine capabilities and defaults feed the unchanged importer/reset logic. Embedded-profile lens correction is now available for supported files; unsupported files retain disabled controls. |
| `23913d3` | Multi-scale PatchMatch healing and fill | Protected PatchPixels kernel replaces removed ContentFill C source in SwiftPM/CMake; checked strides and matching C/header links. Original healing/fill suites plus native seed, outside-hole, allocation-failure, no-source and stride checks. |
| `39d1257` | Texture-aware fill boundary | Current protected PatchPixels source compiles unchanged in both kernel paths. |

RAW verification uses generated Bayer DNGs through the actual LibRaw backend, covering noise/highlight pixel changes in draft/full develops, unsupported small-sensor noise controls and RAW files without supported lens metadata, stable dimensions/capabilities, and exact baseline preview restoration at two sizes. The native upstream sheet checks enabled controls, capability-dependent lens availability, Reset and Cancel. Its modified Group previously lost every child after Exposure; the compat resolver now applies modifiers to each sibling without changing stack layout, and a regression checks all five sliders, both toggles and all three buttons. The pinned LibRaw 0.22.2 OpenMP wavelet routine used an uninitialized allocation count; a one-line dependency patch initializes it in both Flatpak and local builds. Sensor dimensions, color metadata and CFA mapping remain immutable across processing so draft scaling and reset do not use LibRaw’s mutated output state.

The RAW controls are transient develop settings, so no project-format fields or version changes are needed. Lens correction uses embedded DNG OpcodeList3 and supported Sony, Fujifilm, Olympus/OM System and Panasonic metadata; it does not provide Apple’s complete lens-profile database.

## Code-level status audit, 2026-10-16

Every status in the comparison below was checked against code that ran, not only against this document.
`.build/evidence/audit-evidence.py` matches each row's feature to passing evidence in the clean contract run
(`.build/evidence/full-contract-run5-clean.log`: native `Qt … OK` journey lines, passed XCTest cases and
Swift Testing tests). 73 of 91 rows matched automatically and 12 more by targeted search (for example
`CameraRawResetTests`, `ProgressiveBlurTests`, `ExternalChangeTests`, `AdjustmentLayerTests`, the
selected-adjustment preview journey, HEIF 10/12-bit transfer 16/18 fixtures, `middleDraggingScrollsOnlyTheLayerList`,
the four GPUCanvas suites). Tab-strip drops (refused `QDropEvent` during a stroke), the empty-header drop and reopen
rows are covered by `--tab-smoke` and `--save-smoke`. With the two below, all 91 rows have passing executed evidence. Two rows had no executed evidence in the contract: the portable package preview
(`--package-smoke`, which existed but was not run; it now passes and is a contract gate) and updates
(`scripts/test-flatpak-updates.sh`, release workflow only; it passes with 0 failures,
`.build/evidence/flatpak-updates.log`).

`.build/evidence/stub-audit.py` lists empty public compat functions that upstream calls (19 of 25). Delegate and
protocol defaults are empty on macOS too; the compat invokes each one upstream overrides (window close/move, menu
open/close/update, text and table changes, dragging), except `dismantleNSView`, which no host called: upstream's
blend-mode picker ends its hover preview there and both pop-up pickers detach their menu delegates. Both hosting
paths now call it (`RepresentableDismantleTests`). The remaining no-ops are unreachable or have no Linux meaning:
every upstream caller of Metal `commit`/`waitUntilCompleted` is replaced by a Vulkan/CPU override, security-scoped
resources do not exist outside the macOS sandbox, `NSApp.activate()` is called only by the excluded Sparkle
`UpdateDriver`, and PDF pages are recorded until `closePDF`.

## Current feature comparison with upstream

“Implemented” means the upstream behavior is supplied and Linux checks pass for the stated scope.
“Adapted” means a working Linux backend supplies it with the difference stated below.
Neither status certifies visual identity with macOS. This table adds current evidence to the historical
[full element inventory](mac-linux-parity-inventory.md); broad API and physical-device acceptance remain open.
The [70-feature crosswalk](upstream-70-feature-crosswalk.md) separately maps every
row of the original feature matrix and states where visible-control or combined
behavior verification is still required. Its core-suite scope is narrower than
full feature acceptance.

| mac | GNU_Linux | Status |
|---|---|---|
| Camera Raw Shadows adapts to picture content and keeps tone order | Unchanged upstream Swift/C algorithm and both original regression tests pass. The new Shadows table is installed beside the executable in tests, the launcher and Flatpak. Actual Mac visual comparison remains unverified. | Implemented |
| RAW Camera Raw… imports and opens the filter on the imported layer | Qt hosts the generated upstream button. Replacement imports retain the requested RAW layer across mixed batches and reopen its draft after installation. Native single/mixed Import and Camera Raw journeys verify the correct layer, visible panel, Cancel and exact import Undo/Redo; window rejection also releases the staged import. | Adapted |
| Camera Raw section reset, header visibility and imported settings | Original `CameraRawResetTests` pass. Actual Mac/desktop appearance is unverified. | Implemented |
| Camera Raw native-resolution previews during slider edits | Unchanged upstream `largeCameraRawPreviewKeepsNativeResolutionAcrossSliderUpdates` and `nativeCameraRawPreviewsCoalesceSliderChangesAndRespectPreviewOffAndCancel` pass. Linux supplies the bitmap/preview backends; source dimensions, coalescing, Preview Off and Cancel are verified. Physical/Mac appearance and latency remain unverified. | Adapted |
| Camera Raw bounded scope sampling | Unchanged `scopeSamplingChangesAtFourMegapixelsWithoutChangingColors` passes the sampling threshold and color checks. The separate opt-in scope performance benchmark has not been run; the GPU benchmark below includes full preview/scope work. | Adapted |
| Camera Raw GPU composed lookup for large previews | Vulkan uses reusable buffers and unchanged upstream CPU rounding repair. Original exhaustive opaque-RGB profiles and alpha/padded-row tests pass, as do explicit RADV hardware submissions and buffer recreation. The original paired 2–48 MP benchmark passes pixel identity for every workload and direct GPU calls at every size. [Measured gains and limits](camera-raw-linux-performance.md); unsupported/failed GPU work keeps the CPU fallback. Metal-equivalent latency is unverified. | Adapted |
| Smooth rectangle corners, radius-zero refusal and v14 shape persistence | Upstream shape/save/resize tests pass. Compat arc construction and Linux draft smoothing preserve the same geometry. Native `--upstream-153-probe` passes both corner modes, disabled Smooth Corners at zero radius, live enabled-state updates with retained Radius field/focus/cursor, preview/commit pixels and exact Undo/Redo. Physical/Mac appearance remains unverified. | Adapted |
| Middle-button Layers scrolling without selecting or dragging rows | Qt forwards middle-button events to the generated upstream table and clip constraints. Native thumbnail presses verify live 40/80-pixel scroll, window-coordinate continuity, retained release offset, boundary clamp and exact source/selection/history isolation. Physical desktop input remains unverified. | Adapted |
| Zoom cursor direction reversals, middle-pan release and keyboard tool cursors | Qt now applies upstream cursor results for all canvas mouse buttons; the bridge restores cursor rectangles on middle release. Twelve original Cursor/MiddleButton tests and six normal-product native cases pass: left Zoom/Alt, Ctrl/Meta middle zoom, immediate reversals above/below the start, stationary samples, pictured cursors, Move/Brush pan distance, release restoration and unchanged source/history. Normal-product Hand/Zoom key switches also update shape/picture/hotspot before a stationary hover; ordinary hover applies cursor rectangles while preserving Move/selection refinements. The contract includes both cursor probes; see `native-followup-` logs in the baseline. Physical/high-DPI/Mac comparison remains unverified. | Adapted |
| Progressive Blur, linear/radial masks, From/To, invert and movable line | All four original tests pass. CPU Gaussian scale interpolation supplies variable blur; exact Apple-kernel pixel identity remains unverified. | Adapted |
| CMYK proofing, profiles, JPEG/TIFF/PDF export and CMYK PSD import | Original `CMYKTests` pass with an isolated ECI ICC fixture. LittleCMS supplies conversion; users load print ICC profiles. Canvas proofing was previously absent on Linux (only upstream's Metal `gpuFrame` applies it, and compat lacked `CIColorCubeWithColorSpace`); compat now implements that filter and the Qt canvas proofs its full, scaled and stroke-patch display images through upstream's lookups, never exports. `CMYKProofDisplayTests` (fails without the filter) and `--cmyk-proof-probe` verify the visible View › CMYK toggles, dulled blue, retained gray, gamut marking, untouched document/export/history and exact restore. See [1.5.2 feature status](upstream-1.5.2-feature-status.md). | Adapted |
| Keyboard Shortcuts window, live search and editable assignments | Qt refreshes search results while preserving focus/cursor; native recorder and Cancel/Save use the upstream editors. Cancel/reopen discards the draft; saved K replaces B for Brush, and restoring B restores all original bindings. Native tests also verify conflict feedback/disabled Save, removal through the visible control, unaffected alternative tool routing and Restore Defaults Cancel/Save. Original bindings and exact document pixels/layers/history are restored. Fresh-process probes verify saved K, a cleared binding and restored B, including actual K/B canvas routing. Physical/Mac input remains unverified. | Adapted |
| Shortcut clearing, obsolete-command recovery and CMYK shortcuts | All seven original test bodies pass through the type-name mirror. Named settings suites persist independently in SQLite. | Implemented |
| 16-bit/HDR layers, PNG16/EXR photo import, editing, native project save/reopen and dithering | Original deep-layer tests run unchanged. Qt now delegates asset encoding and complete-package decoding to upstream `ProjectStore`, retaining 16-bit PNG and HDR OpenEXR instead of passing through RGBA8. Native photo-import/package and frozen-worker fixtures retain fine steps, brighter-than-white light and transparent/partial/opaque alpha, with new-document dimensions and layer isolation checked. End-to-end Mac color comparison remains unverified. | Adapted |
| Floating-point TIFF import with gray/RGB ICC, alpha and metadata | 192 independent 16/32/64-bit cases pass, covering both byte orders, strips/tiles, planar/contiguous and associated/straight alpha. Float gray ICC conversion uses LittleCMS. | Adapted |
| 10/12-bit HDR HEIF PQ/HLG import | Transfer-equation fixtures preserve highlights and premultiplied alpha; SDR deep imports retain source precision. Qt’s linear-light normalization needs a Mac comparison. | Adapted |
| RAW noise reduction, highlight recovery and embedded lens correction | LibRaw and embedded-profile correction supply these operations. Per-file capabilities govern controls; Apple’s broader lens coverage is unverified. | Adapted |
| Project save preparation; recovery autosave is a Linux addition | Autosave captures committed layer state without applying a pending gradient. `/tmp/compositor-crash-recovery-release-native.log` exits 0 for actual SIGKILL and normal startup recovery of committed edits and a pending gradient: exact pixels/IDs, unsaved state without a draft, separate explicit startup input, save cleanup and clean relaunch. Startup now invokes recovery, and its loader leaves the autosave path unbound. All seven focused save tests, both loader cases, the existing native save journey and required integrity pass; the fresh full framework run passes all 1,100 tests. A deterministic autosave/save race in the acceptance harness has a passing regression; the complete 30-command canonical contract exits 0 (before the later Grid Settings fixes). Explicit saves still prepare transforms as upstream does. Other drafts, multiple recovery slots and installed desktop acceptance remain unverified. The upstream NSOpenPanel/NSSavePanel adapter now provides owned Open/Save dialogs, .comp metadata/default suffix, confirmed package replacement, multiselect and lossless JSON paths. All 35 focused checks, 1,119 framework tests and a seven-scenario Qt CTest pass. A 16-case real ProjectController workflow passes offscreen/native Wayland, including Save As in both windows and opening two distinct selected project packages with exact independent pixels/records. Fresh full 37-gate session 83638 is pending; a later preview Home/scroll failure is tracked separately in the newest baseline. | Adapted |
| Create all twelve adjustment-layer kinds and re-edit the eleven with settings | The six historical editors pass visible creation, thumbnail/Edit-menu reopening, numeric/Curves graph/Reverse changes, Cancel/OK and exact pixel/history/identity checks. The modern-adjustment phase of `/tmp/compositor-invert-editor-native-contract.log` passes all six newer kinds (phase exit 0): Gaussian/Motion Blur, Add Noise, Black & White and Color Balance use numeric controls; Invert applies without an editor and matches independent channel complements. Its Edit command is disabled, and bridge refusal preserves editing readiness and pending gradients. Newer cases verify separate creation/default-setting history steps, saved parameters, every source PNG channel and exact package-reopened composites. All 1,099 framework tests and required integrity pass; the older combined native run exits 1 at an effects-control package save. The autosave-overlap regression and 54-case rerun pass after coordinating test saves; the subsequent complete canonical run passes all 1,100 framework tests, all 30 native commands and required integrity (before the later Grid Settings fixes). Wider parameters, masked/transformed/HDR stacks and physical/Mac appearance remain unverified. | Adapted |
| Feather a selection and create a soft layer/folder mask | Visible Select > Feather, Amount=6 and Cancel/OK controls feed unchanged upstream selection coverage into Add layer mask. Native layer/folder cases verify partial-alpha boundaries, visible center/hidden exterior, source-image isolation and exact selection/mask Undo/Redo with target identity. Selection/transform/HDR combinations and physical/Mac appearance remain unverified. | Adapted |
| Magic Wand tolerance, contiguous and all-layer sampling | Existing upstream Wand code uses visible Qt controls. Eight Point Sample/Anti-alias-off cases cover tolerance 0/24, Contiguous on/off and This Layer/All Layers. Actual clicks and fills match every expected pixel, including nearby/disconnected colors and all-layer sampling into a blank destination. Selection/fill Undo/Redo and target identity pass. Point/3x3/5x5 keyboard choices at tolerance 15 yield distinct point/no-match/background results; no-match New clearing/restoration and exact fill Undo/Redo pass. Wand Add/Subtract buttons and Shift/Alt also pass exact union/difference and coverage Undo/Redo. The captured timeouts exposed main-queue starvation from an expired Foundation RunLoop deadline. A positive one-millisecond deadline fixes task starts/continuations; all six Wand rounds pass in `/tmp/compositor-main-pump-fixed-wand.log` and the full `/tmp/compositor-main-pump-fixed-full-contract.log`, with the five-second gate unchanged. Object/transform/HDR combinations and physical/Mac input remain unverified. | Adapted |
| Rectangle/Ellipse Marquee and Add/Subtract | Existing upstream gestures use Qt controls. Shape/Anti-alias-off, ordinary/fresh-Shift-square-circle and late-Alt captured-New cases pass bounds/interior/exterior and exact coverage Undo/Redo. Add/Subtract works through buttons and Shift/Alt at press. Skia Simplify before AsWinding preserves ellipse holes. The independent ellipse oracle excludes a one-pixel curve band; upstream Marquee does not center on Alt. Antialiased/feathered variants and physical/Mac input remain unverified. | Adapted |
| Freehand and Polygonal Lasso pointer paths | Existing upstream lasso code uses the visible Qt mode picker and canvas events. A concave outline passes exact all-pixel fill coverage. Freehand release and Polygonal first-point/double-click/Return closure, Backspace removal and Escape for both modes pass draft isolation and exact selection/fill Undo/Redo. Visible Add/Subtract controls and Shift/Alt pointers also pass for both kinds, with exact all-pixel union/difference and coverage Undo/Redo. Feathering/other shapes and physical/Mac input remain unverified. | Adapted |
| Eyedropper and temporary Alt sampling in Brush | Existing upstream sampling uses Qt canvas pointer events. Visible Eyedropper and Alt Brush pass opaque and half-alpha composite RGB sampling, held-pointer drag sampling, transparent/outside refusal and retention of the selected tool. Pixels, layer records, active target, background color, modified state and Undo/Redo history remain exact. RGB allows 2/255 for premultiplied raster rounding. Evidence: `/tmp/compositor-eyedropper-pointer-native.log`; 20 UpstreamEditorTests also pass. HDR/transformed/masked composites, other temporary tools and physical/Mac input remain unverified. | Adapted |
| Color Picker foreground/background, RGB/Hex, Hue and saturation/brightness | Qt hosts the unchanged upstream view. Visible fields/gestures, sampling and transparent refusal, Cancel/OK, focus/cursor, preview RGB, title-close and reopen position pass. Selected text, six effects, seven filter colors, Grid, Canvas Size and JPEG/PDF/CMYK TIFF dialog targets pass live preview and their upstream palette/history policies. The complete 1,059-test runner and every native journey pass in `/tmp/compositor-pdf-matte-readback-full-contract.log`, including PDF reader/blending. Detailed evidence: [test baseline](upstream-test-baseline.md). Multiwindow geometry, transformed/HDR sampling and physical/Mac comparison remain unverified. | Adapted |
| Gradient Linear/Radial, colors, Reverse and Opacity | Unchanged upstream GradientControls and raster logic use existing Qt controls and the graphics backend. All 16 combinations of Linear/Radial, Foreground to Background/Transparent, Reverse off/on and Opacity 100/50 pass visible pointer drawing, Cancel/Apply and exact pixel/record Undo/Redo. An independent all-pixel premultiplied RGBA oracle allows 3/255 for raster rounding. Evidence: `/tmp/compositor-gradient-settings-final-native.log` (exit 0); 13 GradientTests/PendingGradientTests also pass. Mask/selection/transformed/HDR combinations, endpoint editing and physical/Mac comparison remain unverified. | Adapted |
| Eraser Size/Hardness/Opacity and selection clipping | Existing upstream BrushControls, Erase mode and destination-out raster logic use Qt controls and pointer events. Ten single-stamp cases cover size 8/16, hardness 0/100, opacity 50/100 and size-24 hard stamps clipped to a rectangular selection. Center alpha/opacity cap, unchanged source RGB, soft partial-alpha edges and exact pixels outside the tip/selection pass; target/count and exact pixel/record Undo/Redo also pass. Alpha allows 3/255 rounding; the hard edge excludes a one-pixel band. Evidence: `/tmp/compositor-eraser-controls-native.log` (exit 0), plus 22 brush-suite tests. Continuous strokes/smoothing, masks/transforms/HDR and physical/Mac input remain unverified. | Adapted |
| Spot Healing Content-Aware / Create Texture / Proximity Match | Existing upstream BrushControls and healing kernel use Qt controls and pointer events. All 12 combinations of the three visible modes, single stamp/short stroke and opacity 100/50 repair or blend an 8x8 red blemish into a striped gray surface. The named mode control retains its selected binding; Size/Hardness/Opacity reach the session. Every outside-footprint pixel and opaque alpha remain exact; target/count and exact committed pixel/record Undo/Redo pass. Evidence: `/tmp/compositor-healing-pointer-final-native.log` (exit 0), plus 22 SpotHealingTests/UpstreamEditorTests. Natural-photo quality, soft tips, selections/masks/transforms/HDR and physical/Mac comparison remain unverified. | Adapted |
| Selection Expand/Contract and All/Inverse controls | Existing upstream selection code uses visible Qt menus and Amount controls. Invalid 0/501, restoring 1, Amount 4, range hint/slider and field/focus/cursor retention pass. Cancel/OK and reversible fills prove changed coverage, exact rectangular inverse, Select All, inverse-of-All policy and Undo/Redo. Renderer validation now updates while typing. Wider selection shapes/edges/amounts and physical/Mac input remain unverified. | Adapted |
| Selection-outline pointer movement and arrow nudging | Existing upstream selection code receives visible Marquee Rectangle/New controls and Qt pointer/platform-key events. All four arrows at 1 px and Shift+10 px, an ordinary drag and a partly off-canvas drag pass every-pixel translated coverage, source/layer/target isolation and one-step Undo/Redo. Evidence: `/tmp/compositor-selection-outline-native.log` (exit 0), plus 19 original SelectionEditTests. Other shapes/tools, feathering, fractional drags and physical/Mac input remain unverified. | Adapted |
| Free-distortion corner/edge drags and Shift-axis constraint | Qt Ctrl-handle events drive the unchanged upstream distortion draft. The Linux composite cache now includes its corners, fixing stale original pixels during pointer edits. Six native Cancel/Apply cases pass expected corners, independent perspective interior/exterior checks away from interpolation boundaries, exact preview/committed pixels, retained target and one-step Undo/Redo. Evidence: `/tmp/compositor-transform-gestures-early-native.log` (exit 0). Folded shapes, masks/groups/HDR and physical/Mac input remain unverified; full-regression evidence is tracked in the baseline. | Adapted |
| Move and scale selected layers or a folder with canvas gestures | Four native selected-layer/folder move/half-size cases pass exact child geometry, nearest-sampled pixel equations, target/hierarchy retention, unselected-layer isolation and one-step Undo/Redo. The fixture sets layer selection; the visible footer creates the folder, and actual canvas gestures commit on release. Evidence: `/tmp/compositor-transform-gestures-early-native.log` (exit 0). Rotation, nested/hidden/masked/HDR members and physical/Mac input remain unverified; full-regression evidence is tracked in the baseline. | Adapted |
| Move/resize snapping to canvas, other-layer edges/centers and visible guides | Existing upstream snapping receives native Qt move/side-resize/proportional-corner gestures. All 66 horizontal/vertical cases pass visible Snap/Snap To/Show/Zoom controls, enabled/disabled/hidden targets, global Snap off, Meta suppression and the screen-point tolerance at 1/2/4 points per document pixel. Independent rectangle pixels, exact geometry/target/unselected records, history-free preview, interior snap-line appearance/removal and one-step saved-state Undo/Redo pass. Guides and initial layer placement use fixture commands. The contract includes `--transform-snap-probe`; 17 original snapping/guide tests also pass. Competing targets/grid, rotated/masked/group/HDR combinations and physical/Mac input remain unverified. | Adapted |
| Layer/folder masks and clipping: paint, fill, blur and visible controls | Existing upstream mask/raster code handles visible Black/White painting, fill, blur, Reveal/Alt–Hide footer creation, right-click Disable/Enable/Delete and Image > Invert Mask. Native layer/folder cases verify coverage, source isolation and exact pixel/record Undo/Redo. Layer Unlink/Link works; folder Unlink stays disabled as upstream requires. Ctrl image-thumbnail selects opaque source pixels ignoring the mask; Ctrl mask-thumbnail selects hidden areas, proven by separate-layer fills. Visible Create/Release Clipping Mask also passes opaque/soft-alpha bases, exact alpha/color without fringe, source records/target identity, exact serialized base ID, Undo/Redo and bottom-layer refusal. Recursive popup hosting uses existing QMenu submenus and original NSMenu leaf dispatch. Native Add Mask Reveal/Hide passes for both targets with disabled-parent refusal and exact Undo/Redo; wider combinations and physical/Mac input remain open. | Adapted |
| Duplicate a folder with its nested descendants | The visible Layer > Duplicate Layer action uses unchanged upstream layerViaCopy/duplicateActiveLayer. Native checks copy two nested folders/two image layers, retain names/appearance/geometry, allocate unique IDs and remap every copied parent. Original records remain exact; hiding the original leaves the copied pixels equal to the original composite. Undo/Redo restores exact hierarchy, copied IDs, pixels and selected root. Mask/clipping/effect/HDR variants and physical/Mac appearance remain unverified. | Adapted |
| Folder opacity through the Layers controls | The visible Opacity percent field sets a folder to 50%. Native checks retain child opacity/parent IDs, verify rendered half alpha and exact pixel/hierarchy Undo/Redo. Uses unchanged upstream LayerAppearanceControls/setLayerOpacity. Nested/masked/HDR combinations and physical/Mac appearance remain unverified. | Adapted |
| Layer blend-mode menu, all 24 upstream modes | The visible upstream AppKit picker hosted by Qt passes highlight preview, Escape Cancel, Return selection and exact pixel/record Undo/Redo for two colored layers with partial alpha. Linux displayedSnapshot now uses upstream displayedBlendMode; source mode and history remain unchanged during preview. All 24 parameterized LivePreviewTests cases pass; the native probe exits 0 in /tmp/compositor-all-blend-modes-fixed-native.log. Final verification exits 0: /tmp/compositor-blend-preview-final-swift.log passes 1,060 framework tests with required Vulkan hardware; the native companion passes all 24 modes and preview/save/transform/tab/RAW/text journeys. Required integrity also passes. Nested/masked/HDR combinations and physical/Mac comparison remain unverified. | Adapted |
| Merge Down / Merge Layers / Merge Group | Visible dynamic Layer menu actions invoke unchanged upstream mergeLayers. Native cases verify exact composite pixels, nonadjacent selected-layer merging with an untouched unrelated layer, folder opacity baked into the merge, expected layer counts and exact hierarchy/ID Undo/Redo. Masks/effects/HDR combinations and physical/Mac appearance remain unverified. | Adapted |
| Canvas Size units/anchors and Image Size resampling/print controls | The visible Image menu and upstream sheet pass focused invalid 0/30001 gates, live size/warning text, ratio-linked Height updates, relative dimensions and exact Cancel isolation. All 36 Pixels/Percent/Inches/Centimeters × nine-anchor cases pass independent every-pixel odd-delta translations and exact single Undo/Redo. Nine crop/re-expansion cases recover outside-canvas source pixels with separate Undo steps. The renderer now refreshes dependent controls while retaining the actual numeric field, text/focus/cursor. All four original CanvasSizeTests, native Grid/transform/scrub/dialog/preview regressions, all 1,100 framework tests and required integrity pass (`/tmp/compositor-canvas-size-fixed.exit` and `/tmp/compositor-canvas-size-regression.exit` are 0). The Image Size probe additionally passes six Inches/Centimeters print-only dimension/DPI edits with unchanged pixels/records, all four units with locked/unlocked Nearest resampling (eight exact uniform/nonuniform pixel cases), two print-unit DPI resizes retaining print dimensions, and focused invalid-DPI/Cancel/reopen checks. Each commit passes single Undo/Redo. Offscreen and native Wayland pass all 17 cases (`/tmp/compositor-image-size-{native,wayland}.exit` are 0), and required integrity passes. The extended probe also passes six 16-bit PNG/HDR EXR checks: print-only saved source-channel retention, Nearest 2× every-channel oracles with transparent/partial/opaque alpha, Undo/Redo/package reopen, and center crop/re-expansion retaining deep assets. Two offscreen profiles and native Wayland each pass all 24 sizing/ownership markers. Scoped requests, explicit session dispatch and task-local ownership fix the reproduced two-window menu/sheet hang; original/newer window reuse and source isolation pass. All 41 focused tests and required integrity pass (`/tmp/compositor-deep-size-bound.exit` is 0). Other sampling algorithms, masked/grouped/transformed deep sizing combinations and physical/Mac acceptance need direct native evidence. High-quality reductions of 2x or more now average every covered source pixel, as Core Graphics does; a bare cubic kernel had aliased and shifted tone (period-5 stripes at 10x gave 128 instead of 102). `test_skia_bridge` covers direct, scaled, rotated and half-alpha cases; the old bridge fails all four. | Adapted |
| Export current canvas at document dimensions and resolution | Legacy Qt PNG/JPEG helpers now read the current session raster instead of an asynchronously cached display frame. Native checks compare immediate post-import PNG to the render ABI and verify both formats at 80x72/300 DPI. Render failures return an empty result without a stale-frame fallback. The actual Export As > More > TIFF RGB path also passes Cancel/Export at document 72/150/300 DPI, with independent Pillow verification of exact DPI/alpha and RGB within 1/255. Qt QActionGroup hosts the Menu Picker; the complete required-hardware /tmp/compositor-scanlines-scratch-fixed-full-contract.log exits 0 with 1,059 framework tests and every native journey, including this follow-up. These are RGBA8 checks; canonical deep/HDR export still uses upstream exporters. Physical/Mac acceptance remains unverified. | Adapted |
| Content-Aware Fill extends a layer into selected added canvas area | Unchanged upstream ContentFill/FilterEdit uses multi-scale PatchMatch in PatchPixels.c. Native Qt expands a textured 64x64 image to an 80x80 canvas and fills each added edge strip through pointer selection and visible Cancel/OK. Every unselected pixel remains exact; selected pixels are opaque and retain color/texture variation. Layer count/identity and exact union bounds, preview/commit equality, Cancel and pixel/geometry Undo/Redo pass. Masked/transformed/HDR combinations and physical/Mac appearance remain unverified. | Adapted |
| RGB Levels / Master Hue-Saturation previews clipped to selection | Native Qt edits Output white to 128 and Hue to 120 through the original numeric controls. Expected selected-pixel colors confirm completed previews; every outside pixel remains exact. Visible Preview Off/On, Cancel and OK preserve source/history or commit the prepared image; exact pixel Undo/Redo retains selection and active-layer identity. Other channels/ranges, HDR/transformed/masked preview combinations and physical/Mac appearance remain to be mapped. | Adapted |
| Levels Auto, eyedroppers, channels and histogram handles | The visible upstream sheet hosted by Qt passes all three Auto buttons and all three pipettes, with all four channels, independent histogram endpoints/neutral gamma/sample ranges and all-pixel equations within 2/255. Alpha remains exact; transparent samples are refused; preview preserves source/history; Cancel/OK and exact pixel/record Undo/Redo pass. The separate native probe exits 0 in /tmp/compositor-levels-controls-focus-native.log and is part of the contract script; all ten original LevelsTests pass. The separate /tmp/compositor-levels-handles-settled-native.log exits 0 for all five triangle handles in all four channels (20 cases), named-space drags, independent all-pixel equations, Preview Off/On and exact Cancel/OK/Undo/Redo. Endpoint crossing, selected/masked/transformed/HDR and physical/Mac combinations remain unverified. | Adapted |
| Curves points and RGB/Red/Green/Blue channels | Existing upstream CurvesControls and Qt gestures pass graph add/move, Remove/Reset and endpoint-removal refusal in all four channels. Native /tmp/compositor-curves-points-native.log exits 0; 14 original filter/adjustment tests pass. Every visible pixel matches the moved middle-knot output within 2/255, with exact clear/partial/opaque alpha, unedited-channel/source/history isolation, Cancel/OK and exact Undo/Redo. This checks the knot and UI routing, not arbitrary interpolation. Multiple-point limits and selected/masked/transformed/HDR/physical/Mac combinations remain unverified. | Adapted |
| Hue/Saturation spectrum range handles | All 24 combinations of four handles and six color ranges pass visible degree labels and an independent Qt HSL/33³ cube oracle within 3/255, including red wraparound and clear/partial/opaque alpha. Invert/Preview, source/history isolation, Cancel/OK and exact Undo/Redo pass. /tmp/compositor-hue-range-cube-native.log exits 0; thirteen original HueSaturationTests pass. The shared Qt gesture host now finishes numeric-field editing and preserves gesture coordinates before refresh. The complete required-hardware /tmp/compositor-hue-gesture-full-contract.log exits 0 with 1,060 framework tests, every native journey and all 54 new Levels/Curves/Hue cases; protected-source/shader integrity also passes. Sampling/targeted adjustment, combined ranges and selected/masked/transformed/HDR/physical/Mac combinations remain unverified. | Adapted |
| Gaussian Blur / Black & White live previews clipped to selection | Unchanged upstream SelectionClip/PixelAdjust blends through the selection. Native Qt checks compare every outside pixel, retain source layers/history during preview, restore exact pixels with Preview Off/On and visible Cancel, match visible OK to the completed preview, and verify exact pixel Undo/Redo with selection/layer identity. Bridge state exposes `filterPreviewRendering` for current or queued workers so clients can await a completed frame. Separate RGB Levels/Master Hue paths are verified in the adjacent row; other filter-family combinations and Mac appearance remain unverified. | Adapted |
| Object mode selects the clicked foreground instance | Qt hosts the original Object mode control and forwards pointer clicks to unchanged CanvasView/ObjectSelection. Required native acceptance loads shipped U²-Net via OpenCV DNN, verifies foreground/background clicks, source-layer identity, selected-fill foreground/background isolation, exact source-pixel Undo and selection Undo/Redo. Linux instance labels come from connected components; natural-photo/Apple Vision instance equivalence and physical/Mac input remain unverified. | Adapted |
| Subject segmentation and Remove Background masks | The shipped U²-Net-small model runs through existing OpenCV DNN and the Vision compatibility seam. Required checks verify actual loading/inference, foreground/background labels, soft confidence and every upstream mask pixel. Bridge commands also verify Select Subject and Remove Background, source-image identity, layer ownership, linked/enabled mask creation, busy/draft completion and selection/mask Undo/Redo. Linux derives instance labels from connected components; Apple Vision model/object equivalence and natural-photo/Mac comparison remain unverified. | Adapted |
| GPU canvas graphs, brush coverage, effects, Smudge and Liquify | Vulkan/CPU replacements are exercised by backend and unchanged-upstream oracle tests. All six layer-effect sheets also pass 54 native numeric/position cases on opaque and half-alpha sources: independent morphology/Gaussian/compositing equations, Cancel/OK, exact numeric Undo/Redo, saved parameters and unchanged source PNG pixels/sRGB. Effect stacks, masks/transforms/HDR and physical/Mac comparison remain unverified. Core Graphics presentation remains the default; full-viewport GPU speed and SDR fidelity gaps remain open. | Adapted |
| Clone Stamp: Alt source, Aligned and all-layer sampling | Existing upstream clone/raster code uses Qt pointer events and controls. Actual Alt source, Aligned on/off and This Layer/All Layers verify offset/restart behavior, composite sampling into a blank destination, source isolation and exact pixel/layer Undo/Redo. Boolean picker dispatch is repaired in the shared SwiftUI compatibility control. Transforms/selections/HDR and physical/Mac appearance remain unverified. | Adapted |
| Shape: rectangle, rounded rectangle, ellipse and line | Unchanged upstream shape code uses existing Qt controls and raster libraries. Visible segments, Radius=0/6 and Width=4 plus pointer drags verify blue foreground, distinct geometry, unchanged exterior, separate layers and exact pixel/layer Undo/Redo. Modifier gestures, selection/mask/HDR combinations and physical/Mac appearance remain unverified. | Adapted |
| Flip Layer Horizontal / Vertical | Visible Layer menu actions mirror a noncentral 32×24 image about its own center on a 64×64 canvas. Exact pixels/geometry Undo/Redo, layer identity/count and unchanged canvas dimensions pass. Masks/groups/HDR combinations and physical/Mac input remain unverified. | Adapted |
| Flip Canvas Horizontal / Vertical | Visible Image menu actions mirror the same fixture about the canvas center, distinct from layer flipping. Exact pixel/geometry Undo/Redo, identity/count and retained canvas dimensions pass. Selection/guide/mask/HDR native combinations and physical/Mac input remain unverified. | Adapted |
| Invert pixels, whole layer or selection | Visible Image > Invert complements RGB within 8-bit rounding tolerance while preserving alpha. Outside-selection and transparent pixels stay exact; identity, geometry and selection survive exact pixel Undo/Redo. Mask/HDR/native-key combinations and physical/Mac input remain unverified. | Adapted |
| Pixel Grid from 800% zoom | Visible View toggle and Zoom field are checked at 799%, 800% and 1600%. Below threshold the canvas frame stays exact; above it visible hairlines remain at document-pixel boundaries, cell centers and surround are unchanged, and Off restores the exact frame. Stored pixels/layers/history remain exact. Existing Qt paint path supplies the upstream geometry. Physical/high-DPI/Mac appearance remains unverified. | Adapted |
| Crop preview, Alt symmetry and edge snapping | Unchanged upstream Crop/CanvasView handles drafts and geometry. All seven original CropTests pass. Native Qt checks verify ordinary/Alt creation, Alt edge resize, canvas-edge snapping at 100%, Meta mapped to upstream Control for temporary snap suppression, unchanged layers/history before Apply, Escape with exact unchanged pixels, Apply with retained layer identity, pixel/dimension Undo and dimension Redo. Physical keyboard/tablet/Mac comparison remains unverified. | Adapted |
| Shift constrains brush strokes to an axis and release resumes freehand | Qt pointer/modifier events reach unchanged upstream CanvasView brush handling. Native checks verify horizontal/vertical constrained painting, unchanged off-axis pixels, visible paint after Shift release, target-layer identity and a single exact pixel Undo/Redo. Physical keyboard/tablet/Mac comparison remains unverified. | Adapted |
| Layer visibility drag/autoscroll and keyboard selection | Native Qt journeys and upstream/compat regressions cover Linux behavior; see the six-area tracker. | Adapted |
| Layers Home/End/Page keys and selection by displayed name | The native Qt preview verifies viewport movement without changing selection or Undo history, delayed viewport stability and selection of a renamed layer. Compatibility tests cover Unicode prefixes, repeated-character cycling and delegate refusal. Upstream tool shortcuts retain priority. The later native-only follow-up (94792) fails after Home: rows 2/8 remain outside the viewport, so Command-click hits no table. Earlier passing scopes are retained; the queued-scroll interaction remains open (see newest baseline). | Adapted |
| Layers disjoint selection and Shift range expansion/contraction | Native Command/Shift clicks and Shift arrows verify exact selected-row sets and retained disjoint bases without adding Undo. Dragging moves the full selected set in upstream order with one grouped Undo. Twenty-six native nesting/Alt-copy cases also pass single/multiple roots, complete nested folders, selected-descendant deduplication, late Alt, moving out, cycle refusal, collapsed sources/targets, cross-folder selections and stationary-pointer autoscroll at both viewport edges for Move/Copy, with exact source records/parents/IDs/order, independent translucent pixels and one-step Undo/Redo. Native rows are synchronized before ordinary pointer presses, fixing a reproduced first-press stale-cache failure. Masks/clipping/effects/HDR combinations remain unverified. Symbol accessibility descriptions survive configuration; the row-drag timer continues after initial tracking and the compatibility router autoscrolls before validating the drop. A 32-session reopen regression checks current native row ownership; close releases cached views/observers and rejects late invalidations, while shared-document handles preserve their own rows. Four lifecycle tests and 16 two-window disjoint rounds pass. Actual Mac/input-device comparison remains unverified. | Adapted |
| Window layout, focus/accessibility and modal/import refusal recovery | Native Qt API evidence is recorded in the six-area tracker. External screen readers, actual desktop appearance and hardware input still need acceptance checks. | Adapted |
| Native text menus, clipboard and local history | Focused Qt text controls receive visible Undo/Redo, Copy/Cut/Paste and Select All. Native fixtures cover Unicode, plain-text paste, read-only refusal and exact font/color restoration. Synthetic IME preedit/commit pass; real input-method sessions remain unverified. | Adapted |
| Copy / Copy Merged / Cut / Paste images through the Qt clipboard | Actual Edit menus and pointer selection over two layers pass all selected/merged PNG pixels and image MIME through NSPasteboard.general and the existing Qt bridge. Paste retains a 20×20 crop at [12,12]; Copy preserves source/history; Cut and Paste have exact pixel/record Undo/Redo, retaining upstream's Clear/Paste action names. /tmp/compositor-image-clipboard-history-native.log exits 0 for three cases, and eleven original SelectionClipboardTests pass. The probe is part of the contract script without XCTestConfigurationFilePath. The Wayland follow-up fixes delayed own-write notifications invalidating cached crop placement; Copy/Copy Merged/Cut/Paste and a replacement 6×8 image pass exact pixels and Undo/Redo with real input on a private Weston/Xvfb seat (`/tmp/compositor-wayland-clipboard-input.exit` is 0). Physical desktop interapplication delivery, other source types and clipping/HDR/mask combinations remain unverified. | Adapted |
| Command palette catalog, search and commands | Original `CommandPaletteMenu`, `CommandPaletteEntry` and `CommandPaletteSearch` supply menu entries, tool modes, masks and ranking. Qt supplies the dialog and restores editor focus before deferred dispatch. Hidden legacy actions no longer enter its catalog. | Adapted |
| Existing-tab selection, menu context and active-stroke refusal | Qt selects the upstream workspace before changing its displayed document. Native tab clicks verify visible menu targets, stroke refusal and release recovery, with independent document pixels and histories. | Adapted |
| Active project window and visible menu context | Qt activation selects the window's displayed upstream tab. Menu opening and dispatch recheck that selection through upstream's operation gates. Native two-window checks verify both menu targets, independent Undo, stale-action refusal during a stroke and recovery after release. Hide Compositor queues a Qt request to minimize all visible project windows. Four cases on each of offscreen/native Wayland verify both origins and normal/maximized owners with an edited floating Gaussian panel: hidden across refresh ticks, same panel/value/preview after activation, Cancel and exact pixel/layer/target/palette/tool/selection-presence/history isolation. Minimize intent survives Wayland NoState notifications. Grid popup owners also survive forced refresh without mouse grabs. All 1,100 framework tests, native preview and required integrity pass; `/tmp/compositor-grid-popup-fixed.exit` is 0. The complete 34-gate contract and required integrity exit 0 in session 94463; that build predates the later numeric-field correction. A later deep-sizing probe reproduces another window draining a queued request, and a deferred task selecting the wrong owner. Explicit session dispatch, task-local ownership, scoped queues and live owning-window lookup for sheets/repaints fix those paths. Both window directions and older-window reuse after newer-window destruction pass in two offscreen profiles and native Wayland; 41 focused tests, all 24 sizing/ownership markers and integrity pass. All 1,103 framework tests, six affected native regression journeys and integrity pass in session 34499; the full 36-gate contract is running in session 87491. The common-entry/popup follow-up additionally verifies supplied SwiftUI handles, nested drop/caller restoration, deferred requests, menu validation/choice/close/replacement ownership and cancellation before stale choices. Main dispatch queue recognition fixes the nested-entry crash on Linux workers. All 12 focused tests, 1,108 framework tests, seven offscreen native journeys, normal-startup Grid persistence and integrity pass. Current full contract 25384 remains pending; Wayland sizing passes but preview clipboard is blocked by the seatless compositor. Direct app-level/onMain-only callbacks and broader teardown still need audit. Physical desktop/Mac delivery remains unverified; cross-application Hide Others/Show All still have empty compatibility methods. | Adapted |
| Visible project-tab reordering and busy refusal | Qt mouse dragging starts only when upstream `Workspace.canSwitch` and Linux replacement-import readiness allow it. Native checks verify selected/inactive moves, pointer reordering with and without hidden projects, document identity and pixel/history isolation, visible menu targets in reversed order, independent Undo, stroke refusal and post-release recovery. Physical-desktop acceptance remains part of the broader audit. | Adapted |
| Hidden-project selection and overflow refresh after reordering | Qt uses the renderer's natural tab widths, keeps the selected project visible without internal selection signals, refreshes overflow after moves and retires replaced menus. Native 800-pixel-window checks verify all five project identities, relative order, pixels, modified state and Undo/Redo state after pointer movement across hidden indices, plus menu targeting/Undo, busy-menu refusal and release recovery. | Adapted |
| Tab-strip file drops and active-stroke refusal | Qt returns a forbidden drop action while switching is blocked, preventing parent-window fallback and queued imports into another document. Ready drops select and import into the requested tab; native checks verify recovery and inactive pixel/history isolation. | Adapted |
| Layer-row, multiple-row and folder drag to another existing project tab | The native pointer grab forwards upstream row IDs to Qt's tab destination. Original provider delivery performs the copy. Native checks cover new layer identities, source isolation, repeated copying, drag retirement and destination Undo/Redo; multiple rows retain one Undo per provider, while a folder copies its descendants with remapped parent IDs in one operation. Folder delivery also passes between two Qt windows. Same-project and Alt preflight refusals use the live payload. Physical-desktop acceptance remains open. | Adapted |
| Drop onto empty header space to create a fitted project | Qt's empty header accepts layer-row, file and image drops through the existing project bridge. Native checks verify fitted dimensions, source isolation, layer-copy Undo to the welcome state and exact Redo, plus forbidden busy entry/movement/drop without queued imports. | Adapted |
| Recent documents and clearing history | SQLite retains the app's recent list; system libxml2 updates XDG `recently-used.xbel`, escapes filenames, retains other applications' metadata and clears only Compositor's entries. Seven XML regressions cover these paths. Host desktop visibility through the Flatpak sandbox remains unverified. | Adapted |
| External package changes, unsaved-work choices and own-save suppression | Qt binds open/saved paths to upstream `ProjectWatcher`, `ProjectDigest` and `ProjectController`. Native checks verify same-tab reload, identical-byte suppression, Keep Mine/Revert through Qt alerts, active-stroke deferral/recovery and own-save Undo preservation. The upstream digest uses manifest bytes and asset names/sizes. Native checks also verify dirty inactive-tab deferral, Keep Mine after selection and independent state/history of the other document. Actual desktop/Mac acceptance remains open. | Adapted |
| Half-written external package and recovery | For clean PNG16/HDR documents, native Qt checks truncate the manifest, remove an asset and truncate an asset. The existing upstream loader preserves the same tab, pixels, layers, selection and Undo/Redo state without a prompt. Restoring each package resumes reload in the same tab. Actual desktop sync-client acceptance remains unverified. | Adapted |
| Replacement import detaches the previous project package | Successful file/RGBA replacement reuses upstream watcher cleanup; RGBA replacement clears the old package URL and advances the persistence generation. Regression cases rewrite the former package and verify that the new document/history remain intact. Refused/busy replacements and inserted layers preserve the binding. | Adapted |
| Close project/window during work, Cancel and Don't Save | Qt checks upstream `Workspace.canSwitch` and replacement-import readiness before closing a tab; window-close preparation also refuses when the settled workspace remains busy. Native signals verify no prompt/removal during a stroke, unchanged inactive pixels/layers, blocked window close and Cancel/Discard recovery after release. Async pending-save close remains covered. Physical desktop/Mac acceptance remains open. | Adapted |
| Closing a project window releases its document resources | Accepted Qt close stops autosave and releases the window's session handles immediately. The bridge removes cached canvases, closes compatibility windows and uses upstream watcher/document/workspace cleanup after the last owner closes. Regression tests preserve a shared document and its watcher for another owner, then verify final cleanup; native pending-save close verifies handle removal and stopped autosave. Physical desktop/Mac acceptance remains unverified. | Adapted |
| Portable project package preview | The unchanged upstream exporter supplies the flattened JPEG on white, up to 1024 pixels on the long side and omitted above 50 MP. Linux caches it per frozen save snapshot and Qt writes `QuickLook/Preview.jpg`. Snapshot regressions and the native pending-transform package save pass; Mac/Finder and desktop thumbnailer acceptance remain unverified. | Adapted |
| Project preview thumbnail program | The real `compositor-thumbnailer` executable reads JPEG or fallback PNG previews and writes proportional PNG thumbnails through existing Qt codecs. Required native checks cover decoded dimensions/content, Unicode paths, encoded file URIs, default/explicit sizes, unchanged source and missing/corrupt preview refusal. Host file-manager invocation through Flatpak remains unverified. | Adapted |
| Local file URI launch and Save As | A shared Qt `QUrl` adapter decodes local file URIs, including encoded Unicode/reserved characters and localhost. Save As refuses empty/relative/malformed or remote-authority file URIs and query/fragment suffixes before preparing a save. Native menu checks preserve document/history and create no files on refusal; actual project/image subprocess launches preserve metadata/pixels. Thumbnailer URI checks also pass. Physical portal/desktop delivery remains unverified. | Adapted |
| Held transform modifiers: Auto Select and aspect-ratio lock | Qt clears the released modifier before updating upstream `HeldModifiers`, fixing a stuck aspect lock when release still reports Shift. Native visible-header checks verify Shift/Ctrl flips, retained release flags, independent release of combined modifiers and unchanged stored Auto Select/document/history. Four original transform-press tests and the complete native transform journey pass. Physical keyboard/Mac comparison remains unverified. | Adapted |
| Application deactivation/reactivation and held transform keys | The shared Qt application-state bridge clears modifiers and posts upstream's resign-active notification on leaving the app. On return it polls Qt's platform keyboard state before the existing become-active notification, then refreshes visible headers. Native signal checks cover inactive reset, return with held keys, simulated input elsewhere and return after release, with unchanged document/history. Physical desktop/keyboard/Mac switching remains unverified. | Adapted |
| Hide Compositor / Hide Others / Show All | Hide minimizes every project window. On an X11 session with an EWMH window manager, Hide Others iconifies other applications' top-level windows and Show All maps again only those it hid, not user-minimized ones; Compositor windows and documents are unchanged. Wayland gives clients no access to other clients' windows, so Hide Others is disabled there (and offscreen) and Show All changes nothing. `--app-visibility-probe` checks the disabled case; `--hide-others-probe` drives a separate X11 client under Xvfb/mutter and passes (`.build/evidence/hide-others-x11-pass.log`). Mac comparison is unavailable. | Adapted |
| Menu tracking ends with current modifier state | An application-owned Qt filter waits until the final menu closes, polls platform modifiers, posts upstream's end-tracking notification for Qt menus and refreshes visible headers. Closing a submenu while its parent tracks defers the refresh. Hosted AppKit menus retain their existing notification. Real root/submenu popup checks verify release recovery and unchanged document/history; physical desktop/Mac menu behavior remains unverified. | Adapted |
| Canvas wheel pan/zoom and active-stroke refusal | Qt normalizes wheel units and delegates to unchanged `CanvasView.scrollWheel`, retaining upstream operation gates. Native events verify pan/zoom refusal during a brush stroke, release recovery, precise/notch pan distances, pointer-anchored zoom and unchanged document/history. Existing Qt wheel direction/gain is retained; physical trackpad and Mac comparison remain unverified. | Adapted |
| Trackpad pinch zoom around the pointer | Qt native zoom gestures delegate to unchanged `CanvasView.magnify`. Native events verify zoom in/out with upstream gain, pointer anchoring, active-stroke refusal and recovery, exact document pixels/history and ignored rotation. The complete transform journey passes in `/tmp/compositor-pinch-native.log`; physical trackpad/Mac comparison remains unverified. | Adapted |
| Rulers and creating/deleting guides by dragging | Qt rulers now convert pointer positions through global coordinates, fixing invalid sibling-widget mapping. Native events through the visible upstream menu verify both guide axes after zoom/pan, document coordinates, creation/deletion Undo, new-guide discard on ruler return, Lock Guides refusal and recovery. Rulers have upstream accessibility names. All 14 original guide tests and the native transform journey pass; physical desktop/Mac acceptance remains unverified. | Adapted |
| Opening several different project/image files at startup | Qt processes the whole desktop/CLI argument list through the existing project loader and image importer, creating ordered separate projects rather than stopping after the first file. A real subprocess and native tab checks cover a mixed project/two-image list, Unicode URIs, invalid-path skipping, exact dimensions/pixels and independent histories/Undo. Actual desktop delivery remains unverified; repeated-project reuse is verified below. | Adapted |
| Reopening an already-open project | Qt resolves the requested/known paths and selects the existing tab without loading another copy. A request from another visible project window activates the owning window. Native checks cover same/cross-window opens, file URI/symlink aliases, no extra tab, retained unsaved changes, exact pixels/history and Undo, plus active-stroke refusal/release recovery. Actual desktop/Mac focus behavior remains unverified. | Adapted |
| Updates and platform integration | Flatpak/Qt replace Sparkle/AppKit. Services and Dock integration use Linux platform behavior. Desktop thumbnailer acceptance remains unverified. | Adapted |
| Update dialog, developer copies and refused restart | The dedicated release-workflow test exercises Qt DBus against a private mock portal: SDK/developer copies make no update request and hide install/restart buttons; update progress, refusal/error/retry and monitor closure pass. A refused window close leaves the window and update dialog visible in Ready to Restart without another transaction. The test script now selects user/system SDK explicitly. Actual installed-release update/relaunch remains unverified. | Adapted |

### Historical inventory audit

The visible Clear Selection Pixels probe passes eight image/mask, rectangle/
ellipse and opaque/half-alpha cases, with disabled-without-selection refusal,
independent interior/exterior coverage, exact full-image/record Undo/Redo and
mask-source preservation. All 19 original selection-edit tests and required
integrity pass; `/tmp/compositor-selection-clear.exit` is 0. Its first mask
failure was a probe choosing the hidden legacy menu; visible-menu routing fixes
the harness. The Clear probe expanded the canonical runner to 33 gates; the later Hide
probe makes 34. Completed session 10792 passes its earlier 32-gate scope (exit 0). See [the baseline](upstream-test-baseline.md)
for exact coverage and remaining boundary/transformed/HDR/desktop checks.

Grid Settings now has direct widget and separate-process persistence checks for
spacing/subdivisions, color/style/opacity, invalid-value gates and live warning
hints, Cancel/OK and Restore Defaults Cancel/OK. The probe reproduces and fixes
stale validation while typing and canceled @State values surviving modal closure.
All 14 original guide tests, the controls/restart driver, required integrity and
the corrected build's 1,100 framework tests and four native modal/field
regressions pass. Five supplemental normal-startup canvas captures verify grid
spacing, subdivision lines, opacity and style gaps with exact off-grid pixels.
The corrected 32-gate contract exits 0 in session 10792; it includes these Grid
Settings fixes and precedes the later Hide corrections.
See [the baseline](upstream-test-baseline.md) for exact logs and scope.

The October 16 standalone group-rotation probe closes a bridge-coverage gap in
historical row 19. All six selected-layer/folder quarter-turn cases pass with
unequal asset sizes/origins, an independent shared-center pixel oracle, untouched
unselected content, Cancel/Undo/Redo, retained leaf IDs and unchanged source-file
hashes. The CMake target and required integrity pass; exact logs are in
[the baseline](upstream-test-baseline.md). Pointer rotation and broader member/
angle combinations remain unverified. The earlier 30-command contract exits 0; the new standalone gate passes
separately and is included in the completed 32-gate contract (session 10792, exit 0).

The 1.3.1 inventory is historical: its excluded-test list, test count and `.cproject` format description
do not describe this checkpoint. Current source coverage and the test baseline above/below are the evidence
for upstream `43d691b`; the current project format is `.comp`, version 13 (16-bit PNG layers from version 12;
HDR OpenEXR layers from version 13).

The native persistence audit found that Qt's RGBA8 copy discarded deep pixels and its package loader
accepted PNG only. The corrected native fixture reproduces the precision loss before the fix
(`/tmp/compositor-deep-native-before-fixed.log`, exit 1). Qt now uses unchanged upstream `ProjectStore`
for staged package encoding and complete snapshot decoding, while retaining dimension/cumulative-budget
preflight, encoded-size limits, destination installation, portal fallback and save/autosave revision handling.
OpenEXR's existing library reads EXR header dimensions during preflight. Project-store decoding restores
the full layer assets before installation, including group/mask/text metadata.

Six save-snapshot tests pass with two deep-data cases (`/tmp/compositor-deep-package-focused-verified.log`).
The subsequent full run expands their fixtures and the native save journey to alpha values of zero,
approximately one quarter/one half and one. The 16-bit samples survive within one integer step and HDR
linear-light samples within 0.008; these are fixture tolerances, not Mac visual certification.
The native large-package journey passes with 120 MP each of images and masks, save/reopen pixel identity,
invalid versions, cumulative-budget refusal and preservation of the previous package after a failed save
(`/tmp/compositor-deep-package-limits-final.log`, exit 0). Its obsolete “version 12 is unsupported” assertion
was replaced with zero, the saved version plus one, and 999. Mac/Finder and physical-desktop acceptance
remain open.

The audit found that `compositor_save_export_preview` in `Sources/LinuxBridge/ProjectSaveSnapshot.swift`
returned zero for every document. The Qt package writer accepted optional previews but received none.
Two new regressions fail against that implementation (`/tmp/compositor-preview-before.log`, exit 1).
The bridge now renders the frozen snapshot through upstream `ImageExporter.quickLookImages`, without
returning to a live session/main actor, and caches the result for size/copy calls. All five snapshot tests
pass (`/tmp/compositor-preview-focused.log`, exit 0), including exact upstream JPEG bytes, independently
decoded red/white pixels, replacement/close isolation, insufficient buffers, released tokens, 1024-pixel
scaling and the 50 MP refusal. The file remains optional and autosaves retain their existing preview skip.
The native pending-transform/Save As journey verifies a readable `QuickLook/Preview.jpg` with the expected
canvas dimensions (`/tmp/compositor-preview-transform-native.log`, exit 0). That journey now runs in
`scripts/linux-contract-tests.sh`. Mac/Finder screenshot acceptance and Linux desktop thumbnailer
integration are still unverified.

Separate acceptance check: **macOS → GNU_Linux → macOS project round trips and screenshot comparisons remain unverified**. No Mac is available, as confirmed by the user. Linux fixture round trips cannot establish this result.

The requested xtool trial used official **1.21.0** on 2026-10-13, with its release checksum verified and all
trial files isolated under `/tmp/compositor-xtool-trial`. Its CLI runs on Linux. On a copy of cached upstream,
`xtool dev build --triple x86_64-apple-macosx13.0` fails with `Could not find Package.swift in this directory`
(`/tmp/compositor-xtool-macos-build.log`, exit 1): upstream supplies `Compositor.xcodeproj`, not a Swift package.
`xtool sdk status` reports `Not installed`; the installed Linux Swift toolchain is 6.3.3, while the current
[installation documentation](https://xtool.sh/documentation/xtool/installation-linux/) requires Swift 6.4 and
an Xcode archive for its Darwin SDK. Official [Xcode-project support](https://github.com/xtool-org/xtool/issues/144)
and [macOS GUI cross-compilation](https://github.com/xtool-org/xtool/issues/262) remain open requests.
This trial produced no Mac build and does not establish Mac runtime, color or screenshot parity.

The extended native tab journey passes in `/tmp/compositor-multi-drag-acceptance-final.log` (exit 0).
It verifies multiple selected rows, folder descendants, fresh identities, source pixels/history and exact
destination restoration with upstream provider Undo/Redo semantics. The fixture explicitly creates its
second source layer and widens the offscreen window to expose both original tabs. The release build and
11 unchanged workspace tests pass in `/tmp/compositor-multi-drag-build-hierarchy.log`.
The subsequent two-window extension passes in `/tmp/compositor-two-window-acceptance-visible.log` (exit 0).
It verifies a folder's descendants, fresh layer/parent IDs, source pixels/history isolation and exact
destination Undo/Redo between distinct Qt windows. The destination visibility assertion rejects a target
outside the offscreen display. This verifies Qt event delivery; physical desktop input remains unverified.

The earlier Color Picker full-contract checkpoint exits 0 with **1,058/1,058 passing framework tests** (141 XCTest; 917 Swift Testing in 148 suites), all native editing/preview/save/transform/tab/RAW-lens/text journeys, thumbnailer and 11 source-coverage checks, with required Vulkan hardware. The RAW Import/Camera Raw single/mixed workflows, window cancellation, Crop/Object gestures and selection-clipped Gaussian Blur/Black & White/RGB Levels/Master Hue previews pass. Native folder opacity, all merge variants, expanded-canvas content-aware and current-raster PNG/JPEG helper exports also pass. The held-worker regression and native repetitions verify that `busy` covers asynchronous document work and pixel-move finalization. The same complete run includes autosave draft preservation, shortcut search/cursor/closed-state fixes, conflicts/removal/default restoration, three fresh-process persistence probes, nested folder duplication and mask paint/fill/blur/Feather follow-ups. The same run also includes visible Shape, Flip/Invert, Pixel Grid, Clone Alt/Aligned/All Layers checks the Boolean Picker regression, mask Paint/Alt footer variants, scoped Button event modifiers, recursive Add Mask submenus, mask menu/thumbnail selection proofs, clipping creation/release, live Amount/Expand/Contract/All/Inverse controls, lasso/marquee combinations and curved-hole Skia normalization. It additionally includes visible Gradient/Eraser/Spot Healing/Eyedropper controls and six Wand rounds after the Foundation main-pump correction. The same run includes the Color Picker refresh/normalization and position fixes, both palette targets and the transition to Gradient. Evidence: `/tmp/compositor-color-picker-final-full-contract.log` (exit code 0 also recorded in its `.exit` file). Required-shader/protected-source integrity passes against `43d691b` in `/tmp/compositor-color-picker-integrity.log` (exit 0); see [the current test baseline](upstream-test-baseline.md).

The earlier `/tmp/compositor-painting-controls-full-contract.log` attempt exits 1 at Wand. Diagnostic future-deadline pumping completes the stalled job in 4 ms; the corrected main pump and six-round regression now pass the full runner above. Earlier failed attempts remain recorded in the baseline. A fresh remote-tip check still returns `43d691b`: `/tmp/compositor-main-pump-upstream-tip.log`. Wider feature combinations and physical/Mac acceptance remain open.

The modal Color Picker ownership correction postdates that full checkpoint. Its focused picker/grid tests and all picker targets followed by 16 Gradient cases pass in `/tmp/compositor-grid-color-picker-parent-{build,native}.log`. Required-shader/protected-source integrity also passes after the correction in `/tmp/compositor-grid-color-picker-integrity.log`; the full runner was not repeated for this focused change.

The subsequent native pointer/overflow acceptance passes in `/tmp/compositor-overflow-pointer-full-contract.log`.
It drags the selected visible project across hidden tab indices to the other visible slot, then verifies all
five handles, expected order, layers, exact pixels, modified state and Undo/Redo names/availability.
Choosing a hidden project through the live overflow menu during an active stroke keeps the source selected
and leaves both its live state and every inactive project unchanged. Release restores overflow selection.
The earlier standalone pointer/refusal run also passes in `/tmp/compositor-overflow-pointer-acceptance.log`;
the full run adds explicit inactive-project assertions. This step changes acceptance tests only.

## Overflow selection and refresh closeout

The initial native overflow regression lost all hidden projects after a reorder:
`/tmp/compositor-overflow-before.log` (exit 1). Preserving selection and refreshing after moves alone did
not resolve it, including at minimum window width (`/tmp/compositor-overflow-narrow.log`, exit 1).
Overflow sizing now reads the tab renderer's natural size hints rather than transient `tabRect` geometry.
Visibility updates preserve the selected tab and block internal `currentChanged` signals; moved tabs
refresh overflow, and replaced menus are retired with `deleteLater`.

The strengthened journey passes in `/tmp/compositor-overflow-acceptance-final.log` (exit 0). At the supported
800-pixel minimum, hidden-project selection reveals the project, visible menu edits target it and Undo
restores its pixels. After moving the last tab to the front through Qt's reorder operation, every tab retains
its handle, expected relative order, layers, pixels, modified state and Undo/Redo names/availability;
every rebuilt overflow entry selects its displayed project. The complete contract and integrity logs above
pass with the fix. The later pointer/overflow checkpoint above covers movement across hidden indices and
busy-menu refusal. Physical-desktop/Mac acceptance remains unverified. Protected sources and project-format
fields are unchanged.

## Visible-tab reorder closeout

Upstream `ProjectTabStrip.handleReorder` requires `workspace.canSwitch` before starting a drag. Qt's
movable tab bar previously started one during an active stroke. The native pointer regression reproduces
that mismatch in `/tmp/compositor-tab-reorder-busy-before.log` (expected exit 1).
The tab bar now checks the exact upstream workspace gate through a small C ABI query, plus Linux's
replacement-import readiness, before forwarding the press to Qt's drag machinery. The unchanged
upstream `moveTab` operation still supplies ordering; no document edit or format change is introduced.
Native acceptance passes in `/tmp/compositor-tab-reorder-acceptance-final.log` (exit 0): selected and
inactive moves preserve identity, pixels and history; stepped pointer drags reorder visible tabs;
visible menus and Undo target the selected project in reversed order; busy drags produce no tab move,
and release restores pointer reordering. The complete contract and integrity logs above pass with the fix.

## Project-window activation closeout

Reactivating a Qt window previously left upstream's shared workspace pointing at the other window's project.
The visible New Blank Layer action therefore edited that other project. The regression reproduces this in
`/tmp/compositor-window-activation-before.log` (expected exit 1).
Activation now selects the displayed tab; menu opening and dispatch recheck upstream selection and refuse
when its operation gates prevent switching. `/tmp/compositor-window-activation-busy.log` (exit 0) verifies
visible menu edits after activation in both directions, inactive pixels/history isolation, independent Undo,
a stale action dispatched during an active stroke, and recovery after release. The complete contract and
integrity logs above pass with the fix. No protected source or project-format fields changed.

Focused latest-feature evidence: `/tmp/compositor-latest-upstream-final.log` (26 Swift Testing tests,
plus six defaults XCTest checks), `/tmp/compositor-hdr-imageio-final.log` (native codec checks), and
`/tmp/compositor-parity-source-integrity.log` (required shaders, generators, ledgers and protected-content checks).
The protected-content gate now accepts untracked upstream additions only when their actual bytes match the
reference; modified, missing or additional protected files still fail. Source coverage passes with 11 fault/control checks.

## Native text and command-palette closeout

The previous preview journey exercised hidden shell Undo/Redo actions. Its replacement validates visible menu
roots as they open, then chooses their actual actions. Without the native text responder, visible Undo failed to
restore deleted text; with it, the preview passes. The bridge offers standard text commands to the focused Qt
line edit, rich text edit, plain text edit or spin-box field before a document action can run. Read-only controls
retain clipboard/selection behavior and refuse Cut/Paste without falling through to document pixels.

The Qt palette previously collected both hidden shell actions and the visible upstream menu, and maintained a
second fuzzy-search implementation. It now requests the original upstream catalog and ranking through the
Linux bridge, including all tool modes and layer-mask commands. Execution resolves an entry by its stable ID,
rechecks current enabled state, returns focus to the editor and dispatches on the next event-loop turn.
Disabled entries keep the palette open, and navigation wraps at both ends.

Evidence: `/tmp/compositor-native-text-palette.log` (native preview, exit 0),
`/tmp/compositor-text-palette-full-contract.log` (all 1,035 framework tests plus every native contract journey,
exit 0), and `/tmp/compositor-text-palette-integrity.log` (required shaders and all integrity gates, exit 0).
The isolated control `/tmp/compositor-native-text-control.log` intentionally unregisters the responder and
fails at visible cross-style Undo (exit 1); it proves the missing-host-bridge regression is detected.
The native checks include a single Copy catalog entry, skipped system menus, disabled-entry refusal,
upstream fuzzy tool-mode lookup, text focus restoration, Unicode clipboard edits and IME preedit/commit.
The strengthened run `/tmp/compositor-text-palette-acceptance.log` passes 13 focused upstream/text tests
and the complete native preview. Wrapping is tested with multiple results, and choosing Polygonal Lasso
changes the actual upstream tool and mode while preserving document pixels, layers and history (exit 0).

## Existing-tab selection closeout

The native regression originally failed because visible New Blank Layer edited another workspace tab after a
Qt tab click (`/tmp/compositor-tab-before.log`, expected exit 1). The host now asks upstream to select the tab
before changing its session handle. The bridge reports refused switches, and Qt restores the previous tab
without emitting another selection event. An already-current tab remains valid even during a stroke.

The strengthened `--tab-smoke` journey verifies actual tab clicks and visible menu actions on both documents,
invalid handles, active canvas-stroke refusal, release recovery, a real pixel change in the painted document,
and unchanged inactive pixels/layers/history. It is included in the standard contract runner.
Evidence: `/tmp/compositor-tab-pixel-acceptance.log` and `/tmp/compositor-tab-full-contract-final.log` (exit 0).
Required shaders, generators, ledgers and protected content pass in `/tmp/compositor-tab-integrity.log`.

## Tab-strip drop closeout

Upstream's `ProjectTabDropDelegate` forbids tab-strip drops while the workspace cannot switch. Linux instead
accepted a drop aimed at another tab during a stroke and queued it against the displayed document. The original
native regression fails at this acceptance (`/tmp/compositor-tab-drop-before.log`, expected exit 1).

The host now validates readiness at drag entry, movement and drop, checks the selected destination before
importing, and checks that a new-tab request actually opened a tab. Merely ignoring drag entry allowed Qt to
offer it to the parent window's different target; that second failure is retained in
`/tmp/compositor-tab-drop-acceptance.log` (expected exit 1). Returning `Qt::IgnoreAction` while consuming the
event keeps a forbidden drag on the tab strip. This does not change window drops, which wait for pending edits.

The strengthened native journey passes ready entry, a drop that becomes busy after entry, forbidden busy
entry/movement/drop, zero queued imports, recovery into the requested tab and inactive pixel/history isolation.
Evidence: `/tmp/compositor-tab-drop-acceptance-final.log` and `/tmp/compositor-tab-drop-full-contract-final.log`
(exit 0). The complete runner also verifies the existing waiting window-drop journey. Integrity checks pass
in `/tmp/compositor-tab-drop-integrity.log`.

## Native layer-row project copy closeout

Qt's tab strip previously accepted only files and images, while row dragging remained inside its native Layers
view. The adapter now forwards the live upstream row UUIDs under `com.compositor.layer-row`, validates their
source/destination and calls unchanged `ProjectWorkspace.receiveProviders`. This preserves upstream copying,
folder/mask/effect handling and per-provider history semantics. Handles returned for an existing destination
preserve the caller's handle even if another window registered the same upstream tab. The transient UUID
payload and response buffers are bounded to 1 MiB; nothing is added to the project format.

The native journey performs a real Layers-row pointer drag to an existing project tab. It verifies the copied
name and new identity, unchanged source pixels/layers/history, destination Undo/Redo, same-project and Alt
preflight refusal, session retirement and a second fresh drag with one-step Undo. The adapter-disabled control
fails at delivery: `/tmp/compositor-layer-project-control-final.log` (expected exit 1). Positive native evidence:
`/tmp/compositor-layer-project-repeat-native.log` and the final full contract log (exit 0).

The lifetime audit exposed pasteboard items retained in a global object-address dictionary. Two new regressions
failed with five issues before the fix (`/tmp/compositor-drag-lifetime-before.log`). Items now belong to each
pasteboard and are released on clearing, global release or object destruction. Both tests pass in the full
1,037-test runner, along with all native journeys. Integrity passes in
`/tmp/compositor-layer-project-integrity-final.log` (exit 0).

This closes copying onto existing tabs. Empty-header project creation is verified in the following update;
broader multi-row/multiple-window interaction acceptance remains part of the API audit.

## Empty-header new-project drop closeout

The native Layers-row regression initially failed to create a project when released on empty header space:
`/tmp/compositor-header-drop-before.log` (expected exit 1). That space now has a Qt destination which shares
the tab strip's readiness and delivery callbacks, using destination 0 for a new project. Its window-drag mouse
handling remains separate. Layer drags use unchanged upstream provider copying, so the new canvas fits the
dragged pixels. File and image payloads also create new projects with their own image dimensions.

The strengthened native journey checks real row-pointer delivery, fitted dimensions, the copied layer name,
unchanged source pixels/history, Undo to the welcome state and exact Redo. It also checks forbidden busy
entry/movement/drop with no parent-window fallback, queued import or new tab, and ready file/image imports
without changes to the preceding project. Evidence: `/tmp/compositor-header-drop-acceptance-final.log` and
`/tmp/compositor-header-drop-full-contract.log` (exit 0). The complete run passes all 1,037 framework tests,
native journeys and 11 source-coverage checks. Integrity: `/tmp/compositor-header-drop-integrity.log` (exit 0).

## Behavior still to verify or implement

The six areas tracked in [the six-area acceptance tracker](linux-six-area-implementation.md)
are **Adapted** as of 2026-10-13: GPU canvas and warp acceleration, layer visibility
drag autoscroll, Layers keyboard navigation, layout and window sizing, focus and
accessibility, and busy/import/modal refusal recovery. The tracker states each
Linux-specific difference and its evidence. The main stated difference: warp
computation runs on Vulkan by default, and canvas graphs run on Vulkan in one fused,
bit-exact pass, but the application still presents the canvas with Core Graphics
because full-viewport Vulkan frames remain slower on the reference AMD Renoir GPU.

Source accounting is complete for this checkout; the full API and feature-behavior inventory remains open. Known unresolved work outside those six areas includes:

- A GPU-resident canvas renderer (layer textures sampled on the GPU, GPU blur for the canvas shadow) that would make the Vulkan canvas faster than Core Graphics at full viewport sizes, and the SDR fidelity gap between graph and Core Graphics frames at those sizes.
- Layers panel real desktop/Mac visual comparison; offscreen Qt endpoint containment and pointer-driven resizing pass.
- Actual Mac color/project round-trip comparisons (no Mac available), physical touch/tablet and native Wayland verification. HDR/PQ/HLG and floating-point TIFF imports now have independent Linux codec evidence as listed above.
- External screen-reader sessions (the native Qt accessibility API is verified) and current feature coverage of ledger references and old manual/screenshot claims.
- Broader multi-row/folder and multiple-window drag acceptance. Existing-tab copy and empty-header project creation are verified above.

See [TODOS.md](../TODOS.md) for the remaining closeout work. The [1.3.1 element inventory](mac-linux-parity-inventory.md) remains historical; its broad feature statuses have not all been re-audited at this tip.

The later autosave production fix has targeted verification in `/tmp/compositor-gradient-autosave-final-build.log`, three native combination logs and `/tmp/compositor-gradient-autosave-final-save.log`. The current full-contract log above now includes that fix; see [the test baseline](upstream-test-baseline.md).

The later shortcut-window fix passes 12 core/lifecycle tests, the complete native combination and preview journeys, and an additional full combination run with middle-text editing/cursor assertions. Historical row 68 is Adapted within that scope. At that checkpoint, live upstream returned `43d691b`. The unfiltered baseline includes this fix; see [the completion audit](linux-status-completion-audit.md).

The newer required-hardware complete runner passes in
`/tmp/compositor-pdf-tiff-matte-full-contract.log` (terminal exit 0 and `.exit` = 0).
All 1,058 framework tests, all native journeys including the expanded picker
families and six Wand rounds, thumbnailer and 11 coverage checks pass.
This includes the modal picker parent, menu Toggle hosting and PDF page matte
corrections. Independent PDF/TIFF artifact validation and required integrity
also pass in `/tmp/compositor-pdf-tiff-matte-{independent,integrity}.log`.
PDF matte re-import and physical/Mac acceptance remain open.
