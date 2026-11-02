# GNU/Linux status completion audit

Audit updated: 2026-10-16, protected upstream `365b574`, GNU_Linux HEAD `94cf71e`.
The October 15 upstream fetch found no missing upstream commits; upstream 1.5.3 is merged.
Implementation changes are in the working tree. This audit preserves the goal
of moving upstream features to Implemented/Adapted; it does not equate a green
status column with complete macOS parity.

## Requirements and current evidence

Startup recovery follow-up, 2026-10-16: a new isolated process test demonstrates
that a completed autosave survives SIGKILL, but the previous normal application
entry point opened an empty document instead of recovering it. Evidence:
`/tmp/compositor-crash-recovery-before-native.log` (exit 1 after the confirmed
crash boundary). Startup now attempts recovery before opening explicit input
files. Recovery uses an unbound package loader, so its autosave directory cannot
become the project's save destination or file watcher. Invalid recovery remains
on disk and reports its path. The release process probe passes committed edits
and a pending gradient, exact pixels/IDs, unsaved recovery without a draft,
startup-file isolation, save cleanup and clean relaunch in
`/tmp/compositor-crash-recovery-release-native.log` (exit 0). All seven
focused save tests, both normal/recovery loader cases, the repeated process
probe, the native async save/reopen/startup journey and required integrity pass;
`/tmp/compositor-crash-recovery-check.exit` is 0. The fresh complete framework
run passes 147 XCTest + 953 Swift Testing tests (1,100 total) in
`/tmp/compositor-crash-recovery-full-framework.log`, exit 0. The earlier combined
Invert run has failed an effects-control project save; its original cause remains unproven; the later full contract below passes. The isolated rerun passes all 54 cases in
`/tmp/compositor-effects-save-repro.log` (exit 0), without establishing the prior
failure's cause. Added explicit-save refusal and failing-case diagnostics are
built successfully, and all seven focused save tests pass in
`/tmp/compositor-effects-save-diagnostics-build.log`. All 54 native effects cases and the native async save/reopen/startup journey
also pass in `/tmp/compositor-effects-save-diagnostics{,-save}.log`, exit 0.
The forced autosave-overlap regression, all 54 cases, focused save tests, native
save journey and required integrity also pass in
`/tmp/compositor-effects-autosave-overlap{,-build,-save,-integrity}.log` (exit 0).
It proves the previous immediate-save sequence refuses during a pending autosave
and succeeds after its completion; the older uninstrumented failure cannot be
definitively attributed. The shared native package helper now waits for pending
saves; application save/refusal behavior is unchanged. The fresh complete canonical
contract exits 0 in `/tmp/compositor-autosave-coordination-contract.{log,exit}`
(session 87013): all 30 native commands, backend/codec/font/thumbnailer,
eleven source-coverage checks and all 1,100 framework tests (147 XCTest + 953
Swift Testing, 104.121 seconds). Required integrity also passes. This checkpoint
precedes the Grid Settings fixes below. Their corrected build passes the full
1,100-test suite and four native regressions; the expanded 32-gate contract exits 0
in session 10792 at `/tmp/compositor-grid-settings-full-contract.log`.


| Requirement | Authoritative evidence | Audit result |
|---|---|---|
| Compare with current protected upstream content | Protected-content checks pass against `365b574`; an October 15 fetch confirms the same upstream tip. | Upstream history is merged; Linux adaptations remain uncommitted. |
| Account for original source and test inclusion | The evaluated-target coverage report accounts for 156 upstream Swift files: 128 unchanged, 20 generated, 6 replaced, 2 platform. It records 87 unchanged test files and 2 selector mirrors. | Inclusion verified; inclusion is not behavioral or API completeness. |
| Use the requested mac / GNU_Linux / Status table | The tested feature table has 90 rows: 3 Implemented and 87 Adapted. Each row states its Linux scope and differences. | Format and status vocabulary verified. |
| Exercise the current working tree | The latest complete canonical checkpoint is the 36-gate/1,103-test menu/deep-sizing build (session 87491, exit 0, including integrity). The current common-entry/popup build passes 1,108 framework tests, 12 focused tests, seven offscreen native journeys, normal-startup Grid persistence and integrity across recorded phases. Wayland sizing passes all 24 markers; full preview and normal-startup dialog pass on a private input-capable compositor. Delayed own-write image clipboard origin retention is fixed and verified with real private seat input and replacement-image invalidation. The close-time lifecycle follow-up passes 17 focused checks, all 1,109 framework tests, four affected native journeys and integrity (session 54499, exit 0). The teardown/clipboard 36-gate run is session 61973 (pending); it predates the latest alert fixes. The alert build passes 29 focused checks, actual unsaved-close prompts offscreen/native Wayland, all 1,113 framework tests, four native regression journeys and integrity (51706, exit 0). Alert-build full 36-gate session 45852 now exits 0, including all 1,113 framework tests and integrity. Session 25384 predates clipboard/teardown fixes and completed 87491 predates the entry/popup correction. | Stated focused scopes verified; current combined contract, remaining API/teardown scope and broader physical/Mac acceptance remain pending. |
| Close the six implementation areas | The six-area tracker records GPU/warp, eye autoscroll, Layers keys, layout/window bounds, focus/accessibility and refusal/recovery. Current native logs include their corresponding checks. | Adapted within the documented scopes; declared performance/platform differences remain. |
| Reconcile the full earlier feature matrix | [The complete crosswalk](upstream-70-feature-crosswalk.md) maps all 70 September 21 rows, in order, to passing suites, native evidence where available, and further verification. The current 90-row tested table is a different inventory. | Row accounting complete; compound-feature and visible-control acceptance remain incomplete. Adapted in the crosswalk applies only to its stated automated scope. |
| Complete physical/platform acceptance | No Mac is available. Desktop portal/file-manager delivery, real screen readers, hardware input, installed-release update/relaunch and Mac round-trip/appearance checks remain recorded in TODOS. | Not verified; automated/offscreen checks do not satisfy these checks. |

The file-panel follow-up fixes wrong Open ownership and Save/Save As returning
Cancel without a chooser. App-defined .comp type metadata, JSON path transport,
package replacement/suffix and real multiple-package selection pass 35 focused
checks, all 1,119 framework tests, seven Qt CTest scenarios and 16 producer cases
offscreen/native Wayland. Fresh 37-gate session 83638 remains pending. A subsequent
preview-only follow-up fails Home/disjoint selection with offscreen rows; the
trace and separate remaining-native wrapper are retained in the newest baseline.
This is an unresolved validation issue, not a passing current combined contract.

## Historical-gap crosswalk checked in this audit

The common-entry/popup audit now reproduces and fixes unowned input requests,
wrong popup completion contexts, stale choices after owner close and nested
main-queue entry crashes. All 12 focused tests and all 1,108 framework tests pass;
seven affected offscreen native journeys and required integrity pass across the
recorded phases. Grid's fast driver now awaits actual validation redraw and the
normal-startup helper verifies persistence. Wayland sizing passes all 24 markers;
full preview and normal-startup dialog now pass on a private input-capable
compositor. Delayed own-write image clipboard origin retention is fixed; the real
private-seat image journey and replacement-image invalidation pass. Current
older full 36-gate session 25384 exits 139 in transform smoke; older session 87491 predates this fix.
Session 87491 is now complete. Both builds predate the clipboard correction; session 84680 stopped because its test source changed during compilation. The teardown follow-up passes 17 focused checks, 1,109 framework tests, four affected native journeys and integrity (session 54499, exit 0). Fresh full 36-gate session 61973 is pending at `/tmp/compositor-close-owner-full-contract.{log,exit}`; see the latest baseline.
The close-time follow-up reproduces disappearance/deferred requests targeting a
survivor and now binds complete teardown to the closing handle. All 17 focused
ownership/lifetime checks, all 1,109 framework tests, four native journeys and
integrity pass in session 54499 (exit 0). Fresh full 36-gate session 61973 is pending. Direct app-level/onMain-only producers, reentrant teardown and
physical/Mac acceptance remain open. The subsequent alert audit fixes wrong native project-alert parenting and checkbox refresh reentry; all 29 focused checks and integrity pass, with real project-close checks passing offscreen/native Wayland, followed by all 1,113 framework tests, four native regression journeys and integrity (51706, exit 0). Alert-build full 36-gate session 45852 now exits 0, including all 1,113 framework tests and integrity. The latest baseline retains each failing and passing
wrapper rather than treating partial phases as combined success.

The deep-sizing follow-up now verifies basic 16-bit PNG/HDR EXR print-only source
retention, Nearest resampling with every-channel/alpha oracles and saved-package
Undo/Redo/reopen, and center crop/expansion retaining deep assets. It also exposes
and fixes cross-window request consumption and deferred menu-owner loss. Explicit
session dispatch, task-local ownership, scoped queues and live session-to-window
sheet/repaint routing pass both window directions and older-window reuse after
newer-window destruction. All 41 focused tests, 24 sizing/ownership markers in
two independent offscreen profiles and native Wayland, four Wayland Hide cases,
and required integrity pass (`/tmp/compositor-deep-size-bound.exit` and
`/tmp/compositor-deep-size-wayland.exit` are 0). Full framework/native regression
session 34499 exits 0 with 1,103 tests, six affected native journeys and integrity.
The complete current 36-gate contract is running in session 87491; the preceding
35-gate session 66977 is now complete (exit 0) and predates this ownership fix. Other sampling algorithms,
masked/grouped/transformed deep sizing and physical/Mac acceptance remain open.

The Image Size follow-up closes the named RGBA8 unit/no-resample control gap in
historical row 57. Six print-only edits, eight locked/unlocked four-unit Nearest
resampling cases, two print-unit DPI resizes and Cancel/validation pass through
the actual upstream sheet, with independent exact pixels, retained source
records/target identity and single Undo/Redo. The isolated executable and required
integrity exit 0. All 17 cases also pass native Wayland; the private headless
compositor is stopped afterwards (`/tmp/compositor-image-size-native.exit`,
`/tmp/compositor-image-size-wayland.exit` and
`/tmp/compositor-image-size-integrity.exit` are 0). The inventory stays at 90 rows
(3 Implemented / 87 Adapted), expanding the existing sizing row. Canonical gates
increase to 36; session 66977 is still the preceding 35-gate full run, whose
1,100 framework tests pass. The older 34-gate session 94463 now exits 0, including all native gates,
1,100 framework tests and required integrity; it predates the numeric-field fix.
The Image Size probe did not rebuild either then-live binary. Direct native sizing with other sampling algorithms,
alpha/deep/HDR and physical/Mac acceptance remains open. See the newest baseline
for the corrected asynchronous picker-wait assumption and exact scope.

