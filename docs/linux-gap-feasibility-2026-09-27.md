# GNU/Linux gaps and implementation feasibility

Assessment date: September 27, 2026. Branch: `GNU_Linux`, commit `f3649f6`, package `1.2.0-linux-alpha.1`.

**All twelve functional gaps below have a viable GNU/Linux implementation path.** Nine are defects in existing behavior; three are missing upstream features or interoperability. This is an implementation assessment, not a claim that those fixes have been made or that Linux has full parity.

The protected `Compositor/` and `CompositorTests/` trees match upstream commit `2309a85`: the 1.3.3 baseline plus readable ASCII dithering. The comparison target is upstream 1.3.4 (`c28f827` including its update-feed commit). Linux's package version is independent of its upstream feature baseline.

Constraint: leave upstream/macOS source and tests untouched. Prefer fixes in `Sources/LinuxBridge`, `Sources/Compat`, and `host`. Where an older shared type cannot express a newer feature, use a narrowly scoped Linux override selected by `Package.swift`, with recorded upstream provenance and a freshness check. Do not edit through `Sources/UpstreamCore` symlinks that point into protected trees. The existing Linux history and generated Smudge/Liquify overrides demonstrate the build mechanism.

## Prioritized functional gaps

Size is relative implementation scope: **S** is a localized change; **M** crosses components or needs several interaction tests; **L** changes persistence, concurrency, or the text pipeline. These are not time estimates. Priorities preserve the review's P1/P2 severity; P1 work should precede feature expansion.

| ID | Priority / size | Gap and current evidence | Can we implement it in GNU/Linux? |
| --- | --- | --- | --- |
| G01 | P1 / M | **Unsafe manifest acceptance.** `UpstreamEditor.importManifest` installs decoded data without checking the format identifier, supported version, and the full shared validation rules. A fresh probe accepted version 999. | **Yes.** Validate before installing or mutating a tab. Prefer routing package loading through the existing `ProjectStore.load` actor, which already validates headers, manifests and assets. Its `validate` method is private, so the bridge cannot simply call it directly. If raw-manifest import remains a separate ABI, add an equivalent Linux validator and differential tests. Reject unsupported versions until G11 is complete. |
| G02 | P1 / M | **Inconsistent save/load size budgets.** The Qt reader caps individual images and cumulative images/masks at 100 MP. Four 6000×5000 layers total 120 MP, while the shared document budget starts at 200 MP. The Qt writer also has its own 512 MiB raw-buffer limit. | **Yes.** Use one authoritative limits policy for import, save and reopen, exposed from Swift to the host or obtained by reusing `ProjectStore`. Define image/mask accounting consistently and retain overflow, file-size and allocation checks. Successfully saved projects must reopen under the same supported resource budget; a lower-memory machine can still need a clear capacity error. |
| G03 | P2 / S | **Mask enablement does not invalidate the composite.** `RenderKey.Layer` carries mask-image identity but not `isEnabled`; the probe's key stayed equal after toggling a mask. | **Yes.** Include the effective enabled state in every layer/folder mask cache entry. Test actual displayed pixels after a SwiftUI Layers-panel toggle, without a subsequent unrelated edit. |
| G04 | P2 / S | **Unlinked mask transforms lack live coverage preview.** `displayedSnapshot` starts with committed `layer.mask?.placement`. A probe moved the draft to x=5 while the snapshot still contained nil. | **Yes.** Build preview records from `displayedMaskPlacement(for:)`, preserving the special placement handling for cropped warp/brush previews. Test move, resize, linked/unlinked masks, Cancel and Commit. |
| G05 | P2 / M | **Zoomed-out spatial adjustments use the wrong scale.** `regionSnapshot` scales geometry but copies adjustment settings unchanged. At 25% scale, a probe shrank a 64-pixel canvas to 16 pixels while radius 8 stayed 8. | **Yes.** Carry the display scale through a Linux render context into spatial adjustment evaluation, or derive render-only scaled settings consistently. The existing `LayerAdjustment.apply(..., scale:)` is a reuse point. Preserve document-space settings, fractional radii and dirty-region halos; do not mutate saved parameters or scale dimensionless color adjustments. |
| G06 | P2 / S–M | **Selected-pixel drags do not show their working raster.** The preview chooses brush/gradient rasters and omits `pixelMove.raster`. The probe's displayed image remained the committed original during a move. | **Yes.** Include the pixel-move raster in preview construction and make its progress observable by the render cache/frame invalidation path. Cover both move and duplicate-drag, partial redraws, Cancel and one-step Undo. |
| G07 | P2 / M | **Text replacement corrupts color-run offsets.** `textSetContent` replaces the string without updating UTF-16 ranges. Deleting colored trailing letters made the probe's style invalid and prevented Done. | **Yes.** Send the actual replacement range and inserted UTF-16 length from the native text document, and call `replaceCharacters(in:withLength:)` before assigning new content. Full-string fallback must calculate an equivalent edit. Cover paste, deletion, undo/redo, IME, emoji, combining marks and multiline text. |
| G08 | P2 / M | **Native text selection is not synchronized.** The `QPlainTextEdit` connection sends text changes, but no selection range to `TextDraft.selection`; layout also sets a whole-editor font/color. | **Yes.** Forward cursor/selection changes as UTF-16 ranges, preserve the selection while changing toolbar controls, and synchronize native attributed display with the draft. Prevent model/view feedback loops. Verify that changing selected letters' color changes only those letters and that empty selection retains the specified whole-text behavior. |
| G09 | P2 / L | **Save and autosave block the GUI.** The host copies, converts, PNG-encodes and writes assets synchronously in `writeProjectPackage`, called by Save and the autosave timer. | **Yes.** Capture an immutable snapshot and revision on the main actor; encode/write on a worker or the existing `ProjectStore` actor. Return completion to the correct tab and mark only the captured revision saved. Serialize writes per destination, retain atomic replacement/recovery, and handle tab close, new edits and failures while saving. Merely moving the current function to a worker would race live session/UI access. |
| G10 | Feature / L | **Per-letter fonts are missing.** Current `LayerTextStyle` has color runs but no font runs; the Qt text ABI accepts one font plus color ranges. Upstream 1.3.4 adds font runs, inheritance and a “(Multiple)” state. | **Yes, through the complete text pipeline.** Use a Linux-specific version of the newer text model, extend attributed layout and rendering across `Sources/Compat/AppKit/TextBackend.swift` and `host/QtImageIO.cpp`, and update the native editor and `TypeControls` override. Measure and render with the same per-run faces. G07/G08 are prerequisites. Missing fonts need explicit fallback behavior; identical rendering requires equivalent installed fonts. |
| G11 | Feature / L, coupled to G10 | **Format-11 interoperability is missing.** The supported shared model writes format 10 and cannot retain font runs. Accepting version 11 is not compatibility. | **Yes, together with G10.** Select a Linux-specific format-11 manifest/validator implementation and complete the text model, encoding, validation and rendering. Update the format documentation for the Linux implementation. Preserve versions 1–10 and reject later unknown versions. Require mixed-font/color macOS→Linux→macOS round trips before claiming interoperability. G01's safe rejection remains necessary for unsupported future versions. |
| G12 | Feature / L | **Select → Color Range is absent.** Upstream adds a selection controller, sampling/mask kernel, menu/panel, preview and session/canvas lifecycle integration. | **Yes.** Port the upstream algorithm into Linux-owned source, add its C kernel to the Linux backend, and wire the menu, ContentView override and native canvas events. Session state must participate in busy/history/file-operation guards. Use a Linux session override where additional stored state/private helpers require it, or an explicitly owned Linux controller with equivalent guards. No Apple-only service is intrinsic to the algorithm. |

