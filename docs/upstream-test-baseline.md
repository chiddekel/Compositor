# Upstream test baseline (unmodified `CompositorTests` on Linux)

## Current green checkpoint: 2026-10-11, upstream `39d1257`

Merged as `74dbacf`. The final unfiltered `scripts/linux-contract-tests.sh` run inside the prepared KDE 6.11
Flatpak SDK passed **869/869 framework tests**: **121 XCTest** (2.806 seconds) and **748 Swift Testing**
across **122 suites** (146.395 seconds), with no runtime skips. All 81 upstream test files are accounted for
(80 unchanged and one selector mirror); macOS UI automation remains outside the Linux target.

The same runner passed all nine source-coverage checks, real Skia/ImageIO/HEIF/font checks, native kernel tests,
and the complete combination, preview and text journeys. PatchMatch checks include seed determinism,
outside-hole preservation, no-source refusal, ten allocation faults and both stride guards. Native editing
covers preserved blur alpha/geometry and exact Undo/Redo, queued Smudge/Liquify turns and release, and the
upstream RAW sheet’s supported controls, disabled lens explanation, Reset and Cancel. Generated Bayer DNGs
verify actual LibRaw draft/full noise and highlight pixel changes, unsupported small-sensor noise, stable
capabilities/dimensions and exact default-preview restoration at two sizes.

WarpCommitParityTests passes all five methods (14 cases) against the unchanged upstream commit oracle;
WarpTipCacheTests also passes its six cases. RawDevelopCapabilityTests verifies callbacks/defaults/reset and
all controls in the actual sheet. The compatibility fix applies modifiers to every Group sibling. The Linux
bridge blur regression now checks both canvas-edge and inset-layer behavior, solid borders and exact Undo/Redo.
Lens correction remains unsupported by the existing RAW backend. These transient controls add no project-format fields.

Complete run: `/tmp/compositor-upstream-catchup-full-contract-verified.log` (exit 0).
Focused/native Group run: `/tmp/compositor-raw-group-contract.log` (exit 0).
Required-shader integrity: `/tmp/compositor-upstream-catchup-integrity-final.log` (exit 0).
Source reports: `.build/linux-contract-native/package-description.json` and `source-coverage.json`.
Protected `Compositor/`, `CompositorTests/`, `CompositorUITests/` and `Compositor.xcodeproj/` match upstream exactly.

Earlier failures remain diagnostic evidence: `/tmp/compositor-warp-commit-before.log` captures the original
warp differences. The first catch-up full run exposed an obsolete canvas-edge blur expectation; the next
run exposed Foundation’s nested-dictionary comparison in the added Undo assertion. Geometry/pixel checks
passed, and canonical JSON comparison now verifies every transform field. The native RAW journey also
found LibRaw 0.22.2’s uninitialized OpenMP wavelet allocation count and the missing Group children; both
are fixed and covered by the final run. A clean hosted dependency build/CI run has not been executed locally.

## Earlier checkpoint: 2026-10-11 (before upstream catch-up and warp commit checks)

Release build of the current GNU/Linux worktree succeeded with Swift 6.3.3 in KDE SDK 6.11. With the Skia and
ImageIO backends explicitly configured and `CameraRawTables.bin` copied beside the test executable, the full
unfiltered run completed: **856/856 tests passed: 121 XCTest and 735 Swift Testing across 120 suites**, with no runtime
skips. Compiled target exclusions remain in `Package.swift`; these counts do not include macOS UI automation.

A subsequent audit added WarpCommitParityTests and an unchanged upstream commit oracle. Its original two methods
(eight parameter cases) failed with 19 issues: synchronous commit pixels differed, and sliced input also differed
in points/pixels (`/tmp/compositor-warp-commit-before.log`). The current implementation fixes those failures by
preserving queued segments and upstream commit coverage/sampling. The four audited commits through `39d1257`
are now merged as `74dbacf`; the historical 856-test checkpoint below predates that work. See
[the current inventory](current-linux-compatibility-inventory.md).

```sh
install -m644 Compositor/Resources/CameraRawTables.bin .build/x86_64-unknown-linux-gnu/release/
COMPOSITOR_SKIA_BRIDGE="$PWD/.build/linux-contract-native/libCompositorSkiaBridge.so" \
COMPOSITOR_IMAGEIO_BACKEND="$PWD/.build/linux-contract-native/libCompositorQtImageIO.so" \
QT_QPA_PLATFORM=offscreen swift test -c release --skip-build --no-parallel
```

Run the command inside the Flatpak SDK with its Swift extension enabled. That earlier full run took
141.924 seconds for Swift Testing and 2.880 seconds for XCTest. Native combination, preview and text journeys
also completed successfully; the complete runner returned 0. Log: `/tmp/compositor-full-contract-panel-width-final.log`.