Historical row 57 now has direct Canvas Size unit/anchor evidence and a reproduced
UI defect: invalid width 0 left OK enabled while focused. Value-backed numeric
fields now refresh dependent controls without losing the active field/text/cursor;
shared formatting and signal-blocked sibling updates also keep linked dimensions
current. All 36 four-unit/nine-anchor pixel cases, nine retained-crop cases,
live controls/Cancel, all four original CanvasSizeTests, native Grid/transform/
scrub/dialog/preview regressions, all 1,100 framework tests and required integrity
pass (`/tmp/compositor-canvas-size-fixed.exit` and
`/tmp/compositor-canvas-size-regression.exit` are 0). The current inventory adds
this explicit tested behavior (90 rows: 3 Implemented / 87 Adapted); earlier
checkpoint notes below retain their historical row counts. A fresh 35-gate
contract is running in session 66977. Session 94463 is the earlier pre-numeric-fix
34-gate run. At that checkpoint Image Size unit/no-resample controls were still
open; the later evidence above covers their stated RGBA8 scope. HDR sizing and
physical/Mac acceptance remain open. The baseline distinguishes corrected async/modal/clipboard
probe assumptions from the actual focused-width defect.

The preceding Hide/popup follow-up fixes two observed lifecycle gaps: floating tools stayed
exposed over minimized projects, and a keyboard combo popup could lose its
owning controls during a refresh without a mouse grab. Native Wayland exposed
an additional `NoState` notification during minimization; panel suppression now
lasts until activation. Four Hide cases pass on each backend, including normal/
maximized owners and intact drafts/Cancel. Forced Grid popup refresh and restart,
eight Clear cases, native preview, all 1,100 framework tests and required
integrity also pass (`/tmp/compositor-grid-popup-fixed.exit` is 0, session 48896).
Its 34-gate contract is running in session 94463 and predates the newer numeric-field
change. Window-lifecycle evidence
under private headless Weston does not certify physical input or task-switcher
interaction. Exact before/after logs are in [the baseline](upstream-test-baseline.md).

The native API audit now reproduces a visible Hide Compositor failure: its
AppKit callback was never connected to the Qt host. The installed callback and
new shell request minimize all visible project windows, preserving desktop
restoration. Both originating windows pass the native minimize/restore probe
with exact pixels and editing state, and the corrected build passes Grid
Settings controls/restart and all eight Clear cases. Logs use
`/tmp/compositor-app-visibility-fixed-`. All 1,100 framework tests and required
integrity also pass; `/tmp/compositor-app-visibility-fixed.exit` is 0
(session 49829). The canonical runner includes this
new gate (34 total); session 10792 exits 0 using its earlier pre-Hide-fix executable.
Physical desktop delivery and cross-application Hide Others/Show All remain
unverified/unimplemented respectively; the latter compatibility methods are
empty. See [the baseline](upstream-test-baseline.md) for the precise scope.

Historical row 33 now has eight passing visible Clear menu cases: rectangle/
ellipse, opaque/half-alpha, image/mask targets. Interior/exterior coverage,
disabled-without-selection refusal, retained target/palette and exact complete
pixel/record Undo/Redo pass; disabling the edited mask restores source pixels.
All 19 original selection-edit tests and required integrity also pass
(`/tmp/compositor-selection-clear.exit` is 0). The initial mask refusal came from
the probe selecting a hidden legacy menu; explicit visible-menu routing corrects
the harness. No application fix was needed. Adding the Clear probe expanded the canonical runner to 33 gates; the later
Hide probe makes 34. Session 10792 passes its earlier 32-gate scope (exit 0). Boundary equations,
transformed/HDR combinations and physical/Mac delivery remain unverified.

Historical row 60 now has direct Grid Settings widget and restart evidence.
The new probe reproduces stale validation during typing, then canceled spacing
32 reappearing although preferences correctly retained 24/3. Focus-preserving
validation/hint refresh and closed-modal SwiftUI-state cleanup correct both.
All 14 original guide tests, the native controls/reopen/defaults/persistence
driver and required integrity pass (`/tmp/compositor-grid-settings.exit` is 0).
The corrected build passes all 1,100 framework tests in
`/tmp/compositor-grid-settings-full-framework.log`; all four native modal and
field regressions also pass (session 24273, exit 0). Five supplemental startup
captures verify grid spacing/subdivisions, opacity and style gaps with exact
off-grid pixels. Session 87013 exits 0 for the earlier pre-grid-fix contract and
cannot certify this later code; the expanded 32-gate contract exits 0 in session 10792. Exact failure
and success evidence is recorded in [the baseline](upstream-test-baseline.md).

Historical row 19 now also has rotation-specific bridge evidence: the standalone
`test_group_rotation` target passes six selected-layer/folder cases (+90°, -90°,
180°) using the current executable and unequal asset sizes/origins. Independent
shared-center pixel equations, unselected isolation, Cancel, single Undo/Redo,
retained leaf IDs and unchanged source manifest/asset hashes pass. CMake build,
native checks and required integrity exit 0 in
`/tmp/compositor-group-rotation-cmake-{build,native}.log` and
`/tmp/compositor-group-rotation-integrity.log`. The canonical runner includes the
new standalone gate; it is verified separately from completed session 87013, which
retained its earlier 30-command script (exit 0). Pointer rotations, other angles and broader
member combinations remain unverified.

The evidence below is present in the current full-run log or the explicitly named native follow-up logs. These entries resolve
specific old claims; they do not close every combined feature in an old row.

| Earlier claim | Current evidence and scope | Remaining audit work |
|---|---|---|
| Folder duplication missing | The original selector-mirror method passes. `/tmp/compositor-folder-duplicate-native.log` exits 0 with the visible Duplicate Layer action, nested descendants, new IDs/remapped parents, original-record and visibility isolation, exact pixels/hierarchy Undo/Redo and copied-root selection. | Adapted for the automated nested RGBA8 scope. Mask/clipping/effect/HDR variants and physical/Mac appearance remain unverified. |
| Merge command/menu missing | The original menu test passes; `/tmp/compositor-folder-merge-acceptance-native.log` exits 0 with visible Merge Down/Layers/Group actions, exact composites, an untouched unselected layer, opacity baking and exact hierarchy/ID Undo/Redo. | Adapted in the automated RGBA8 scope. Masks/effects/HDR combinations and physical/Mac acceptance remain unverified. |
| Folder opacity rejected | Original group/appearance tests pass. The same native log verifies the visible percent field, rendered half alpha, unchanged child opacity/parent IDs and exact pixels/hierarchy Undo/Redo. | Adapted for the interactive folder scope. Nested/masked/HDR combinations and physical/Mac appearance remain unverified. |
| Multiple tabs and cross-project layer drag missing | Native tab acceptance covers existing/new projects, multiple rows, folders, two windows, overflow, source isolation and provider Undo/Redo. | Physical desktop drag delivery remains unverified. |
| Mask target/link controls unavailable | Native preview verifies Shift-click and unlinked drag. `/tmp/compositor-mask-edit-final-native.log` exits 0 with visible mask creation, pointer Brush/Smear, black fill, softened edges, source-image isolation and exact Undo/Redo for both layer and folder masks. Fourteen original mask tests also pass. | Paint/fill/local blur are Adapted in the automated scope. The actual Feather-selection → mask workflow also passes for layers/folders in `/tmp/compositor-feather-mask-native.log`. Map remaining selections/transforms/HDR cases before closing the combined old row; physical/Mac acceptance remains open. |
| Existing adjustment re-edit entry point missing | The six historical editors pass visible creation, thumbnail/Edit-menu reopening, numeric/Curves graph/Reverse changes, Cancel/OK and exact pixels/hierarchy Undo/Redo in `/tmp/compositor-six-adjustment-diagnostic-native.log`. `/tmp/compositor-modern-adjustment-native.log` also exits 0 for the six newer kinds, including the five additional editable kinds and Invert without an editor, with saved settings/source PNGs and exact package-reopened composites. | Adapted for all twelve current kinds and all eleven editors within the tested scopes; broader parameters, masked/transformed/HDR stacks and physical/Mac input remain unverified. |
| Type tool not ported | Original TypeToolTests pass; native preview/text journeys cover colored editing, local commands, fonts, UTF-16 styling, fallback and Undo/Redo. | Broader text API and real input-method acceptance remain open. |
| Guides/rulers not ported | All original GuideTests and native ruler creation/deletion, coordinates, lock/refusal/recovery and history checks pass. | Actual desktop/Mac ruler input and appearance remain unverified. |
| Crop snapping and Option symmetry unavailable | All seven original CropTests pass. `/tmp/compositor-crop-final.log` exits 0 with native ordinary/Alt creation, Alt resize, canvas-edge snapping, Meta suppression, unchanged draft history/layers, Escape pixel preservation and Apply/Undo/Redo dimensions. The visible Actual pixels button sets 100% so the snap point is inside upstream’s 8-screen-point tolerance. | Adapted for the automated scope; physical keyboard/tablet/Mac comparison remains unverified. |
| Shift-straight brush unavailable | Native Qt acceptance now verifies horizontal/vertical painting, retained first axis across pointer-dominance changes, off-axis isolation, release to freehand and one exact Undo/Redo. The full log contains its pass marker; original CanvasView supplies the behavior. | Physical keyboard/tablet/Mac input remains unverified. |
| HEIC/TIFF import incomplete | Required native codec checks and deep-import journeys cover ICC, alpha, HDR transfers and 192 float-TIFF cases. | Mac color comparison remains unverified. |
| Content-Aware Fill past layer edges was unverified | Four original SmartEditTests and `/tmp/compositor-content-extend-acceptance-native.log` exit 0. The native journey fills all four added canvas edge strips, verifies exact outside pixels, opaque/color-varying results, unchanged layer count/identity, exact grown bounds, visible Cancel/OK and pixel/geometry Undo/Redo. The current engine is unchanged upstream multi-scale PatchMatch, not the historical OpenCV description. | Adapted for the automated RGBA8/unmasked scope. Masked/transformed/HDR combinations and physical/Mac appearance remain unverified. |
| Live filter previews limited to selection were unverified | `/tmp/compositor-selection-filter-acceptance-native.log` exits 0 for Gaussian Blur and Black & White: every outside pixel is exact, Off/On and visible Cancel preserve source/history, visible OK matches the completed preview, and Undo/Redo preserves exact pixels and selection/layer identity. The bridge reports pending preview workers independently of edit busy state. | Adapted for these native filter scopes; RGB Levels/Master Hue paths also pass in three complete runs `/tmp/compositor-levels-hue-fixed-{1,2,3}.log`; map other channels/ranges, HDR/transformed/masked cases and remaining filter families before closing the combined historical adjustment row. Physical/Mac appearance remains unverified. |
| Subject/Object mode needs a Vision replacement | Required shipped U²-Net/OpenCV inference and Select Subject/Remove Background bridge/history tests pass. `/tmp/compositor-object-native.log` exits 0 with loaded-model Object pointer clicks through the visible mode, selected-fill isolation, exact pixel Undo, unchanged source-layer identity and selection/background Undo/Redo. `/tmp/compositor-object-build.log` passes both model acceptance tests. | Adapted for the automated scope. Linux connected-component instance labels, natural-photo/Apple Vision equivalence and physical/Mac input remain unverified. |
| Shortcut window/Photoshop keys incomplete | Core settings and native tool routing pass. The new native editor journey verifies visible search/recording, Cancel/reopen, Save, K replacing B and exact restoration of bindings/documents. | Conflict/clear/Restore Defaults interaction now passes in `/tmp/compositor-shortcut-conflict-clear-native.log`; fresh-process persistence now passes in `/tmp/compositor-shortcut-restart-native.log`; physical/Mac input remains unverified. |

