# GNU/Linux status completion audit

Tested checkpoint: 2026-10-14, protected upstream `43d691b`, GNU_Linux HEAD `8185eee`.
Live upstream and cached protected source both match `43d691b`; the four-commit catch-up is verified.
Implementation changes are in the working tree. This audit preserves the goal
of moving upstream features to Implemented/Adapted; it does not equate a green
status column with complete macOS parity.

## Requirements and current evidence

| Requirement | Authoritative evidence | Audit result |
|---|---|---|
| Compare with current protected upstream content | Protected-content checks pass against cached `43d691b`; a live October 14 check returns `43d691b`. | Catch-up verified within the documented Linux scopes; working-tree content is not merged history. |
| Account for original source and test inclusion | The evaluated-target coverage report accounts for 155 upstream Swift files: 128 unchanged, 20 generated, 5 replaced, 2 platform. It records 84 unchanged test files and 2 selector mirrors. | Inclusion verified; inclusion is not behavioral or API completeness. |
| Use the requested mac / GNU_Linux / Status table | The tested feature table has 79 rows: 3 Implemented and 76 Adapted. Each row states its Linux scope and differences. | Format and status vocabulary verified. |
| Exercise the current working tree | `/tmp/compositor-color-picker-final-full-contract.log` and its `.exit` file confirm exit 0: 141 XCTest + 917 Swift Testing in 148 suites, all native journeys, thumbnailer and 11 source-coverage checks with required Vulkan hardware. It predates the test-only text/effect target additions, which pass their focused and next-tool sequence journeys below. The modal Color Picker ownership correction postdates that complete checkpoint and passes its focused picker/grid and next-tool tests. Required integrity at the complete checkpoint passes against `43d691b`. | Complete checkpoint plus scoped follow-ups verified; no broader claim for unexecuted combined cases. Wider feature combinations and physical/Mac acceptance remain open. |
| Close the six implementation areas | The six-area tracker records GPU/warp, eye autoscroll, Layers keys, layout/window bounds, focus/accessibility and refusal/recovery. Current native logs include their corresponding checks. | Adapted within the documented scopes; declared performance/platform differences remain. |
| Reconcile the full earlier feature matrix | [The complete crosswalk](upstream-70-feature-crosswalk.md) maps all 70 September 21 rows, in order, to passing suites, native evidence where available, and further verification. The current 79-row tested table is a different inventory. | Row accounting complete; compound-feature and visible-control acceptance remain incomplete. Adapted in the crosswalk applies only to its stated automated scope. |
| Complete physical/platform acceptance | No Mac is available. Desktop portal/file-manager delivery, real screen readers, hardware input, installed-release update/relaunch and Mac round-trip/appearance checks remain recorded in TODOS. | Not verified; automated/offscreen checks do not satisfy these checks. |

## Historical-gap crosswalk checked in this audit

The evidence below is present in the current full-run log or the explicitly named native follow-up logs. These entries resolve
specific old claims; they do not close every combined feature in an old row.

| Earlier claim | Current evidence and scope | Remaining audit work |
|---|---|---|
| Folder duplication missing | The original selector-mirror method passes. `/tmp/compositor-folder-duplicate-native.log` exits 0 with the visible Duplicate Layer action, nested descendants, new IDs/remapped parents, original-record and visibility isolation, exact pixels/hierarchy Undo/Redo and copied-root selection. | Adapted for the automated nested RGBA8 scope. Mask/clipping/effect/HDR variants and physical/Mac appearance remain unverified. |
| Merge command/menu missing | The original menu test passes; `/tmp/compositor-folder-merge-acceptance-native.log` exits 0 with visible Merge Down/Layers/Group actions, exact composites, an untouched unselected layer, opacity baking and exact hierarchy/ID Undo/Redo. | Adapted in the automated RGBA8 scope. Masks/effects/HDR combinations and physical/Mac acceptance remain unverified. |
| Folder opacity rejected | Original group/appearance tests pass. The same native log verifies the visible percent field, rendered half alpha, unchanged child opacity/parent IDs and exact pixels/hierarchy Undo/Redo. | Adapted for the interactive folder scope. Nested/masked/HDR combinations and physical/Mac appearance remain unverified. |
| Multiple tabs and cross-project layer drag missing | Native tab acceptance covers existing/new projects, multiple rows, folders, two windows, overflow, source isolation and provider Undo/Redo. | Physical desktop drag delivery remains unverified. |
| Mask target/link controls unavailable | Native preview verifies Shift-click and unlinked drag. `/tmp/compositor-mask-edit-final-native.log` exits 0 with visible mask creation, pointer Brush/Smear, black fill, softened edges, source-image isolation and exact Undo/Redo for both layer and folder masks. Fourteen original mask tests also pass. | Paint/fill/local blur are Adapted in the automated scope. The actual Feather-selection → mask workflow also passes for layers/folders in `/tmp/compositor-feather-mask-native.log`. Map remaining selections/transforms/HDR cases before closing the combined old row; physical/Mac acceptance remains open. |
| Existing adjustment re-edit entry point missing | `/tmp/compositor-six-adjustment-diagnostic-native.log` exits 0: visible creation, thumbnail double-click and Edit Adjustment menu reopen all six historical editors. Numeric edits, Curves graph dragging and Gradient Map Reverse, Cancel/OK and exact pixels/hierarchy Undo/Redo pass. Eighteen core tests also pass. | Adapted for the six historical editors; modern kinds, broader parameters and physical/Mac input remain unverified. |
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
new probe. The table now has 79 rows: 3 Implemented and 76 Adapted; physical
interapplication delivery and additional image types/mask/HDR combinations remain
open. The earlier full checkpoint predates this test-only follow-up.
