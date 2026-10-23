# Compatibility gap implementation

Scope: the twelve gaps in the supplied September 27, 2026 attachment. Work stays
on `GNU_Linux`; protected `Compositor/` and `CompositorTests/` files remain unchanged.

## G01: manifest validation

Implemented the raw-manifest bridge validation before session installation.
`scripts/gen-project-validation.py` extracts the shared metadata validation rules
from `Compositor/IO/ProjectStore.swift` into Linux-owned source. Its `--check` mode
is included in the existing upstream cleanliness check. The bridge additionally
retains its canvas surface limit and enforces the 4 MiB metadata limit.

Verified on September 27, 2026:

- Release build succeeded in the KDE 6.10 SDK with Swift 6.3.3.
- `ProjectManifestValidationTests`: 17 invalid metadata cases, 10 supported-format
  save/load cases, and one oversized-metadata case passed. Rejection preserves
  existing document metadata, rendered pixels, and the render key.
- Existing `ProjectTests` and `UpstreamEditorTests`: 30 tests passed.
- `UPSTREAM_REF=2309a85 sh scripts/check-upstream-clean.sh` passed, including both
  generated-source freshness checks. `git diff --check` passed.

The new tests exercise the bridge and shared package store. The native Qt package
journey also verifies rejection of versions 11 and 999 without replacing the
active session or changing its displayed pixels. Other malformed metadata cases
are covered by the bridge suite, rather than individual desktop journeys. At that checkpoint format
11 was deliberately rejected. The mixed-font integration below now accepts 11
and tests rejection of 12 and 999.

## Remaining work

- G10–G11: real macOS fixture interchange verification. The Linux mixed-font/format-11 pipeline and native mixed-style undo are implemented and tested below.
- G12 is implemented and verified below.

The full goal remains active. Passing the focused persistence tests does not
establish completion of these remaining gaps or full macOS interoperability.

## G02: project resource accounting

Qt save and load now call the same Swift C ABI for per-surface and cumulative
asset accounting. The values come from `DocumentLimits`: 30,000 maximum side,
200 MP maximum surface, and the memory-dependent document budget. Images and
masks use separate cumulative totals, matching `ProjectStore`.

The loader preflights every asset header before decoding pixels and sets Qt's
allocation ceiling to the supported RGBA surface size. The writer preflights
all asset sizes before PNG encoding. The 512 MiB limit now applies to the flushed
encoded PNG on both paths, rather than to the writer's raw RGBA buffer. Both paths
enforce the 4 MiB metadata limit, including the writer's formatted JSON output.

Release test run: `ProjectResourceLimitsTests|ProjectManifestValidationTests|ProjectTests|UpstreamEditorTests`
passed, 36 tests in four suites. New resource checks cover invalid dimensions,
overflow inputs, surface boundaries, cumulative boundaries, and four 30 MP assets.

The opt-in `CompositorHostBootstrap --package-smoke` journey uses the native
package methods with four 6000×5000 images and four same-sized masks. It checks
save/reopen, retained asset dimensions and displayed pixels, unsupported versions,
and cumulative-limit rejection without replacing the active document. It also
duplicates immutable assets beyond the document budget and verifies that save
fails, preserves the previous package, and leaves that package reopenable with
matching pixels.

Native acceptance passed on September 27, 2026 using the release executable and
Qt's offscreen platform. This exercises the real Qt package IO and Swift session,
not a mock writer. It does not certify interactive responsiveness (G09) or a
macOS format-11 round trip (G10–G11). The protected-tree and generation-freshness
checks still pass against upstream baseline `2309a85`.

Reproduce after building the release bootstrap inside the KDE SDK:

```sh
COMPOSITOR_SKIA_BRIDGE=$PWD/build/lib/libCompositorSkiaBridge.so \
COMPOSITOR_IMAGEIO_BACKEND=$PWD/build/lib/libCompositorQtImageIO.so \
QT_QPA_PLATFORM=offscreen XCTestConfigurationFilePath=package-smoke \
.build/release/CompositorHostBootstrap --package-smoke
```