Additional current native evidence closes later gaps in wheel/pinch navigation,
project reopening/startup, external package changes, accepted-close cleanup and
modifier recovery on key release, application activity and menu tracking.

## Declaration inventory is diagnostic

The current reproducible name inventory contains 4,512 upstream declarations,
1,432 candidate matches and 3,080 unmatched names. Its own warning states that
candidate matches are not functional parity. Unmatched names are not a count of
missing features; inherited/generated code and naming differences must be
accounted for before drawing that conclusion.

```sh
python3 scripts/upstream-audit.py --ref upstream/main \
  --json /tmp/compositor-status-audit.json --csv /tmp/compositor-status-audit.csv
```

The outputs were generated for this audit. Declaration names must not be used
to turn unresolved behaviors into Implemented/Adapted.

## Next verification targets

[The four new upstream commits](upstream-pending-2026-10-14.md) are synchronized and verified.
Native Option/snap crop and Object-mode pointer selection are now verified.
Gaussian Blur/Black & White selection-clipped previews are now verified.
RGB Levels/Master Hue selection-clipped previews are now verified.
Content-aware expanded-canvas behavior is now verified on all four edges.
Folder opacity, all three merge variants and nested folder duplication now have native control/menu evidence.
Continue the 70-row historical crosswalk with remaining preview combinations,
remaining folder variants and mask selection/transform/HDR combinations. Keep physical/Mac acceptance open.
The [70-row crosswalk](upstream-70-feature-crosswalk.md) now lists the remaining
verification for every historical feature. Prioritize visible controls that
currently have only core-suite evidence, including adjustment re-editing,
Hue/Saturation range handles, remaining visible-control variants and physical/Mac acceptance.
The complete goal remains unproven until its full inventory and required
acceptance are accounted for.

## Pending-gradient autosave closeout

The earlier line-loss and invalid-command failures were caused by the 60-second
autosave calling document preparation and transformCommitFinal. The deterministic
forced-autosave test fails before the fix. Autosave now captures layer state
without committing/canceling live drafts; explicit saves retain preparation.
Eleven targeted tests pass, three complete native combination runs exit 0, and
the separate async save/recovery journey exits 0. Exact live state/history and
all source PNG pixels in recovery are checked. Evidence and historical failures
are retained in [the test baseline](upstream-test-baseline.md). The full
older 1,053-test runner predates this fix; the current 1,054-test full runner now includes it.
Other draft kinds, real process crashes and physical/Mac acceptance remain open.

## Shortcut window: scoped closeout

The original failure was a stale Qt display, rather than lost Swift local state.
Direct view, bridge and C ABI probes all retained Search correctly. Qt suppressed
all panel resolution while any field was focused, so live filtering never showed
its results. Search now refreshes with focus/cursor/selection restoration. Native
window pointer events exercise the recorder instead of bypassing Qt focus routing.

A second issue retained canceled drafts on reopening: Qt did not resolve a closed
model to release its cached state/native views, and nil-panel resolution left
old action handlers. The host now queries closure using the content's owning
session; the existing discard path also clears actions. The new C ABI regression
fails before cleanup and passes afterwards.

Twelve tests pass in `/tmp/compositor-shortcut-lifecycle-final-build.log` (exit 0).
Complete combination and preview journeys pass in the corresponding native and
preview logs. `/tmp/compositor-shortcut-cursor-native.log` additionally passes
middle-text deletion/insertion with preserved focus/cursor, native recording,
Cancel/reopen, Save, new/old key routing and restored original bindings. Document
pixels/layers/history remain exact. Row 68 is Adapted for that scope.
Conflict/clear/Restore Defaults interaction now passes as described below. Fresh-process persistence now passes as described below. Physical/Mac input remains unverified.
Temporary production logging and the ineffective dirty-panel prototype are gone.
The latest live upstream check still returns `43d691b`. The full unfiltered test
baseline has now been refreshed by the current full runner, including this production fix.

### Shortcut validation/removal/defaults follow-up

`/tmp/compositor-shortcut-conflict-clear-build.log` passes 12 tests in two suites
(2.037 seconds). The complete combination journey exits 0 in the matching native
log. Recording M for Brush exposes the conflict message and disables Save; Cancel
retains original bindings. The visible removal control clears Brush, while
Marquee still works and B no longer selects Brush. Restore Defaults changes only
the draft until Save; Cancel retains the cleared binding, and Save restores all
original bindings and B routing. Every document pixel/layer/history invariant
remains exact. The fixture requires default bindings before testing restoration.
This changes only acceptance tests; production code is unchanged.

### Shortcut persistence across actual process launches

Twelve tests pass in `/tmp/compositor-shortcut-restart-build.log` (2.327 seconds).
The complete native combination journey exits 0 in the matching native log.
After each visible Save, a QProcess launches the same application with the same
test profile and reads the persisted table. Three independent launches verify
saved K, an unassigned Brush shortcut, and restored B; each also tests actual
K/B canvas routing and unchanged document pixels. The main journey restores
all original bindings and preserves document layers/pixels/history. This is an
acceptance-harness extension; production settings code is unchanged.

## Full integration verification after the follow-ups

The unfiltered release run `/tmp/compositor-shortcut-current-full-contract.log`
exits 0 with 1,054 framework tests (140 XCTest + 914 Swift Testing/145 suites),
all native editing/preview/save/transform/tab/RAW-lens/text journeys, thumbnailer
and 11 source-coverage checks. Vulkan execution is required, and hardware warp
submissions report AMD RADV Renoir. The separate required-shader/protected-source
check also exits 0 in `/tmp/compositor-shortcut-current-integrity.log`.
This closes the integration-verification gap left by the earlier targeted runs.
It does not close unverified feature/control scopes or physical/Mac acceptance.

## Pixel-grid visible acceptance

Four original DownsampleTests pass in `/tmp/compositor-pixel-grid-build.log`
(0.037 seconds). The whole native combination journey exits 0 in
`/tmp/compositor-pixel-grid-native.log`. Visible View > Pixel Grid and the Zoom
field exercise 799%, 800% and 1600%. At 799% On/Off frames are identical; at the
higher values changes occur only along pixel boundaries, with unchanged cell
centers and canvas surround. Off restores the exact canvas frame and all stored
pixels/layers/history remain identical. This acceptance-harness follow-up changes
no production rendering code; the full 1,054-test checkpoint predates the added
case. Physical/high-DPI/Mac appearance remains unverified.

## Visible Flip Layer/Canvas and Invert follow-up

Forty-one tests in four suites pass in 1.544 seconds:
`/tmp/compositor-visible-flip-invert-build.log`. The whole native combination
journey exits 0 in the matching native log. Four visible flip actions use an
asymmetric 32x24 image on a 64x64 canvas, distinguishing layer-centered from
canvas-centered mirroring. Pixels, geometry and identity are exact through
Undo/Redo. Whole/selected Invert preserves alpha, exact outside/transparent
pixels, layer geometry/identity and selection; RGB complements allow only
8-bit premultiplication rounding. These acceptance tests change no production
code. Broader mask/group/guide/HDR combinations and physical/Mac input remain
unverified as scoped in the current feature rows.

## Boolean Picker and visible Clone Stamp follow-up

The native Clone test reproduced All Layers failing to change its Boolean setting.
The shared SwiftUI Picker now parses Bool tags with Swift's existing parser;
its regression covers both directions and invalid values. Existing upstream clone
code now receives actual Alt source and visible Aligned/This Layer/All Layers
choices. Aligned offset, unaligned restart, composite sampling into a blank layer,
source isolation and exact pixels/layer Undo/Redo pass in
`/tmp/compositor-clone-pointer-native.log`. The complete runner also exits 0 with
1,055 framework tests in `/tmp/compositor-clone-current-full-contract.log`.
Transforms/selections/HDR and physical/Mac acceptance remain unverified.
Required-shader/protected-source integrity exits 0 in
`/tmp/compositor-clone-current-integrity.log`, matching protected `43d691b` content.

## Visible mask Paint and Alt footer follow-up

Four native layer/folder × Reveal All/Alt–Hide All cases pass in
`/tmp/compositor-mask-paint-picker-native.log`. Actual Paint picker keys hide and
reveal strokes, with unchanged exterior, source-over antialiasing coverage,
source-image isolation and exact pixel/layer Undo/Redo. Alt footer creation initially
failed because Qt Button actions lacked NSApp.currentEvent. The bridge now scopes
native activation modifiers to Button actions and restores prior event/flags.
A new C ABI regression also verifies unchanged legacy pointer-handler semantics.
The final full runner exits 0 with 1,056 tests and all native journeys in
`/tmp/compositor-mask-picker-final-full-contract.log`. An earlier full attempt
hit a five-second text-to-gradient timeout; the repeated run passes, but the cause
of that timeout is not established. Physical/Mac and broader combinations remain open.
Required-shader/protected-source integrity also exits 0 in
`/tmp/compositor-mask-picker-final-integrity.log` against protected `43d691b` content.

## Native mask menus and thumbnail selection follow-up

Fourteen unchanged tests and the focused native mask-menu journey exit 0 in
`/tmp/compositor-mask-menu-{build,native}.log`. Layer/folder Enable/Disable/Delete,
Image > Invert Mask, layer Unlink/Link and upstream-disabled folder Unlink pass.
Ctrl image-thumbnail loads source pixels ignoring the mask; Ctrl mask-thumbnail
loads hidden mask areas. Separate-layer fills prove coverage, source isolation,
unchanged exterior and exact pixel/record Undo/Redo.

These are acceptance-harness additions; the last full 1,056-test checkpoint
predates them. At that checkpoint popup serialization/Qt hosting flattened menu items; the
recursive Add Mask implementation below subsequently resolves that gap. Existing footer
Reveal/Alt–Hide behavior passes. Wider selection/transform/HDR and physical/Mac
acceptance remain open; these checks do not complete the full goal.