Previous upstream `b2a0c45` was merged as `83a8cd5`, incorporating narrow-panel sizing and folder imports.
The two new ImageImportTests run unchanged: folders expand only their direct importable children in natural
name order, omit hidden/nested/non-image files, exclude project packages, and report empty folders.
The native import flow now collects mixed image/folder selections through native file and directory choosers.
Its preview journey verifies add/remove/duplicate handling and the resulting three-layer name order; the complete
853-test runner and all native journeys returned 0. Real desktop portal directory grants remain unverified.
The Qt Layers dock now resizes within upstream’s 222–352-point bounds, forwards its content width to the unchanged
LayersPanel body, and persists it without a document edit. Three LayersPanelWidthTests cover old preference clamping,
persistence, invalid offers and targeted panel invalidation; all 42 focused width/hosting/scroll tests passed. The
native preview verifies endpoint control containment and a pointer-driven splitter drag. Native custom pop-up
minimum sizing follows upstream’s sizeThatFits; the stack’s decorative border no longer consumes its content width.
The pre-change fixed-width dock fails this journey. Real desktop layout and Mac screenshot comparison remain unverified.
An initial full width-change run passed all 856 framework tests, then timed out in the native combination journey
after selection/gradient Undo. The same binary passed the standalone combination rerun; the runner now reports the
precise rail/drag/gradient action and session state on a timeout. This intermittent failure remains recorded in
`/tmp/compositor-full-contract-panel-width.log` and `/tmp/compositor-panel-width-combo-recheck.log`.
The final complete runner (`/tmp/compositor-full-contract-panel-width-final.log`) passed all 856 framework tests,
all nine source-coverage checks and all native journeys with exit 0; no framework test was skipped. The earlier
intermittent combination timeout is not considered explained by that successful rerun.

The SDK runner now evaluates SwiftPM source targets and checks all 151 protected Swift files: 124 unchanged,
20 generated adaptations, five backend replacements and two platform substitutions. All 81 upstream test files
are accounted for (80 unchanged, one selector mirror). The source gate has nine Python checks: two valid controls and seven injected faults for missing sources,
undeclared or duplicate implementations, and missing/duplicate mirrors; these are separate from the 856 framework
count. See [the current inventory](current-linux-compatibility-inventory.md). The full runner includes this gate;
its source-coverage and initial eight checks passed before the framework and native journeys. All nine final checks then passed in the SDK (`/tmp/compositor-source-coverage-sdk-final.log`); existing tip/pinned policy remains the separate drift gate’s responsibility.

`DocumentHistory` now compiles directly from upstream. The Linux first-canvas baseline patch and generated
history override have been retired: Undo of initial New Canvas restores no document, and Redo restores the
canvas, active layer and unsaved revision. All seven original HistoryTests run unchanged, including the two
previously failing cases. Both CI jobs run them; the weekly job has no per-test skips. The generator rejects
a stale history override so it cannot silently replace the upstream type again.
The native Qt journey verifies Ctrl+Z to the visible welcome screen and immediate Ctrl+Shift+Z back to exact
canvas pixels, the original active layer and modified state. After history retirement, the contract runner passed 73 Swift Testing tests
and 5 XCTest tests, native color checks and the editing/touch/Camera Raw journeys.
Log: `/tmp/compositor-upstream-history-contract.log`. The existing native `--dialog-smoke` also passed
after this history change (resize, filter preview/commit/Undo, palette, autosave, save/reopen and tool transitions).
Log: `/tmp/compositor-upstream-history-dialog.log`. Required-shader integrity checks passed.

Constrained HStack/VStack measurement now shares main-axis allocation with placement. Responsive native
views receive their allocated width/height, after spacing, fixed children and layout priority, before the
cross axis is measured. Six new checks passed (21 HostingMeasurementTests total), including vertical and
nested stacks and retention of unknown bounds for renderer-owned leaves. The first three failed against
the old implementation with oversized panel heights; all passed after the fix.
The contract runner passed 76 Swift Testing tests and 5 XCTest tests after those first three checks, followed
by native editing, synthetic touch and Camera Raw sizing journeys. The final six checks passed in the
unfiltered 816-test run above. Logs: `/tmp/compositor-constrained-hosting-regression.log` and
`/tmp/compositor-constrained-hosting-contract.log`.

Natural hosting sizes now come from the actual Qt widget builder through a registered measurement callback.
Supported text, buttons, toggles, fields, sliders, pickers and symbol labels participate in both fitting and
native placement. Font/control environments reach separately measured descendants. The callback strips
lifecycle/event modifiers, rejects unsupported descendants and measures hidden widgets without showing them.
The GUI probe checks text bounds, inherited font size, padding counted once, constrained wrapping and line
limits, button chrome, every supported control kind, placement beside a native view, no dispatched actions,
and fallback for unsupported images or an unavailable renderer. Existing 21 HostingMeasurementTests still
pass headlessly. The complete contract runner passed all 824 framework tests and native backend, combination,
preview and text/hosting journeys with process exit 0. Logs: `/tmp/compositor-hosting-gui-probe.log` and
`/tmp/compositor-full-contract-hosting-renderer.log`. Sizing options, scroll geometry and broader SwiftUI/Qt
text-layout parity remain open; natural widget measurements alone do not prove all macOS layout behavior.

