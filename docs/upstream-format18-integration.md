# Upstream format 18 integration

Target: `7b5ba975694b1462d6c13007c6aea1d01bbc69ff`, following the 1.5.8 checkpoint at `c9c7531`. A fresh upstream fetch still resolved to this target after verification.

Upstream adds Vignette, Lens Effects and Tonal Contrast adjustment layers, their persistent settings, editing, format-18 validation and a grouped Filter menu. The protected application and test sources match upstream unchanged. `docs/project-format.md` and `ProjectManifest.current` both specify 18; older supported formats remain readable.

Linux compiles the original `MetalFinishing` and `FinishingKernel` through its Metal and Core Image compatibility interfaces. `FinishingCompute` executes the two finishing kernels on float textures with the original arithmetic, premultiplied coverage and document coordinates. It checks texture sizes, formats and parameter-buffer length before execution. This is CPU execution through the compatibility API; it does not establish Vulkan hardware support. The Linux `GPUAdjustment` implementation contains the unchanged upstream adjustment block, including document-size propagation and HDR handling.

The app menu and project-validation adapters are regenerated from upstream. The C kernel target excludes the new Swift file. Linux icons cover the three new symbols, and native save journeys expect format 18. The shared parity corpus adds nine adjustment images, for 173 cataloged images overall.

## Settings ownership correction

The unchanged upstream editor tests initially reported three failures when reopening the new kinds: `beginAdjustmentEditing` overwrites every shared editor's Gaussian radius with `original.gaussianRadius` (default 10), while the new assertions compare against an independent `FilterSettings` object (radius 5). Complete diagnostic settings dumps matched after substituting only this unrelated radius. The initial 29-test run and bounded failure details remain in `upstream-format18-followup-tests.log` and `upstream-format18-test-summary.json`.

The generated Linux `AdjustmentEditing` adapter applies `linux/patches/adjustment-editing-linux.patch`: the three new kinds retain their independent settings objects; legacy adjustment fields are copied only for the earlier kinds. Saving updates the relevant object and retains the other stored fields; Cancel restores the original adjustment. The original upstream assertions remain unchanged and pass with this adapter. Regeneration applies the patch without fuzz and fails on upstream drift. Native macOS code remains upstream's; the Linux adapter does not correct that upstream unused-field mismatch on macOS.

## Published integration verification

Logs and JSON evidence below are relative to `.build/evidence/` in the verification checkout.

- Protected-content, generator, override-drift, icon and ledger checks pass. Nine Python parity-tool regressions pass with the existing Python environment.
- The affected serial run passes 29 tests in six suites, including the three previously failing cases and an off-center vignette tile/alpha regression (`upstream-format18-independent-settings-tests.log`).
- The production executable builds successfully in 237.94 seconds. The extended native adjustment journey passes nine kinds, including all three new kinds: visible creation, thumbnail/Edit menu reopening, numeric preview, Cancel/OK, exact creation/edit Undo/Redo, format-18 nested settings, preserved source PNGs and exact package reopening (`upstream-format18-native-adjustments.log`).
- A separate native bridge is built from this integration's source, excluding the pending byte-compositing candidate. Its CTest passes (`upstream-format18-native-clean-build.log`). With this bridge, the full parallel run covers 180 XCTest cases and 1,038 Swift Testing tests; the latter reports only the 15 previously known GPU-availability issues. The entire Linux golden suite passes (`upstream-format18-clean-full-parallel.log`).
- All 48 shared-state serial tests and all 18 adjustment golden cases pass (`upstream-format18-clean-full-serial.log`, `upstream-format18-clean-adjustment-goldens-initial.log`). Three reviewed, previously nonexistent adjustment fixtures were added. No existing golden baseline was replaced.
- Both complete 173-image Linux renders pass their catalog/manifest checks. All 173 decoded images are unchanged by the settings adapter. With the separate native bridge, all 164 older cases are decoded-RGBA identical to the published checkpoint before the pending compositing changes (`upstream-format18-independent-settings-regression.json`, `upstream-format18-clean-corpus-regression.json`).

`upstream-format18-clean-verification-summary.json` records source, test-executable and native-library hashes and both full-suite issue breakdowns. The first full run used the existing native library containing the pending byte-compositing corrections and reported 23 issues: the same 15 GPU-availability issues plus eight known golden differences. The independent bridge removes those eight differences, separating the integration from the pending work.

## Remaining work