## Acceptance checks before each item can be called complete

| IDs | Required evidence |
| --- | --- |
| G01 | Versions 11 and 999 are rejected until supported; wrong format, malformed runs/transforms, duplicate IDs, invalid hierarchy and unsafe asset paths are rejected; failed opens preserve the existing tab/document. Once G11 lands, 11 is accepted correctly and 999 remains rejected. |
| G02 | Save/reopen a four-layer 6000×5000 project under an adequate memory budget; test masks and boundaries just below/above supported limits; excessive input fails before expensive decoding and does not replace an existing saved project. |
| G03–G04 | Pixel assertions and a native-desktop journey for layer/folder enablement, moving and resizing unlinked masks, Cancel, Commit, Undo and Redo. Handles and rendered coverage must agree while dragging. |
| G05 | Compare a 25% and 50% preview against appropriately downsampled full-resolution Gaussian/Motion Blur output; check dirty-region edges and masked/folder adjustments. Rendering differences need bounded tolerances, not screenshots judged only by eye. |
| G06 | Observe changed pixels before mouse-up for Ctrl-drag and Ctrl+Alt-drag; check exposed background, transparency, masks, selection outline, Cancel and exact Undo. |
| G07–G08 | Native keyboard/mouse tests for selection preservation, per-letter color changes, replacement, paste, deletion, IME and Unicode boundaries; Done must commit a valid style and reopening must preserve ranges. |
| G09 | Edit another tab during a large save/autosave; measure input responsiveness. Edits after snapshot capture remain dirty. Test concurrent autosave/manual save, tab close, disk/write failures, cancellation where supported, and recovery of the previous complete package. |
| G10–G11 | Render and measure mixed fonts and colors, edit across run boundaries, test font fallback, and round-trip real format-11 fixtures through both platforms. Old projects and the Linux initial-canvas undo boundary must keep working. |
| G12 | Sample/replace/add/subtract colors, Shift/Alt modifiers, fuzziness, invert, transparency, preview and zoom-coordinate mapping. Cancel restores the exact prior selection; Apply produces one undo entry. Stale background results must not overwrite a newer preview or another document. |