Hosting intrinsic sizing now follows the option contract: `.standardBounds` combines `.minSize`,
`.intrinsicContentSize` and `.maxSize`; the intrinsic option exposes ideal metrics, while `[]` leaves those
metrics unspecified without disabling explicit fitting measurements. A known dimension survives when the
other is unknown. Root changes and native intrinsic-size invalidation schedule the parent Auto Layout pass.
Four new tests reproduced failures before the fix; all 25 HostingMeasurementTests now pass. The GUI probe
also verifies that Auto Layout consumes Qt-measured text metrics and updates a child's frame after a longer
text root replaces it. The complete runner passed 828 framework tests and all native journeys with exit 0.
Logs: `/tmp/compositor-hosting-intrinsic-before.log`, `/tmp/compositor-hosting-intrinsic-after.log` and
`/tmp/compositor-full-contract-hosting-intrinsic.log`. The contract is documented in
[Apple's sizingOptions reference](https://developer.apple.com/documentation/swiftui/nshostingview/sizingoptions).
At that checkpoint, minimum/maximum constraint generation and window size bounds remained unimplemented;
the later hosting-limit implementation is described below.

The Auto Layout solver now enforces required dimension inequalities on sizes not already determined by
required equalities. It intersects constant and sibling-dimension bounds before resolving centered/trailing
positions, handles layout guides and supports multiplier inequalities with the adjustable dimension on
either side. Three initial cases failed before the fix; all four LayoutDimensionBoundsTests now pass, along
with the 25 hosting and two reused-mask geometry checks. Per-push CI includes the bounds suite. The GUI
hosting probe constrains actual Qt-measured text metrics with minimum/maximum width anchors. The complete
runner passed 832 framework tests and all native journeys with exit 0. Logs:
`/tmp/compositor-layout-bounds-before.log`, `/tmp/compositor-layout-bounds-after.log` and
`/tmp/compositor-full-contract-layout-bounds.log`. Positional inequalities, lower-priority constraints and
infeasible intervals remain outside this propagation solver's supported cases. Hosting-generated minimum/maximum constraints were still pending at that checkpoint; they are implemented
below. Window bounds remain pending, so the entire sizing-options contract is not yet complete.

Hosting views now generate required minimum/maximum dimension constraints when participating in Auto
Layout, according to their enabled sizing options. The constraint pass runs before the containing view solves
its layout. Minimum and maximum proposals are forwarded through frames, padding, stacks and representables;
unknown or infinite maxima do not create finite caps. Generated constraints follow root updates and disappear
when the corresponding option is removed or the host returns to autoresizing. Two cases reproduced missing
constraints, and a third caught an unbounded representable being incorrectly capped at its ideal size. Infinite
responses are now accepted only on axes proposed as infinite; ordinary invalid-size fallback remains tested.
All 28 hosting tests passed in the full runner, alongside 835 total framework tests and all native journeys.
The GUI probe verifies generated width limits and their update using real Qt text metrics. Logs:
`/tmp/compositor-hosting-generated-bounds-before.log`, `/tmp/compositor-hosting-generated-bounds-after.log`,
`/tmp/compositor-hosting-unbounded-before.log` and `/tmp/compositor-full-contract-hosting-limits.log`.
Apple documents the maximum proposal in its
[maxSize reference](https://developer.apple.com/documentation/swiftui/nshostingsizingoptions/maxsize).
Window content minimum/maximum sizes were still pending at this checkpoint; they are implemented below.
Constraint priority/position coverage and scroll behavior remain open.

Compatibility windows now expose content minimum/maximum sizes and apply hosting-root measurements to
those bounds. Unknown axes retain explicit window limits; disabling hosting sizing restores the underlying
explicit limits. `setContentSize` clamps to the bounds while the explicit `setFrame(_:display:)` path bypasses
them; both keep the content view sized to the window. Replacing content detaches its window association,
and moving a root to another window clears the previous window's content and hosted limits. Four cases
reproduced failures before the fix; a fifth checks unknown-axis/explicit-limit restoration. All 33 hosting
tests passed in the complete 840-test run, followed by all native journeys, with process exit 0.
The GUI probe measures window bounds using actual Qt text metrics and verifies bounded content sizing,
clearing options and detachment. Logs: `/tmp/compositor-window-hosting-bounds-before.log`,
`/tmp/compositor-window-hosting-bounds-after.log` and `/tmp/compositor-full-contract-window-bounds.log`.
Apple documents content sizing enforcement in
[contentMinSize](https://developer.apple.com/documentation/appkit/nswindow/contentminsize).
These checks exercise the compatibility window model. Qt's existing floating panels use a separate session
path with fixed fit-content layouts; native window-manager forwarding of compatibility bounds is not verified
by this probe and remains an integration audit item.

Native AppKit scroll views now exchange viewport dimensions, rendered document dimensions and offsets with
Qt. Programmatic reveals reach the native scroll bars; manual offsets return to the clip view and survive
subsequent layer updates. Drawing a full document no longer expands or resets its viewport. Deferred reveals
wait for the first usable viewport, unflipped documents convert Qt's top-left coordinates, and hosted document
dimensions survive upstream fitting fallbacks. Short native tables fill their viewport while long tables retain
their full row height. Geometry callbacks update viewport state without dispatching document edits.
Four initial regression cases failed before the fix; all six NativeScrollGeometryTests pass and run in per-push
CI. The native preview journey verifies a short table fills its viewport, a selected bottom layer is revealed
in a 25-layer list, and manual scrolling survives a visibility update without changing pixels or Undo state.
The short-table assertion also failed before its sizing fix. The complete runner passed all 846 framework
tests and existing native journeys. Logs: `/tmp/compositor-native-scroll-before.log`,
`/tmp/compositor-native-scroll-after.log`, `/tmp/compositor-short-table-before.log` and
`/tmp/compositor-full-contract-native-scroll.log`. Broader scroll fitting, wheel/autoscroll and keyboard
interaction parity remain open.

The compatibility table now handles Up/Down selection when the upstream layer table forwards those keys to
its superclass. It sends selection notifications and reveals the selected row. Shift-arrows extend and contract
a range around its anchor, including switching from plain navigation; selection changes or removed rows reset
the remembered range. Single-selection tables and row boundaries remain valid, and modified, unrelated or
disabled keys continue through the responder chain. Five NativeTableKeyboardTests run in per-push CI.
Three initial cases failed before the handler (ten assertions); the actual native journey then exposed a missing
anchor when switching from plain arrows to Shift-arrows, reproduced by the expanded regression. A separate
removed-row regression caught an out-of-range anchor. Both fixes pass in the complete 851-test run.
The Qt preview journey uses platform keyboard dispatch with verified focus, including deferred focus restoration
after panel replacement. It verifies Up/Down selection, Shift extension/contraction without an Undo step, and
the upstream Move-tool override's exact one-pixel nudge of a visible layer. Existing native editing, mask,
scrolling, font and text journeys also passed; protected Mac trees remain unchanged. Logs:
`/tmp/compositor-table-keyboard-before.log`, `/tmp/compositor-table-keyboard-anchor-before.log`,
`/tmp/compositor-table-keyboard-removed-rows-before.log` and `/tmp/compositor-full-contract-table-keyboard-bounds.log`.
Type selection, page/home/end keys, disjoint-selection semantics and actual Mac comparison remain audit items;
this checkpoint establishes the exercised arrow paths rather than complete table keyboard parity.

System font factories now retain all nine weights, fixed-pitch traits and monospaced digits in native text
and SwiftUI lowering. Native text and Qt controls share one weight mapping; semibold is matched before bold,
and ultraLight/thin map in increasing weight order. Three SystemFontTests passed, including the actual
upstream mask badge's AppKit title font. The native FontTraits test checks all weights, PostScript semibold/
italic aliases, fixed pitch and the `tnum` feature. Its isolated old-parser regression fails as expected.
The Qt text smoke verifies regular/semibold glyph pixels differ and attributed/AppKit bounds match drawing.
It also retains its mixed-font, wrapping and color checks. Both native checks now run in the CI runner;
SystemFontTests is included in per-push CI.
The final exact runner passed locally without filters or skips: all 819 framework tests followed by native
editing/touch/Camera Raw and text journeys. The filtered contract passed 87 framework tests and the same native
checks. Logs: `/tmp/compositor-full-contract-system-fonts.log`,
`/tmp/compositor-system-font-shared-contract.log`, and `/tmp/compositor-font-traits-regression.log`.

Named AppKit fonts now retain the complete name through lowering; Qt resolves family/style aliases,
PostScript names and full names from installed faces' name tables. Custom SwiftUI text and picker faces use
the same resolver. The Swift scanner includes bundled Inter, and monospaced factory names can be reopened.
The app and native journeys share UI-font setup; native system-text measurement uses the selected application
font, following the bundled Inter preference in MACOS_UI_PARITY_RULES.md. Three added font checks passed;
the filtered runner passed 90 framework tests and all native journeys. The complete runner then passed
822 framework tests without filters/skips and all native color/editing/touch/Camera Raw/text checks.
Bundled Inter's PostScript/full names produce identical semibold pixels and bounds. The isolated old resolver
reports regular weight 400 instead of semibold 600. Logs: `/tmp/compositor-full-contract-named-fonts.log`,
`/tmp/compositor-named-font-bundled-contract.log`, and `/tmp/compositor-named-font-regression.log`.

The native preview journey now passes. Its retired Qt mask-thumbnail locator was replaced with the
current upstream AppKit table. A fresh masked cell laid out correctly, but a reused cell placed the mask
at x=83 instead of x=106: `removeFromSuperview` deactivated the cell's internal constraints. Detaching a
subtree now removes only constraints connecting it to outside views, retaining its internal view/guide
constraints for reuse. The reused-row regression failed before this fix and passes afterward.
`--preview-smoke` now verifies layer/folder mask Shift-click with exact Undo/Redo pixels, live unlinked mask
transforms, selected-pixel move/duplicate previews, Unicode text editing, font-picker changes, formatting
Undo/Redo and format-11 save/reopen. It is included in the CI contract runner, and NativeMaskGeometryTests
is included in per-push CI. The complete updated runner passed all 824 framework tests, native backend
checks, tool combinations, preview and text journeys with process exit 0. Full log:
`/tmp/compositor-full-contract-mask-reuse.log`. Focused logs: `/tmp/compositor-mask-reused-row.log`,
`/tmp/compositor-mask-reuse-fix.log`, and `/tmp/compositor-mask-reuse-preview.log`.

The new `PendingGradientTests` passed, including successful, busy, failed, changed-target and held-worker paths;
the targeted PendingGradientTests / ToolCombinationTests / UpstreamEditorTests run passed all 38 tests. The full
run also passed `TouchTargetsTests` and `ColourManagementTests`; neither proves physical touch behavior or full
color-management coverage. Logs for this session: `/tmp/compositor-full-tests.log` and
`/tmp/compositor-gradient-renderer-tests.log`.

The contract and weekly workflows now provision the pinned manifest dependencies and run `scripts/linux-contract-tests.sh`
inside the build environment. Neither job uses per-test skips; the local full
baseline above is unfiltered. This runner rebuilds Skia/ImageIO, requires the native Skia smoke to pass, installs
Camera Raw tables and invokes both the selected suites and `--combo-smoke`. Through `flatpak-builder --run` locally,
it passed **73 Swift Testing tests across 12 suites and 5 XCTest color/import tests, plus initial canvas history and all 6 native combination journeys**. The journeys cover selection/gradient,
selected-pixel movement, transform release, pending-gradient/brush sequencing, selected text/local Undo/live-text
restoration, and refused switches/recovery. They compare every pixel outside selections and use Qt's window-level
key path, including menu shortcuts. Existing `--transform-smoke` and `--dialog-smoke` also passed. The combo journey
exposed a disabled stale Undo accelerator; the host now validates menu state on ShortcutOverride before Qt matches
the key equivalent. It also proves bridge refusals produce diagnostics without status-bar error text.

The four legacy format-11 test mirrors have been removed. Their original upstream TypeToolTests, GroupTests,
LayerMaskTests and LayerAppearanceTests remain unchanged and passed **40 tests across 4 suites** after the
removal, followed by the native combination and touch journeys. The format generator rejects stale copies when
tip already owns format 11; the Linux image fixture helper remains. Log: `/tmp/compositor-original-format11-tests.log`.

The same combo smoke now delivers synthetic touchscreen events through a Qt window and tablet/mouse events
through the canvas. It verifies large transform reach after touch with Qt, system and application mouse synthesis;
pen input (including explicit pen metadata) and real mouse restore normal reach. Touch in a second window remains
usable after that window closes. Each check distinguishes resizing through a corner from the ordinary Move drag
and verifies Undo. The application owns one filter with no window captures, and handle drawing stays unchanged.
The old filter fails the corrected pen-restoration check; the fixed filter passes. These are synthetic-event checks,
not physical touchscreen/tablet or native Wayland verification. Logs: `/tmp/compositor-touch-contract.log` and
`/tmp/compositor-touch-regression-old.log`.

The contract runner also requires `test_imageio_color --require-heif`, which uses the production decode/encode
callbacks and independently encoded fixtures. It verifies PNG gray/gray-alpha conversion (including 16-bit),
linear RGB alpha, P3 alpha, genuinely untagged import, actual decoded sRGB profiles in PNG/JPEG/TIFF/WebP exports,
HEIF BT.709/linear/sRGB transfer at 8/10/12 bits, ICC precedence and HEIF export profile/alpha. This exposed and fixed
Qt rejecting the nonmonotonic BT.709 table, and gray-alpha PNG profiles being dropped after RGB expansion. The latter
uses CRC-checked PNG ICC recovery with a 4 MiB decompression limit, and converts gray independently of alpha.
Qt's behavior is visible in its [PNG reader](https://code.qt.io/cgit/qt/qtbase.git/tree/src/gui/image/qpnghandler.cpp?h=6.11)
and [QImage profile assignment](https://code.qt.io/cgit/qt/qtbase.git/tree/src/gui/image/qimage.cpp?h=6.11).
The Swift untagged test now uses an independently constructed PNG containing only IHDR/IDAT/IEND. Its marker-based
export checks alone remain weaker evidence than the native decoded-profile checks. Per-push CI includes both Swift
color/import suites. HDR/PQ/HLG, floating-point TIFF and actual Mac color comparison remain unverified.
Logs: `/tmp/compositor-color-contract.log` and `/tmp/compositor-combined-color-contract.log`.

Grayscale TIFFs with alpha now decode through libtiff, preserving source precision and alpha before ICC conversion.
The prior Qt path produced opaque RGB and discarded the gray profile; a second parser confirmed that the independent
fixture contains both. Four manually assembled 8/16-bit, little/big-endian fixtures pass, including a dark 16-bit value
that catches premature reduction. A 32-case independent libtiff-writer matrix covers Deflate compression with horizontal
prediction, strips/tiles (including edge tiles), contiguous/separate planes, associated/straight alpha, black/white
photometry, BigTIFF, orientation and DPI. A truncated strip is rejected without falling back to opaque Qt decoding.
The isolated old Qt path fails the same pixel check (1 instead of sRGB 13). Block allocations and embedded profile sizes
are bounded; allocation failure returns a decode error. CMake requires libtiff 4.5+ and both host builds link it explicitly.
The exact contract runner passed 71 framework tests and all native color/editing/touch/Camera Raw checks after this change.
Logs: `/tmp/compositor-gray-tiff-contract-final.log` and `/tmp/compositor-gray-tiff-regression.log`.

`NSHostingView.fittingSize` now measures explicit frames, padding, stack spacing and native intrinsic sizes.
The initial fifteen HostingMeasurementTests passed, including native root updates without recreating the view, missing intrinsic
axes supplied by a frame, empty stacks, restored lowering state, no dispatched actions, unknown-control fallback,
and the actual upstream FloatingPanelController's content dimensions and preserved top-left position. The six
upstream FloatingPanelTests also passed. Per-push CI now includes both suites; the exact runner invocation passed
66 Swift Testing tests and 5 XCTest tests, plus the native color, editing, touch and Camera Raw sizing checks.
Unknown SwiftUI text/control sizes still use the 320×240 fallback, so complete hosting parity remains open.
`NSViewRepresentable.sizeThatFits` now reaches the existing native view and coordinator in both natural measurement
and placement. Frame and fixed-size proposals are forwarded, including through padding; invalid sizes fall back to
intrinsic bounds. Six added checks cover that callback, coordinator/view reuse, latest updated native state,
fixed-size placement, invalid results, CameraRawSlider and preservation of already assigned lowering widths.
The native Qt journey now opens Camera Raw, checks the lowered temperature slider's 22-point height before/after
panel relayout, then cancels and compares every document pixel. The existing `--dialog-smoke` also passed separately;
it does not itself open Camera Raw. Constrained native-stack allocation is now covered above; renderer-backed text/control leaf measurement is implemented above; sizing options, scroll geometry and broader text-layout parity remain.
Logs: `/tmp/compositor-custom-sizing.log`, `/tmp/compositor-custom-sizing-contract.log`, and `/tmp/compositor-custom-sizing-dialog.log`.

A fresh hosted CI dependency build has not been executed. A run without the explicitly configured renderer
libraries failed pixel checks and the initial parallel combined run crashed. The configured sequential runs above
establish the current evidence; parallel stability remains unproven. The refreshed full-suite log is
`/tmp/compositor-full-contract-named-fonts.log`; runner and native journey logs are `/tmp/compositor-combo-contract.log`,
`/tmp/compositor-native-transform.log`, and `/tmp/compositor-native-dialog.log`.

The previous October 11 run had 835 tests (833 passed, 2 failed), including 40 duplicate format-11 tests.
The deduplicated run had **795 tests (793 passed, 2 failed)**. The first nine hosting measurement tests brought it to **804 tests (802 passed, 2 failed)**.
Six custom sizing checks brought it to **810 tests (808 passed, 2 failed)**. Retiring the Linux history deviation
brought that run to **810 tests (all passed)**. Six constrained hosting checks bring the current run to
**816 tests (all passed)**. Three system-font checks brought that run to **819 tests (all passed)**. Three named/bundled-font checks
brought the earlier checkpoint to 822 tests. Two mask/subtree constraint regressions brought the checkpoint to 824 tests; four intrinsic-size regressions brought it to 828 tests. Four dimension-bound regressions brought it to 832 tests. Three hosting-limit regressions brought it to 835 tests; five window-bound/ownership regressions brought it to 840 tests. Six native scroll regressions brought it to 846 tests; five table keyboard regressions brought it to 851 tests. Two new upstream folder import tests brought it to 853 tests. Three Layers panel width regressions now bring it to **856 tests (all passed)**.

The entries below are historical checkpoints, not verification of this worktree.

Run: `COMPOSITOR_SKIA_BRIDGE=<cmake-b>/libCompositorSkiaBridge.so COMPOSITOR_IMAGEIO_BACKEND=<cmake-b>/libCompositorQtImageIO.so QT_QPA_PLATFORM=offscreen swift test --no-parallel --skip CompositorCoreTests --skip tiledLayersDrawLikeOneImage`
(`tiledLayersDrawLikeOneImage` passes but takes ~110 s on the software path. Build the libraries with
`ninja CompositorSkiaBridge CompositorQtImageIO`.)

Progress: All 211 tests across 35 active upstream test suites pass cleanly on Linux (100% green).
All confirmed upstream test regressions and platform-incompatible UI tests are quarantined and documented in `linux/UPSTREAM_TEST_EXCLUSIONS.md`.

Failing tests: None. All 211 tests in CompositorUpstreamTests pass.


## 2026-09-21 re-check: FilterTests and LayerAppearanceTests

Both files are compiled again (file-level exclusion removed). 7 of their 9 tests pass; the 2 that fail are stale
upstream tests, skipped individually (see `linux/UPSTREAM_TEST_EXCLUSIONS.md`):
`--skip gaussianBlurSoftensAHardEdgeWithoutFadingTheBordersAsOneUndoStep --skip moveToolNumberKeysSetSelectedLayersOpacityAsOneUndo`.

## 2026-09-21 re-check: TiledLayerTests and DistortTests

Both files compile again. 5 of 9 tests pass (`distortedLayerIsTrimmedToItsVisiblePixels`, `tiledLayersDrawLikeOneImage` x3,
`paintingAtTheLayersEdgeDoesNotChangeIt` x2, `paintingAScaledDownLayersMaskDoesNotShiftItsPixels`). Skip per test:
`--skip perspectiveMappingHitsTheCorners --skip distortingWarpsTheLayerIntoTheShape`.
Distort's two are stale upstream tests. The three Tiled ones are real Linux fidelity gaps (clip rasterisation and piece
resampling), open work, not upstream problems.

Correction: `paintingAScaledDownLayerDoesNotShiftItsPixels` is not a Skia resampling gap. The AppKit shim's cached-display bitmap
(`bitmapImageRepForCachingDisplay`, `NSImage(size:flipped:drawingHandler:)`) was a top-left-origin context with an emulated
flip, so images drew mirrored inside each drawn rect, and pieces disagreed with the whole layer. Those contexts are now real
bottom-left Core Graphics bitmaps (flipped views flip them back) and the test passes. Only the two 25° tile-seam tests remain
skipped in TiledLayerTests (`translucentStrokesDrawLikeOneImage`, `maskStrokesDrawLikeOneMask`).

Fixed: the 25° tile-seam failures (`TiledLayerTests`, now fully passing, 6/6, ~7 min in a debug build). Skia rasterizes a
hard-edged clip under a rotation differently depending on what is already clipped (it trims the edge to the current clip,
which shifts fixed-point rounding at pixel-centre ties), so upstream's clear-then-draw-inside-the-clip pattern drew a
few edge pixels twice. The bridge now rasterizes such clips once, against the whole surface, and applies them as a
region, so a path has one answer as in Core Graphics (`HardClipConsistencyTests` locks it in). The earlier
"Skia vs Core Graphics rasterization" wording was only half right: the fill/clip/image-draw primitives agree; the
ancestor-dependence was the cause.

## 2026-09-22 current baseline (post upstream 1.1.8 -> 1.2.2 merge, CompositorCore retirement)

Run: `COMPOSITOR_SKIA_BRIDGE=<cmake-b>/libCompositorSkiaBridge.so COMPOSITOR_IMAGEIO_BACKEND=<cmake-b>/libCompositorQtImageIO.so
QT_QPA_PLATFORM=offscreen swift test --no-parallel --skip CompatTests --skip LinuxOverrideTests --skip tiledLayersDrawLikeOneImage
--skip gaussianBlurSoftensAHardEdge --skip moveToolNumberKeysSetSelectedLayersOpacity --skip perspectiveMappingHitsTheCorners
--skip distortingWarpsTheLayerIntoTheShape` (the test-target name is now `CompositorUpstreamTests`, not `CompositorCoreTests`
— that fork target no longer exists).

**260 of 260 run tests pass** (up from the 211/222 baselines above; 1.2.0-1.2.2 added PSD/RAW import, Outer Glow,
Invert/Black&White/Color Balance, and the full Photoshop blend-mode set, each with its own tests). Only 5 stale-upstream-test
skips remain, all previously verified as genuine upstream test bugs (not Linux fidelity gaps), each documented at its
own re-check above:
- `gaussianBlurSoftensAHardEdgeWithoutFadingTheBordersAsOneUndoStep`
- `moveToolNumberKeysSetSelectedLayersOpacityAsOneUndo`
- `perspectiveMappingHitsTheCornersAndTwistedShapesAreRefused`
- `distortingWarpsTheLayerIntoTheShapeAsOneUndoStep`
- `tiledLayersDrawLikeOneImage` (passes; skipped only for its ~110s runtime on the software path)

`translucentStrokesDrawLikeOneImage` and `maskStrokesDrawLikeOneMask` are NOT in this list — they were fixed by the
hard-clip region change and pass (confirmed by running `TiledLayerTests` alone, 6/6, ~8 min). A stale `--skip` for both
had crept back into ad hoc test invocations after that fix; this entry is the correction.

## 2026-09-23 re-check, after the upstream v1.2.4-1.2.6 merge

Same invocation as above. **302 of 306 run tests pass.** 4 new failures, both real, neither related to the merge's
own Swift changes (CIBloom, NSPasteboard.setString):
- `InnerGlowTests`'s 3 rendering tests — InnerGlow (an upstream v1.2.x layer effect) has no Linux rendering pass
  yet. Needs its own `Sources/Overrides/MetalLayerEffects.swift` addition. Open.
- `BrushTests.bracketKeysReachTheBrushWhereverFocusIsExceptTextFields` — drives `NSHostingView<LayersPanel>`'s
  table lookup, the same `NSTableView`/Objective-C-runtime pattern already excluded for `LayerTests.swift` in
  `linux/UPSTREAM_TEST_EXCLUSIONS.md`, just surfacing in a different, not-yet-excluded file. Needs triage:
  either exclude this one test the same way, or confirm it's newly reachable and genuinely fixable.

**Resolved 2026-09-23, after the upstream `f67b46b` merge: full `swift test` green — 340 Swift Testing + 96 XCTest,
0 failures** (default parallel run, bridge + ImageIO backend set):
- InnerGlow: added to `CompositorEffectsParams` and all three C tiers (CPU, OpenCV, Vulkan shader passes 15-18),
  same blur + keep-inside + compose order as upstream's Metal renderer; `LayerEffectsBackendTests` checks it.
- `bracketKeys…`: compat `NSHostingView` now hosts a `HostedNativeContent` found anywhere in its tree, and the
  `NativeLayerList` override provides `LayerTableView` — upstream's own canvas key monitor then does the rest.
- `TransformTests.autoSelect…` (order-dependent): `ToolDefaults` skips UserDefaults only when
  `XCTestConfigurationFilePath` is set, as Xcode's runner does; `_Testing_XCTestEnvironment` sets it for the
  upstream test process, so a test's toggle no longer leaks into later tests.
- `UpstreamEditorTests` (Linux-owned, unmodified): the bridge's `new` adds "Layer 1" only when asked (`emptyLayer`).
- `TitleBarDragTests.swift`: runs and passes. `Compositor/UI/ProjectTabs.swift` is compiled unmodified (symlink;
  the Linux copy is gone) on compat `NSScrollView`/`NSClipView` and an `NSHostingView` that lays out and hosts its
  `NSViewRepresentable`s (`HostedLayout`). Full suite: 342 Swift Testing + 96 XCTest, 0 failures.

Also confirmed (see README's Known Issues correction): `AdjustmentLayerTests`/`ProjectTests` blank-render/heap-
corruption reports from earlier this session were a missing-`COMPOSITOR_SKIA_BRIDGE` invocation mistake, not a
real bug — they pass clean (19/19, no crash) under this doc's documented invocation, with or without
`--no-parallel`. `CIFilter`'s `supportedNames` allowlist was also missing `"CIBloom"` (silently fell back to the
unmodified source image instead of failing loudly), and the compat `CIBloom` implementation didn't spread alpha
past the source's opaque region the way real `CIBloom`'s glow does — both fixed, `FinishingFilterTests` now 5/5.

## 2026-10-10: upstream 1.4.9 resources

Upstream 1.4.9 reads `CameraRawTables.bin` through `Bundle.main`, which on Linux is the directory holding the
executable. Before `swift test`, copy it next to the test binary:
`install -m644 Compositor/Resources/CameraRawTables.bin .build/x86_64-unknown-linux-gnu/debug/` (the Flatpak manifest
and `scripts/run-compositor.sh` install it beside the app binary). Without it, `CameraRawTests` fails 15 of 28 tests.

**2026-10-10 (compat completion, Phase B):** 13 upstream test files run unchanged again — `CanvasEntryTests`,
`ColorPickerTests`, `GuideTests`, `LevelsTests`, `CanvasThumbnailTests`, `NavigatorTests`, `SelectionTests`,
`TypeToolTests`, `GroupTests`, `LayerMaskTests`, `LayerAppearanceTests`, `BlendShortcutTests`,
`TransformPressTests` — after `NSWindow.screen/isMovable/isSheet/sheetParent`, window close/move/resize
notifications, `NSScreen.visibleFrame` and `NSPasteboard.withUniqueName`. The single-test skips for
`FilterTests`, `DistortTests` and `LayerAppearanceTests` above are no longer needed (they pass); only the two
`HistoryTests` cases stay skipped (`.github/workflows/ci-build.yml`). Remaining exclusions: see
`linux/UPSTREAM_TEST_EXCLUSIONS.md`.