The Gaussian, byte-compositing, Lanczos, affine and tone corrections remain local. Twelve replacements of existing goldens are proposed: the original ten comparisons retain their hashes and maximum 2/255 differences; two Lens Effects comparisons change by up to 18/255 (filter) and 21/255 (adjustment) after the native tone correction. The review is `.build/evidence/upstream-format18-tone-rendering-review/index.html`, with exact before/after hashes in `review.json`. It supersedes the ten-image proposal. These replacements remain unapproved; no tracked baseline has been replaced.

The native macOS 173-image reference is available from CI run `40122628134`. Its 164 older decoded images are identical to the earlier native reference. CI runs `40122628173` and `40122627994` report three failed `AdjustmentEditorTests.sharedEditorsKeepPixelsDynamicAndSupportCancel` cases in the unchanged macOS code; Linux passes these cases through the generated settings-ownership adapter. Both macOS screenshot jobs pass. The candidate has 36 earlier rendering discrepancies: nine adjustment, four blend, six filter, five raw, three shape and nine text cases. Hardware verification below resolves the earlier GPU-availability uncertainty.

## Combined rendering candidate after format 18

The CPU candidate now passes 137/173 native comparisons, with matching upstream, corpus, input and case-catalog identifiers (`upstream-format18-tone-parity-diff/report.json`). All nine new adjustment cases pass. Prism improves from a 14-byte maximum channel error to one byte; Anamorphic Flare improves from 20 to two; Mist improves from five to one. No previous passing case is lost. These are unpublished candidate measurements.

The first comparison was rejected for mismatched input hashes: only `p3.png` differed. Linux was rendered again with the exact CI inputs; provenance checks and application thresholds remain unchanged.

The compatibility changes are separated by responsibility:

- `Lanczos.swift` implements separable antialiased reconstruction, preserving negative/HDR values and alpha overshoot. Fourteen direct native cases validate byte output and integral bounds.
- Affine planning samples before connected transfer, unpremultiplication and alpha replacement operations, retaining genuine crop boundaries. Fifty-six native pointwise/rectangle cases validate fractional geometry and sampled float rows.
- Gaussian affine intermediates use the requested inverse-mapped region as their sampling domain. Twenty-four native blur/affine cases pass. Separate regional captures confirm that native interior requests differ from cropping a larger render by up to 0.7471 byte units, independently of caching. The new regional regression passes on CPU and AMD Vulkan, checking byte output within one level and tile-versus-full float differences within `1/1024`. This resolves the sampling-boundary review concern (`native-regional-sampling-comparison.json`, `upstream-format18-regional-targeted.log`, `upstream-format18-regional-hardware.log`).
- `ToneCurve.swift` implements the native perceptual working-space response separately from `CIColorCurves`. Sixteen native byte/float cases cover two highlight thresholds, contrast, identity and doubled RGB inputs. Native identity recipes preserve HDR; the upstream faint-flare assertion now passes. A natural spline with sRGB-shaped encode/decode matches the captured float response within approximately 0.001 byte units; the earlier raw-curve model differs by up to 46.

The native tone capture in run `40130017115` validates 334 cases and 672 buffers; all 318 preceding recipes and both identity inputs retain their hashes. Regional run `40131936749` extends this to 358 cases and 720 buffers, with all preceding 334 recipes unchanged. Earlier native cardinal-motion controls support pixel-area weights, but arbitrary-angle sampling remains unresolved, so production motion blur is unchanged.

## Hardware candidate verification

The SDK sees the host's AMD Radeon Graphics (RADV RENOIR) when `flatpak build` includes `--device=dri`. Removing the CPU-only `COMPOSITOR_COREIMAGE_BACKEND` and `COMPOSITOR_FORCE_GPU_CANVAS` overrides lets the existing tests exercise the real Vulkan backend. Thirty-four dedicated GPU tests pass, including verified Camera Raw submissions, padded rows, buffer recreation and all texture upload formats (`upstream-format18-tone-hardware.log`).

The full hardware run passes all 186 XCTest cases, all 48 serial shared-state Swift tests and the nine-kind native adjustment journey. The 1,038-test parallel Swift run reports only the twelve proposed golden replacements (`upstream-format18-tone-hardware-full-parallel.log`, `upstream-format18-tone-hardware-full-serial.log`, `upstream-format18-tone-hardware-native-adjustments.log`). The earlier fifteen GPU-availability assertions pass with device access. The finishing kernels remain the CPU compatibility implementation described above; these checks also exercise their integration with the Vulkan canvas.