## Other gaps, differences and work needing verification

These are separate from the twelve functional items; existing functionality must not be counted as missing merely because its tests are incomplete.

| ID | Item | Feasibility and next evidence |
| --- | --- | --- |
| V01 | Gaussian/Motion Blur adjustment Undo assertions | **Investigate first.** Release notes disclose two desktop assertions; their root cause is not established. Reproduce the exact native journeys and compare document state, pixels and test timing. Do not assume G05 fixes them. A software fix or test correction is likely, but the implementation cannot be specified responsibly before diagnosis. |
| V02 | Inner Glow in the opt-in Skia effects tier | **Implementable, backend-specific.** README documents support in Vulkan/OpenCV/C++ and absence in `COMPOSITOR_EFFECTS=skia`. Add that pass if this optional tier is supported, or route it to an existing supported backend and test parity. Inner Glow is not missing from the default app generally. |
| V03 | Very large PSB acceptance | **Conditional / large architecture work.** The documented 1.27 GiB stress fixture exceeds the document budget. Resolve G02 independently, then profile peak decoded memory and consider tiling/lazy decode/bounded intermediate surfaces. Raising limits alone is not a safe implementation. No same-hardware macOS comparison currently establishes a Linux-specific regression. |
| V04 | Subject/object segmentation quality and fallback | **Improvements and validation are feasible; identical Apple Vision output is unproven.** The Linux implementation uses U²-Net-small/OpenCV and falls back when the model cannot load. Test installed model availability, fallback behavior and a labeled image corpus. Comparable quality is a measurable target; literal Apple implementation parity is not an available Linux backend. |
| V05 | Physical tablet/pressure, Wayland, display latency, RAW and portal coverage | **Platform validation work.** These are not established missing features. Add targeted integration/desktop tests, real tablets and a native Wayland session; exercise LibRaw-enabled packages, representative camera files and update/file portals. Hardware and representative fixtures are necessary to close these evidence gaps. |
| V06 | Excluded upstream tests and older parity inventories | **Implementable test/documentation work.** Map every excluded behavior to a Linux-native test, intentional difference, confirmed stale assertion or open gap. Refresh the “100%” matrix and stale shortcut/layer-drag inventory only from that evidence. Passing a subset of tests is not full parity. |
| V07 | Sustained input backlog | **Optimization is feasible; a universal latency claim is not verified.** The tool report distinguishes sub-100 ms first visible feedback from 135–353 ms completion after its rapid-input stress workload. Profile queues and frame scheduling, then retest trajectory/pixel fidelity and both latency measures. This is a performance limitation, not an absent tool. |

Already included: readable ASCII dithering, per-letter color data/rendering (with G07/G08 editing defects), layer drag/drop and shortcut capture. Preserve the intentional Linux rule that undo stops at the initial canvas. Flatpak updates and Qt dialogs/window chrome are platform replacements; literal macOS Dock/Services/Quick Look behavior is not part of this GNU/Linux implementation plan.

## Recommended implementation order

1. **Protect project data:** G01, then G02. Safe rejection is an immediate fix, not a substitute for eventually implementing G11.
2. **Repair current editing:** G03, G04 and G06; then G05. Reproduce V01 separately.
3. **Fix native text synchronization:** G07 and G08, including selection-preserving toolbar actions and live attributed display.
4. **Add mixed fonts and format 11 as one deliverable:** G10 and G11. Do not enable version 11 with only the header constant changed.
5. **Make saving asynchronous:** G09, reusing the validated persistence path from G01/G02 where practical.
6. **Add Color Range end to end:** G12. It can be developed independently of the mixed-font work once the session integration approach is chosen.
7. **Close the conditional/validation backlog:** V01–V07 and refresh the parity inventory. Keep platform requirements and quality/performance claims bounded by actual evidence.

## Evidence checked for this assessment

The two supplied reviews were treated as findings to verify, not as proof of full parity. Graph discovery was followed by coverage checks; stale/partial graph entries for the bridge and host were read directly. The worktree was clean at the start. Only this assessment document is added.

Primary source locations, relative to this repository:

| Evidence | Location |
| --- | --- |
| Manifest import without supported-version validation | [UpstreamEditor.swift](../Sources/LinuxBridge/UpstreamEditor.swift), `importManifest`, lines 834–844 |
| Text string replacement without run bookkeeping | [UpstreamEditor.swift](../Sources/LinuxBridge/UpstreamEditor.swift), `textSetContent`, lines 501–505 |
| Mask/pixel-move preview and scaled adjustment records | [UpstreamEditor.swift](../Sources/LinuxBridge/UpstreamEditor.swift), `displayedSnapshot`, `regionSnapshot` and `renderKey` |
| Native text synchronization and synchronous package IO | [SessionWindow.cpp](../host/SessionWindow.cpp), `syncTextEditor`, `writeProjectPackage`, `readProjectPackage`, `performAutosave` |
| Existing validated actor-based persistence and format-10 model | [ProjectStore.swift](../Compositor/IO/ProjectStore.swift), `load`, `save`, private `validate` and `checkSize` (read-only reference) |
| Existing immutable snapshot/revision support and resource policy | [DocumentLimits.swift](../Compositor/Document/DocumentLimits.swift), [DocumentHistory.swift](../Compositor/Document/DocumentHistory.swift) and `ProjectSnapshot` in `ProjectStore.swift` (read-only references) |
| UTF-16 replacement helper and selection model | [TypeTool.swift](../Compositor/Document/TypeTool.swift), `replaceCharacters` and `TextDraft` (read-only reference) |
| Current single-font native render ABI | [QtImageIO.cpp](../host/QtImageIO.cpp), `compositor_qt_text_render_runs`; [TextBackend.swift](../Sources/Compat/AppKit/TextBackend.swift) |
| Linux font control and menu integration | [TypeControls.swift](../Sources/Overrides/TypeControls.swift), [AppMenus.swift](../Sources/LinuxBridge/AppMenus.swift), [ContentView.swift](../Sources/Overrides/ContentView.swift) |
| Scale-aware adjustment API and current exporter | [LayerAdjustment.swift](../Compositor/Document/LayerAdjustment.swift), `apply`; [ImageExporter.swift](../Compositor/IO/ImageExporter.swift) (read-only references) |
| Linux override build selection | [Package.swift](../Package.swift), target `Compositor` exclusions and `Sources/UpstreamCore/Overrides` |
| Conditional platform/performance items | [README.md](../README.md), [tool-e2e-status.md](tool-e2e-status.md), [linux-ui-e2e.md](linux-ui-e2e.md), [SubjectSegmentation.swift](../Sources/LinuxBridge/SubjectSegmentation.swift), [UPSTREAM_TEST_EXCLUSIONS.md](../linux/UPSTREAM_TEST_EXCLUSIONS.md) |

The local upstream comparison (`git diff 2309a85 upstream/main -- Compositor CompositorTests`) shows the Color Range additions and font-run/format-11 changes. The protected-tree comparison (`git diff --quiet 2309a85 HEAD -- Compositor CompositorTests`) succeeds. These checks compare known revisions, not a claim that upstream can never advance.

### Fresh focused probe

Recompiled and ran the existing review probe against the available release core using `/tmp/compositor-review-compile.py`. Output was saved in `/tmp/compositor-gap-feasibility-probe.log`:

```text
COMPILE_EXIT 0
MASK_ENABLED_KEY_UNCHANGED true
FUTURE_FORMAT_IMPORT_RESULT 0
MASK_PLACEMENT_DRAFT ... origin: (5, 0) ...
MASK_PLACEMENT_SNAPSHOT nil
PIXEL_MOVE_BEGAN true
PIXEL_MOVE_STILL_ORIGINAL true
TEXT_VALID_BEFORE true
TEXT_VALID_AFTER false TEXT_COMMIT_RESULT false
SCALED_BLUR_CANVAS 16 SCALED_RADIUS 8.0
PROBE_EXIT 0
```

The probe confirms six structural/behavioral defects; exit 0 means the probe ran successfully, not that the application passed its assertions. G02, G08 and G09 were verified by tracing current source in this assessment, not by a new large-memory or full packaged-GUI run. Feasibility of G10–G12 is based on the upstream implementation and current Linux integration points; no feature prototype or complete port was produced.

**Correction to the earlier release audit:** its statement that Linux explicitly refuses format-11 projects applies to the shared `ProjectStore` path, not the native Qt loader. The actual Linux bridge currently bypasses that version check. G01 addresses the resulting data-loss risk; G11 supplies real interoperability.

Existing test logs and prior desktop results are scoped evidence only. This assessment neither reruns the full packaged GUI suite nor certifies all earlier release features. The acceptance checks above remain required before implementation can be called complete.