## Recursive Add Mask popup implementation

The flat-popup gap above is now resolved: Swift encodes nested items with IDs,
Qt builds QMenu submenus and chosen IDs dispatch the original NSMenu leaf.
Disabled ancestors prevent dispatch. A dedicated regression and all four native
layer/folder Reveal/Hide submenu cases pass in
`/tmp/compositor-mask-submenu-{build,native}.log`, with exact pixels/records
Undo/Redo and disabled Add Mask after creation. The focused run also includes
all preceding mask-menu/thumbnail checks. Physical/Mac input and broader
combinations remain open; the entire goal is not yet complete.

The complete integration runner now includes these changes and exits 0 with
1,057 framework tests and all native journeys:
`/tmp/compositor-mask-submenu-full-contract.log`.
Required-shader/protected-source integrity also exits 0 in
`/tmp/compositor-mask-submenu-integrity.log` against protected `43d691b` content.

## Native clipping creation/release follow-up

The focused native menu journey and 14 original tests exit 0 in
`/tmp/compositor-clipping-menu-{build,native}.log`. Visible Create/Release clips
a blue top layer to opaque or 32/64/128/255-alpha bases, preserving exact alpha
and color without fringe. Source records/count and target identity remain exact;
the saved manifest contains the exact base-layer UUID. Pixel/record/clipping-state
Undo/Redo and disabled bottom-layer refusal also pass. Production clipping code
is unchanged and the previous full 1,057-test checkpoint predates these harness
additions. Clipped stacks, effects/transforms/HDR and physical/Mac input remain open.

## Visible selection menus and live Amount validation

The focused build and native journey exit 0 in
`/tmp/compositor-selection-menu-{build,native}.log`: 46 original tests in three
suites and actual Expand/Contract/All/Inverse UI checks. The native regression
first reproduced stale OK enablement while Amount had focus. The renderer now
refreshes button enablement, range-hint opacity and slider position without
replacing the field; QSignalBlocker prevents slider feedback. Returning to the
cached initial value also updates validation. Field identity/focus/cursor, invalid
0/501, valid 1/4, Cancel/OK, coverage and Undo/Redo pass. Wider combinations and
physical/Mac input remain open; this does not complete the full goal.

The complete integration run includes this renderer fix and all preceding
clipping/menu follow-ups, and exits 0 with 1,057 tests and all native journeys in
`/tmp/compositor-selection-menu-full-contract.log`. Existing Feather-to-mask
checks also pass. This extends the verified scope; wider combinations remain open.
Required-shader/protected-source integrity exits 0 in
`/tmp/compositor-selection-menu-integrity.log` against protected `43d691b` content.

## Native Freehand and Polygonal Lasso follow-up

Twenty-seven original tests in two suites and the focused native journey exit 0
in `/tmp/compositor-lasso-pointer-{build,native}.log`. A concave L-shaped outline
proves actual path coverage at every pixel. Visible Freehand/Polygonal modes,
freehand release, three polygonal closure paths, Backspace corner removal and
Escape for both modes pass draft isolation and exact selection/fill Undo/Redo.
Production lasso code is unchanged; the prior full 1,057-test checkpoint predates
these added harness cases. Add/subtract modifiers, feathering/other shapes and
physical/Mac input remain open.

## Lasso Add/Subtract native follow-up

Forty-six original tests and the focused native journey exit 0 in
`/tmp/compositor-lasso-modes-{build,native}.log`. Freehand/Polygonal each pass
visible Add/Subtract controls and Shift/Alt pointer gestures: overlapping concave
union/difference at every pixel, source/target isolation and exact coverage
Undo/Redo, using reversible fills. The full 1,057-test checkpoint predates these
harness additions; production selection code is unchanged. Marquee/Magic/Object,
combined modifiers/feathering and physical/Mac variants remain open.

## Marquee modifiers and curved-hole normalization

Forty-seven tests and the focused native journey exit 0 in
`/tmp/compositor-marquee-pointer-{build,native}.log`. Rectangle/Ellipse modes,
Anti-alias off, ordinary/fresh Shift and late Alt gestures, Add/Subtract buttons
and Shift/Alt-at-press variants pass. Exact Undo/Redo covers the entire raster;
the independent ellipse interior/exterior oracle excludes a one-pixel curve band.
Upstream Marquee never requests centered dragging on Alt; this is retained.

The direct ellipse regression reproduced an interior hole remaining filled in
both CGPath winding hit-testing and coverage. Native diagnostics showed correct
Skia difference before AsWinding, then a filled center after conversion. Using
existing Skia Simplify before AsWinding canonicalizes curved contours and preserves
the hole. Diagnostic logging is removed. Wider variants and physical/Mac input
remain open; the full goal is not complete.

The complete integration runner now includes these changes and exits 0 with
1,058 tests and all native journeys in
`/tmp/compositor-marquee-pathops-full-contract.log`.
Required-shader/protected-source integrity also exits 0 in
`/tmp/compositor-marquee-pathops-integrity.log` against protected `43d691b` content.

## Magic Wand visible controls follow-up

Six original tests and the focused native journey exit 0 in
`/tmp/compositor-wand-controls-{build,native}.log`. Eight cases cover actual
Tolerance 0/24, Contiguous on/off, This Layer/All Layers, Point Sample and
Anti-alias off. Clicks and green fills match every expected pixel for connected,
disconnected and nearby colors; All Layers samples the visible source with a
blank layer active. Before painting, source pixels/records remain exact; target
identity and selection/fill Undo/Redo pass. The harness restores This Layer,
Anti-alias and Tolerance defaults afterward. Production Wand code is unchanged;
the full 1,058-test checkpoint predates this addition. Average sample sizes,
mode/transform/HDR and physical/Mac combinations remain open.

## Wand sample-size native follow-up

The focused build and native journey exit 0 in
`/tmp/compositor-wand-sampling-{build,native}.log`, including six original tests
and all previous Wand cases. Actual keyboard choices of Point/3x3/5x5 at
tolerance 15 produce distinct point/no-match/background results. Pixel fills
are exact; New-mode no-match clears a prior selection with correct Undo/Redo.
Production code is unchanged, and the previous full 1,058-test checkpoint
predates these acceptance-harness additions. Remaining mode/transform/HDR and
physical/Mac combinations are still open.

## Wand Add/Subtract native follow-up and timing evidence

Thirty-three original tests and the final focused native journey pass in
`/tmp/compositor-wand-modes-build.log` and `/tmp/compositor-wand-late-native.log`.
Visible Add/Subtract and Shift/Alt yield exact disconnected union/difference,
source/target isolation and coverage Undo/Redo. A fixture history marker confirms
asynchronous completion rather than accepting an old entry. Two earlier focused
attempts hit the five-second busy gate at different Wand phases; the final attempt
passes without a timeout. That repetition does not establish the timing cause.
Failure-only diagnostic observation is removed. Production code is unchanged;
the previous full 1,058-test checkpoint predates these acceptance additions.
Object/combined modifier/feathering/transform/HDR and physical/Mac variants remain open.

## Eyedropper native pointer follow-up

Twenty original editor bridge tests pass in 0.468 seconds in
`/tmp/compositor-eyedropper-pointer-build.log`. Both native success markers are
present in `/tmp/compositor-eyedropper-pointer-native.log`: visible Eyedropper
and temporary Alt Brush sample opaque/half-alpha composite RGB, update during
dragging and refuse transparent/outside points. RGB tolerance is 2/255 for
premultiplied rounding. Pixels, records, target, background palette, modified
state and history remain exact, and temporary sampling retains Brush.
Existing Qt events and upstream sampling supply the behavior; production code
is unchanged. The full 1,058-test checkpoint predates this harness addition.
HDR/transformed/masked composites, other temporary tools and physical/Mac
input remain open. The tested comparison table now has 70 rows: 3 Implemented
and 67 Adapted; the historical 70-feature crosswalk remains a separate inventory.

## Gradient visible shapes/settings follow-up

Thirteen original gradient/pending-gradient tests pass in 0.037 seconds in
`/tmp/compositor-gradient-settings-final-build.log`; the focused native journey
exits 0 with all 16 markers in `/tmp/compositor-gradient-settings-final-native.log`.
Existing Qt controls and upstream gradient logic supply both shapes, both color
styles, Reverse off/on and Opacity 100/50. Independent all-pixel premultiplied
RGBA comparison allows 3/255 for rounding. Visible Cancel/Apply, draft isolation,
target retention and exact Undo/Redo pass. An initial harness widget-lifetime
fault was corrected by reacquiring the Colors combo box between key events;
production code is unchanged. The previous full 1,058-test checkpoint predates
this acceptance addition. Mask/selection/transformed/HDR combinations, endpoint
editing and physical/Mac comparison remain open. The current tested table has
71 rows: 3 Implemented and 68 Adapted.

## Eraser visible controls follow-up

Twenty-two tests in three brush suites pass in 80.022 seconds in
`/tmp/compositor-eraser-controls-build.log`; the focused native journey exits 0
with all ten Eraser cases in `/tmp/compositor-eraser-controls-native.log`.
Existing Qt controls feed unchanged upstream Erase mode and destination-out
painting. Size 8/16, hardness 0/100, opacity 50/100 and Smoothing 0 single stamps,
plus two selection-clipped size-24 hard stamps, pass alpha/opacity-cap checks,
source RGB retention, soft partial edges, exact outside pixels, target/count
retention and exact Undo/Redo. Alpha tolerance is 3/255; hard-tip edges exclude
a one-pixel band. No production code changed. The previous full 1,058-test
checkpoint predates this addition. Continuous strokes/smoothing, mask targets,
transforms/HDR and physical/Mac comparison remain open. The current tested table
has 72 rows: 3 Implemented and 69 Adapted.

## Spot Healing native pointer follow-up

Twenty-two original healing/editor bridge tests pass in 0.558 seconds in
`/tmp/compositor-healing-pointer-final-build.log`; the focused native journey
exits 0 with all 12 cases in `/tmp/compositor-healing-pointer-final-native.log`.
All three visible modes, single stamps/short strokes and opacity 100/50 repair
or blend the red blemish into gray stripes while retaining selected binding,
outside-footprint pixels, opaque alpha and target/count. Exact Undo/Redo
restores original and actual committed pixels/records. Existing Qt controls
and the unchanged upstream healing kernel supply the behavior. The initial
test selector missed the upstream accessibility identifier; the corrected
selector uses `spotHealingType`. Production code is unchanged; the earlier
full 1,058-test checkpoint predates this addition. Natural-photo quality,
soft tips, selections/masks/transforms/HDR and physical/Mac comparison remain
open. The current tested table has 73 rows: 3 Implemented and 70 Adapted.

## Full painting-controls attempt and Wand main-pump investigation