## Vulkan spectral sampling correction

The first complete automatic-backend render passed 136/173 native comparisons. Five RGB Split images differed from CPU; the extreme filter's alpha error reached eight byte levels and added one failure. A fresh render with corrected Linux backend metadata reproduced the same PNGs (`upstream-format18-tone-hardware-labeled-parity-diff/report.json`). The parity tool now labels an unset Linux backend as `automatic` instead of `Apple Core Image`.

An isolated AMD probe found two numerical causes in the dispersion shader: phase arithmetic was optimized differently from its explicit CPU `fma`, and approximate device sine introduced rounding errors amplified by `fract(sine * 43758.5453)`. Precise phase and cycle arithmetic removed the phase drift, but approximate sine still produced nearly full-interval jitter changes. A degree-21 double polynomial on the reduced angle avoids that amplification. The Vulkan backend already requires float64; this adds no device requirement. CPU dispersion and the protected upstream Metal source are unchanged.

Five sharp-alpha component comparisons improved from maximum errors of 87.58, 52.54, 94.18, 47.46 and 3.98 byte units to 0.501, 0.429, 0.715, 0.477 and 0.019. The new pixel-level regression fails against the original shader and passes after regeneration, alongside the unchanged native Metal edge references. Generated shader checks, protected-content checks, override-drift checks and nine Python parity-tool tests pass.

The corrected hardware corpus passes 137/173 comparisons, restoring the extreme RGB Split case without losing any passing case (`upstream-format18-dispersion-hardware-parity-diff/report.json`). All nine new adjustment cases pass on both backends. The remaining 36 native comparison failures still require work; matching pass counts do not establish pixel identity between CPU and Vulkan. All 93 decoded golden candidates are unchanged by this shader correction, so the existing twelve-image review remains applicable. No baseline was replaced.

The rebuilt candidate passes 35 focused XCTest cases and 29 focused Swift tests. Its full hardware run passes 187 XCTest cases (now including the regional regression), 48 serial Swift tests and nine native adjustment journeys. The 1,038-test parallel Swift run reports only the same twelve golden differences (`upstream-format18-dispersion-hardware-full-parallel.log`, `upstream-format18-dispersion-hardware-full-serial.log`, `upstream-format18-dispersion-hardware-native-adjustments.log`). All twelve original-baseline and reviewed-candidate SHA-256 checks still match. This correction and the other rendering candidates remain uncommitted.

## Byte Hue and Saturation candidate

The local Skia canvas candidate now handles byte Hue and Saturation separately from deep/HDR blending. It rounds alpha products and saturation-normalized channels to bytes, and rounds the combined uncovered contribution once. This resolves the large errors caused by normalizing nearly gray components before native byte rounding. The cached runtime blenders use immutable mode uniforms; other blend modes and float surfaces retain their previous paths.

The independent native capture from run `40114760151` provides 18 recipes over every source alpha and background value, with opaque, translucent and clear backdrops at three opacities. The new compressed fixture retains the captured source, three backdrops and all outputs with SHA-256 checks. The real bridge passes all 1,179,648 pixels within one byte; the preceding bridge fails the new regression. Existing native bridge tests pass, and the contract script includes the new check.

The CPU and physical AMD application corpora both improve from 137 to 140 passing comparisons out of 173, without losing a passing case (`upstream-format18-hsl-cpu-parity-diff/report.json`, `upstream-format18-hsl-hardware-parity-diff/report.json`). Both Hue cases and full-opacity Saturation pass. Half-opacity Saturation improves from a 26-byte maximum error to two bytes and remains a failure. The 33 remaining native comparisons are still open.

The full hardware run passes 187 XCTest cases, 48 serial Swift tests and nine native adjustment journeys. Its 1,038-test parallel run reports 16 golden differences only (`upstream-format18-hsl-hardware-full-parallel.log`). All 93 decoded golden candidates are identical between CPU and AMD. The original twelve before/after hashes remain unchanged. Four additional Hue/Saturation comparisons are under review in `.build/evidence/upstream-format18-hsl-rendering-review/index.html`; their maximum changes are 2, 56, 2 and 2 byte levels. The 56-byte Hue case occurs where half opacity rounds a nearly gray source to gray. Native run `40136860217` confirms that output exactly, validates thirteen paired-control buffers and preserves all earlier sampling, blend and text captures unchanged. It also reproduces the remaining clipped-saturation discrepancies independently of the application. No golden baseline has been replaced.

