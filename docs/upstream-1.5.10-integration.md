# Compositor 1.5.10 integration

Target: `2d75d9172835e1dd6111cb2b659958ec33fa5abf`, public upstream main checked
on 2026-10-26. This release follows the previously qualified `8cdc2b6` checkpoint.
Integration and local feature/regression qualification are complete. Results
below qualify this revision within their stated scope; previous performance
results do not qualify this revision.

The incoming changes add Align/Distribute commands, custom crop ratios and a
2.39:1 preset, reorganized tool-header controls, and Sharpen as a filter and an
adjustment layer. Sharpen raises the project format to 19. The original upstream
app and test trees are applied exactly; Linux implementation belongs in API
compatibility, generated adapters and native presentation.

All 26 incoming paths were backed up before applying the patch, with source
hashes and the preexisting staged-patch hash in
`.build/evidence/upstream-2d75d91-backup/manifest.json`. Generated adapters and
affected Linux files have separate backups beneath that directory. README and
project-format prose retain the existing Linux-specific material while taking
the upstream feature and version changes.

| Requirement | Current state |
| --- | --- |
| Exact protected upstream content | Content check passes, including the new LayerAlign source and tests |
| Generated adapters | Rebuilt; the adjustment-editor patch now includes Sharpen's independent settings |
| Complete Swift source/test inclusion | Fresh SwiftPM evaluation accounts for 176 application files, 99 unchanged upstream test files and four generated mirrors; all 13 coverage fault/control tests pass |
| Align/Distribute core behavior and undo | Original upstream tests pass |
| Custom crop ratios and validation | Original upstream tests pass |
| Optional CGFloat field widths | Compile and optional/nil dimension checks pass |
| Explicit popover arrow edge | API capture/dismissal checks and native bottom-edge placement journey pass |
| Sharpen filter and adjustment | CIUnsharpMask added; original upstream edge, canvas/export and save checks pass; native pixel equivalence remains unverified |
| Format 19 persistence and older-version refusal | Original upstream Sharpen save/load and version-18 refusal check passes |
| New control icons | All thirteen mappings and SVG XML checks pass |
| Latest source ledger | 133 non-merge commits, 101 code commits; every new row has test/source references |
| Full Linux regression and rendering qualification | Release XCTest passes 237 tests (one skip); 1,072 parallel and 48 serialized Swift tests pass; 178 CPU/Vulkan exports match |

The first Linux build exposed optional CGFloat and explicit popover API gaps.
The compatibility additions preserve the original callers. Compilation also
caught an exhaustive switch in the Linux render corpus that needed the new
Sharpen recipe. Before CIUnsharpMask was implemented, the focused upstream run
failed exactly its two new edge-contrast assertions: unchanged values 77 and 179.
All alignment, crop and adjustment-editor checks already passed.

After the image-filter implementation, 25 Swift tests and six selected XCTest
checks pass in `.build/evidence/upstream-2d75d91-green-feature-tests.log`. Added
checks cover floating-point HDR/negative channels, source alpha, zero intensity,
cropped halo requests and optional frame dimensions. This is functional and
regression evidence, not a native macOS Sharpen capture. The filter uses the
existing Gaussian implementation and an unsharp detail pass. Default radius
2.5 and intensity 0.5 follow Apple's
[filter reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/).

The native transform journey initially fails at its old text-only `Flip H`
selector because upstream now uses an accessible icon button. Its updated
selector uses `Flip Horizontal`, and the journey now also exercises the Align
popover during a pending move, disabled one-layer distribution, canvas alignment
and Undo. The current Release executable passes this complete journey, including
separate Undo steps for the pending move and alignment. The final feature run
also passes all 25 Swift tests and six selected XCTest checks.
Popover placement follows the attachment-edge meaning and optional automatic
edge described in Apple's
[popover API](https://developer.apple.com/documentation/swiftui/view/popover%28ispresented%3Aattachmentanchor%3Aarrowedge%3Acontent%3A%29).

The complete source/generator/shader/icon/ledger guard passes in
`.build/evidence/upstream-1510-final-source-guard.log`, with shader checking required.
The current Release XCTest run passes 237 tests with one skip and
zero failures in `upstream-2d75d91-xctest.log`. Native adjustment acceptance passes all ten cases, including
Sharpen's visible creation, editor preview, Cancel/OK, exact Undo/Redo, saved
parameters/source PNG and reopened composite. The native logs are
`.build/evidence/upstream-2d75d91-transform-native-final.log` and
`.build/evidence/upstream-2d75d91-modern-adjustment-native.log`; both commands
exit zero in `upstream-2d75d91-native-acceptance.exit`. These are offscreen Qt
checks and do not establish native macOS pixel equivalence.

## Regression fixture closeout

The first complete run executes 1,072 parallel Swift tests and retains three
issues: the two new Sharpen golden images are absent, and the previously
recorded text-and-shapes golden differs. All 48 serialized tests pass. The
exporter produces 178 images, but the catalog still lists 173; the five new
Sharpen adjustment/default/extreme recipes are now included in `cases.json`.
No old catalog case was removed.

Both new 64-by-48 Sharpen goldens were visually reviewed and have identical
decoded CPU/Vulkan pixels. The text-and-shapes discrepancy was localized to
the ellipse (43 channels above one, maximum twelve) and diagonal line (93
channels above one, maximum seven). Text and the upper background remain
within one byte, and the rectangle is unchanged. The before/after images were
visually reviewed; the original golden is backed up before accepting the
earlier intentional shape-coverage corrections. All thirty independent native
ellipse controls and all 52 straight-stroke controls pass within one byte.
The unrelated native rounded-rectangle control still fails at three pixels
by two levels; this baseline review does not remove or relax that check.

The affected golden tests now pass on CPU and Vulkan. Both complete export
commands pass with all 178 catalog cases, and their decoded pixels, ICC
profiles and numeric samples match exactly. All nine parity-tool tests pass.
The CPU Core Image setting retains the separate hardware dispersion driver;
this is not wholly software application equivalence. The final complete Swift
rerun after fixture review passes all 1,072 parallel tests in 190 suites and
all 48 serialized tests in nine suites. Both commands exit zero in
`upstream-1510-framework-final.exit`; logs use the
`upstream-1510-swift-final-` prefix. The production source hashes still match
the recorded candidate; fixture review changes no renderer or test tolerance.

Evidence: `.build/evidence/upstream-1510-closeout.exit`,
`upstream-1510-sharpen-golden-review.json`, `upstream-1510-text-golden-review.json`,
`upstream-1510-cpu-vulkan-review.json`, `upstream-1510-stroke-controls.log` and
`upstream-1510-curve-controls.json`. The native application capture still
predates this release and does not qualify Sharpen's native pixel equivalence.

The completed 1.5.9 benchmark remains in
`.build/evidence/upstream-8cdc2b6-rgb-parameter-benchmark-result.json`. It exposes
very high uncached lens costs and a multi-second baseline. The separate opt-in
Starburst diagnostic and bounded CPU stack samples are described in the
[earlier integration report](upstream-7651033-integration.md#starburst-profiling-diagnostic).
Those costs remain open and are not resolved by applying a newer release.