The earlier full attempt exits 1 in
`/tmp/compositor-painting-controls-full-contract.log`, despite all 1,058 framework
tests and native Gradient/Eraser/Healing cases passing. A Wand mode click remains
busy beyond five seconds, and later native journeys are not reached. Independent
required-shader/protected-source integrity exits 0 in
`/tmp/compositor-painting-controls-integrity.log` against `43d691b`.

GDB captures idle workers and tracking=false at the timeout in
`/tmp/compositor-wand-repeat-stacks.log`. A queued-start timeout in
`/tmp/compositor-wand-pump-completion-stacks.log` is released by future-deadline
RunLoop calls: the job starts immediately and completes in 4 ms, with the correct
Magic Wand history entry. The correction gives the existing Foundation RunLoop
a positive deadline bounded to 1 ms. The original kernel and five-second gate
are unchanged. Temporary diagnostic traps/API were removed; six native Wand
rounds now run in the full runner through `--wand-repeat`. Focused verification
passes 32 tests in four suites in `/tmp/compositor-main-pump-fixed-build.log` and
all six rounds in `/tmp/compositor-main-pump-fixed-wand.log` (exit 0): 48 controls,
12 Add/Subtract cases and 18 sample-size cases. The post-correction full run
now exits 0 in `/tmp/compositor-main-pump-fixed-full-contract.log`, with all 1,058
framework tests, all six Wand rounds and all later native journeys. Required
integrity passes in `/tmp/compositor-main-pump-fixed-integrity.log`; a fresh remote
read still returns `43d691b` in `/tmp/compositor-main-pump-upstream-tip.log`.
A generic XCTest pump
experiment passed on old code and was removed, rather than being claimed as a
failing regression.

## Color Picker text/effect target follow-up

The existing upstream observers, Qt text document and generated controls pass
two text entry points and all six effect targets without production changes.
Text selection preview, Cancel, local Undo/Redo, outer-letter isolation and
foreground policy pass in `/tmp/compositor-text-color-picker-native.log`, with
32 source tests in its build log. All visible fx menus/swatches/Hex previews,
exact alpha, Cancel/OK, palette isolation, upstream effect history, exact
Undo/Redo and saved effect RGB pass in
`/tmp/compositor-effect-color-picker-menu-native.log`, with 17 source tests.
All targets followed by 16 Gradient cases pass in
`/tmp/compositor-color-picker-target-sequence-native.log` (exit 0).
The earlier complete 1,058-test run predates these acceptance additions;
other filter/dialog targets, multiwindow geometry/HDR and physical/Mac
comparison remain open. The table remains 74 rows: 3 Implemented and 71 Adapted.

## Color Picker filter/modal follow-up

Seven filter color targets pass exact preview/commit, alpha, Cancel/OK,
palette/source/history isolation and Undo/Redo in
`/tmp/compositor-filter-color-picker-native.log` (exit 0), with 20 source tests.
The modal Grid Settings fixture exposed blocked Hex Return; `SessionWindow.cpp`
now uses the active sheet as the picker parent. Nine picker/grid source tests
and all previous picker targets, Grid Color and 16 subsequent Gradient cases pass
in `/tmp/compositor-grid-color-picker-parent-{build,native}.log` (exit 0).
The complete 1,058-test checkpoint predates this correction and was not rerun.
Required-shader/protected-source integrity passes after the correction in
`/tmp/compositor-grid-color-picker-integrity.log` (exit 0).
Canvas Size/Export dialog targets and physical/Mac acceptance remain open.
The table remains 74 rows: 3 Implemented and 71 Adapted.

## Canvas Size and JPEG picker follow-up

The existing modal-owner correction also supports Extension Color and Export
Background. No production changes were needed in this follow-up. Eleven source
tests and all prior picker targets, seven modal cases and 16 subsequent Gradient
cases pass in `/tmp/compositor-dialog-color-picker-oracle-{build,native}.log` (exit 0).
Actual swatches, Hex Return, Cancel/OK, outer Cancel/commit, centered 72×72 green
extension with exact Undo/Redo, and JPEG at quality 100/85/10 pass. All JPEG
pixels match an independently composed matte encoded through the Qt library
within 2/255; source/history/palette isolation and busy-release checks pass.
The complete full-run checkpoint predates the modal-owner correction; PDF/CMYK
TIFF matte variants and physical/Mac acceptance remain open.
The current table remains 74 rows: 3 Implemented and 71 Adapted.

## PDF/CMYK TIFF matte correction

The native visible RGB/CMYK menu exposed omitted Toggle actions; Qt now hosts
checkable actions using the existing handler. PDF recording now retains the
page matte rather than dropping CGContext.fill. Twenty source tests and all
picker targets plus 16 Gradient cases pass in
`/tmp/compositor-pdf-tiff-matte-fixed-{build,native}.log` (exit 0).
The independent artifact validator passes in
`/tmp/compositor-pdf-tiff-matte-independent.log`: exact PDF image/mask composition,
green rendered PDF corners, interior/exterior delta at most 5/255 within ramp
step 6 with transition band excluded, and exact four-channel TIFF inks against
LittleCMS using its embedded ICC. The first Scanlines preview/commit mismatch
was not reproduced in subsequent combined runs; its cause remains unresolved.
PDF matte re-import and physical/Mac acceptance remain open.
The new required-hardware full runner exits 0 in
`/tmp/compositor-pdf-tiff-matte-full-contract.log` and its `.exit` file: all 1,058
framework tests, native journeys, thumbnailer and 11 source-coverage checks pass.
The table remains 74 rows: 3 Implemented and 71 Adapted.

## Latest full checkpoint confirmed

`/tmp/compositor-pdf-tiff-matte-full-contract.log` and its `.exit` file are
confirmed terminal exit 0. All 1,058 framework tests (141 XCTest; 917 Swift
Testing in 148 suites), every native journey, thumbnailer and 11 coverage checks
pass with required Vulkan hardware (AMD RADV Renoir). The expanded palette,
text/effect/filter/Grid/Canvas Size/JPEG/PDF/CMYK TIFF picker targets are included.
Required integrity and independent PDF/TIFF artifacts also pass. No broader
claim is made for PDF matte re-import or physical/Mac acceptance.

## Exported PDF read/draw follow-up

`PDFMatteTests` covers nil/green matte and 72/150 DPI through the public reader
and page-drawing API, with semi-transparent blue and opaque red. The corrected
fixture exposed lost fills and double premultiplication. PDF.swift now reads
its own exporter's rectangle fills and paints them before the image;
Context.swift uses the source alpha format for fallback blending. Foundation
and the existing CoreGraphics/Skia path are reused.
Thirty-five XCTest and 13 Swift Testing tests pass in
`/tmp/compositor-pdf-matte-readback-env-fixed.log` (exit 0), including all four
new PDF parameter cases and the existing CMYK/export checks. A first scoped
command omitted the XDG ICC fixture paths; its five CMYK failures are corrected
by the same-build rerun with the proper test environment.
The latest complete 1,058-test run predates this reader/blending correction.
The new required-hardware runner is in progress in
`/tmp/compositor-pdf-matte-readback-full-contract.log`; no new full-pass claim.
Broader PDF input and physical/Mac acceptance remain open.

The new reader/blending full run has passed all 1,059 framework tests (141
XCTest; 918 Swift Testing in 149 suites). Native journeys are still live.
Fresh PDF/TIFF artifacts pass independent validation in
`/tmp/compositor-pdf-matte-readback-independent.log`, and required integrity
passes in `/tmp/compositor-pdf-matte-readback-integrity.log` (exit 0).
No new terminal full-pass claim is made.

## Current upstream format reconciliation

The historical 70-row label “Export PNG / TIFF / WebP” is retained for row
accounting. Current protected upstream `ExportFormat` in
`Compositor/IO/ProjectController.swift:417` actually enumerates PNG, JPEG, TIFF,
PDF and EXR. WebP is not offered by its Export As UI; it is therefore removed
from the outstanding upstream-visible-export work. Codec capability is a
separate fact. RGB TIFF visible export and metadata acceptance remain open.
The oversized Color Picker cells are condensed; detailed logs and scope remain
in the test baseline. Historical row numbering and status counts are unchanged.

## PDF readback full-run checkpoint completed

`/tmp/compositor-pdf-matte-readback-full-contract.log` and its `.exit` file are
confirmed terminal exit 0: 141 XCTest + 918 Swift Testing in 149 suites, every
native journey, six Wand rounds, thumbnailer and 11 source-coverage checks.
Required Vulkan hardware executes on AMD RADV Renoir. Fresh independent
PDF/TIFF artifacts and protected-source/shader integrity also pass. This
checkpoint includes the new four PDF readback cases and fallback alpha fix;
it predates the subsequent test-only visible RGB TIFF acceptance addition.

## Scanlines and Menu Picker full-run checkpoint completed

`/tmp/compositor-scanlines-scratch-fixed-full-contract.log` and its `.exit` file
are confirmed terminal exit 0. It passes 141 XCTest + 918 Swift Testing in 149
suites, every native journey, six Wand rounds, thumbnailer and 11 source-coverage
checks on required AMD RADV Renoir Vulkan hardware. This checkpoint includes
the actual More > TIFF Menu Picker and all six RGB TIFF Cancel/Export cases at
72/150/300 document DPI. The poisoned-allocator Scanlines regression fails
before and passes after Linux-only zero-initialized scratch allocation using
standard `calloc`; protected C source remains unchanged. Required shader and
generator integrity exits 0 in `/tmp/compositor-scanlines-scratch-integrity.log`.
This completed checkpoint predates the next 24-mode blend-menu GUI probe;
that new probe is not yet a verified completion claim.

## All 24 blend modes verified through the visible menu

The new GUI probe exposed a Linux snapshot defect: Qt correctly highlighted the
chosen mode and the render key noticed it, but the displayed manifest retained
the committed mode. Linux now uses unchanged upstream `displayedBlendMode` in
that snapshot; the source document remains unchanged during hover preview.
The final `/tmp/compositor-blend-preview-final-swift.log` passes 141 XCTest and
919 Swift Testing tests (1,060 framework tests) on required AMD RADV Renoir.
The terminal follow-up exits 0: its native log passes all 24 visible modes,
Escape/Return, source/history isolation, exact Undo/Redo and the separate
preview/save/transform/tab/RAW/text journeys. Required source/generator/shader
integrity also exits 0. The earlier complete combined native runner was not
repeated in this follow-up. The tested table now has 75 rows: 3 Implemented
and 72 Adapted. Masked/nested/HDR and physical/Mac combinations remain open.

## Levels Auto, eyedroppers and four channels verified