## Native byte clipping refinement

The byte blend adapter now rounds the clipping bounds after the luminance shift,
while retaining fractional color components and target luminance. Rounding the
shift itself resolves the two paired Saturation discrepancies but creates thirteen
larger channel errors elsewhere in the captured grid; quantizing the bounds
instead preserves the complete grid and paired controls within one byte.

The compressed native fixture preserves all eighteen original grid cases exactly
and adds the six paired cases from successful run `40136860217` at `7d1c119`.
All thirteen added buffers retain their native SHA-256 values. The regression
now checks 24 cases and 1,179,696 pixels with its original one-byte tolerance.
It fails before the correction at half-opacity Saturation, blue 126 versus native
124, and passes afterward alongside the bridge contracts. Deep/HDR blending and
the other blend modes retain their existing paths.

Fresh CPU and physical AMD corpora both pass 141/173 native comparisons. The
half-opacity Saturation case now passes with a maximum difference of one byte;
no previously passing case is lost. Thirty-two native comparisons remain open.
All 93 golden candidates are identical between these backends. The full AMD
run dispatches all 187 XCTest cases without errors; 1,040 parallel Swift tests
report only the same sixteen golden issues, and all 48 serial tests pass.
The two captured glyph-geometry tests also pass in each complete corpus run.

The updated sixteen-image review is in
`.build/evidence/upstream-format18-hsl-clipping-rendering-review/index.html`.
Its original twelve before/after hashes are unchanged; the four Hue/Saturation
after-images are revised, with maximum changes from the committed baselines of
2, 56, 3 and 2 byte levels. It supersedes the earlier sixteen-image proposal.
All sixteen replacements still require explicit approval; no baseline or test
tolerance is changed. `hsl-clipping-verification-summary.json` and the CPU/AMD
comparison reports under `.build/evidence/` record the current results.

## Shared path coverage candidate

The local byte-surface candidate separates polygon coverage and compositing in
`linux/graphics/PolygonCoverage.h`, straight-stroke geometry in
`StraightStrokeCoverage.h`, and device-space curve subdivision in `CurveCoverage.h`.
The curve adapter supports simple single-contour paths with two monotone edge
chains. It validates geometry before drawing; nonmonotone or intersecting paths,
multiple contours, conics, disabled antialiasing, perspective and deep surfaces
retain the existing renderer. Fully covered row interiors and adjacent tile runs
avoid clipping every interior pixel. Fully covered tiles bypass mask sampling.

Native capture `40158718770` preserves every earlier reference buffer and adds
763 opacity, pretransformed-path and floating-surface controls. Context transforms
and pretransformed geometry produce identical pixels in all 109 recipes. Floating
opaque controls also retain byte-quantized coverage. Using 256 coverage steps
before clamping the A8 mask improves the curve adapter from 92 to 93 passing
default native cases out of 94, with the one-byte limit unchanged. The remaining
`rounded-size-4-phase-0.25-affine` case differs by two levels at three pixels.
`tests/test_curve_coverage.py` reports all 94 cases and currently fails this case;
it is not yet added to the contract runner. No fixture or tolerance is weakened.

The new compressed curve fixture preserves native paths, transforms, colors,
outputs and output hashes. All 52 supported native stroke cases and the 24-case,
1,179,696-pixel Hue/Saturation check still pass within one byte. Device clips and
copy/clear checks pass for strokes and curves. Nine unsupported-path and deep
surface controls remain byte-identical to the preceding renderer. A 1024-by-768
ellipse improved from about 62 ms in the initial prototype to about 6–7 ms after
optimization, compared with about 5 ms for Skia; a straight stroke measures about
1.36 ms versus 1.13 ms before extraction. These are local CPU timings.

Fresh CPU and physical AMD application corpora both pass 144/173 comparisons.
Ellipse and smooth Rectangle now pass, with no previous passing case lost; 29
native comparisons remain open. The full 1,092-test Swift run reports 17 golden
differences only. The candidate images and exact hashes are available in
`.build/evidence/upstream-format18-curve-rendering-review/index.html`. This
provisional review adds Color Overlay and revises six candidates from the earlier
sixteen-image proposal. All replacements remain unapproved and tracked baselines
are unchanged. The runtime candidate remains uncommitted while the strict native
curve failure and the broader parity gaps are investigated.