Use temporary `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `XDG_CACHE_HOME` directories
to isolate the journey from normal application settings, as in the verified run.

## G03, G04, G06: live mask and selected-pixel previews

The Linux composite cache key now includes mask enablement for layers and folders.
Displayed snapshots use the session's draft mask placement during transforms and
include the selected-pixel move's working raster. Cropped raster previews retain
the mask's document placement instead of fitting its coverage to the crop. Pixel
moves also participate in the dirty-region ABI using the raster's published area.

Verified on September 27, 2026:

- `LivePreviewTests|RegionRenderTests|MaskTransformTests|UpstreamEditorTests`:
  30 Swift tests in four suites passed. New parameterized cases cover layer and
  folder mask toggles, linked/unlinked layer and mask targets, moves, resizing,
  cancel, commit, undo/redo, selected-pixel moves and duplication with masks,
  transparent source holes, moving selection outlines, and partial renders.
- Move, cancel, commit, and undo pixel comparisons are exact. Resized partial
  renders permit a maximum one-byte channel difference from a full render, after
  measuring the fractional-resampling rounding differences. Unscaled partial
  pixel moves retain exact comparisons.
- `CompositorHostBootstrap --preview-smoke` passed on Qt's offscreen platform.
  It sends Shift-click events to actual SwiftUI layer/folder mask thumbnails and
  pointer events to the canvas. Cached frames are checked before mouse-up for
  detached-mask movement and resizing and for Ctrl/Ctrl+Alt selection-tool drags.
  Mask cancellation and commit, plus undo/redo for masks and pixels, are checked.

Use the same backend environment and isolated settings as `--package-smoke`.
These tests verify the native Qt event and cached-render paths; they do not claim
physical Wayland/tablet validation or completion of the remaining feature gaps.

## G05: scaled spatial adjustments

Linux preview rendering now passes the preview scale to `LiveMaskRenderer`, so
Gaussian radii and motion distances scale after parameter normalization. Saved
adjustment settings stay unchanged. The preview entry point is generated from
the protected exporter with only its name and adjustment-scale injection changed;
the upstream cleanliness check also verifies generator freshness.

Partial renders include the summed sampling support of visible spatial
adjustments, align to the full preview's pixel grid, and crop the result back to
the requested output. Stroke dirty rectangles include blur influence beyond the
published paint tiles. Synchronous and asynchronous preview paths use the scale.

Verified on September 27, 2026:

- `ScaledAdjustmentPreviewTests|LivePreviewTests|RegionRenderTests|UpstreamEditorTests`:
  30 tests in four suites passed in the release SDK build.
- Gaussian and motion previews at 50% and 25%, unmasked and with adjustment/folder
  masks, exactly match the protected exporter given explicitly reduced distances.
  Whole-image mean channel error versus area averaging of the full-resolution
  composite stays below two byte values. Hard mask and canvas edges differ because
  reducing before filtering does not equal reducing the final composite.
- Fractional-radius behavior, unchanged saved settings, background rendering,
  stacked-filter partial redraws, and expanded dirty areas pass. The regression
  test demonstrates that the old unscaled distances produce larger errors.
- Full-resolution rendering exactly matches the protected upstream exporter.
- The native `--preview-smoke` journey passed with the updated core. Protected
  trees still match `2309a85`, and `git diff --check` passes.

## G07–G08: text color ranges and native selection

The Linux bridge now exposes exact UTF-16 replacement and selection commands.
Replacements call the shared text model's color-run bookkeeping before changing
content, validate the resulting style, and publish the resulting caret. Invalid
ranges, split surrogate pairs, and text beyond 100,000 UTF-16 units are rejected
without changing the draft. Whole-string callers retain a Unicode-safe minimal
replacement fallback; native Qt edits report the exact affected range.

Qt document edits and selection changes now update the shared draft. Draft state
includes its identity, selection, and color runs, allowing the native editor to
restore session selections and show per-letter colors without modifying its undo
history. Opening a draft synchronizes the caret at the end. External text commands
refresh the inline editor; normal typing retains the native document and undo stack.

Verified on September 27, 2026:

- `NativeTextEditingTests|TypeToolTests`: all 21 tests in two suites passed in
  the release SDK build. New cases cover emoji/Unicode edits, color-run shifts,
  selection-based recoloring, invalid-input preservation, commit/undo/redo, and
  text metadata in saved manifests.
- The expanded native `--preview-smoke` passed. It opens colored text from a
  real `.comp` package, checks displayed color spans and the opening caret,
  replaces selected text with Unicode input, checks exact resulting color-run
  lengths and caret positions, exercises native undo/redo, restores a session
  selection in Qt, and cancels editing. Existing mask and pixel-drag journeys
  still pass in the same run.
- Protected trees still match `2309a85`; generated files are current and
  `git diff --check` passes. Physical IME and clipboard interaction have not
  been exercised by this automated journey.

## G09: asynchronous saving and autosaving

`ProjectSaveSnapshot` captures immutable image references, document metadata,
the history revision, and a reload generation on the main actor. Token-based C
exports serialize metadata and materialize pixels without reading a live session
or dispatching to the UI thread. Dimension preflight does not materialize pixels.
Tokens survive session closure and release safely. Successful completion can mark
the captured revision saved; edits made afterward remain modified. Reloading the
same document ID invalidates an old completion. Autosave releases without marking
a user save.

The Qt package writer reads only a frozen token on a serialized worker queue.
Manifest serialization, raster materialization, PNG encoding, package replacement,
and recovery cleanup run off the UI thread. Per-document and destination
reservations reject overlapping submissions. Temporary packages are cleaned on
failure, and save tokens release through RAII even if the window disappears.

Save/Save As and the autosave timer return after scheduling. Completion marks the
captured revision and updates the originating tab, even if the user changes tabs
while choosing a destination or while writing. Closing during a save waits for
completion, then rechecks unsaved changes; failure keeps the document open.
The synchronous package-test hooks wait using a Qt event loop while the same worker
does the writing. They do not run the encoder on the UI thread.

Autosave never marks a user save or adds a recovery path to recent projects.
Recovery opens as unsaved text/image content with no user save destination, so
Save asks for a real path. A normal save removes only a recovery package with the
same document ID, in queue order; saving a different document preserves it.

Verified on September 27, 2026:

- `ProjectSaveSnapshotTests|ProjectResourceLimitsTests|ProjectManifestValidationTests`:
  nine tests in three suites passed, including parameterized metadata cases.
- Snapshot tests export metadata and pixels on a detached worker after replacing
  and closing the source session; verify captured-revision completion through
  undo/redo; and reject completion after same-ID reload. The C bridge is entered
  from detached test tasks to avoid recursively dispatching the Swift Testing
  runner's main queue.
- The native `--package-smoke` journey passed with the frozen writer: 120 MP of
  images plus 120 MP of masks, save/reopen, unsupported-version rejection,
  cumulative limits, and preservation of the previous package on save failure.
- `--save-smoke` passed with 2,262 UI timer events during its run. It checks
  exact saved pixel bytes and captured metadata, editing and switching tabs while
  writing, duplicate destination rejection, captured-revision undo/redo, failed
  saves preserving dirty state, asynchronous autosave/recovery, another document's
  recovery surviving a save, pending-close completion, and the real Save menu with
  a tab change dispatched from the injected file dialog.
- `--dialog-smoke` passed, including its existing autosave, recovery, save/reopen,
  dialog preview/cancel, and undo checks. All native journeys use isolated settings
  and the Qt offscreen platform.
- Protected-tree and generator-freshness checks pass against `2309a85`.

## G10–G11: mixed-font rendering foundation (in progress)

The comparison source is pinned upstream commit
`c28f827385303c4b90480b9e18d0b645c79acd5e` (1.3.4), available in the local Git
objects. Its text model and format documentation define `fontRuns` as sorted,
nonoverlapping UTF-16 ranges with a `fontName`, gated on format 11. The protected
working trees remain at the original baseline.

The Qt backend now has attributed measurement and rendering entry points. Swift
forwards effective `NSAttributedString` ranges containing both font and color,
so overlapping source attributes become disjoint ranges before reaching Qt.
Both measurement and rendering use the same `QTextLayout` formats, including
paragraph intersections and per-line font metrics. AppKit-compatible bounding
rectangles and glyph drawing now use this path. Existing single-font entry points
and the no-native-engine fallback remain available.

Verified on September 27, 2026:

- Rebuilt `libCompositorQtImageIO.so` in the KDE 6.10 SDK.
- `TypeToolTests|NativeTextEditingTests`: 21 tests in two suites passed.
- New `CompositorHostBootstrap --text-backend-smoke` runs with a real Qt
  application and DejaVu Sans / DejaVu Sans Mono. It requires the native engine,
  checks mixed-font widths against independently measured font spans, checks
  wrapping and render dimensions, verifies overlapping font/color ranges, and
  compares AppKit glyph output byte-for-byte with the attributed backend. It
  also checks that lookup of a nonexistent face returns nil for explicit fallback.
- The existing `--preview-smoke` passed, including colored native text replacement,
  selection synchronization, local undo/redo, and the mask/pixel preview checks.
- Protected-tree and freshness checks pass; `git diff --check` is clean.

That backend checkpoint preceded the integration below. Its tests alone did not
establish format-11 compatibility.


### G10–G11: Linux model, editor and format integration

The Linux build now selects generated overrides for `TypeTool.swift` and
`ProjectStore.swift`. `scripts/gen-text-format-11.py` applies a vendored exact
patch from baseline `2309a85` to pinned upstream `c28f827`. Regeneration requires
neither a network connection nor Git objects. Protected files are only read.
The freshness check includes these overrides and the bridge validator extracted
from the selected Linux ProjectStore.

The text model preserves sorted UTF-16 font runs, shifts them during edits,
validates them, and applies effective font/color attributes to measurement and
rasterization. The font picker follows the selection and shows `(Multiple)` for
mixed faces; choosing a face changes the selected letters. Native selection
changes refresh the toolbar immediately. Native shaping uses a QSyntaxHighlighter
with the same font resolver as the raster backend, and point-text editor width
is measured using the mixed fonts. These display changes do not add typing undo
steps. Font runs and tracking are exposed in native draft state.

New Linux saves declare version 11. Versions 1–10 remain readable, font runs in
those older versions are rejected, and unknown versions remain rejected before
changing the document. The format documentation identifies the Linux writer and
the unchanged version-10 macOS source baseline explicitly.

Four existing test suites are generated into the Linux test target: TypeToolTests
includes the pinned upstream font tests; GroupTests, LayerMaskTests and
LayerAppearanceTests change only expected writer version 10 to 11. Their original
assertions remain, and the shared image fixture helper is copied unchanged into
the new test module. The existing documented stale opacity-test skip remains.

Verified on September 27, 2026:

- 48 tests in eight suites passed: TypeToolTests, NativeTextEditingTests,
  FontRunValidationTests, ProjectManifestValidationTests, ProjectSaveSnapshotTests,
  GroupTests, LayerMaskTests and LayerAppearanceTests. Parameterized cases include
  all 11 supported versions; 11 malformed/old-version font-run cases; Unicode
  replacements crossing either end of a font/color range; and whole-run removal.
- Native `--text-backend-smoke` passed with the shared font resolver.
- Extended `--preview-smoke` passed: actual Qt font-picker mixed-state display,
  whole-text and selected-emoji font changes, retained selection and typing undo,
  mixed-font display, overlapping colors, document undo/redo, format-11 save/reopen,
  exact saved-pixel preservation, editable font metadata, and cancellation.
- `--package-smoke` passed again (120 MP images plus 120 MP masks), including
  rejection of versions 12 and 999 and failed-save preservation.
- `--save-smoke` passed again with 2,387 UI timer events during asynchronous saves.
- Protected trees match `2309a85`; generated files and whitespace checks pass.

These are Linux tests. A real macOS→Linux→macOS fixture round trip remains pending;
no macOS execution is implied. Native local typing undo is exercised within a run;
exact restoration after deleting across different style runs still needs an audit.
The full goal remains active. Color Range was implemented in the next stage below.


## G12: Select → Color Range

The Linux build now includes the pinned upstream 1.3.4 Color Range model, panel,
selection kernel, and session gates as Linux-owned generated sources. The original
EditorSession and C kernels remain protected. `scripts/gen-color-range.py` uses
the vendored `linux/patches/color-range.patch`; its freshness check and the menu
generator's new `--check` mode run from the upstream-cleanliness check.

Select → Color Range opens a nonmodal panel beside the canvas. It samples the
visible composite, supports replace/add/remove modes (Shift adds, Alt removes),
fuzziness, inversion, and a black-and-white preview. Canvas sampling takes priority
over the current tool, including Brush and Idle. Escape cancels; Return and keypad
Enter accept. Cancel and window close restore the original selection. Confirmation
records the result as one undoable selection change, including an empty result.

Linux preview jobs run through a serial worker actor. Superseded queued jobs skip
large mask allocation; a running job may finish but cannot publish a stale result.
The panel shows Updating and disables OK during computation; the model and command
bridge also refuse premature confirmation. Nonfinite/out-of-bounds sample points
are rejected before integer conversion. The UI uses Linux Alt-click wording.

Verified on September 27, 2026:

- `ColorRangeTests|NativeTextEditingTests|UpstreamEditorTests`: 31 tests in three
  suites passed in the release SDK build. The six Color Range tests cover
  noncontiguous matches; add/remove/invert; premultiplied-alpha recovery and exact
  fuzziness boundaries; transparent/invalid samples; latest-result wins; pending
  cancellation; original-selection restoration; busy edit/history/file-operation
  gates; and single-step undo/redo for nonempty and empty results.
- `CompositorHostBootstrap --color-range-smoke` passed with Qt's offscreen platform
  and isolated settings. It uses the real Select menu, floating SwiftUI panel,
  native canvas pointer events, fuzziness slider and Invert checkbox. Sampling
  while Brush is active leaves document pixels unchanged; sampling with Idle
  also works. Cancel, window close, Escape, keypad Enter, and single-step undo are
  checked. Clearing the resulting selection verifies which document pixels were
  selected, including both disconnected red areas and the inverted blue area.
- The test compares decoded exports before/after sampling. A diagnostic confirmed
  Qt reports RGBA8888 and ARGB32 QImages unequal despite identical normalized
  pixels; comparing the same export format avoids that fixture artifact.
- Existing `--preview-smoke` and `--dialog-smoke` journeys passed again, covering
  text/font editing, mask and pixel drags, dialog previews/cancel/undo, autosave
  and save/reopen after the shared canvas and session changes.
- The static `libCompositorCore.a` contains the new `color_range_mask` definition.
- Protected trees match `2309a85`; generator and whitespace checks pass.

No macOS runtime or physical desktop/tablet validation is implied. The remaining
mixed-style local undo audit is independent of Color Range. A small Qt probe
confirmed `contentsChange` reports the resulting `availableUndoSteps()` value
(including grouped typing, undo, redo and redo-branch replacement), which can be
used to associate native text history with its font/color metadata.


## G07–G11 follow-up: native rich-text undo

The audit reproduced a real loss: replacing text across font/color boundaries
and undoing restored the characters but inferred the deleted characters' styles.
`NativeTextHistory` now retains style metadata and a content digest at each Qt
undo position. Qt continues to own text, typing groups and cursor behavior. The
validated `textRestore` command atomically restores the matching draft's full
style and UTF-16 selection. New edits discard future metadata; reopening a draft
resets native history even when the text is identical.

Toolbar formatting creates an undoable Qt block property without changing glyphs.
Color-picker previews do not add history; cancel restores the original attributes,
and accepting adds one formatting step. The state pump synchronizes external
formatting without taking focus from the picker. Edit → Undo/Redo now use native
text history while a draft is open, including native availability and menu labels.

Rich-text restoration may use the project's 4 MiB metadata budget. Other commands
retain the original 1 MiB cap. The restore command rejects stale draft IDs,
invalid styles, oversized content and selections splitting UTF-16 surrogate pairs.

Verified September 27, 2026:

- `NativeTextEditingTests|TypeToolTests`: 27 tests in two suites passed. This
  includes exact style restoration, invalid/stale history rejection, and a valid
  style with 10,000 font runs exceeding 1 MiB, plus command-budget rejection.
- `--preview-smoke` passed in the real offscreen Qt application. It verifies
  cross-boundary deletion, grouped typing, Edit-menu undo/redo, redo-branch
  replacement, toolbar-font undo/redo, color preview/cancel/commit history,
  separate histories for reopened drafts, and a >1 MiB rich-text restoration
  through the actual synchronous C bridge. Existing mask/pixel drag and
  format-11 save/reopen checks in that journey also pass.
- The synchronous command ABI depends on the application's event loop. Calling
  it from Swift Testing stalled the initial large-payload test; the unit test
  now uses the asynchronous editor API, and the native journey verifies the ABI.
- Protected trees match `2309a85`; generator and whitespace checks pass.

Real macOS→Linux→macOS interchange remains unverified. This follow-up resolves
the local mixed-style undo issue; it does not establish cross-platform rendering
or font equivalence.


## Interchange fixture and retention verifier

`CompositorHostBootstrap --interchange` now provides three operations:
`fixture NEW_DIRECTORY`, `roundtrip INPUT.comp NEW_OUTPUT.comp`, and
`verify ORIGINAL.comp RETURNED.comp [ORIGINAL.png RETURNED.png]`. These use the
real Qt/Swift package paths. The generated format-11 fixture contains four layers:
a background, a translated translucent raster with opacity and an unlinked mask,
a folder with nonuniform mask coverage and opacity, and paragraph text with
mixed fonts, overlapping colors, an emoji, a combining accent and Greek omega.

Verified September 27, 2026:

- Fixture generation and native Linux save/reopen/save preserve every manifest
  field and all five decoded assets exactly (maximum channel error zero).
- The standalone `roundtrip` operation also passes and exports its reopened canvas.
- `scripts/test-interchange.py` passes 13 positive/negative cases. It accepts
  alternate JSON/PNG encoding with unchanged data and rejects changed fonts,
  color ranges, layer order, pixels, mask coverage, missing/broken assets,
  unsafe filenames and a symlinked images directory. Optional flattened-image
  comparison accepts identical output and rejects a changed image.
- Nine focused tests across NativeTextEditingTests and FontRunValidationTests
  pass (including their parameterized cases).
- The generated reference PNG was visually inspected: the fixture content is
  visible and legible. This is an interchange test image, not a UI design.
- The artifact is `build/compositor-format11-interchange.zip`; it contains the
  packages, references, procedure and SHA256 checksums. Generated artifacts stay
  outside versioned source. Reproduction and manual Mac checks are documented
  in `linux/interchange-verification.md`.
- Protected trees remain identical to `2309a85`; generator/whitespace checks pass.

The comparator is strict about manifest fields, including IDs and layer order.
Mask coverage must match exactly; premultiplied color assets/flattened references
allow one byte of channel rounding. It is evidence of retained saved data, not
proof of editability or matching font rasterization on a Mac. Actual Mac runs and
returned packages remain required; no Mac execution has been claimed.


### Integrated Linux test audit

The complete release suite passed: **425 tests in 75 suites**, using only the six
existing per-test skips documented in `linux/UPSTREAM_TEST_EXCLUSIONS.md` (and the
existing compile-time exclusions in that file). Command:

```sh
swift test -c release --skip 'everyLayerEditRoundTripsWithSelection|historyBlockedDuringImportsAndDialogs|gaussianBlurSoftensAHardEdgeWithoutFadingTheBordersAsOneUndoStep|moveToolNumberKeysSetSelectedLayersOpacityAsOneUndo|perspectiveMappingHitsTheCornersAndTwistedShapesAreRefused|distortingWarpsTheLayerIntoTheShapeAsOneUndoStep'
```

The first integrated run exposed two ColorRangeTests timing out while other
parallel tests occupied the main actor for about 20 seconds. Their five-second
wall-clock wait was a completion check, not a worker-performance assertion. It
now uses a 60-second monotonic deadline and `#require` to avoid checking stale
results after a timeout. With that test-harness correction, all 425 tests passed
in 24.582 seconds. No application behavior was changed for this correction.