The separate `--levels-controls-probe` is now invoked by the contract script.
All six native cases exit 0 in `/tmp/compositor-levels-controls-focus-native.log`:
Contrast, Color, Color + neutral midtones and Black/Gray/White samples. Visible
channel ranges match independent histogram/sample calculations; all-pixel
RGB equations pass within 2/255, alpha is exact, transparent sampling is refused,
and Cancel/OK/source history plus exact Undo/Redo pass. All ten original
LevelsTests pass. The initial failure was the test's immediate key sequence
retaining RGB after a panel rebuild; refetching/focusing between events fixes
the harness. No filter code change was needed. The current table has 76 rows:
3 Implemented and 73 Adapted. Histogram-handle dragging and masked/transformed/
HDR/physical/Mac combinations remain open. The earlier full framework and native
checkpoints predate these test-only additions; the combined runner was not
repeated for this follow-up.

## Levels histogram handles verified

`/tmp/compositor-levels-handles-settled-native.log` is confirmed terminal exit 0
with all 20 combinations of five handles and four channels passing. The actual
triangle drag uses its named coordinate space; captured pixels match independent
Levels equations within 2/255 with exact alpha. Preview Off/On, source/history
isolation, Cancel/OK and exact Undo/Redo pass. Ten original LevelsTests also pass.
The initial Gamma failure was an earlier asynchronous preview frame; diagnostics
showed the correct result arriving, so the test now waits for all-pixel equation
agreement before capturing. No filter or hosting change was needed. The current
table remains 76 rows: 3 Implemented and 73 Adapted. Endpoint crossing and
selected/masked/transformed/HDR/physical/Mac combinations remain open.

## Curves point editing and channels verified

The terminal `/tmp/compositor-curves-points-native.log` exits 0 for four visible
RGB/Red/Green/Blue cases. Graph add/move, Remove/Reset, endpoint-removal refusal,
middle-knot output within 2/255, exact clear/partial/opaque alpha and unchanged
other channels/source/history pass, including Cancel/OK and exact Undo/Redo.
Fourteen original filter/adjustment tests pass. The contract script includes the
new separate probe; no application implementation or dependency changes were
needed. The tested table now has 77 rows: 3 Implemented and 74 Adapted. Arbitrary
interpolation, multiple-point limits and selected/masked/transformed/HDR/physical/
Mac combinations remain open. Earlier full checkpoints predate this test-only
follow-up; they were not repeated here.

## Hue/Saturation spectrum handles: focused acceptance passes

The actual gesture changes Swift's band but previously left Qt degree labels
stale: a still-focused Hue field made the shared renderer defer panel refresh.
DragPressFilter now ends field editing outside the gesture, capturing origin,
identity and minimum distance before the resulting rebuild. The native fixture
directly asserts the numeric field loses focus at the gesture's start.
`/tmp/compositor-hue-range-cube-native.log` is confirmed terminal exit 0 for all
24 handle/range cases, including red wraparound, degree labels, inverted bands,
Preview Off/On, exact alpha/source history and Cancel/OK/Undo/Redo. Thirteen
original HueSaturationTests pass. The independent oracle uses existing Qt HSL
conversion, fractional unpremultiplied input, rounded-degree response and the
actual 33³ cube interpolation contract, without calling the app's conversion
or kernel; RGB tolerance stays 3/255. The initial direct-HSL assumptions and
diagnostic evidence are retained in the baseline. No temporary dispatch or Swift
state logging remains. The current table has 78 rows: 3 Implemented and 75
Adapted. The new shared host change still awaits terminal full-regression
evidence in `/tmp/compositor-hue-gesture-full-contract.log`; the goal remains
active and physical/Mac and compound sampling/HDR cases remain open.

## Gesture focus full checkpoint completed

`/tmp/compositor-hue-gesture-full-contract.log` and its `.exit` file are confirmed
terminal exit 0. The required AMD RADV Renoir run passes 141 XCTest + 919 Swift
Testing tests in 149 suites (1,060 framework tests), every native journey,
six Wand rounds and all 54 separate Levels/Curves/Hue control cases. The shared
gesture focus correction is included. Thumbnailer, 11 source-coverage checks
and required protected-source/generator/shader integrity also pass. The complete
runner evidence closes the earlier pending gate for that host change. It
predates the subsequent image-clipboard probe; that probe is still unverified.

## Image clipboard menus and Qt MIME verified

`/tmp/compositor-image-clipboard-history-native.log` is confirmed terminal exit 0
for three actual Edit-menu Copy/Copy Merged/Cut > Paste cases on a pointer
selection over two colored layers. The normal NSPasteboard.general bridge is
installed and XCTestConfigurationFilePath is absent. All PNG pixels and exposed
image MIME, 20×20 crop at [12,12], source/history isolation and exact Cut/Paste
Undo/Redo pass. Eleven original SelectionClipboardTests also pass. Initial
failures were harness assumptions: omitted bridge setup, QImage object equality,
Codable geometry arrays and the Cut history label (upstream records Clear).
No application clipboard change was needed. The contract script includes the
new probe. The table now has 89 rows: 3 Implemented and 86 Adapted; physical
interapplication delivery and additional image types/mask/HDR combinations remain
open. The earlier full checkpoint predates this test-only follow-up.

## Selection-outline native acceptance, 2026-10-15

The release build passes all 19 original SelectionEditTests. The new native
`--selection-outline-probe` completes with exit 0: four arrow directions at 1 px
and Shift+10 px, an ordinary pointer drag and a partly off-canvas drag pass exact
all-pixel coverage, unchanged source/layers/target and one-step Undo/Redo.
Logs: `/tmp/compositor-selection-outline-{build,native}.log`. Protected-upstream
integrity and shell syntax also pass. The existing upstream implementation
supplies the behavior; only acceptance tests and their contract invocation changed.
Historical row 29 now has native rectangular-control evidence. The current table
has 80 rows: 3 Implemented and 77 Adapted. The full checkpoint predates this
test-only addition. Other shapes/tools, feathering, fractional drags and
physical/Mac acceptance remain open; the full goal remains active.

## Free-distortion preview and group pointer transforms, 2026-10-15

The native corner-drag probe exposed a real Linux cache defect: distortion
corners changed while ordinary transforms and image identities stayed fixed,
so the C ABI kept the original cached composite. `RenderKey` now includes draft
corners. The original failing perspective/pixel evidence is retained in
`/tmp/compositor-transform-gestures-diagnostic-native.log`.
All 33 focused tests in five suites pass, including the new corner-cache
regression. Both the early and focused native logs terminate with exit 0 for
six corner/edge/Shift-axis Cancel/Apply cases and four selected-layer/folder
move/scale cases. Independent perspective checks, exact preview/commit pixels,
child geometry, target/hierarchy, unselected-layer isolation and one-step
Undo/Redo pass. Historical rows 18 and 19 now have native pointer evidence.

Required source/generator/shader integrity passes. The corrected full contract
run passed 141 XCTest + 926 Swift Testing tests (1,067 total) and all six Wand
rounds in `/tmp/compositor-transform-gestures-verified-full-contract.log`.
It was deliberately stopped (terminal exit 143) during subsequent native
journeys after live upstream moved to 1.5.3; the full gate moves to the merged tree.
Its earlier attempt failed because the isolated CMYK fixture and explicit
Vulkan backend selection were omitted; those setup failures remain in the
original full-contract log. The full regression gate is not closed yet.
The current table has 82 rows: 3 Implemented and 79 Adapted. Folded distortion,
group rotation, nested/hidden/masked/HDR cases and physical/Mac acceptance
remain open, so the full goal remains active.

Live upstream `365b574` (1.5.3, nine new commits) is now merged as `94cf71e`.
Its compatibility catch-up and acceptance are in progress; the table above
remains evidence for the stated 1.5.2 scopes. See the latest baseline section
for build findings, preserved work and pending merged-tree verification.

The 1.5.3 focused release gate passes 10 XCTest + 64 Swift Testing tests,
including unchanged exhaustive opaque-RGB Camera Raw lookup checks. Three
Linux acceptance tests additionally verify actual RADV hardware submissions,
odd padded rows, buffer recreation, shape draft/commit pixels and clip bounds.
The corrected native probe passes middle-button Layers scrolling and both
shape corner modes. It exposed and corrected stale dependent Qt controls while
the Radius field retained focus. The exact logs and earlier failures are listed
in the baseline. The unchanged 2–48 MP paired GPU benchmark also passes,
including exact CPU/GPU pixels for every workload and successful direct GPU
calls. [Linux measurements](camera-raw-linux-performance.md) retain all samples
and report limited preview gains, with no mixed Shadows/Clarity gain.
The full merged-tree framework phase passes 1,086 tests; the native phase later
exits 1 at the stale schema assertion described below. These results do not
close the complete regression gate or the broader parity goal.

The next 1.5.3 native gap is cursor delivery during middle-button navigation:
`SessionWindow::canvasMousePressEvent`, `canvasMouseMoveEvent` and
`canvasMouseReleaseEvent` discarded the cursor returned by the upstream
bridge. The left-button path applies that cursor. The isolated native
`--zoom-cursor-probe` reproduces the failure (exit 1) after both left-button cases
pass: the middle-button reversal retains its previous picture. The shared
cursor installer now serves both paths. Its first isolated run passes both
left-button and both Ctrl/Meta middle-zoom cases, then fails plain pan release:
the compatibility cursor-invalidation hook is empty. The bridge's existing
left-release cursor restoration is now extended to middle release; the static
target and coherent isolated host now pass all six native cursor cases (exit 0,
`/tmp/compositor-zoom-cursor-coherent-native.log`).
The probe covers displayed pictures through reversals, stationary samples,
modifier release/click behavior and plain middle pan from Move/Brush.
The earlier full run excludes this follow-up and exits 1 at the preview journey's
stale manifest-version-13 assertion. It passes all prior phases, including the
1.5.3 controls and 1,086 framework tests. The assertion now checks version 14
separately from exact font-run preservation. The standard package/test-product
rebuild passes 12 original Cursor/MiddleButton tests, all six native cursor
cases and the three 1.5.3 Layers/Shape cases. Preview then fails an earlier
Shift-click mask-coverage assertion, which the baseline binary had passed.
The remaining document journeys were not reached. An extracted mask probe keeps
exact alpha/Undo/Redo assertions and adds model/viewport diagnostics; no
production mask change is made before its root cause is known. The diagnostic
build and focused/context runs use `/tmp/compositor-mask-toggle-diagnostic-*`.

The current feature table now has 88 rows: 3 Implemented and 85 Adapted. Six new
rows record the independently verified 1.5.3 scopes: native-resolution Camera
Raw previews, bounded scope sampling, Vulkan lookup, smoothed rectangle corners,
middle-button Layers scrolling and cursor direction/release restoration.
These feature scopes do not close the incomplete full regression gate or the
broader parity goal.