The verification artifacts use the `curve-worktree-` prefix under
`.build/evidence/`. The protected application corpus and the original staged patch
are unchanged. Upstream `main` still resolves to `7b5ba975694b1462d6c13007c6aea1d01bbc69ff`.
Native contour-direction and starting-vertex controls are published separately in
`a5ded72`; their successful macOS capture is run `40159794074`. Both controls
produce identical pixels to the original contour in all 109 cases, preserving
every earlier buffer. Contour direction and starting vertex therefore do not
explain the remaining coverage discrepancy (`coverage-contour-native-comparison.json`).

## Native image minification candidate

The local `linux/graphics/ImageSampling.h` component corrects high-quality
Core Graphics image minification. It owns filter contributions and separable
resampling; `SkiaBridge.cpp` selects the supported device grid and retains canvas
state, clipping and compositing. Upstream Dither code and its C kernel are unchanged.

Native sampling controls identify corner-aligned Lanczos-2 with edge extension.
The nearest tap is fixed at one before weights are normalized. Ordinary normalized
cubic/Lanczos models miss that rule and its phase-dependent bias. RGBA8-to-RGBA8
draws round the horizontal intermediate before the vertical pass. Float draws
preserve negative/HDR RGB and clamp alpha; independent size controls confirm the
native float32 final-pixel repetition during complete two-axis minification.
The implementation reproduces that format-specific behavior without changing
byte draws or 1:1 copies.

Native runs `40160191965`, `40161126195` and `40161789782` preserve every earlier
buffer and add brightness/phase, independent size/geometry and stripe controls.
The compressed sampling fixture contains all of those references. The regression
checks 172 supported byte/float frames within one level, and 62 legacy geometry
controls remain byte-identical to the preceding renderer. Ten additional mixed-axis
controls also remain unchanged. Fractional, rotated, mixed magnification and
reductions below 2x retain their preceding sampling path; single-pixel reductions keep
their area fallback pending separate native geometry verification.

The old smoke test assumed a box average at every image edge. Native captures of
its exact opaque/translucent stripe input instead give edge values of 186/93,
with interior values near 102/51. The test now checks captured native rows for
direct and scaled draws, retaining its one-byte tolerance and checking all RGB
channels. Its rotated fallback check is unchanged. The recompiled smoke executable
passes with the candidate library verified as loaded, including Vulkan execution
and device-loss fallback. The contract runner includes the new sampling regression.

Both complete Dither exports match native decoded RGBA exactly. CPU and AMD
application comparisons improve from 144 to 146 of 173, losing no passing case;
27 comparisons remain open. The full 1,092-test Swift run reports 18 golden
differences only. The new review is
`.build/evidence/upstream-format18-dither-rendering-review/index.html`: all seventeen
previous candidate hashes are unchanged, and Dither adds one proposal with a
maximum 255-level change. Existing baselines remain unchanged and unapproved.

Local 1024-by-768 to 512-by-384 timing is about 9.8 ms with native filtering versus
3.5 ms with the preceding area prefilter. Verification artifacts use the
`dither-sampling-` prefix under `.build/evidence/`. Runtime corrections remain local;
the native capture-only commits through `05c8499` are published on both branches.

A separate checkout at the published capture commit contains only the six-file
sampler change. Its native smoke and all 172 reference frames pass independently
of the other rendering candidates. Its full parallel run executes 1,044 Swift
tests and reports only the Dither golden issue; all 48 serial shared-state tests
pass. Its Dither PNG matches the exact reviewed after-image hash. The sampler-only
patch is `.build/evidence/native-image-sampling-owned.patch`. Replacing that one
baseline is awaiting explicit approval; the other seventeen proposals are separate.

Native scale controls from run `40173414215` subsequently expose a single-axis
float tail mismatch. The sampler now repeats the last pixel when either axis
shrinks, retaining its byte and identity behavior. The independent regression
grows to 204 native frames within one level, with 286 additional preservation
controls unchanged. The sampler-only checkout passes the same native controls
and smoke test. CPU and AMD comparisons remain 146/173; the complete Swift run
retains only the same 18 golden issues, and all 93 candidate PNG hashes are
unchanged. No golden baseline is replaced. See the single-axis section of
`coreimage-sampling-diagnostics.md` and `.build/evidence/single-axis-sampling-*`.

## Current code integration and compatibility status

