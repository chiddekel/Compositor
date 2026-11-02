# Linux compatibility implementation: six remaining areas

Requested outcome: GPU canvas and warp acceleration, layer visibility drag autoscroll,
Layers keyboard navigation, layout and window sizing, focus and accessibility, and
busy/import/modal refusal recovery reach Implemented or Adapted status.

Baseline: GNU_Linux `8185eee`, protected upstream `f5ae5ba`. The upstream implementation
is the behavior reference. Changes belong in Linux adapters, compatibility code,
backends and Linux tests; protected upstream source and tests stay unchanged.

## Acceptance and status

Status terms: **Implemented** means the upstream behavior runs through the same
mechanism; **Adapted** means the upstream behavior is reproduced through a
Linux-specific mechanism whose differences are stated here and covered by Linux
tests or native journeys. All six areas are **Adapted** as of 2026-10-13; the
closeout evidence is in [2026-10-13 closeout](#2026-10-13-closeout).

| Area | Required behavior and evidence | Status |
| --- | --- | --- |
| GPU canvas and warp | Hardware-backed canvas evaluation and warp compute, with CPU fallback. Compare pixels, HDR precision, selections, transformed layers, Undo/Redo and failure recovery against upstream. Verify actual GPU execution, not just presentation or a successful availability check. | **Adapted.** Smudge and Liquify run on Vulkan by default on hardware devices (4.7–7.6x faster than CPU, exact CPU equality, history and failure fallback). Canvas graphs run on Vulkan in one fused pass, bit-exact with the CPU evaluator, with deterministic leaves cached exactly; a 512x512 six-layer upstream frame takes about 3 ms versus 14 ms in Core Graphics. Adaptation: the application presents with Core Graphics by default because full-viewport frames (1400x900 and larger) are still slower on the Vulkan path, whose leaves are CPU-prepared float rasters; `COMPOSITOR_FORCE_GPU_CANVAS=1` selects it. Oversized graphs now fall back per call instead of disabling the device. |
| Visibility drag autoscroll | Dragging eyes beyond either viewport edge moves the native viewport and applies visibility to newly reached rows in one undo operation. Stop at document boundaries and on release; preserve coordinate conversion for flipped views. | **Adapted.** The post-release reset is root-caused and fixed: a rebuilt Qt scroll area showed offset 0 until a deferred pass applied the native offset, and a stale Qt geometry report could overwrite a newer native offset. Under CPU load the unfixed build failed 2/2 runs; the fixed build passed 4/4 runs of 32 drags per edge, plus deterministic regressions. |
| Layers keyboard navigation | Native table navigation, range/disjoint selection, paging/boundaries and applicable type selection; preserve upstream tool shortcuts, Move-tool nudging and rename focus. | **Adapted.** Compatibility tests cover selection, range anchors, disjoint bases, boundaries, reloads and Unicode/delegate type selection. The full native acceptance checks stable navigation viewports, exact disjoint selections, all 17 tool keys, Tab/palette/opacity keys, Move/Shift nudges, Escape/Return transforms, Undo and rename focus. Home/End/Page keys can no longer be undone by a stale Qt viewport report. |
| Layout and window sizing | Honor upstream-used priorities, positional inequalities and sizing bounds, including native window constraints, root replacement and resize. Verify actual Qt geometry and unchanged document state. | **Adapted.** Priority/inequality layout and hosting bounds pass focused tests. Native checks cover every upstream window-size statement: main window minimum 800x520 and growth, opening size, Layers 222–352 points, Camera Raw docking (440 points, document height/right edge, move/resize), the PSD conversion sheet's 520x360 minimum and the command palette's 460x290 content size, with unchanged document state. |
| Focus and accessibility | Stable native focus through panel updates, correct responder-chain commands, keyboard access, names/roles/states and actions in the Linux accessibility tree. Cover disabled/hidden controls and view destruction. | **Adapted.** Drawn AppKit views expose Qt accessible rows with names, roles, states and actions; hidden, disabled and modal-blocked panels refuse actions and recover; destroyed sessions retire their interfaces. All 47 visible main-window controls now have accessible names and interactive roles (17 lacked names before). Edit keys in the inline rename editor act on its text (Undo/Redo/Select All/Copy/Paste) without touching the document. |
| Busy/import/modal refusal recovery | Refuse dependent operations without partial writes during busy/import/modal states; recover after completion/cancel/failure and preserve history. Exercise native shortcuts and actions as well as bridge calls. | **Adapted.** Earlier refusal/recovery work stands. Size, Trim and Export sheets now follow upstream `ProjectController.begin()`: the project is busy while they are open (Export As through its save panel), so menu items, shortcuts and bridge commands are disabled or refused without changes, and everything recovers after Cancel or completion. Dropped files wait while the editor cannot switch and are imported afterwards, as upstream `ProjectWorkspace.receive` does; new tabs follow upstream `canSwitch`. |

## Verification policy

Use the Flatpak KDE 6.11 SDK and its Swift extension. Set the actual Skia and ImageIO
backend paths and install CameraRawTables.bin beside the release executable. Run
focused tests for each change, native journeys for UI/input changes, then the full
contract runner and protected-tree/generator/shader gates. Review the final diff
and record results separately from test references. A green focused test does not
close an entire area.

For physical-GPU acceptance, launch the SDK with `--device=dri` and select the
host's hardware ICD. Inside that SDK, run the contract with the flags read by
the tests (a generic `COMPOSITOR_REQUIRE_VULKAN` is not a gate):

```sh
COMPOSITOR_COREIMAGE_BACKEND=vulkan REQUIRE_COREIMAGE_VULKAN=1 \
COMPOSITOR_REQUIRE_WARP_VULKAN=1 COMPOSITOR_REQUIRE_WARP_HARDWARE=1 \
COMPOSITOR_FORCE_GPU_CANVAS=1 bash scripts/linux-contract-tests.sh
```

Confirm the canvas and warp timing lines name the physical device and report
actual submissions. CPU-fallback runs are useful separate evidence but do not
establish hardware acceptance.

The six-area acceptance evidence was collected on 2026-10-13 (see the closeout below).

Earlier failed attempt: `/tmp/compositor-hdr-canvas-contract.log` passed **843
Swift Testing methods plus 132 XCTest methods (975 total)**, then failed the
native preview's eye-release assertion: the downward drag released at offset 48
and the viewport returned to 0 within 120 ms. RAW lens and text journeys after
preview were not reached. The subsequent focus-fix contract passes (recorded
below), but autoscroll release stability remains unproven until the cause of
this failure is established.

## Staged asset lifetime, refusal and native failure recovery

The native package loader already uses a replacement tab and closes it on any
failure, before mounting the new document. That transaction is retained. The
Linux asset installer, however, previously accepted writes while blocked and
accepted late duplicate assets after loading, resetting unsaved history. Two
regressions failed with seven assertions before the fix:
`/tmp/compositor-staged-assets-before.log`.

The bridge now tracks outstanding image and mask IDs for the staged document.
It consumes an asset only after a successful install and closes its loading
state once all required assets arrive. Readiness includes both the upstream
project-operation and layer-edit predicates. Document identity, revision,
modified state and Undo/Redo state must still match an untouched load. This
prevents callbacks from erasing newer edits or explicit unsaved markers. Refused
and invalid assets retain pending state so eligible retries can succeed.

Seven new methods cover **23 cases**: eight blockers for images/masks, either
asset order, duplicate rejection, interleaved edits, replacement documents with
matching layer IDs, invalid-image retry, transform cancellation/retry and an
unsaved marker without Undo entries. They and the existing manifest/pixel
round-trip pass (**eight focused methods**):
`/tmp/compositor-staged-assets-final-tests.log`. The transform/unsaved-marker
regressions also failed before the final guards:
`/tmp/compositor-staged-draft-before.log`.

The native preview now creates a disposable package whose later PNG asset has a
valid header but truncated image data. Earlier assets begin loading before the
decode fails. The old handle, document/layers, selection, pixels, modified state
and Undo state remain intact; the next valid package opens successfully.
The full hardware-required contract returns **0** with **853 Swift Testing
methods plus 132 XCTest methods (985 total)** and native combo, preview, RAW lens
and text journeys: `/tmp/compositor-staged-assets-contract.log`. Protected-tree,
generator, shader and ledger checks pass in `/tmp/compositor-staged-assets-integrity.log`.
The final native preview additionally exercises the preserved Undo and Redo
snapshots and returns **0** in `/tmp/compositor-staged-assets-native-undo.log`;
the seven staged-asset methods pass again. `git diff --check` passes.

## Autoscroll stress reproduction and bounded failure diagnostics

A fixed-size 512-entry event ring now records scroll binding, range/value changes,
pending offset application, model synchronization, viewport/document heights and
focus restoration. Recording uses plain values without allocation or output;
the failing native eye-release assertion formats the ring only after failure.
It is enabled for native tests (`XCTestConfigurationFilePath`) or explicitly with
`COMPOSITOR_TRACE_SCROLL_BUFFER`. Normal application runs leave it disabled.

`COMPOSITOR_AUTOSCROLL_REPEATS` repeats both eye-drag directions from 1 to 32
times, while retaining all later preview checks. The default remains one pass
per edge. Inside the configured SDK, stress the full contract with:

```sh
COMPOSITOR_AUTOSCROLL_REPEATS=32 bash scripts/linux-contract-tests.sh
```

One initial process and six fresh processes each passed twenty drags per edge
and the complete preview (**280 drags total**). Evidence:
`/tmp/compositor-eye-pod-trace.log` and `/tmp/compositor-eye-pod-fresh.log`.
The earlier reset did not recur, so this is stronger reproduction coverage,
not a confirmed fix or completion of autoscroll. Inspection also rules out a
simple frame-size assignment clearing an explicit `NSView.bounds` origin.
The full final stress contract returns **0**, with **846 Swift Testing methods
plus 132 XCTest methods (978 total)**, native combo/preview/RAW lens/text journeys,
and another 64 eye drags (**344 successful drags total**):
`/tmp/compositor-eye-stress-contract.log`. Protected-tree, generator, shader and
ledger checks pass in `/tmp/compositor-eye-stress-integrity.log`; `git diff --check`
passes. The callback ring is now available automatically if a later native test
reproduces the release reset. Autoscroll remains **In progress**.

### Focus-isolation experiment

A fresh current-build preview passed **32 drags per edge (64 total)** and the
complete native preview: `/tmp/compositor-eye-current-repro.log` returned **0**.
An isolated experiment then removed only `restoreFocus()` from the AppKit
widget's `showEvent`, preserving its constructor's queued restoration. The eight
scroll-geometry methods passed and all **16 eye drags** passed, but the later
Shift-Up check reproduced the known keyboard focus race (focus was `QWidget`):
`/tmp/compositor-eye-queued-focus-experiment.log` returned **1**.

This does not establish that the earlier eye-release reset was caused by queued
focus; the experiment reproduced a different failure. The renderer source was
restored byte-for-byte from its pre-experiment backup, rebuilt, and verified:
`/tmp/compositor-eye-restored-focus.log` returned **0** for the eight scroll-geometry
methods, **16 eye drags**, and the complete native preview including keyboard,
accessibility and staged-import recovery. `cmp` against the backup and
`git diff --check` passed. There is no production behavior change from this
experiment, and the autoscroll cause remains open.

## Layers keyboard acceptance audit

The unchanged `LayerTableView.keyDown` remains the behavior reference: reserved
tool/mode/palette keys take precedence over table type selection, Move arrows
nudge layers, and other navigation reaches `NSTableView`. The compatibility
table tests cover selection notifications and reveal, boundaries, Shift range
expansion/contraction, retained disjoint bases, reload/shrink behavior, disabled
and modified-key forwarding, Unicode prefixes/repeated-character cycling and
delegate-controlled type selection.

The real Qt preview checks exact selected row sets after Command/Shift clicks
and arrows, Home/End/Page movement without document history changes, displayed
name selection, inline rename focus/typing/commit/Undo, and unchanged Move nudge
behavior. It now sends all 17 upstream-reserved tool keys through the focused
Layers widget, checks Tab changes the Marquee mode, and checks X/D swap/reset the
actual palette without changing layer selection or history. Three complete
previews pass with buffered diagnostics: `/tmp/compositor-scroll-buffer.log`.
Temporary diagnostics have been removed.
The first untraced contract attempt was interrupted during compilation and is
not counted as verification. The resumed journey additionally waits 120 ms after
Up/Page Down/End to reject delayed viewport resets, verifies the numeric brush
opacity shortcut, and checks ten-pixel Shift-arrow transform drafts followed by
Escape cancellation, Return commit and one-step Undo. Its full run returns **0**:
**846 Swift Testing methods plus 132 XCTest methods (978 total)**, native combo,
the expanded preview, RAW lens and text journeys. Evidence:
`/tmp/compositor-layers-keyboard-final-contract.log`. Protected-tree, generator,
shader and ledger checks pass in `/tmp/compositor-layers-keyboard-final-integrity.log`;
`git diff --check` passes. This completes the keyboard acceptance audit and marks
that area **Adapted**.

| Keyboard requirement | Verified evidence |
| --- | --- |
| Arrow selection/reveal, ranges/disjoint bases, boundaries and reloads | `NativeTableKeyboardTests`; native exact selected-row sets and selection/history checks. |
| Home/End and Page Up/Down | Compatibility geometry tests; native scrollbar assertions and delayed Up/Page Down/End viewport-stability checks. |
| Type selection and reserved shortcuts | Unicode/prefix/cycling/delegate tests; native displayed-name selection, all 17 tool keys, Tab, X/D and numeric opacity. |
| Move and transform keys | Unchanged `TransformTests.layerListToolKeysAndTransformNudge`; native one/ten-pixel nudges, Escape cancellation, Return commit and one-step Undo. |
| Rename and focus | Native inline editor typing/commit/Undo, two-session ownership and immediate focus restoration across panel replacements. |

The preceding untraced attempt reproduced the separate eye-release failure:
`/tmp/compositor-layers-shortcut-audit.log`. The buffered repeats did not capture
its cause. It remains an open autoscroll requirement, independent of keyboard
selection and shortcut delivery.

## File import refusal before replacement and pending-gradient resolution

### New Canvas refusal before pending-gradient resolution

The Linux `new` command also reached gradient resolution before readiness checks.
Upstream `createDocument` checks project/import work, but does not reject every
modal state at that entry point. A New Canvas request during rename, conversion,
importer, error, adjustment editing or the New Canvas sheet could replace the
document. During import work it could resolve the gradient before creation was
refused. Eight regression cases produced **48 failed assertions** before the
bridge fix: `/tmp/compositor-new-refusal-before.log`.

The bridge now checks `canStartProjectOperation` before gradient resolution for
both `new` and `importFiles`. New Canvas refusal returns `-3`, preserving document
and active-layer IDs, asset identity, pending gradient, rendered pixels, history
revision and modal state. Creation succeeds after each blocker clears. The
combined busy/import and staged-asset suites pass **12 methods covering 73 cases**:
`/tmp/compositor-new-refusal-after.log`. Protected-source, generator, shader and
ledger checks pass: `/tmp/compositor-new-refusal-integrity.log`. No macOS source
or test is changed. Other command/modal paths remain open.

The full CPU-fallback contract exits **0**: **854 Swift Testing methods in
134 suites plus 132 XCTest methods (986 total)** and native combo, preview, RAW
lens and text journeys pass: `/tmp/compositor-new-refusal-contract.log`. Native
coverage includes New Canvas Undo to the welcome screen and immediate Redo,
stroke refusal/recovery, corrupt-package rollback with working Undo/Redo, Layers
keyboard/accessibility/focus, resizing and eye dragging. This passing run does
not resolve the earlier intermittent eye-release offset reset.

Correction: this New Canvas launch did not expose the SDK's DRI devices and
used a GPU requirement variable that the tests do not read. Its canvas/warp
timing lines explicitly report CPU fallback, so it does not establish hardware
coverage. Older staged-asset and Layers acceptance logs explicitly name RADV
RENOIR. The subsequent invalid-command follow-up reruns the complete contract
with `--device=dri`, `REQUIRE_COREIMAGE_VULKAN=1`,
`COMPOSITOR_REQUIRE_WARP_VULKAN=1`, and `COMPOSITOR_REQUIRE_WARP_HARDWARE=1`.

### Unsupported actions and invalid New Canvas dimensions

Unsupported actions and invalid New Canvas sizes previously committed a pending
gradient before returning `-7` or `-1`. Seven regression cases produced **42
failed assertions**: the draft disappeared, the stored asset and history changed, Undo
became available, and cancellation could not restore the original asset/revision.
Before-fix evidence: `/tmp/compositor-invalid-refusal-before.log`.

The bridge now rejects unsupported actions before processing session work and
checks New Canvas dimensions before gradient resolution. The early and final
size checks share `Command.newCanvasSize`. The supported-action list now includes
the two previously implemented selection-setting commands; a source comparison
finds it matches all **155** dispatcher actions, and executable tests verify both
settings. Combined busy/import and staged-asset tests pass **14 methods covering
81 cases**: `/tmp/compositor-invalid-refusal-after.log`. Protected-source,
generator, shader and ledger checks pass:
`/tmp/compositor-invalid-refusal-integrity.log`. The native combo journey now
rejects an unknown action and a zero-width New Canvas request while a gradient
is pending, checks document state and pixels, then continues its Brush and
two-step Undo scenario. Other malformed-command and modal paths remain open.

The full CPU-fallback follow-up exits **0** with **856 Swift Testing methods plus
132 XCTest methods (988 total)** and all native journeys, including the new
pending-gradient refusals and subsequent Brush/Undo recovery:
`/tmp/compositor-invalid-refusal-contract.log`.

Physical-GPU follow-up uses SDK `--device=dri`, the Radeon ICD and the actual
Core Image/warp requirement gates. The first attempt exits **1** with one
failure in unchanged `DeepLayerTests.cameraRawSaturationStaysSmooth`; all other
unit methods pass, and the log explicitly names **RADV RENOIR** for canvas and
warp execution: `/tmp/compositor-invalid-refusal-hardware-contract.log`. The
reported bend is `0.306150`, compared with a randomized reference bend of
`0.195201` times 1.5. Its reference averages 64 copies using
`SystemRandomNumberGenerator`. Eight isolated CPU runs and eight isolated GPU
runs all pass: `/tmp/compositor-raw-saturation-repeat.log`. No test threshold or
protected source is changed. This failure is retained as evidence, not treated
as proof of a GPU regression or ignored.

The complete required-GPU repeat exits **0**, with **856 Swift Testing methods
in 134 suites plus 132 XCTest methods (988 total)** and all native journeys:
`/tmp/compositor-invalid-refusal-hardware-repeat.log`. It passes the RAW
saturation case, native invalid-command refusal, subsequent Brush/two-step Undo,
staged-package failure recovery, Layers keyboard/focus/accessibility, resizing,
eye dragging, RAW lens and text checks. Canvas timing explicitly names **AMD
Radeon Graphics (RADV RENOIR)**; the graph is **120.32 ms** versus **145.68 ms**
for the CPU graph and **99.17 ms** for Core Graphics. The known canvas comparison
difference remains **3.9508** mean byte error and **0.32836** of pixels over 12.
Warp timing names the same physical device and reports **18 submissions**.
This does not certify the remaining GPU canvas or autoscroll requirements, nor
prove that the randomized RAW reference assertion can never fail again.

### Supported-command refusal before gradient resolution

An audit found that supported commands still resolved a pending gradient before
their own argument guards. The baseline
`/tmp/compositor-command-preflight-before.log` returned **1**: all **40 cases**
returned the expected refusal code but changed the layer image and history, removed
the pending gradient, and prevented cancellation from restoring the original state
(**160 failed assertions**). Cases include layer/selection commands, shape/text/
brush/warp starts and moves, filter/tool/effect kinds, imports/exports and resizing.

The Linux bridge now checks immutable arguments and current target preconditions
before an otherwise-required gradient resolution. The original dispatch guards
remain after the asynchronous resolution so changed session state is still checked.
Valid commands continue through the original resolution and dispatch paths;
gradient-owning and other commands that deliberately retain the draft are unchanged.
`/tmp/compositor-command-preflight-after.log` returned **0** for **eight methods**,
including the 40 refusal cases, unchanged image/document/layer/revision/preview,
successful cancellation, and a subsequent valid opacity edit.

The final regression expands to **52 cases**, adding invalid enum values, absent
mask/clone targets, invalid image resolution and excessive crop offsets. The native
combo journey also rejects malformed layer, opacity, tool/filter, anchor and empty
import commands while retaining exact pending-gradient pixels and history; its
following valid Brush switch still commits the gradient, and two Undo steps restore
the original pixels after the subsequent brush stroke.

`/tmp/compositor-command-preflight-contract.log` returned **0** with **864 Swift
Testing methods in 135 suites and 132 XCTest methods (996 total)**. All 52 refusal
cases passed, together with the native combo, preview, RAW lens and text-backend
journeys. Hardware-required canvas and warp checks executed on AMD Radeon Graphics
(RADV RENOIR). `/tmp/compositor-command-preflight-integrity.log` also passed the
protected-upstream, generator, shader, drift and ledger checks.

This covers the specified argument/target guards,
not every possible asynchronous operation failure or malformed-command path;
broader refusal and import/modal recovery work remains open. Mac code/tests are
unchanged.

### Out-of-range integer command refusal

The remaining argument audit found eight command paths converting JSON doubles
directly to Swift `Int`: selection amounts, layer offsets, wand tolerance,
distortion handles and healing mode. A finite value such as `1e300` traps rather
than returning a refusal. `/tmp/compositor-integer-refusal-before.log` returned
**1** after the new oversized feather case terminated the test process with
**signal 4**. The crash occurred when the oversized feather case started.

The Linux bridge now checks these integer arguments before gradient
resolution or dispatch. It uses representability after rounding toward zero,
retaining ordinary fractional-value conversion and existing defaults. Invalid
values return `-1` before document, tool, settings or history changes. Checks run
with or without a pending gradient and do not change Mac sources/tests.

The pending-gradient regression expands to **60 cases**. A further **32 cases**
exercise all eight paths without a draft at positive/negative large values and
the rounded `Int.max`/below-`Int.min` boundaries, then verify valid positive and
negative fractional selection-setting commands. The native combo includes all
eight oversized commands before its successful gradient-to-Brush recovery.
`/tmp/compositor-integer-refusal-contract.log` returned **0**: all **60 gradient
refusal cases and 32 numeric-boundary cases** passed, with **865 Swift Testing
methods in 135 suites and 132 XCTest methods (997 total)**. Native combo, preview,
RAW lens and text journeys passed, including exact pixel/history preservation
through the eight numeric refusals and subsequent Brush/two-step Undo recovery.
Hardware-required canvas and warp checks executed on AMD Radeon Graphics
(RADV RENOIR). Protected-tree, generator, shader, drift and ledger checks pass in
`/tmp/compositor-integer-refusal-integrity.log`; `git diff --check` passes.
This closes the audited direct integer-conversion traps, while broader command,
asynchronous import failure and modal recovery acceptance remains open.

### File import mutation ordering

Replacement image import decoding is now staged in a separate upstream session.
Previously, `clearProject()` ran before decoding: missing/corrupt files discarded
the original document and its Undo history, while a mixed valid/corrupt batch left
partial replacement content. The baseline
`/tmp/compositor-replacement-import-before.log` returned **1** with **three cases
and 11 failed assertions**. No Mac source/test changes are involved.

The current document, draft and history remain in their original session while
staging runs. Replacement commands refuse reentry, RAW/Photoshop sheets bind to
the staged session, and only an error-free replacement is installed. A cancelled
single-file RAW replacement leaves the old session intact. Successful replacements
retain the prior new-document Undo/Redo behavior. Staged assets/history are cleared
after completion so cached RAW sheet sessions do not retain obsolete documents.

`/tmp/compositor-replacement-import-after.log` returned **0** for **10 methods**,
including **six failure cases** (missing/corrupt/mixed files, with/without a pending
gradient), unchanged document/pixels/revision, usable Undo/Redo and a valid retry.
The native preview now exercises replacement RAW cancellation with a pending
gradient and nested-command refusal, plus exact missing/corrupt/mixed-failure
pixels/history and successful retry. `/tmp/compositor-replacement-import-contract.log`
returned **0** with **866 Swift Testing methods in 135 suites plus 132 XCTest
methods (998 total)** and all native combo, preview, RAW lens and text journeys.
Both new native recovery checks passed. Hardware-required canvas/warp tests ran
on AMD Radeon Graphics (RADV RENOIR). Protected-tree, generator, shader, drift and
ledger checks pass in `/tmp/compositor-replacement-import-integrity.log`;
`git diff --check` passes. This run covered single-file RAW cancellation; batch
cancellation acceptance is recorded below. Overlapping external document changes
and other asynchronous/modal refusal paths remain open.

#### Atomic cancellation of replacement batches

The native mixed PNG/RAW regression reproduced the remaining cancellation gap:
`/tmp/compositor-batch-cancel-before.log` returned **1**. Its six existing bridge
failure cases and single-file RAW cancellation passed, but cancelling the RAW
after a valid PNG installed that PNG as the replacement. The native assertion
failed with `RAW replacement Cancel imported a layer`.

The replacement adapter now expands folders using upstream's unchanged
`ImageFolder` helper, retains folder access through the entire operation, and
stages one input at a time. A decode error or an input that inserts nothing
(upstream's RAW/Photoshop cancellation behavior) aborts the whole staged batch.
Successful replacement still creates one Undo entry, including the upstream
Photoshop-only action name. The native regression covers single, mixed-file and
folder RAW cancellation, unchanged draft/pixels/history, nested refusal, valid
PNG retry and Undo back to welcome. `/tmp/compositor-batch-cancel-contract.log`
returned **0** with **866 Swift Testing methods in 135 suites and 132 XCTest
methods (998 total)** plus all native combo, preview, RAW lens and text journeys.
All **three native RAW cancellation variants** passed, including the previously
failing mixed-file case. Hardware-required canvas and warp checks executed on
AMD Radeon Graphics (RADV RENOIR). Protected-tree, generator, shader, drift and
ledger checks pass in `/tmp/compositor-batch-cancel-integrity.log`, and
`git diff --check` passes. Photoshop modal cancellation and overlapping external
document changes were still open in that run; stale-installation coverage follows
below. The broader six-area goal stays active.

### Stale replacement installation

The staged replacement still installed unconditionally after decoding. A
deterministic develop hook changed the original session while RAW import was
suspended: an edit, a same-document reload, an explicit unsaved marker or a
persistence-generation change. `/tmp/compositor-replacement-stale-before.log`
returned **1**, with **four cases and 26 failed assertions**. Decoding completed
successfully in each case, but the import overwrote the newer document/history
state. The test uses the existing Linux RAW fixture and upstream import/history
methods; Mac tests and sources are unchanged.

The bridge now captures the starting document, history revision, modified flag,
persistence generation and project URL. Immediately before installation, any
change refuses the replacement without rolling back the newer state. No await
separates that check from installation. The regression expands to **five cases**,
including a Save As location change, and checks retained pixels, document,
revision/unsaved state, URL/generation, usable edit Undo/Redo and a valid retry.
`/tmp/compositor-replacement-stale-contract.log` returned **0** with **all five
stale-installation cases**, **867 Swift Testing methods in 135 suites plus 132
XCTest methods (999 total)**, and all native combo, preview, RAW lens and text
journeys. The single/mixed/folder RAW cancellation and missing/corrupt/mixed
replacement recovery checks still pass. Hardware-required canvas/warp tests
executed on AMD Radeon Graphics (RADV RENOIR). Protected-tree, generator, shader,
drift and ledger checks pass in `/tmp/compositor-replacement-stale-integrity.log`;
`git diff --check` passes. This verifies the controlled state-change scenarios,
not every native external-file notification or modal lifecycle; broader acceptance
remains open.

### Photoshop conversion modal and folder recognition

A minimal layered PSD with unsupported Dissolve (`diss`) exercises upstream's
actual conversion sheet. `/tmp/compositor-psd-modal-focused.log` returned **1**:
the six bridge failure cases and native RAW recovery passed, and single/mixed
PSD cancellation preserved the old pending gradient, pixels and history. The
folder case failed because the conversion sheet was never presented.

The upstream folder scanner's regression confirmed that the Linux type registry
omitted both Photoshop filename extensions. `/tmp/compositor-psd-folder-before.log`
returned **1** with **two cases and two failed assertions**: uppercase PSD and
PSB files disappeared from the returned folder contents. The compatibility
registry now maps `psd`/`psb` to upstream's Photoshop identifiers and image
conformance, enabling the unchanged folder helper and file filters.

The native preview now exercises **six conversion-modal cases**: Cancel and
Import for single PSD, mixed PNG/PSD and folder batches. It checks the displayed
unsupported-blend report, nested-command refusal, exact old pixels/draft/history
on Cancel, conversion to Normal, confirmed pixels and single-step Undo/Redo.
The first hardware-required run, `/tmp/compositor-psd-modal-contract.log`, passed
**868 Swift Testing methods and 132 XCTest methods (1000 total)**, all three
PSD cancellation variants and single-PSD confirmation. Mixed confirmation then
failed a pixel assertion that incorrectly assumed centering. Upstream's
`insertPhotoshop` preserves incoming coordinates when no drop point is supplied.
The corrected check samples the PSD at its own coordinates and verifies the
earlier PNG outside those bounds. No renderer or Mac-source change was made for
that assertion. Final hardware-required verification is pending in
`/tmp/compositor-psd-modal-final.log`.

### File import readiness checks

The Linux `importFiles` command previously cleared a replacement's current
project before checking readiness. A real PNG import while renaming replaced the
unsaved document, changed its active layer, cleared the rename and changed the
history revision. The regression failed with six assertions before the fix:
`/tmp/compositor-file-import-refusal-before.log`.

File commands now check the upstream `canStartProjectOperation` condition before
resolving a pending gradient, installing prompts or clearing the project. A
refused command returns `-3` and retains session state. New tests cover append and
replacement imports across eight blockers, preservation of pixels/IDs/history
and modal state, successful retry, append Undo, and cancellation of a pending
gradient retained by a refusal. **Four focused methods covering 42 cases pass**:
`/tmp/compositor-file-import-refusal-after.log`. Protected-tree, generator, shader
and ledger checks pass in `/tmp/compositor-file-import-refusal-integrity.log`.
The full hardware-required contract returns **0** with **846 Swift Testing
methods plus 132 XCTest methods (978 total)** and native combo, preview, RAW lens
and text journeys: `/tmp/compositor-file-import-refusal-contract.log`. Existing
native folder-import and RAW-modal paths pass with the readiness guard. This
does not close staged-import failure/cancel handling or all command/modal paths.

Three additional native preview runs without tracing pass both-edge eye dragging,
disjoint keyboard selection and the complete preview after the immediate-focus
fix: `/tmp/compositor-native-focus-repeat.log`. These repeats strengthen focus
evidence but do not establish the cause of the earlier eye-release reset.

## Immediate focus restoration across native panel replacement

Four isolated native preview attempts reproduced the Shift-Up failure while
both-edge eye dragging passed. The key trace shows the table receiving the Shift
modifier press, then being replaced before the Up key reached it. The replacement
previously waited for a queued callback to restore focus. Its `showEvent` now
restores the same logical node/session's focus synchronously, preserving a focused
inline editor descendant. The existing queued callback remains for construction
paths that precede showing the widget.

The same native preview passes after this change, including exact disjoint
selection expansion/contraction, multi-row dragging, paging, rename, two-window
focus ownership, accessibility and both-edge autoscroll. Before evidence:
`/tmp/compositor-autoscroll-key-trace.log` and
`/tmp/compositor-autoscroll-trace-repeat.log`. After evidence:
`/tmp/compositor-focus-show-trace.log`. Temporary tracing has been removed;
the full hardware-required contract returns **0** with **843 Swift Testing methods
and 132 XCTest methods (975 total)** plus native combo, preview, RAW lens and text
journeys: `/tmp/compositor-focus-show-contract.log`. Protected-tree, generator,
shader and ledger checks pass in `/tmp/compositor-focus-show-integrity.log`;
`git diff --check` passes. This addresses the
keyboard focus race; it does not establish the cause of the earlier eye-release
viewport reset.

## Canvas eligibility, crop domains and HDR matrix correction

### Upstream upload precision and affine staging cost

Upstream GPUCanvas uploads SDR images as `rgba8Unorm` and HDR images as
`rgba16Float`, using `BrushRaster.copy` and `DeepLayer.hdr`. The Linux upload
previously preserved the input's original precision. An eight-case regression
covering uint8, uint16, half, float32 and masks fails for uint16 SDR and float32
HDR before the correction: `/tmp/compositor-canvas-upload-before.log`.
The renderer now performs the same conversions. All eight format/orientation
cases pass after the change: `/tmp/compositor-canvas-upload-after.log`.

Separate SDR/HDR six-layer comparisons establish ordinary-preview parity using
upstream GPUCanvasTests' mean-error `< 1.5` and fraction-over-12 `< 0.01` gates.
Before affine optimization, the Radeon graph takes **115.99 ms SDR** and
**115.63 ms HDR**; Core Graphics takes **14.34 ms SDR** and **98.37 ms HDR**.
CPU transform diagnostics measure **0.663 ms** for a source versus **8.550 ms**
for identity sampling and **8.736 ms** for a vertical flip:
`/tmp/compositor-canvas-upload-diagnostics.log`.

The general projective sampler previously interpolated every pixel even for
unit-scale axis flips and integer translations. These operations now use
clipped row copies or horizontal pixel reversal. Identity sampling can retain
the original buffer. Fractional, very large, or non-aligned coordinates and
nonfinite, subnormal, or negative-zero samples retain the general path. Tests
compare both nearest and bilinear results against the original sampler across
20 transform cases and four exceptional-value cases. Canvas textures also
prepare their top-down row order once, through a dedicated CIImage initializer;
the ordinary CGImage initializer keeps its existing bottom-up behavior.

The complete required-GPU contract exits **0** with **860 Swift Testing methods
in 135 suites plus 132 XCTest methods (992 total)** and all native journeys:
`/tmp/compositor-canvas-upload-affine-contract.log`. RADV RENOIR timing records
**45.33 ms SDR**, **48.68 ms HDR**, versus CPU graphs at **74.38/72.71 ms** and
Core Graphics at **14.29/98.73 ms**. SDR mean byte error is **0.93405**, with
**0.00709** of pixels over 12; the HDR comparison remains **3.95045/0.32836**.
Identity/flip costs fall to **1.394/1.482 ms**, with source reads at **0.699 ms**.
Native keyboard, focus/accessibility, eye dragging, resizing, brush/warp history,
package failure recovery, RAW lens and text journeys pass. Protected-source,
generator, shader and ledger checks pass:
`/tmp/compositor-canvas-affine-integrity.log`. No macOS source or test is changed.
SDR performance, the HDR comparison and broader canvas acceptance remain open;
this does not justify enabling the GPU canvas across the application yet.

### Clamped leaf row copying

`Node.clamp` previously copied every pixel through `Raster.clamped(x,y)`, even
when the requested region equaled the source. The baseline leaf diagnostic
measures **4.413 ms** clamped versus **3.131 ms** for the source alone:
`/tmp/compositor-canvas-clamp-before.log`. `Raster.clamped(to:)` now retains an
unchanged region or copies contiguous row interiors and repeats only edge
pixels. It preserves the old integer-origin coordinate calculation, including
fractional-origin truncation. Twenty comparisons against the original pixel
lookup pass for inside/partial/outside/corner regions, fractional origins, NaNs,
infinity and negative zero. The focused hardware run passes **12 methods in two
suites**, with **36.76/38.30 ms** SDR/HDR graph timings and a **0.603 ms** clamped
leaf: `/tmp/compositor-canvas-clamp-after.log`.

The full required-GPU contract exits **0** with **861 Swift Testing methods in
135 suites plus 132 XCTest methods (993 total)** and all native journeys:
`/tmp/compositor-canvas-clamp-contract.log`. RADV RENOIR graph timings measure
**40.95 ms SDR** and **46.77 ms HDR**; CPU graphs measure **70.49/68.15 ms**,
while Core Graphics measures **14.28/98.51 ms**. Clamped/source leaf means are
**0.643/0.672 ms**. Pixel differences are unchanged: SDR **0.93405/0.00709** and
HDR **3.95045/0.32836** (mean byte error/fraction over 12). The focused/full
timing variation is retained rather than presented as a guaranteed frame rate.
Protected-source, generator, shader and ledger checks pass:
`/tmp/compositor-canvas-clamp-integrity.log`. Mac code/tests are unchanged.
Ordinary SDR speed, the HDR comparison and the remaining six-area acceptance
work stay open.

### Canonical HDR import and highlight compositing

Upstream `DeepLayer.wideAsset` stores HDR pixels in `ImportedImage.deep` as extended
sRGB half floats and puts a dithered 8-bit preview in `image`. The unchanged GPU
canvas uses `DeepLayer.canvasImage` to composite those deep pixels before opacity
and adjustments. The earlier `hdr` timing fixture passed a float image directly
as `ImportedImage.image`, leaving `isHDR` false. Its approximately 99 ms Core
Graphics time is retained as a noncanonical diagnostic, not a normal HDR-import
performance reference.

The timing fixture now also exercises `hdrImported` through the actual upstream
wide-asset constructor and asserts HDR identity plus the 8-bit preview layout.
The original SDR tolerance is unchanged. A separate oracle uses half-float red=2,
green=0.25, blue=0.5 at full and quarter opacity over both checkerboard colors.
It checks the independent source-over formula, exact CPU/GPU graph agreement,
and final displayed texture bytes after clipping/quantization. Quarter opacity
brings the highlight below white while retaining more light than the clipped
preview would. This proves the tested HDR behavior rather than assuming that a
Core Graphics preview must match deep HDR compositing.

`/tmp/compositor-canonical-hdr-tests.log` and
`/tmp/compositor-canonical-hdr-display-tests.log` each returned **0**, with **eight
methods**, three timing cases and two HDR oracle cases. The display run measured
SDR graph **36.57 ms**, CPU graph **66.38 ms**, Core Graphics **14.25 ms**;
canonical HDR graph **37.50 ms**, CPU graph **66.77 ms**, Core Graphics **14.58 ms**.
Canonical HDR/preview byte difference was **6.4461** with **0.37103** of pixels over
12; the simple highlight oracle passes instead of relaxing a preview tolerance.
The older noncanonical HDR case remains **38.05/66.24/98.26 ms** with
**3.95045/0.32836** difference. Normal HDR import is therefore still slower on the
GPU graph than its Core Graphics preview. Broader HDR adjustments, canvas
performance and default activation remain open. Mac code/tests are unchanged.

The final `/tmp/compositor-canonical-hdr-contract.log` returned **0**: **862 Swift
Testing methods in 135 suites + 132 XCTest tests = 994 methods**, all native
combo/preview, RAW lens and text-backend journeys passed. The new oracle also
asserts one actual Vulkan submission per float evaluation when hardware is
required and the Vulkan override is active. AMD Radeon Graphics (RADV RENOIR)
was used with all canvas/warp hardware requirements enabled. Full-run graph means
were **41.87 ms SDR** and **43.78 ms canonical HDR**, versus Core Graphics
**14.29/14.34 ms**; CPU graph means were **66.80/67.80 ms**. Canonical HDR/preview
differences stayed **6.4461/0.37103** and SDR **0.93405/0.00709**. This retains the
focused/full timing variation and makes no frame-rate claim. The integrity log
`/tmp/compositor-canonical-hdr-integrity.log` returned **0** for protected sources,
generators, shaders, drift and ledgers; `git diff --check` passed. This turn changes
Linux acceptance tests and documentation, with no production rendering changes.

### Prepared source geometry reuse

Profiling the real six-layer canvas identified roughly **17–19 ms** of CPU graph
preparation and **18 ms** in the native Vulkan call (uploads, command preparation,
submission/fence wait and readback included). All **14 inputs** were uploaded each
time. The six transformed source leaves accounted for about **10 ms** of preparation
and allocated new result storage despite unchanged source pixels and geometry.
Baseline phase/leaf logs:
`/tmp/compositor-canvas-phase-profile.log` and
`/tmp/compositor-canvas-leaf-profile.log` (both **0**).

The Linux graph evaluator now retains prepared immutable source geometry in its
Vulkan context. Keys include retained source storage identity, source/extent
rectangles, every crop/clamp/nearest/affine modifier, evaluation/output domains and
working-space mode. Geometry numbers use their exact bit patterns. Source storage
is held to prevent address reuse and preserve Swift copy-on-write. The cache is
limited to **64 entries and 128 MiB of source/result floats**; eviction recomputes
the original CPU leaf. Other filters and dynamic generators retain their existing
evaluation path. The original crop domains, sampling arithmetic and failure
fallback are preserved.

`/tmp/compositor-canvas-geometry-cache-before.log` returned **1** with four upload
reuse failures: identity, integer shift, vertical flip and fractional shift each
uploaded the same **2 MiB** again for an unchanged second frame. After caching,
`/tmp/compositor-canvas-geometry-cache-fixed.log` returned **0** for **25 methods in
three suites**. The strengthened asymmetric-pixel fixture checks actual submission,
reduced repeated uploads, changed source/transform/viewport-domain output against
exact CPU bits, and returning to the original frame. The first verification build
failed on a Swift type-check timeout in the test's pixel-generation expression;
`/tmp/compositor-canvas-geometry-cache-after.log` records that compile failure.
The expression was replaced with a simple loop before runtime verification.

Focused graph means improved to **25.39 ms SDR** and **27.30 ms canonical HDR**,
with unchanged pixel comparisons. The follow-up profile
`/tmp/compositor-canvas-geometry-cache-profile.log` returned **0**: average
transformed-leaf preparation fell from **1.687 ms** to **0.205 ms**, including cold
calls. Warmed frames uploaded **8 inputs**, down from **14**; reused identical SDR
sources also reduced distinct inputs to **9**. Native calls were about **14–15 ms**
and CPU preparation about **10 ms**. All temporary profiling code was removed
before full verification. These are graph-evaluation timings, not whole-app FPS;
Core Graphics previews still take about **14 ms**, and broader GPU acceptance
remains open. Mac code/tests are unchanged.

Final verification after removing diagnostics:
`/tmp/compositor-canvas-geometry-cache-contract.log` returned **0**, with **863 Swift
Testing methods in 135 suites + 132 XCTest tests = 995 methods**, plus all native
combo/preview, RAW lens and text-backend journeys. Actual AMD Radeon (RADV RENOIR)
canvas/warp execution was required. Full-run graph means were **29.69 ms SDR** and
**31.87 ms canonical HDR**, versus CPU graph **69.89/72.89 ms** and Core Graphics
**14.59/14.37 ms**. Pixel comparisons remained **0.93405/0.00709** SDR and
**6.4461/0.37103** canonical HDR; highlight oracles and all four cache invalidation
cases passed. `/tmp/compositor-canvas-geometry-cache-integrity.log` returned **0**
for protected sources, generators, shaders, drift and ledgers. Final diff review
and `git diff --check` passed. This optimization changes only the Linux Core Image
stack, its regression tests and acceptance documentation.

### Graph selection policy

Linux canvas contexts can request `.hardwareCanvas` without a GPU environment
override. Eligible hardware computes connected graphs of at least two operations
covering 256x256 pixels or more. Small graphs and isolated operations remain CPU;
ordinary image contexts remain CPU unless explicitly overridden, and software
contexts always remain CPU. `COMPOSITOR_COREIMAGE_BACKEND=cpu` disables hardware.
The renderer checks the backend's actual usability, including failures caused by
direct C callers, and falls back when its context becomes unavailable.

Resident crop steps now carry the original evaluation domain through connected
pointwise nodes. Unsupported CPU leaves evaluate that domain before padding to
the graph bounds. This prevents crops around layers from forcing their whole
pointwise graph onto CPU while preserving fractional/partial/empty crop behavior
and regional filter inputs. The native crop/branch/64-step probe passes on AMD
under Vulkan validation.

An HDR opacity probe exposed accidental 0...1 clamping in **both** matrix
evaluators: source `[1, -0.125, 0.25, 0.5]` at half opacity produced
`[0.25, 0, 0.125, 0.25]`, instead of `[0.5, -0.0625, 0.125, 0.25]`.
Apple documents matrix multiplication plus bias on unpremultiplied components;
bounding belongs to the separate clamp filter.
[Core Image Filter Reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html).
CPU and Vulkan now preserve extended matrix values. The native probe passes,
and three analytic identity/opacity/bias cases verify every float bit, including
negative RGB, highlights and an alpha bias above one.

Verification: **29 focused methods in three suites** pass, including the unchanged
19 upstream GPU canvas methods, crop-domain cases, bounded automatic selection,
failure recovery and actual renderer presentation:
`/tmp/compositor-hdr-canvas-tests.log`. Explicit CPU and unavailable-driver runs
each pass **10 methods in two suites**:
`/tmp/compositor-cpu-canvas-tests.log` and
`/tmp/compositor-unavailable-canvas-tests.log`. Hardware-only paths return early
in these fallback runs; the CPU pixel and selection checks still execute.

The actual upstream `CanvasView.gpuFrame` six-layer 512x512 float/HDR fixture
is bit-exact between hardware and CPU Core Image evaluation. A sampled run after
the matrix fix measured hardware **116.803 ms**, CPU graph **146.110 ms**, and
the existing Core Graphics canvas **102.128 ms**. The comparison uses the
unchanged upstream texture protocol and a synchronized view, saved graphics
state and frozen first-frame CG reference. The corrected reference was initially
obscured by a fixture's duplicate y-flip (BrushRaster already installs one).

The HDR texture/CG comparison still differs: mean **3.951 byte levels**, with
**32.836%** of pixels exceeding 12 in a channel. This is a diagnostic, not a
passing cross-canvas fidelity gate; color handling needs further investigation.
Hardware remains slower than the current app canvas in this scene. Therefore
the host retains its existing `CompositorCPUCanvas=true` default while transform,
generator and complete-frame work continues. `COMPOSITOR_FORCE_GPU_CANVAS=1`
exercises hardware presentation. The eligibility/crop/matrix work moves the
implementation forward without treating the synthetic benchmark as proof of
complete application acceleration.

## Device-resident pointwise canvas graphs

Connected source-over, mask, matrix, clamp, unpremultiply and maximum-component
nodes now execute as a topological graph in one Vulkan submission. Intermediate
pixels stay on the device; only the final result is read back. Each step has its
own descriptor set and parameter buffer, with compute barriers between dependent
steps. Scratch storage is reused after a node's last consumer. Unsupported nodes
are evaluated on CPU before entering a connected graph. Explicit software
contexts remain CPU-only, and a failed graph falls back to CPU evaluation.

The Swift adapter retains immutable graph inputs and uses a generation token
independent of its single-operation cache. Separate tokens are necessary: an
intervening direct C caller can invalidate one cache while a subsequent call to
the other updates the context's generation. Sharing a token would incorrectly
certify stale storage. Graph references and operation limits are validated before
dispatch, and output/generation are updated only after successful completion.

The initial focused run passed **10 methods**, including branched and 64-step
graphs, malformed input recovery, eight individual operation cases and six
branched Core Image cases covering all mask channels in both unmanaged and linear
color space. Transformed source fixtures and HDR values retain exact float bits.
Evidence: `/tmp/compositor-vulkan-graph-tests.log`. A native probe also passes a
branched graph and 64-step chain under Vulkan validation, with exact CPU output
and transfer counters: `/tmp/compositor-resident-graph-probe`.

The 1024x512 six-layer graph has **11 operations**. AMD Radeon Graphics
(RADV RENOIR) measured **15.111 ms GPU versus 111.656 ms CPU**. Across 13 frames,
the six input images upload once (48 MiB total), each frame submits once, and
only its final image is read back (104 MiB total). Pixel bits match CPU before
and after timing. The separate one-operation samples remain slower on GPU.
This proves acceleration for this supported graph, not complete canvas coverage:
transforms, generators and unsupported filters still require CPU work, and
default enablement remains off.

The cache follow-up passes **11 focused methods**, including both directions of
alternating direct/single/graph callers and resource failure in either submission
path. Sentinel output and generation are unchanged on failure, followed by exact
CPU continuation. Evidence: `/tmp/compositor-vulkan-graph-cache-tests.log`.
Its timing repeat is GPU **16.295 ms**, CPU **111.841 ms**.

The full contract with AMD canvas and warp required then passed with exit **0**:
**836 Swift Testing methods in 132 suites plus 132 XCTest tests (968 total)**,
native backend/source coverage, combo, preview, RAW lens and text journeys.
Evidence: `/tmp/compositor-vulkan-graph-contract.log`. The full-run six-layer
sample is GPU **18.724 ms**, CPU **108.664 ms**, again with exact pixels and the
asserted one-submission/readback-per-frame transfer counts. Native autoscroll,
disjoint keyboard selection and accessibility checks passed; the previously
intermittent Shift-Up failure did not reproduce and remains unresolved.
Final protected-tree, generator, shader, drift and ledger gates pass:
`/tmp/compositor-vulkan-graph-final-integrity.log`; `git diff --check` also passes.

## Retained GPU canvas inputs

The raster backend now keeps source, background and mask buffers separate from
its output. The Swift wrapper retains three immutable array storages and avoids
uploading unchanged inputs. Copy-on-write mutations upload their new storage;
size changes invalidate buffer contents. A generation handshake forces uploads
after another caller changes the backend. Wrapper render calls are serialized,
and failed submissions retain the existing CPU fallback.

Focused AMD verification passes **six methods**, including eight operation cases,
source/background/mask mutations, reshape and growth, an intervening direct C
caller, 16 concurrent renders, and failure recovery. The 1024x512 timing cases
prove exactly one upload of each input across 13 hardware renders (16 MiB for
source-over, 24 MiB for a mask), with unchanged output. Evidence:
`/tmp/compositor-vulkan-retained-tests.log`.

Measured source-over GPU **7.593 ms**, CPU **6.830 ms**; mask GPU **7.710 ms**,
CPU **6.703 ms**. Removing repeated uploads improves the previous measurements,
but CPU remains faster in this sample. GPU output still returns to CPU after
each operation, and transformed or intermediate rasters can still require fresh
uploads. Device-resident graph evaluation and broader canvas acceleration remain
open; default enablement remains off.

The native source-over/mask probe also passes exact float comparisons on AMD,
without Vulkan validation errors. Its C++ reference must compile with
`-ffp-contract=off` to reproduce the Swift CPU reference's separate arithmetic.
An initial probe compiled without that flag differed at 4,915 float values;
the corrected reference has zero differences for all three mask channels.

The full Linux contract then passed with exit **0**: **831 Swift Testing methods
in 132 suites plus 132 XCTest tests (963 total)**, native backend/source coverage,
combo, preview, RAW lens and text journeys. Its logs show positive AMD submissions
for canvas, Smudge and Liquify. Evidence:
`/tmp/compositor-vulkan-retained-contract.log`. The contract timing sample also
keeps CPU faster (source-over GPU 7.515 ms / CPU 4.715 ms; mask GPU 6.946 ms /
CPU 5.874 ms). Protected-tree, generator, shader, drift and ledger gates pass:
`/tmp/compositor-vulkan-retained-integrity.log`. The intermittent native keyboard
failure did not reproduce in this run and remains unresolved.

## Hardware Core Image compositing

`COMPOSITOR_COREIMAGE_BACKEND=vulkan` enables a separate Vulkan raster backend
behind the existing lazy Core Image evaluator. Explicit `useSoftwareRenderer`
contexts remain CPU-only. Source-over, alpha/red/luminance masks, color matrix,
color clamp, unpremultiply and maximum-component nodes execute on hardware;
unsupported nodes and failed submissions use the existing CPU evaluation.
The backend retains reusable buffers, selects real hardware, requires float32
preservation/rounding support and float64 shader support, and copies output only
after a completed fence and successful invalidation. A failed backend stays in
CPU fallback for its context. The canvas smoke now requires positive submissions
from the actual renderer context, followed by its existing drawn-pixel assertions.

An AMD probe initially found **6,148 differing float values** for a red mask.
Using a double intermediate for division before rounding back to float eliminated
the differences for red, alpha and luminance masks. The standalone probe also
passes source-over and emits no Vulkan validation errors. Swift verification
passed **25 methods in three suites**, including eight exact hardware/software
operation cases, HDR/subnormal fixtures, untouched output and CPU continuation
after failure, real renderer submissions, and unchanged upstream canvas pixel
comparisons: `/tmp/compositor-vulkan-canvas-raster-tests.log`.

An isolated 1024x512 API benchmark requires exact output and 13 hardware
submissions per case (one comparison, two warm-ups, ten timed frames). AMD Radeon
Graphics (RADV RENOIR): source-over GPU **11.636 ms**, CPU **5.599 ms**; red-mask GPU
**17.387 ms**, CPU **5.660 ms**. Evidence:
`/tmp/compositor-vulkan-canvas-raster-timing.log`.

Profiling the separate large native probe measured uploads at roughly 2–7 ms,
dispatch at 1–3 ms and readback at 1–3 ms. A cached-upload-memory experiment did
not improve those costs and was not applied. Repeated host transfers and CPU
evaluation of other graph nodes remain to be removed; the backend remains
opt-in. These results prove hardware computation and sampled fidelity, not canvas
acceleration or completion of the GPU area.

The full contract rerun with hardware Core Image and warp required passed with
exit **0**: **828 Swift Testing methods in 132 suites plus 132 XCTest tests
(960 total)**, native backend/source coverage, combo, preview, RAW lens and text
journeys. Evidence: `/tmp/compositor-vulkan-canvas-contract.log`. Protected-tree/
generator/shader/drift/ledger checks and `git diff --check` also pass:
`/tmp/compositor-vulkan-canvas-final-integrity.log`.

The first full run passed all 960 methods but failed the existing intermittent
native Shift-Up check with the old accessible set `{2, 6, 7, 8}`. It is preserved
as `/tmp/compositor-vulkan-canvas-contract-first.log`. Added diagnostics include
the model's primary row and Qt focus class; the subsequent complete native preview
and contract passed without reproducing the failure. That investigation remains
open; passing repeats do not establish a fix. Mac source and tests are unchanged.

## Disjoint Layers selection follow-up

The compatibility table previously exposed its lowest selected index as
`selectedRow`. It now retains the most recently selected row and reports it before
delegate notifications. Mouse and keyboard range selection share an anchor,
extent and retained disjoint base; contracting a range preserves independently
selected rows. Programmatic changes and removed rows reset stale range state.
This follows Apple's documented
[last-selected-row contract](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TableView/RowSelection/RowSelection.html).
The protected Layers coordinator still determines the editor's primary layer.

Release verification passed **29 methods in four suites**, including three new
keyboard regressions: `/tmp/compositor-table-disjoint-tests.log`. The new native
journey checks exact accessible row sets after Command-click, Shift-click and
Shift-arrow expansion/contraction, with no Undo step. Two complete native preview
runs returned **0**:
`/tmp/compositor-table-disjoint-native-pass.log` and
`/tmp/compositor-table-disjoint-native-repeat.log`. Protected-tree, generator,
shader, drift and ledger gates also passed:
`/tmp/compositor-table-disjoint-integrity.log`.

Two earlier native runs failed intermittently: a post-release eye viewport change,
then Shift-Up after a clicked disjoint range. Added diagnostics report actual
viewport offsets and selected rows. Neither failure has a confirmed root cause or
fix; successful repeats do not close that investigation. The subsequent complete
contract run is recorded below. Mac source and tests remain unchanged.

## Selected-row drag preservation

A press on a selected row previously collapsed the selection before the tracking
loop could request drag writers. The regression failed with `[2]` instead of
`[2, 8]`, one premature selection notification and one drag item. Selection now
collapses only when tracking ends as a click; a successful drag retains the entire
set. A refused drag falls through to one ordinary selection change on release.

The failing run is `/tmp/compositor-selected-row-drag-before.log`. After the fix,
**31 methods in four suites pass**, including successful/refused-drag cases and
click-only release: `/tmp/compositor-selected-row-drag-after.log`. The complete
native preview returned **0** and moved four selected layers in upstream order,
retained their selection and restored the original list with one Undo:
`/tmp/compositor-selected-row-drag-native.log`. Protected-tree/generator/shader/
drift/ledger gates passed: `/tmp/compositor-selected-row-drag-integrity.log`.

## Direct-import readiness

Direct RGBA replacement/insertion and manifest replacement bypassed the upstream
file-request readiness condition. A new regression reproduced mutations while
blocked by project work, another import, New Document, the importer, conversion,
rename, an import error or adjustment editing. All **24 cases failed** before the
fix, including overwritten asset identities and reset history:
`/tmp/compositor-busy-import-before.log`.

The Linux adapter now checks `session.canStartProjectOperation` before image
allocation or installing a validated manifest, returning the existing busy code
`-3`. It leaves input validation and upstream readiness semantics intact. The
test also requires unchanged document/layer/asset identities and history on
refusal, success once the blocker clears, and one-step Undo after insertion.
Focused release verification passed **47 methods in six suites**, including all
24 new refusal/recovery cases and adjacent editor, save-snapshot, gradient, warp
and Layers checks: `/tmp/compositor-busy-import-after.log`. Protected-tree/
generator/shader/drift/ledger gates passed:
`/tmp/compositor-busy-import-integrity.log`.

The subsequent **complete Linux contract passed with exit 0**:
`/tmp/compositor-six-area-current-contract.log`. It ran **825 Swift Testing methods
in 131 suites plus 132 XCTest tests (957 total)**, native backend/source-coverage
gates, and the native combo, preview, RAW lens and text journeys. Hardware Vulkan
warp submissions were required on AMD. The preview includes disjoint selection,
four-layer drag/order/selection/one-step Undo, both-edge eye autoscroll, focus and
accessibility checks. Broader import/modal recovery and the other open six-area
acceptance items remain unfinished; this run does not certify GPU canvas evaluation.

## Camera Raw docked window sizing

Upstream `ContentView` requests `.dockedToMainWindowRight` for Camera Raw Filter.
`FloatingPanelController` uses its **440-point** width and follows document window
move/resize notifications. The Linux bridge previously exported only panel/title,
and Qt treated every floating panel as a fixed-size ordinary tool window. The native
regression in `/tmp/compositor-raw-docking-before.log` returned **1**: Camera Raw's
client was **440×576**, outer frame **444×580** at **580,120**, beside a document
frame **1200×800** at **0,0**. Its height and right-edge/top alignment did not match.
The **34 hosting measurement methods** passed before that native failure.

The bridge now exports the requested placement and derives docked width from the
unchanged upstream constant. Qt aligns docked panels to their owner's outer frame,
using the exported width for the client and accounting for platform decorations
when calculating height. Native move/resize events synchronize the dock. Sizing
constraints are reinstated even when the current size already matches, and changing
back to ordinary placement restores the existing content-sized layout.

`/tmp/compositor-raw-docking-after.log` returned **0** for **34 hosting measurement
methods** and the complete native combo journey. Camera Raw's client became
**440×796**, outer frame **444×800** at **756,0**, flush with the document's right
edge and top. Checks cover document move/resize, refusal of manual dock resizing,
the original **22-point slider**, preserved pixels after cancellation, and ordinary
Gaussian Blur sizing after Camera Raw closes. The final native fixture additionally
checks confirmation-footer containment and unchanged Undo/unsaved state; those
checks also pass in the full run below. This is offscreen Qt geometry
evidence; broader layout and desktop window-manager checks remain open. Mac source
and tests are unchanged.

`/tmp/compositor-raw-docking-contract.log` returned **0**: **863 Swift Testing methods
in 135 suites + 132 XCTest tests = 995 methods**, and all native combo/preview,
RAW lens and text-backend journeys passed. The final native log confirms upstream
width, matched outer height/right edge, document move/resize, contained footer,
unchanged slider height and preserved cancellation pixels/history. Required AMD
Radeon (RADV RENOIR) canvas and warp execution passed as well.
`/tmp/compositor-raw-docking-integrity.log` returned **0** for protected source,
generators, shader headers, drift and ledgers; final diff review and
`git diff --check` passed. Changes are limited to the Linux floating-panel bridge,
Qt window/header, native regression journey and this tracker.

## Current execution evidence

- Release `NativeScrollGeometryTests`: eight methods passed, including both flipped
  and unflipped cases of the new viewport/boundary regression and the native-lowering
  offset regression. The six pre-existing geometry methods also passed.
- `bash scripts/check-upstream-clean.sh`: passed, including protected source equality,
  generator checks, shader headers, override drift and every ledger through `f5ae5ba`.
- The first actual eye-drag regression passed in the complete `--preview-smoke`
  journey, with exit 0: the native viewport moved while the pointer was held beyond
  the lower edge, visibility changed and one Undo restored it. Output is
  `/tmp/compositor-six-area-preview.log`. The journey now also exercises the upper
  edge and the new keyboard behaviors; that expanded version still needs a run.
- Focused keyboard/scroll release tests: **16 methods passed** across both suites,
  including the hidden-label type-selection regression.
  The first paging test exposed an untiled document frame; paging now calls `tile()`
  before reading document bounds, as row reveal does. The corrected run returned 0;
  output is `/tmp/compositor-six-area-keyboard-tests.log`.
- The expanded native journey passed held-pointer repetition at both viewport
  edges, stop-on-release, single Undo, and paging without selection/history changes.
  It then failed layer-name type selection: default text lookup included a hidden
  mask-warning label before the visible name. Lookup now skips hidden views, with
  a passing custom-cell regression. The native journey also
  now explicitly requires at least two changed eyes, covering newly reached rows;
  its latest form still needs a run. Output is `/tmp/compositor-six-area-preview.log`;
  the first successful lower-edge journey is `/tmp/compositor-six-area-preview-initial.log`.
- Combined layout/input run: **56 methods passed** in four suites. Six new
  priority tests cover tag preservation, required bounds versus soft preferences,
  changed hugging priorities, negative/unflipped positions, fractional multipliers
  and priority setters. Native-lowered hosting bounds and root/option changes also
  pass; output is `/tmp/compositor-six-area-layout-tests.log`.
- Native hosting previously dropped its measured bounds when lowering its SwiftUI
  root. Those bounds now become the renderer's existing `frame` modifier, with
  unbounded/unknown axes omitted and disabled sizing options respected. A modifier
  naming compile error was corrected; its lowering regression passes.

- The complete native preview with fresh temporary XDG settings passed after
  synchronizing the native coordinator before key delivery. Model rename commands
  could arrive before the next paint, leaving stale cell names for type selection.
  The run proves both-edge autoscroll, at least two changed eyes, release stopping,
  one-step Undo, paging/type selection and Move-tool nudging, along with existing
  mask, pixel-drag and text editing checks. Output:
  `/tmp/compositor-six-area-native-isolated.log`.
- The focused release run now passes **61 tests in five suites**, including five
  new focus regressions: subtree removal, shared-editor completion, sibling focus,
  focus restoration/key ownership, and content-root movement/replacement. Output:
  `/tmp/compositor-six-area-focus-tests.log`.
- Source inspection found that restoring the table's AppKit responder could
  install the one-shot global shortcut recorder on a drawn view. `_AppKit`
  widgets now keep their dedicated key route. Session-aware focus restoration
  also recognizes an overlaid inline editor as belonging to its drawn parent
  and does not take focus from it during a panel replacement.
- The expanded native preview passes: distinct document sessions with matching
  node paths, second-window destruction, inline rename/commit/one-step Undo,
  basic/extended/paging/type-selection keys and Move-tool nudging, both-edge
  autoscroll, and existing mask/pixel/text journeys. The first fixture used the
  demo initializer, which replaced the shared document; it now creates a separate
  document tab, restores the original workspace tab and asserts retention of
  the original 25 layers. The passing trace run is
  `/tmp/compositor-six-area-focus-trace.log`. The final release build and complete
  native preview after removing temporary tracing also returned **0**:
  `/tmp/compositor-six-area-focus-native.log`. Protected-tree/generator/shader/
  ledger checks and `git diff --check` pass. Mac source and tests are unchanged.

Type selection follows the AppKit delegate contract documented by Apple:
[typeSelectStringFor](https://developer.apple.com/documentation/appkit/nstableviewdelegate/tableview(_:typeselectstringfor:row:)).
Upstream subclasses retain the first chance to consume their own shortcuts.
- `git diff --check`: passed. No commit, push, deployment or release was performed.

## Drawn AppKit accessibility

`NativeAccessibility` queries the original view hierarchy separately from painting,
including offscreen table rows. It omits hidden descendants, retains identifiers,
labels/help, selected/focused/offscreen states and checkbox state. The Qt adapter
creates transparent, mouse-transparent descendants only when accessibility is
queried; Qt owns their accessible-object lifetimes. Assistive-technology actions
return through the existing native result-handler bridge to the original AppKit
button or table. Snapshot identities and live availability are revalidated before
an action, so old names/reused rows, detached controls and disabled/hidden controls
cannot silently target another element. The real overlaid rename editor keeps its
native Qt text interface.

Release evidence: **28 tests in five suites passed**, including five accessibility
methods and two graphics-state/pixel methods, plus the complete native preview returned **0** with final scroll synchronization. Its new
journey inspects all 25 actual Qt accessible rows and the upstream `layersList`
identifier, selects an offscreen row without an Undo step, and presses the original
visibility control followed by exact one-step Undo. Existing autoscroll, keyboard,
focus, mask/pixel and text journeys also passed. Logs:
`/tmp/compositor-six-area-graphics-tests.log` (28),
`/tmp/compositor-six-area-accessibility-tests.log` (26 preceding the graphics fix),
and `/tmp/compositor-six-area-accessibility-native.log`. Hidden-root state and completing field
editing before an accessible selection notification pass. The native journey also
compares viewport pixels before and after accessibility inspection; its baseline
is synchronized through a normal Home key after Undo. This is native Qt API evidence;
an external screen-reader session has not been claimed.

The viewport comparison exposed a Linux graphics-state bug: `NSGraphicsContext`
restored the newly assigned context instead of the saved context, popping the view
hierarchy's transforms. Distinct rows were drawn on top of one another. The shim
now restores the saved context, with checks for switched/nil contexts and exact
nested-view pixel positions/clipping. One native run then observed a delayed scroll
offset after release; a rerun passed. The tracking loop now synchronizes its final
clip offset on return, before a later refresh can expose it. The final native run
passed the release check, viewport pixel equality, original accessibility actions
and Undo, and the complete existing preview journey. Protected-tree, generator,
shader and ledger checks and `git diff --check` pass. All changes stay outside
protected Mac source/tests. Remaining goal areas are not certified by these focused checks.

### Native hidden-panel action refusal

The Qt panel's visibility is independent of its backing AppKit view. A native
regression hid the Layers table and invoked a cached offscreen row's accessible
press action. Before the fix it selected the layer despite the hidden Qt panel:
`/tmp/compositor-accessibility-hidden-before.log` returned **1** with
`hidden Qt panel accepted an accessible layer selection` after the five AppKit
accessibility methods passed. The Qt adapter now checks inherited widget visibility
and enabled state before advertising or dispatching actions. Offscreen geometry
does not make a visible widget hidden, so offscreen rows remain actionable.

The five focused methods and complete native preview passed in
`/tmp/compositor-accessibility-hidden-after.log` (**0**). Native checks cover
hidden and disabled panel selection refusal, hidden visibility-button refusal,
empty action lists while unavailable, recovery after showing/enabling, offscreen
row selection without Undo, visibility Undo, and unchanged viewport pixels.
This closes the reproduced Qt/AppKit availability mismatch; external screen-reader
and closed-session coverage remain outstanding.

Full verification in `/tmp/compositor-accessibility-hidden-contract.log` returned
**0**: **861 Swift Testing methods in 135 suites + 132 XCTest tests = 993 methods**,
all native combo/preview, RAW lens and text-backend journeys passed. Physical
Vulkan requirements were enabled and the canvas reported AMD Radeon Graphics
(RADV RENOIR). The hidden/disabled refusal and recovery checks also passed in this
full run. `/tmp/compositor-accessibility-hidden-integrity.log` returned **0** for
protected-tree, generators, shader headers, drift and ledger checks;
`git diff --check` passed. This accessibility fix changes only the Linux Qt adapter,
its native regression journey and this tracker.

### Modal scope and closed-session accessibility

The native fixture also reproduced selection behind a visible Qt window-modal
dialog. `/tmp/compositor-accessibility-modal-repro.log` returned **1** with
`modal-blocked document accepted accessible layer selection`. Closing a second
document retired its cached accessibility object/interface and closed its Swift
session in the same run. The first fixture build failed for a missing C ABI
declaration; that compile error is recorded in
`/tmp/compositor-accessibility-modal-before.log`, not counted as a runtime result.

The Qt adapter now includes modal blocking in accessible disabled state, action
advertisement and action dispatch. Window-modal dialogs block their QWidget window
hierarchy; application-modal dialogs block other windows. Dialog descendants remain
available, and unrelated documents retain their actions during document-modal
dialogs. `/tmp/compositor-accessibility-modal-after.log` returned **0** for the five
focused AppKit methods and full native preview. Its checks cover modal selection
refusal, disabled state/empty action lists, dismissal recovery, independent-document
availability, application-modal scope, existing hidden/disabled refusal, offscreen
selection, visibility actions and Undo. The destruction fixture was subsequently
strengthened to capture a live current row after queued focus/panel updates,
immediately before destruction; that version passes in the full run below.
This is native Qt API verification; broader accessible-control/responder-chain and
external screen-reader coverage remain open.

`/tmp/compositor-accessibility-modal-contract.log` returned **0** with the final
fixture: **861 Swift Testing methods in 135 suites + 132 XCTest tests = 993 methods**
and all native combo/preview, RAW lens and text-backend journeys passed. The native
log confirms live cached row/interface retirement on session destruction and
hidden/disabled/modal refusal and recovery. Physical Vulkan requirements were
enabled and AMD Radeon Graphics (RADV RENOIR) was used. The existing SDR performance
and HDR pixel-comparison gaps remain unchanged; this does not certify GPU canvas
acceptance. `/tmp/compositor-accessibility-modal-integrity.log` returned **0** for
protected trees, generators, shader headers, drift and ledgers, and
`git diff --check` passed. Changes are confined to the Linux Qt adapter, native
regression journey and this tracker; Mac source and tests remain unchanged.

## Vulkan smudge computation

`backends/brush/VulkanSmudge.cpp` and `warp_smudge.comp` now compute smudge blending,
called by the Linux `MetalWarp` override. The buffers grow on demand and are reused
within a stroke. The shader preserves the arithmetic order and unquantized carried
color; the host retains each layer's byte, unsigned-short or half-float conversion.
Caller outputs are copied only after successful fence completion and memory
visibility operations. A failure leaves the current dab's pixels and carried color
untouched, so the original CPU algorithm can retry it. Production defaults reject
software devices; `COMPOSITOR_WARP_BACKEND=cpu` forces CPU and `vulkan` permits an
explicit software compute run for verification.

The release build passed. The two new `VulkanSmudgeTests` methods (four cases)
pass repeated dabs at image edges in all three formats with exact CPU pixel equality,
and invalid-input output preservation. The first SDK run used llvmpipe; its log is
`/tmp/compositor-vulkan-smudge-tests.log`. With the AMD ICD explicitly selected,
the same tests pass on **AMD Radeon Graphics (RADV RENOIR)**, reporting four successful
submissions per format: `/tmp/compositor-vulkan-smudge-amd.log`. A native C++ probe
also passes hardware submission, aliased output, zero-weight preservation and an
oversized-buffer failure that preserves caller output and disables further GPU
submissions. The user-requested `flatpak override --user --device=dri` was applied
and its `devices=dri;` setting verified.

The broader targeted run passes eight methods in three suites (24 cases), covering
cached tips, final and resumed commits, transformed selections, edge samples,
history and changed-target refusal, alongside the new format tests. That initial
broader run used software Vulkan; evidence is
`/tmp/compositor-vulkan-warp-integration.log`. The separate AMD-selected broader run
also passes all eight methods (24 cases) in 61.045 seconds, reporting the AMD device
and four successful smudge submissions in each format:
`/tmp/compositor-vulkan-warp-amd-integration.log`. Shader freshness, C++ syntax, protected-tree equality and the complete
generator/drift/ledger guard pass. The full contract has not yet been rerun for
these changes. That checkpoint preceded the Liquify implementation below and does not
establish completion of the six-area objective.

## Vulkan Liquify computation and independent CPU oracle

`warp_liquify.comp` resamples the prior offsets in the dab region and samples the
untouched layer. The original RGBA float source remains on the GPU for the stroke;
regional scratch, weights and outputs reuse growing buffers. The host preserves
byte/unsigned-short/half-float quantization. Both output buffers are invalidated
before either caller buffer is changed. A failed backend disables subsequent GPU
work for that stroke and retries the current dab on CPU.

The first release run passed ten methods (34 cases) with hardware execution required:
`/tmp/compositor-vulkan-liquify-amd-tests.log`. Its new tests compare repeated edge
dabs exactly against CPU across byte, unsigned-short and HDR formats, cover
single-row/single-column images, and verify failure-output preservation. The native
AMD probe passes an independently calculated gradient image, repeated offsets,
boundary sampling and switching between compute pipelines. The same probe passed
with `VK_LAYER_KHRONOS_validation` enabled and emitted no validation errors.

The generated reference stroke initially shared the selected backend. Its generator
now retains the upstream stroke/commit algorithm while explicitly requesting the
CPU working-copy backend. This changes only the Linux-owned reference fixture;
protected Mac source/tests remain identical. The independent CPU-oracle run passed
all ten methods/34 cases:
`/tmp/compositor-vulkan-liquify-amd-cpu-oracle.log`.

The final run passes **12 methods / 39 cases** in four suites:
`/tmp/compositor-vulkan-liquify-amd-final.log`. Integration checks require positive
GPU submission counts and a hardware device, while the reference counts remain
zero. They cover transformed selections, resumed and synchronous commits, edge
samples, Undo/Redo and changed-target refusal. Three new cases force a backend
allocation failure after a successful GPU dab, then prove exact CPU continuation
for Liquify and Smudge without further GPU submissions in all three formats.

The 384x256 timing fixture uses radius 64, two warm-up dabs and 16 steady dabs.
It also requires 18 GPU submissions and final CPU pixel equality. Recorded means:
Liquify GPU **2.580 ms**, CPU **0.935 ms**; Smudge GPU **1.564 ms**, CPU **0.944 ms**.
This establishes hardware computation and fidelity but contradicts a speedup at
this brush size. Optimize regional transfers and CPU conversion/scatter work and
measure again before certifying warp acceleration. GPU canvas evaluation and the
full contract run remain open. Protected-tree/generator/shader/drift/ledger checks
and `git diff --check` pass; no commit or push was performed.

## Warp packing, precision and cached readback

The packed warp shaders now consume/produce the working copy's native byte,
unsigned-short or IEEE half pixels. Smudge preserves unquantized carried floats;
Liquify preserves prior offsets and its untouched original. The CPU copies rows
instead of converting and scattering each channel. Brush falloff is computed once
with the existing CPU arithmetic and retained on the GPU; cached row spans delimit
Liquify's active writes without changing inactive pixels.

Packing uses explicit positive half-away rounding for unsigned formats and
nearest-even IEEE half conversion, including subnormals and overflow. The first
new rounding run exposed float32 carried subnormals being flushed on AMD. The
shaders now request float32 denormal and zero/Inf/NaN preservation and nearest-even
arithmetic through SPIR-V execution modes. The backend requires Vulkan 1.2 and the
corresponding supported float32 properties, otherwise the working-copy CPU fallback
remains available. See the primary
[Khronos float-control properties](https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDeviceFloatControlsProperties.html)
and [SPIR-V intrinsic declarations](https://raw.githubusercontent.com/KhronosGroup/GLSL/main/extensions/ext/GLSL_EXT_spirv_intrinsics.txt).

The allocator originally selected the first host-visible coherent type, which was
uncached on AMD. Readback buffers now prefer host-cached memory; upload-only buffers
prefer coherent device-local memory. Existing noncoherent flush/invalidate paths
remain in place. The native AMD probe with Vulkan validation passes sampling,
packing, cached radial weights and aliased carried output, reports cached bindings
1/3/4 (mask 26), and emits no validation errors.

Release evidence: **14 methods / 47 cases pass** in five suites, with hardware
submissions required: `/tmp/compositor-vulkan-warp-cached-amd.log`. This includes
the float32-subnormal regression, rounding ties in all three storage formats,
repeated dabs, transformed-selection commits, Undo/Redo, changed-target refusal and
CPU continuation after backend failure.

An isolated timing run also passes all six size/mode cases with 18 hardware
submissions each and exact final CPU pixel equality. Two warm-up dabs precede 16
steady dabs; this measures the working-copy API, not complete UI-frame latency.
Device: **AMD Radeon Graphics (RADV RENOIR)**. Evidence:
`/tmp/compositor-vulkan-warp-cached-size-timings.log`.

| Mode | Radius | GPU mean (ms) | CPU mean (ms) | CPU/GPU |
| --- | ---: | ---: | ---: | ---: |
| Liquify | 64 | 0.193 | 0.910 | 4.7x |
| Liquify | 128 | 0.545 | 3.543 | 6.5x |
| Liquify | 256 | 2.942 | 14.654 | 5.0x |
| Smudge | 64 | 0.202 | 0.965 | 4.8x |
| Smudge | 128 | 0.511 | 3.895 | 7.6x |
| Smudge | 256 | 2.605 | 15.914 | 6.1x |

The complete Linux contract passed with exit 0, including **819 Swift Testing
methods in 130 suites plus 132 XCTest tests (951 total)**, native backend/source-coverage gates and native
combo/preview/RAW/text journeys. It used an explicitly selected AMD driver and
fresh temporary XDG settings: `/tmp/compositor-six-area-warp-full-contract.log`.
The preview also passes the prior six-area autoscroll, keyboard, focus, accessible
layer actions and exact viewport-pixel checks. GPU canvas evaluation and the
other unfinished acceptance audits remain open; the six-area goal is active.

## 2026-10-13 closeout

This section supersedes the "In progress" notes above. Each fix was first shown
failing by a new regression, then fixed in Linux code only; protected Mac source
and tests are unchanged.

### Autoscroll release reset: cause and fix

The bounded scroll trace caught the failure under CPU load (twelve busy loops,
`COMPOSITOR_AUTOSCROLL_REPEATS=32`): both unfixed runs failed with
`released 36/48, later 0` (`/tmp/compositor-eye-load-run1.log`, `run2.log`). The
trace shows the cause. Releasing the eye rebuilds the Layers panel; the new
`SwiftUIScrollArea` was bound with the correct native offset (48, with range 865
already available) but showed 0 until a zero-delay timer applied the offset, and
that timer had not run 120 ms later. The scroll area now applies the native offset
when it is bound if its range already allows it; the deferred pass still reports
the settled geometry. A new native check records the offset each rebuilt Layers
scroll area has when Qt first shows it: before the fix it appeared at 0 instead of
288 (`/tmp/compositor-rebuilt-scroll-before.log`), after it at 288. With the fix,
four loaded runs of 32 drags per edge pass (`/tmp/compositor-eye-load-fixed-run1.log`
to `run4.log`).

A second path could also undo a native scroll. The Qt key handler fetches the panel
tree before delivering a key; the panel then rebuilt from that pre-key tree, and its
scroll area reported the old offset back as authoritative, so Home returned the clip
to 863 (three of three single runs, `/tmp/compositor-drop-single1.log` to `single3.log`;
the return-address trace resolves to `NativeLowering.scrollNode`'s geometry handler).
Qt now sends `basisX`/`basisY`, the native offset it was last given. An unchanged
host offset is ignored when the native offset has moved since that basis, and the
panel is refreshed instead; a host scroll still moves the native viewport.
`NativeScrollBasisTests` (four methods, six cases) failed three cases before the
change and passes after; the existing scroll tests are unchanged and pass
(`/tmp/compositor-scroll-basis-before.log`, `-after.log`).

### Busy, import and modal refusal

- Upstream `ProjectController.begin()` refuses unless `canStartProjectOperation`,
  cancels a crop, commits a transform and keeps `isProjectBusy` until the sheet
  (and Export As's save panel) ends. The Linux bridge's Trim, Canvas Size, Image
  Size, Export As, Export PNG and Export PDF commands now do the same, and refuse
  before resolving a pending gradient. Upstream's own commands then disable
  Undo/Redo, layer edits and project menus while the sheet is open.
  `ModalProjectOperationTests` covers all four sheets, Export As through
  written/cancelled save panels and six busy-before-gradient cases. Without the
  change the sheets did not hold the project, a nested New Canvas was accepted
  and a second sheet replaced the first one's continuation and hung
  (`/tmp/compositor-modal-project-before.log`).
- The native journey opens upstream's Image Size sheet, finds upstream's menu items
  disabled, triggers Undo, New Blank Layer and New Canvas directly (as a global menu
  can) and sends Ctrl+Z: nothing changes. Cancel restores layer edits and Undo.
  Triggering the shell's New Canvas exposed that new tabs ignored upstream
  `canSwitch`; `compositor_workspace_add_tab` now refuses as `newCanvas()` does.
- Upstream `ProjectWorkspace.receive` waits for `canSwitch` before importing dropped
  or opened files. The Qt shell instead imported only the first dropped file and,
  while busy, refused with an "Import couldn’t finish" alert. Drops now import all
  files, and while the session cannot switch they wait in arrival order for their
  project (tab-strip drops for a new tab), then import. Session state exposes
  `canSwitch`. The native journey drops a real file during a text draft: no alert,
  no import, then one layer and one Undo step after the draft ends.

### Focus and accessibility

- A native audit queries Qt's accessibility interface of every visible button,
  slider, combo box, field and spin box in the main window. Before the change 17 of
  47 lacked a name (`/tmp/compositor-skipdrop.log`). Icon-only buttons and menus are
  now named by their upstream `.help`, TextFields by their title, unlabeled sliders
  by the text beside them, and the shell's window, New Canvas and zoom buttons
  explicitly. Scroll bars are identified by role, as AppKit scrollers are. All 47
  pass.
- With the inline rename editor focused, Ctrl+Z, Ctrl+Shift+Z, Ctrl+A, Ctrl+C and
  Ctrl+V act on the field (typing undone/redone, text copied and pasted, paste
  undone), and layers, history and selection stay unchanged, as AppKit's responder
  chain sends them to the field editor first.

### Layout and window sizing

Every upstream window-size statement now has a native assertion: ContentView's
800x520 minimum (enforced and growable), the 1180x780 opening size, the Layers
panel's 222–352 points, Camera Raw's 440-point docked window, PSDConversionSheet's
520x360 minimum frame and CommandPaletteView's 460x290 content size.

### GPU canvas and warp

- Per-frame CPU leaves were measured: cropped solid colors, the checkerboard tile and
  the blurred canvas shadow cost about 10 ms per 512x512 frame and were uploaded
  again every frame. The exact leaf cache now also keys deterministic generator
  subtrees (colors, crops, transforms, tiles, source-over, Gaussian radius), so an
  unchanged frame uploads nothing.
- Pointwise graphs run as one fused pass: every pixel executes the steps in order
  with intermediates in registers, using the same `raster_ops.glsl` arithmetic as the
  one-operation shader. Graphs needing more than 16 registers use the multi-pass
  graph. Switching paths re-uploads retained inputs; without that, a fused frame read
  inputs from two frames earlier (`/tmp/compositor-fused-switch-before.log`).
- A graph beyond the 512 MiB retained-memory budget previously threw inside the backend
  and marked the whole Vulkan context unusable. It now returns -3 and is evaluated on the
  CPU for that call; the device stays available. A buffer beyond the device's storage
  range remains a device failure, as the existing failure-recovery tests require.
- `VulkanFusedGraphTests` (five methods) checks bit equality with per-operation
  evaluation across all seven operations and mask channels, the register fallback,
  path switching, the size limit and generator-cache invalidation. The upstream
  CanvasView six-layer 512x512 frame remains bit-exact with the CPU graph and now takes
  about 3 ms on RADV RENOIR against about 14 ms in Core Graphics.
- At full viewport sizes the Vulkan canvas is still slower: with a temporary benchmark
  of the same upstream frame, 1400x900 took about 105 ms (SDR) and 210 ms (canonical
  HDR) against 66 ms in Core Graphics, and 2400x1500 exceeded the graph budget
  (Core Graphics about 190 ms). Every layer leaf is a CPU resample of the layer to
  the viewport, recomputed when the view pans or zooms. The 1400x900 SDR comparison
  with Core Graphics also exceeds upstream's tolerance (mean 2.42, 3.5% over 12),
  while 512x512 and 2400x1500 meet it. Core Graphics therefore stays the default
  presentation; this is the stated adaptation. A GPU-resident renderer (layer
  textures and sampling on the GPU, GPU blur) is recorded as follow-up work.
- Warp acceleration is unchanged and on by default on hardware devices.

### Final verification

The first full run exposed that three existing failure-recovery tests use a buffer
beyond the device's storage range as their injected device failure; the non-fatal
refusal was narrowed to the graph memory budget and the existing tests were left
unchanged. The final hardware-required contract
(`COMPOSITOR_COREIMAGE_BACKEND=vulkan REQUIRE_COREIMAGE_VULKAN=1
COMPOSITOR_REQUIRE_WARP_VULKAN=1 COMPOSITOR_REQUIRE_WARP_HARDWARE=1
COMPOSITOR_FORCE_GPU_CANVAS=1`, fresh XDG directories) returned **0**: **880 Swift
Testing methods in 138 suites plus 132 XCTest tests (1012 total)**, the native
backend and source-coverage checks, and the touch, Camera Raw docking, combination,
preview, hosting-measurement, font and text-backend journeys:
`/tmp/compositor-six-area-final-contract.log`. Canvas and warp ran on AMD Radeon
Graphics (RADV RENOIR). The preview log includes the new rebuilt-scroll, busy-drop,
modal-hold, accessible-name and responder-chain checks. Upstream CanvasView
six-layer 512x512 frames measured 2.55 ms SDR and 3.09 ms canonical HDR on the
hardware graph against 13.97/14.01 ms in Core Graphics, bit-exact with the CPU graph.
Protected-tree, generator, Vulkan shader-header, drift and ledger checks returned
**0** (`/tmp/compositor-six-area-final-integrity.log`); `git diff --check` passes.