## 1.5.3 complete checkpoint and event/cursor follow-ups, 2026-10-15

The fresh complete checkpoint `/tmp/compositor-upstream-153-final-contract.log`
terminates with exit 0: 141 XCTest + 945 Swift Testing tests, all 11 coverage
checks and every native journey. Required-shader/protected-source/generator
integrity also passes. Without the extra pre-click state read, the focused mask
probe and three complete preview repetitions pass; the separate document-tail
journeys also pass. These results supersede the pending-job statements above,
but do not explain the original intermittent mask failure.

Two later cursor failures are reproduced with explicit native shape/picture
checks: Zoom hover retains the arrow, and a stationary Hand shortcut retains
the Zoom picture. Hover now applies tool cursor rectangles while preserving
Move/selection refinements. The Qt host refreshes at the recorded pointer
position after tool/key changes outside gestures and sampling. The rebuilt
normal product passes Hand/Zoom keyboard checks, the existing six Zoom/pan
cases, all three 1.5.3 Layers/Shape cases and the complete preview journey in
`/tmp/compositor-native-followup-*.log` (combined terminal exit 0). The keyboard
probe is now part of the contract runner.

The new actual-mask regression independently reproduces stale event context:
an outer middle release redirects incoming Shift-click hit testing to the
table. Moving left-button hit testing inside dispatch fixes the regression;
all three NativeMaskGeometryTests pass, including mask/history restoration,
in `/tmp/compositor-native-event-context-fixed.log`. The failing before-log is
retained. This is a verified separate defect, not a proven explanation for the
earlier intermittent failure. The complete run including these follow-ups passes
in `/tmp/compositor-upstream-153-event-cursor-contract.log` (terminal exit 0):
141 XCTest + 946 Swift Testing tests, all 11 coverage checks and every native
journey. Both mask cases, all six Wand rounds, both cursor probes and all three
1.5.3 controls cases pass. Required-shader/protected-source/generator integrity
passes in `/tmp/compositor-upstream-153-event-cursor-integrity.log`.

The table remains 88 rows (3 Implemented, 85 Adapted) with the cursor row's
verified scope expanded. Broad API, feature-combination and physical/Mac
acceptance remain open; the full goal remains active.

The subsequent right-click audit finds a second stale-event hit-test path.
An enclosing middle release selects the wrong context-sensitive menu because
`PointerRouter.rightDown` calls hit testing before dispatch installs the new
event. The new NativePointerContextTests regression records six failures before
the one-line move and passes afterward. Incoming type/modifiers/location and
event identity through menu presentation, plus outer-event restoration, are
verified. Five focused pointer/mask/popup tests pass. Full-framework follow-up
passes 141 XCTest + 947 Swift Testing tests in 156 suites (1,088 total), complete
native preview and all 1.5.3/cursor probes; integrity passes. The combined
`/tmp/compositor-right-click-context-regression.exit` is 0. See the baseline for
individual logs. The earlier complete native contract predates this follow-up;
its combination/document-tail phases were not repeated. Broader API and device
acceptance remain open.

The next pointer audit reproduces incorrect right-button identity and loss of
held-button state across overlapping left/middle presses. The compatibility
mouse-event factory now supplies right/other button numbers; left transitions
preserve unrelated bits and middle release clears its bit before callbacks.
A stronger test exposes stale pressed state during hit testing even after the
callback fix; press bits now update before left/middle hit testing. A real
`NSWindow.nextEvent` regression verifies consumed left release retains middle
and clears the left target. Original and intermediate failing logs remain in
`/tmp/compositor-pointer-buttons-before.log` and
`/tmp/compositor-pointer-hit-buttons-before.log`.

All 19 focused tests in five suites pass. Full follow-up verification passes
141 XCTest + 949 Swift Testing tests in 156 suites (1,090 total), complete native
preview, all three 1.5.3 Layers/Shape cases, six Zoom/pan cases and both keyboard
cursor cases. Required source/generator/shader integrity passes; the combined
`/tmp/compositor-pointer-buttons-regression.exit` is 0. The earlier full native
contract's combination/document-tail phases were not repeated. Physical
multi-button input, broader API/feature acceptance and the unexplained earlier
intermittent mask failure remain open. The 88-row table retains its scoped
3 Implemented / 85 Adapted assessment; the goal remains active.

## Native transform-snapping acceptance and preview reliability, 2026-10-15

Historical row 20 now has 66 native pointer cases, 33 on each axis. Canvas and
other-layer edges/centers, visible guides, side resizing and a proportional
corner pass visible Snap/Snap To/Show/Zoom controls, hidden/disabled targets,
global Snap off and Meta suppression. Explicit rectangle geometry/pixels,
screen-point tolerance at 1/2/4 points per document pixel, history-free preview,
interior alignment-line display/removal and exact saved-state Undo/Redo pass.
Imports, initial placement and guide creation are fixtures; transform gestures
use native Qt pointer delivery. The existing upstream implementation supplies
the behavior; no production snapping change was needed. The contract now runs
`--transform-snap-probe`. The 17 original snapping/guide tests also pass.

Related ten transform-gesture and eight numeric-field cases and required
integrity pass. The subsequent complete preview reproduces the intermittent
mask failure. Additional diagnostics show both a failing visible/current-project
click and, in a different repetition, an impossible synthetic click at global
y = -582 from a table scrolled by 863 pixels. Another repetition fails earlier
at Command-click disjoint selection. Those failures remain in the baseline's
logs; there is no complete regression pass for this checkpoint.

The mask harness now requires active-project ownership, a reachable viewport
point and the native mask thumbnail before sending input, with a five-second
timeout. Exact mask alpha/Undo/Redo checks remain unchanged. It fixes the proven
test synchronization gap, without claiming a production mask fix or explaining
all earlier failures. Its focused scroll/replacement probe, three original
mask-geometry tests and three complete previews pass; combined terminal status
`/tmp/compositor-mask-visible-ready.exit` is 0. Final required integrity passes
in `/tmp/compositor-transform-snap-final-integrity.log`. The earlier valid-target
mask failure and independent Command-click failure remain unexplained. These
follow-ups do not constitute a repeated complete contract run.

The feature table now has 89 rows: 3 Implemented and 86 Adapted. Competing
snap targets/grid, rotated/masked/group/HDR combinations, native preview
reliability, broader API and physical/Mac acceptance remain open. The goal
remains active.

## Window-construction state reset and selection regression, 2026-10-15

The new native `--layer-disjoint-probe` consistently reproduced Shift-Up failing
after another window closed. Traces established delivery to the correct table
and intact native root/window/first responder. Temporary Swift instrumentation
then showed that the session had changed from Brush to Move: the second Qt
constructor registered the existing workspace tab and explicitly selected Move
and a black foreground. The upstream table correctly nudged instead of extending
selection. Construction now reads the session's tool/palette after building its
controls. No upstream table selection logic or test expectations were changed.

All 16 exact Command/Shift-click and expanding/contracting Shift-arrow rounds
pass, including eight second-window lifecycles, retained tool/palette, unchanged
pixels and history. The contract runner now includes the probe. The corrected
full suite passes 141 XCTest + 949 Swift Testing tests (1,090 total), and three
complete native previews and required source/generator/shader integrity pass;
`/tmp/compositor-disjoint-window-verified.exit` is 0. The initial full attempt
stopped on nine missing-ICC-fixture issues; the existing fixture resolved that
setup error. Exact logs and scope are in [the baseline](upstream-test-baseline.md).
Related tab/window, asynchronous save and transform journeys also pass;
`/tmp/compositor-disjoint-window-journeys.exit` is 0.

This proves the window-reset fix, not the cause of the older intermittent
Command-click and valid-target mask failures. The earlier complete contract was
not repeated here. The 89-row inventory retains 3 Implemented / 86 Adapted within
its documented scopes; broader combinations, API, physical and Mac acceptance
remain open, so the overall goal remains active.

## Motion Blur spread and native filter controls, 2026-10-15

Historical row 52's visible-controls gap now has 42 native cases spanning Motion
Blur, Add Noise and Lens Correction, with whole-image and pointer-selected edits.
The selection is independently checked by a reversible all-pixel fill; its
boundary cuts Motion Blur's streak. Blur direction/absolute spread, noise moments/
amplitude/distribution/channel/alpha behavior and a separate radial lens oracle
check the rendered pixels. Preview, Cancel/OK, exact source/target/history and
Undo/Redo pass; zero lens distortion closes without adding history.

This work found a production mismatch that direction-only tests would miss:
upstream calibrates Distance using radius as standard deviation, but compat
uniformly sampled ±radius. The new impulse regression first fails all 12
radius/angle combinations (radius 4: variance 6.6667 versus 16). Gaussian weights,
matching sampling/extent margins and weighted SIMD/boundary accumulation now
pass those moments, scalar comparisons and regional rendering. Default Full HD
raw kernel timing remains approximately 13–16 ms, below the existing 500 ms
guard; this does not establish end-to-end latency or extreme-radius performance.

The full follow-up passes 143 XCTest + 949 Swift Testing tests (1,092 total) and
required source/generator/shader integrity. Exact logs and numerical tolerances
are in [the baseline](upstream-test-baseline.md). All 42 native cases pass in
three repetitions (126 executions), followed by complete preview and required
integrity; `/tmp/compositor-filter-controls-focus-ready.exit` is 0. The earlier complete native
contract predates this correction. Extreme values, transformed/masked/HDR
combinations, Mac kernel/appearance comparison, physical input, older intermittent
input failures and wider API acceptance remain open. The 89-row inventory keeps
3 Implemented / 86 Adapted within its stated scopes; the goal remains active.

## Exposure, Gradient Map and Grain native controls, 2026-10-15

Historical row 50 now has 30 passing native Image-menu cases, half through
pixel-proven pointer selections. Exposure verifies individual/combined stops,
Offset and Gamma against independent linear-light equations. Gradient Map
verifies both endpoint pickers, Hex submission/RGB, live preview, picker Cancel/
OK and Reverse against luminance interpolation. Grain verifies same-seed
amplitude scaling, larger particles with Size, finer detail with Roughness,
midpoint interpolation, zero/restore and neutral channels. All six numeric
sliders pass Home/End range checks, including logarithmic Gamma and Size.

Preview Off/On, parent Cancel/OK, exact source/target/palette/history isolation,
alpha/outside pixels and pixel/record Undo/Redo pass. Default Exposure and zero
Grain leave history unchanged. Eighteen original adjustment/editor tests pass;
no production adjustment implementation was changed. The initial Hex-draft and
retired-widget failures were harness expectations, corrected against upstream
submission semantics and the visible field retaining text/focus/cursor.
The final 30-case grid passes in three repetitions (90 executions), with all
18 original adjustment/editor tests passing again in the focused rebuild.
Related 42 filter cases, complete native preview and required source/generator/
shader integrity also pass; `/tmp/compositor-image-adjustments-verified.exit`
is 0. This is focused framework/native acceptance, not another full contract run.