Upstream `main` was rechecked at `7b5ba975694b1462d6c13007c6aea1d01bbc69ff`.
That source is integrated on both published branches, and the complete upstream
guard passes. Source synchronization is complete through that commit; Linux
rendering parity is still incomplete. The RGB Split fast-sine correction is
published through `2dcb83f`; other local rendering candidates remain unpublished.
The dashboard and check runner are published through `8443d47`.

Fresh CPU and AMD application corpora both pass 150 of 173 comparisons. The
RGB Split fast-sine correction adds two passing comparisons without losing any
prior pass; all non-RGB-Split PNGs remain unchanged. The earlier angular motion
candidate also adds two passing comparisons. Its cropped-preview origin
correction preserves every exported PNG and fixes the quarter-scale
partial-render regression.

| Remaining application comparisons | Count | Work required |
| --- | ---: | --- |
| Gaussian Blur | 1 | Match native large-radius sampling |
| Motion Blur | 1 | Match native large-radius angular sampling |
| Progressive Blur | 5 | Match native spatial blur and alpha |
| RGB Split | 2 | Resolve remaining adjustment-layer color and alpha differences |
| RAW sensor cases | 5 | Resolve remaining color differences |
| Inter text at three weights and sizes | 9 | Match native glyph coverage |
| **Total** | **23** | |

The full local qualification executes 1,300 tests: 207 XCTest checks, 1,045
parallel Swift Testing tests and 48 serialized tests. The latter 48 pass; the
parallel runs retain 18 golden-image issues and two strict native motion
assertions. The native motion fixture matrix passes 530/532 comparisons, including
all 80 cardinal and 404 small-radius controls. The two angular failures differ by
two byte levels. No tolerance or golden baseline changes. Verification artifacts
use the `motion-origin-` prefix; details are in `coreimage-sampling-diagnostics.md`.
The later RGB Split correction is qualified with the `dispersion-model-root-`
prefix. Its combined 1,300-test run retains exactly the same known failures.

### macOS CI baseline at the imported upstream commit

The fork's macOS Verify run `40186549247` fails three parameter cases in
`AdjustmentEditorTests.sharedEditorsKeepPixelsDynamicAndSupportCancel`, at
`AdjustmentLayerTests.swift:269`: Vignette, Lens Effects and Tonal Contrast reopen
with an unrelated Gaussian radius of 10 instead of the expected default 5.
This is also present in [upstream's own Verify run at 7b5ba97](https://github.com/robbietilton/Compositor/actions/runs/40118025373).
The macOS source, tests, project and Verify workflow are byte-identical to that
upstream commit. The downloaded result bundle confirms the radius mismatch;
`.build/evidence/mac-upstream-adjustment-ci-audit.json` records its provenance.

The Linux generated adjustment-editing override already preserves independent
settings for these later layer kinds. All 17 parameter cases of the equivalent
Linux editor test pass in the clean publishing checkout. The two checks skipped
by the older dialog-smoke failure also pass locally: 20 parallel save/callback
tests and four RAW precision tests with the generated 16-bit DNG. Remote Linux
CI at `2dcb83f` passes; the macOS upstream failures remain visible.

The clean publishing checkout at `2dcb83f` subsequently passes the complete Linux
contract workflow locally: all 44 native journeys and the following native checks,
251 selected Swift tests, 20 save/callback tests, and four 16-bit RAW precision
tests. All 34 monitor/dashboard tests also pass. The earlier upstream integration
at `a523cd7` passes the complete remote Linux workflow, as does the per-push Linux
run `40190979678` at `2dcb83f`. Evidence is in
`.build/evidence/upstream-complete-native-contracts-verification.json`.

The separate render-parity run `40190979686` exposes fifteen GPU-availability
issues in its unfiltered Linux suite, before rendering begins. Linux's CPU-backed
Metal compatibility device satisfies the upstream device predicate without
providing a hardware Camera Raw or canvas backend. Generated test mirrors now
adapt only that availability metadata; original bodies and assertions are retained.
The full CPU suite passes locally, as does the full physical Vulkan profile
(`--device=dri`, `COMPOSITOR_COREIMAGE_BACKEND=vulkan`, `REQUIRE_COREIMAGE_VULKAN=1`):
1,044 parallel Swift tests and 48 serial tests. Explicit hardware qualification
still fails when the required backend is absent. The policy correction is
published as `121a84b` on both branches; both upstream-sync guards pass. Its
Linux and render-parity CI runs remain in progress. This does not resolve the
23 image differences. Evidence is in
`.build/evidence/gpu-capability-policy-verification.json`.