The contract runner includes the new probe. Exact values, numerical tolerances
and native logs are in [the baseline](upstream-test-baseline.md). The last full
framework/native checkpoints predate this test-only follow-up. Transformed/
masked/HDR combinations, larger images, continuous slider/pointer gestures,
physical/Mac appearance, older intermittent input failures and broader API
acceptance remain open. The inventory remains 89 rows: 3 Implemented / 86 Adapted
within its documented scopes. The overall goal remains active.

## Native panel ownership and release, 2026-10-15

A new repeated create/render/close regression exposes a production defect:
31 of 32 reopened Layers panels used a closed session's coordinator instead of
showing the current session's uniquely named row. Panel scopes used an entry's
allocator address hash, while close left the native/state/observer caches alive.
The bridge now uses UUID scopes and discards all rendered panels, handlers,
pending snapshots and dirty notifications on close. Late observation callbacks
are rejected. Two handles sharing a document keep independent scopes; closing
one preserves the other's native rows and document.

The scope fix passes reopening/alias/invalidation tests, but the asynchronous
weak-session test initially still fails. The generated Linux ContentView patch
now clears arrow-stepper callbacks on disappearance: the stored change closure
captures a view that owns the same stepper. All four lifecycle tests now pass,
including session release. Four complete native previews, 16 disjoint-selection
rounds across two windows and the mask-scroll/replacement probe pass; required
source/generator/shader integrity passes and their script exits 0. The full
framework run passes 147 XCTest + 949 Swift Testing tests (1,096 total). Its
complete native contract also exits 0, including all configured control, preview,
save/recovery, transform, tab, RAW lens and text journeys. Required hardware and
protected-source/generator/shader/ledger checks pass; see the baseline for exact logs.

The earlier intermittent Command-click and valid-target mask failures have not
been conclusively traced to this ownership defect. Repeated passing input runs
are scoped regression evidence, not proof of that historical root cause.
Physical input, wider combinations and Mac comparison remain open. The inventory
stays at 89 rows, 3 Implemented / 86 Adapted within the documented scopes; the full
goal remains active.

## Layer-effect numeric and position controls, 2026-10-15

Historical row 14 now has native acceptance beyond color swatches. The new
`--effects-controls-probe` passes 54 cases across all six effects on opaque and
half-alpha rectangles: Stroke Inside/Outside and Size/Opacity (including numeric
Size 50 beyond the slider's 20), Drop/Inner Shadow cardinal angles, Distance and
Blur, Color Overlay opacity, and Outer/Inner Glow sizes. Independent all-pixel
morphology/Gaussian/compositing equations agree within 4/255 premultiplied RGBA;
inner shadow/glow and overlay alpha remain exact. Cancel/OK, source/target/palette
isolation, exact numeric-edit Undo/Redo, saved parameters and unchanged saved
source PNG channels/sRGB pass. All 36 focused framework tests also pass.

The initial metadata-equality and negative-QRect erosion failures were harness
errors, demonstrated by zero differing source pixels and a standalone Qt geometry
probe. Their corrections preserve exact source-pixel checks and the original
oracle tolerance. Application effect code is unchanged. Exact logs and parameter
values are recorded in the baseline. The full earlier 1,096-test/native contract
predates this test-only addition; the contract runner now includes it. Effect
stacks, selections/masks/transforms/HDR, continuous pointer controls, extreme
values and physical/Mac comparison remain open. The inventory remains 89 rows,
3 Implemented / 86 Adapted within documented scopes; the full goal remains active.

## Layer nesting and Alt-drag duplication, 2026-10-15

Historical row 5 now passes eleven actual-pointer nesting/copy cases, including
multiple rows, complete nested-folder trees, selected-descendant deduplication,
late Alt, moving out and move/copy refusal into descendants. Record-level parent/
ID/order and source-isolation checks, an independent translucent source-over
pixel oracle and exact one-step hierarchy/ID/pixel Undo/Redo pass. The focused
framework run passes 4 XCTest + 83 Swift Testing cases.

The move-out setup first reproduced a stale native coordinator: direct cached
accessibility showed the original single `input` row while the model held the
renamed red/blue rows and destination. The valid Qt press hit the correct session
and table but never entered native drag tracking. Ordinary left/right presses
now synchronize native panel state before hit testing; active tracking loops are
preserved. With the same stale-cache snapshot and event sequence, all eleven
cases pass. This is a production correction backed by a before/after regression,
not a widened wait or relaxed assertion. The contract runner includes the probe;
the complete combined framework/native regression exits 0: 147 XCTest + 949 Swift
Testing cases (1,096 total) and all configured native journeys, including all
eleven nesting cases and 54 effect-control cases. Required Vulkan hardware,
protected-source/generator/shader/ledger integrity and evaluated-target coverage
checks pass. Exact logs and scope are in the baseline. Masks/clipping/effects/HDR,
collapsed/scrolling targets,
cross-folder multi-selection and physical/Mac delivery remain open. The table
continues to use 3 Implemented / 86 Adapted for its documented scopes; the overall
goal remains active.


## Collapsed folders and held-pointer autoscroll, 2026-10-15

The focused framework run passes 4 XCTest + 84 Swift Testing cases (88 total),
including a new native symbol accessibility regression. All 26 nesting/copy
cases pass in `/tmp/compositor-layer-nesting-both-edges-native.log`, exit 0.
The additions cover collapsed sources/targets, cross-folder multiple selections
and stationary-pointer autoscroll upward/downward for Move and Copy, retaining
exact record/parent/ID/order, independent translucent pixel, source-isolation,
selection and one-step Undo/Redo checks.

Two reproduced production defects are corrected: NSImage symbol creation and
configuration now preserve accessibility descriptions, and row-drag sessions
continue edge-repeat delivery and invoke compatibility table autoscroll before
drop validation. The baseline records failing-before evidence and separate Qt
viewport-lifetime corrections in the acceptance harness. The expanded complete
contract's original log stops during Wand repetition 5 without an exit result;
October 16 host inspection confirms no remaining runner. A fresh run at
`/tmp/compositor-layer-autoscroll-resume.log` passes all 1,097 framework tests
(147 XCTest + 950 Swift Testing), with required protected-source/generator/
shader/ledger integrity passing in the matching integrity log. Every configured
native journey, including all 26 nesting/copy cases, also passes and its `.exit`
file is 0. This completes the combined checkpoint before the later Invert fix;
the corrected build's remaining native journeys are tracked separately below.
Masks/clipping/effects/HDR combinations and physical/Mac delivery remain open.
The 89-row table remains 3 Implemented / 86 Adapted within its documented scopes;
the full parity goal remains active.

## Thumbnail selection modifiers, 2026-10-16

Historical row 31 now passes twelve native Ctrl/Shift/Alt window-pointer cases
for image, layer-mask and folder-mask thumbnails, including subtract precedence
when Shift and Alt are both held. Independent all-pixel set equations and
reversible blue fills prove the original selection after Undo and loaded
coverage after Redo. Source pixels/records and the gesture's immediate edit
target remain exact. The isolated release build and native log
`/tmp/compositor-thumbnail-selection-{build,native}.log` pass, with native exit 0.

The initial failure was an incorrect harness comparison spanning its temporary
proof layer: upstream history deliberately clears the mask target across layer
switches. The corrected probe compares each gesture with its immediate entry
state; pixel/record/history checks remain unchanged. Production code is unchanged.
The contract runner includes the probe; shell syntax/diff checks and required
protected-source/generator/shader/ledger integrity all pass. The integrity log
is `/tmp/compositor-thumbnail-selection-integrity.log` (exit 0).
The earlier full run has now exited 0 on its prior executable/script; it did not
include this test-only addition. The current corrected runner includes it. Transformed/HDR/partial-alpha
combinations and physical/Mac input remain open. The goal remains active.

## All current adjustment-layer kinds, 2026-10-16

Historical rows 11 and 12 now have native evidence for every current kind.
`/tmp/compositor-modern-adjustment-native.log` exits 0 for six additional cases:
Gaussian Blur, Motion Blur, Add Noise, Black & White, Color Balance and Invert.
Together with the historical six-kind journey, native creation covers all twelve
kinds and re-editing covers all eleven that have settings. The newer editors
pass actual window-pointer double-clicks and the Edit menu, live numeric changes,
Cancel/OK, exact history/pixel/identity Undo/Redo, saved numeric parameters,
unchanged source PNG channels and exact package-reopened composites. Invert has
no editor and passes independent channel-complement/alpha checks.

The initial failures were harness assumptions about default-settings history,
native release delivery and escaped Qt menu text. Diagnostics and the confirmed
tracking stack are retained in the baseline; production code is unchanged.
The isolated release build and required source/generator/shader/ledger integrity
pass in `/tmp/compositor-modern-adjustment-{build,integrity}.log`; shell syntax
and diff checks pass. The contract now includes the probe. Its predecessor has
now exited 0 on its earlier script/executable without this or the thumbnail
modifier addition. The current Invert-corrected runner includes both. Wider parameter combinations, masked/transformed/
HDR stacks and physical/Mac appearance remain open. The 89-row inventory remains
3 Implemented / 86 Adapted within its documented scopes; the goal remains active.

## Invert adjustment editor: production lifecycle correction, 2026-10-16

The new regression disproves a broader interpretation of the earlier no-editor
claim: requesting Invert editing could retain a hidden edit and block the next
Exposure editor. An inactive Invert request could first commit a pending gradient.
Two methods / three cases fail with 22 issues before the fix. The bridge now
checks `isEditable` before changing edit state and before resolving the draft;
the generated menu disables the unsupported action. The manifest records this
adaptation, while all protected upstream files remain unchanged.

The current build passes all 1,099 framework tests (147 XCTest + 952 Swift Testing),
including all three regression cases. The modern native phase also passes all
six kinds and the strengthened Invert menu/refusal checks, with exact document,
history, target and switchability. Backend/codec/font/thumbnailer, eleven
source-coverage checks and required source/generator/shader/ledger integrity pass.
Logs and phase exit files use the `/tmp/compositor-invert-editor-` prefix; exact
paths are in the baseline. The new runner contains all 29 configured native
commands and has now exited 1 (execution session 74583): the effects-control
phase fails a package save after its opaque cases, without logging the specific
refusal guard. This remains unresolved. The earlier autoscroll
runner has exited 0 with all 1,097 framework tests and configured native journeys,
including 26 nesting/copy cases. Its earlier executable cannot certify this
production change. Do not replace that complete combined checkpoint
until the new runner terminates successfully. Wider combinations and physical/
Mac acceptance remain open. The full goal remains active.
