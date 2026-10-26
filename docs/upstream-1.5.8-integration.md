# Upstream 1.5.8 on GNU/Linux

Target: `c9c7531` (upstream main fetched October 24, 2026), following the
[1.5.7 integration](upstream-1.5.7-integration.md).

The seven changed upstream application, test, Xcode project and update-feed files are incorporated unchanged.
Linux platform support stays in the compatibility modules and Linux-owned tests.

## Behavior

- Projects written by 1.5.4 and 1.5.5 open again. Upstream's loader accepts versions 1–17 plus the GIF branch's 27;
  new saves still write format 17. This restores an accepted-version range and does not change the saved format.
- Prism makes crisp copies across the full frame, has Blur instead of Reach, and can echo to one side or both.
  Offset zero remains an applicable effect because its color fringe is still visible.
- Threshold reaches 100. Above 95, flare and starburst weigh the size and density of clipped-white lights against
  the picture's strongest source, rather than treating every small white glint as equally strong.
- The Linux About version follows upstream 1.5.8, build 54.

The original optics and controls compile directly. The compatibility layer adds `CIAreaMaximum`, `.Rf` bitmap
output, and `CIMorphologyMaximum`; `LensRaster` owns the circular dilation. Sliding maxima across the disc's spans
avoid searching a full disc at every output pixel. Reduction and float output retain HDR precision and working
color space, without passing through an 8-bit bitmap.

## Verification

Evidence is collected under `.build/evidence/upstream-1.5.8/`.

- The initial focused SDK run passes 10 XCTest cases and 25 Swift tests, including the new compatibility operations,
  Threshold 100 behavior, updated upstream Prism tests and restored project-version loading.
- Upstream's [1.5.8 macOS release CI](https://github.com/robbietilton/Compositor/actions/runs/40063779824) ran its filter
  suites and passed all four unit-test groups. Its protected sources match the integrated upstream files.
- The commit ledger covers 116 commits, including 89 code commits, with references for each new behavior.
- The C ABI UI-action follow-up passes 5 XCTest cases and 8 Swift tests. Prism's direction picker round-trips
  through the same JSON selection actions emitted by Qt, with Preview both off and on. Its asynchronous preview
  adds/removes the opposite-side echo, while original pixels and history remain unchanged; Cancel preserves them.
  The native-session lifetime and event/shortcut action regressions pass alongside it (`prism-native-actions.log`).
- All 180 XCTest cases, 48 serial Swift tests and 16 native CTest targets pass. The parallel Swift run executes
  1,032 tests before the UI-action follow-up and records exactly the existing 16 issues: 15 unavailable-GPU failures and the RGB Split tail-pixel
  discrepancy. No additional failures were reported. The full suite is not green.
- Protected-source/generator/shader checks pass. Source coverage accounts for 174 upstream Swift files and
  98 unchanged test files plus two generated mirrors; all 11 coverage fault tests pass.
- The final release application builds and links. The native filter journey passes all 42 cases, covering preview,
  Cancel/OK, pixels, history isolation and exact undo/redo. The verification script exits nonzero for the known
  parallel Swift test failures; it does not hide or permanently exclude them.

The selected checks include the unchanged upstream `LensEffectsTests` and `ProjectTests`, Linux controls and bokeh
tests, RGB Split centering, and new compatibility cases for area-reduction extents/HDR precision, red-float row
order and padding, working-space conversion, circular dilation and tiled output. A full-filter test checks that
Threshold 100 rejects small glints while retaining the stronger light source. Linux CI selects these suites.

The initial 1.5.8 verification retained the RGB Split tail-pixel discrepancy and device-availability limits
documented for 1.5.7; upstream 1.5.8 does not change that shader or its test. The first native Metal
[reference capture](https://github.com/chiddekel/Compositor/actions/runs/40099667440) passed on Apple's paravirtual
device, macOS 26.6.2. Both shader and fixture hashes match the local probe. At pixel (44, 30), the original shader
produces blurred alpha 9/255, with zero alpha in the unblurred tail. Its diagnostic jitter is 0.8752594, versus
Linux libm's 0.2852325. This confirms a platform arithmetic discrepancy rather than an obsolete upstream assertion.
The probe now observes phase, sine, noise and jitter with both default and disabled fast math to locate the
difference. The [follow-up capture](https://github.com/chiddekel/Compositor/actions/runs/40100150422) also passed:
disabling fast math returns sine/jitter values close to Linux libm. The default Metal values match float-cycle
range reduction and a fused dot product, which identifies the compatible arithmetic used below. These diagnostic
kernels do not modify the production shader.

The compatibility backend now performs that reduction and dot product explicitly on CPU and Vulkan, with a
regenerated shader header. On CPU, all nine captured blurred pixels match the Metal bytes exactly; the unblurred
pixels differ by at most one byte. The checked-in native reference includes device/OS, shader/fixture hashes,
arithmetic diagnostics and the capture URL. Its regression fails against the old CPU implementation and passes
with the fix, alongside the existing standalone spectrum/centering/ROI/alpha checks. The unchanged upstream
`rgbSplitSpreadsASpectrumAlongItsAngle` test now passes; all 16 selected Swift filter and centering tests pass.
The full follow-up executes all 180 XCTest cases successfully and 1,033 parallel Swift tests with exactly the
15 device-availability issues listed above; RGB Split passes and no additional failures appear. All 48 serial
Swift tests and 16 CTest targets pass, as do source/generator/shader/ledger integrity and coverage checks. The
release application builds and links; its Qt filter journey passes all 42 cases. The verification script reports
one failed gate, the parallel suite's unavailable-GPU assertions. Evidence is in
`.build/evidence/upstream-1.5.8/rgb-fix/`. The full suite remains nonzero for unavailable GPU devices, and Vulkan
execution remains unverified. This does not establish bitwise parity across all devices or images.

The first full macOS render-corpus job built and passed its native tests, then correctly rejected an incomplete
case catalog: upstream now emits `Lens Effects-default` and `Lens Effects-extreme`. Both cases are now included;
the catalog matches all 164 captured macOS images and all seven parity-tool tests pass. The full cross-platform
comparison remains pending.

The subsequent [native macOS corpus job](https://github.com/chiddekel/Compositor/actions/runs/40101971068)
passes and exports all 164 cases. The artifact's upstream commit, corpus hash and every image/sample checksum
match. A local CPU render uses the same downloaded inputs, completes successfully and produces a valid matching
manifest. The comparison passes 123 cases and fails 41: adjustments 11, blends 6, export 1, filters 6, RAW 5,
shapes 3 and text 9. All five color, six effect and six transform cases pass, as do both Lens Effects cases.
The RGB Split single-fixture regression is fixed, but the full image corpus still exposes edge-pixel differences;
the nine-pixel reference does not prove complete RGB Split parity. No comparison threshold was relaxed.
Reports, manifests and difference images are under `.build/evidence/upstream-1.5.8/full-parity-*`.

Dithering's alpha differs before its C kernel, during high-quality downsampling. Linux maps `.high` to Skia's
Catmull–Rom sampler; native output has a different edge response. `capture-coregraphics-reference.swift` and the
manual `Core Graphics sampling reference` workflow capture the same bitmap/draw recipe for the overlay fixture,
horizontal/vertical impulses and constant controls at scales 1, 2 and 6. The diagnostic passes local parsing,
Linux type checking, its unsupported-platform guard and workflow checks; native execution remains pending.

The first [native sampling capture](https://github.com/chiddekel/Compositor/actions/runs/40103412068) passes all
24 cases on macOS 26.6.2. Every buffer hash and size validates, all eight scale-1 controls are byte-identical,
and constant colors stay unchanged at scales 2 and 6. Nearest-expanding the captured overlay alpha reproduces
both native Dither alpha planes exactly, confirming the downsample stage as the source of their alpha mismatch.
The probe now also captures native vImage scaling with default and high-quality flags; that comparison is pending.

SwiftShader is not a suitable replacement for the unavailable Vulkan device: its
[capability implementation](https://github.com/google/swiftshader/blob/cddb5c91b23ff70a1f607ea31610aa0d7f4b5ad5/src/Vulkan/VkPhysicalDevice.cpp)
reports no Float64, Float32 denormal preservation or round-to-even support. No driver was installed and the
renderer requirements remain intact. The fork's macOS Verify and upstream-sync guard workflows pass on both
branches at `af6cb99`; the Linux contracts and remaining render-parity workflow jobs are still running.

The [vImage comparison capture](https://github.com/chiddekel/Compositor/actions/runs/40103980858) passes, but neither
native vImage mode reproduces Core Graphics' high-quality sampling. A direct substitution does not resolve the
dithering mismatch; that investigation remains open.

PNG export's one-byte discrepancy is independently isolated to source-over rounding. The
[native source-over capture](https://github.com/chiddekel/Compositor/actions/runs/40105222452) covers opaque,
translucent and clear backgrounds at full, half and quarter opacity. In RGBA8, Core Graphics quantizes the
opacity-adjusted premultiplied source to bytes, then blends using division by 255 with nearest rounding.
This rule reproduces all nine matrices exactly. The Skia canvas now uses a cached runtime blender for that
arithmetic, with floating-point arithmetic retained for deep surfaces. Its output matches all 589,824 captured
pixels byte for byte. The independent integer C++ regression checks 393,216 source-alpha/background-byte pairs
across the same three opacities; the original implementation fails the regression.

The final CPU corpus comparison passes 124 of 164 cases: decoded PNG-export RGBA pixels are now identical to the
native reference, with no case regressed against the original 123-case passing baseline. Forty discrepancies
remain in the other categories. Source integrity, coverage and the seven parity-tool tests pass; broader
source-over verification completes all 180 XCTest cases, 48 serial Swift tests, 16 CTest targets and all 42 Qt
filter cases successfully. The parallel run executes 1,033 Swift tests and reports 21 issues: 15 unavailable-GPU
assertions and six Linux golden baselines affected by the corrected rounding. A separate capture of those
six fixtures confirms unchanged 64×48 dimensions and a maximum difference of 2/255. The candidates and amplified
differences are reviewed locally under `source-over-golden-review/index.html`; tracked baselines remain untouched,
with their proposed updates awaiting approval. No test tolerance was changed. Evidence is under
`.build/evidence/upstream-1.5.8/source-over-*`.

`render-parity.py --skip-build` permits reuse of existing Linux test executables when only a dynamically loaded
native backend changed. The default still builds. Linux manifests record whether tests were reused and the
explicitly configured Skia, ImageIO and PDF library SHA-256 values, alongside the existing input, corpus, output
and upstream provenance. Explicit paths resolve from the same repository directory used to launch Swift, and
their hashes must remain unchanged during rendering. Bare loader sonames record configuration only, since a
same-named local file does not establish which library the dynamic loader selected.

The [expanded native blend capture](https://github.com/chiddekel/Compositor/actions/runs/40106852437) adds
Exclusion, Hue and Saturation matrices. Exclusion uses the same input quantization as Source Over, then computes
premultiplied RGB as `s + d - round(2*s*d/255)` and source-over alpha. The canvas implements this in the same
precision helper. Both modes match all 18 native matrices exactly: 1,179,648 pixels in total. The integer bridge
regression now checks 786,432 pixel cases across both modes and fails against the original Exclusion path.

The complete CPU corpus now passes 126 of 164 cases, including PNG export and both Exclusion cases with identical
decoded pixels; no case regresses against the original passing baseline. Thirty-eight rendering discrepancies
remain. The latest verification passes 180 XCTest cases, 48 serial Swift tests, 16 CTest targets, native matrix
comparisons and all 42 Qt filter cases. Its parallel run executes 1,033 Swift tests with 23 issues: the same 15
unavailable-GPU assertions and eight old Linux snapshots affected by verified rounding corrections. The two
additional snapshots are `blend/Exclusion@100.png` and `blend/Exclusion@50.png`. Their dimensions are unchanged
and maximum channel differences are 2/255. The combined eight-image review is in
`.build/evidence/upstream-1.5.8/blend-golden-review/index.html`; its original six candidates have the same hashes
as the earlier proposal. All tracked baselines remain untouched pending approval. No test tolerance changed.

Hue and Saturation still use their existing renderer paths. The native captures expose differences up to three
and five channel values respectively; numeric investigation of their intermediate rounding continues without
changing production behavior for those modes. Evidence for this follow-up is under `blend-verification`,
`blend-native-matrix-comparison.json`, `exclusion-parity-*` and `coregraphics-blend-reference` in the evidence root.

A separate Fontconfig experiment disables hinting while retaining antialiasing. All 164 cases render, but the
comparison still passes only 126: eight of nine text overlaps improve, one worsens, and none reaches the text
gate. All non-text PNGs remain unchanged; two sample JSON files differ only in serialization order. A gamma-only
coverage experiment also leaves substantial shape differences, so neither setting was applied to production.
The local Qt metric probe confirms that the current helper rounds fractional pixel sizes to integers, an
additional limitation outside the nine integer-size cases. The
[native font capture](https://github.com/chiddekel/Compositor/actions/runs/40111031733) compiles and passes on
macOS. It records resolved font checksums, metrics and five rendering variants at integer and fractional sizes;
all 18 cases resolve the exact bundled font checksums and all 90 pixel buffers validate. The nine default
integer-size alpha planes match the macOS corpus exactly. Disabling native font smoothing reduces coverage to
nearly the Qt level, isolating a major contributor to the weight difference. Native default line heights are
15, 29 and 44 at sizes 12, 24 and 36. Metric-derived line heights and Qt vertical subpixel positioning were tested
separately; neither closes the native pixel discrepancy, so those experimental backend changes were reverted.
Local evidence is in `font-hinting-experiment.json`, `native-font-comparison.json`, `font-nohint-parity-*`,
`font-lineheight-*`, `font-subpixel-*` and `qt-font-metrics.json` under the evidence root. Tracked goldens remain
unchanged. After restoring the backend, all 164 PNG outputs are byte-identical to the pre-experiment render and
all numeric sample contents match. The restored manifest verifies all three configured native library hashes;
the nine parity-tool tests pass, including relative-path and loader-soname provenance regressions.

Fractional text sizing is now corrected in the Qt compatibility backend. Qt's
[font database](https://github.com/qt/qtbase/blob/6.10/src/gui/text/qfontdatabase.cpp) rounds point sizes to whole
pixels, and its raw-font layout setter is unsupported for drawing. Fractional layouts therefore use a larger
coordinate space with an inverse painter transform, preserving Qt shaping, font fallback, attributed ranges,
tracking, wrapping and alignment. Font metrics use a resized `QRawFont`; default line heights follow rounded
font metrics rather than a fixed 1.2-em estimate. The generic `fontFor` helper and upstream Swift sources remain
unchanged.

The native text ABI regression matches all 18 captured Inter size/face combinations, including the nine half-pixel
sizes. It checks ascent, descent, advance and default line height, nonempty premultiplied RGBA rendering,
explicit fractional line spacing and wrapping. The previous whole-pixel implementation fails the fractional
metrics check. The native build and all 16 CTest targets pass. A fresh full image comparison remains 126/164;
all 164 corpus PNGs and all eight proposed golden replacements have the same hashes as before this change.
An explicit reconstruction of the previous rounded-size/1.2-em recipe reproduces all nine existing integer
text alpha planes exactly. Against that control, all nine half-pixel renders improve their overlap with both
native default and unsmoothed glyphs: default overlap rises from 0.465–0.780 to 0.708–0.883. Smoothing and edge
rasterization remain separate open discrepancies; this does not claim full text image parity.
Evidence is under `fractional-font-*` in the local evidence root. Broader verification passes all 180 XCTest
cases and 48 serial Swift tests. The parallel run executes 1,033 Swift tests and reports exactly the same 23
issues as before: 15 GPU-availability assertions and eight unchanged golden candidates. No new failure
descriptions appear. The existing GPU and golden approval gates remain open.
The release application builds successfully, and its native Qt font-history journey passes live highlights,
Cancel, one-step Undo, mixed-font restoration and Redo. The fractional-text fix is published on both branches
as `9352cf3`; the Source Over/Exclusion renderer and baseline proposal remain separate pending work.

The [native affine capture](https://github.com/chiddekel/Compositor/actions/runs/40113732025) tests default/high
vImage affine resampling, three sampling phases and two edge rules. All 384 sampling buffers validate, with all
96 identity comparisons exact. None reproduces Core Graphics' downsampling; the best overlay alpha differences
remain 38/255 at 2× and 62/255 at 6×. A
[corner-alignment capture](https://github.com/chiddekel/Compositor/actions/runs/40114224923) adds scales based on
the first and last pixel centers. Its 672 buffers validate and all 192 identity comparisons match. Corner
alignment improves the best overlay alpha difference to 16/255 at both scales, but still does not establish a
replacement kernel. All existing 24 Core Graphics outputs and 288 earlier affine outputs retain their hashes.

The [floating-point capture](https://github.com/chiddekel/Compositor/actions/runs/40114760151) repeats those
recipes in extended-sRGB RGBAFloat32 contexts, with exact byte/255 source values. All 886 buffers validate,
including 720 sampling buffers and 166 unchanged blend/text controls; all eight float identity cases match
exactly. Rounded float outputs reproduce all opaque impulse/constant byte cases exactly. The two overlay
cases differ by at most one channel value, so final byte rounding does not explain the larger sampling errors.
The prior 24 byte outputs and all 576 affine outputs remain unchanged. Simple cubic and Lanczos fits still
leave unexplained impulse differences; no inferred resampling kernel was applied to production and no test
tolerance changed. Evidence is in `coregraphics-affine-reference`, `coregraphics-corners-reference`,
`coregraphics-float-reference`, `affine-native-comparison.json`, `corners-native-comparison.json` and
`float-native-comparison.json` under the evidence root. The complete image comparison remains 126/164.

The [native Core Image capture](https://github.com/chiddekel/Compositor/actions/runs/40115920106) uses the same
unmanaged context as `PixelAdjust`, with opaque-gradient and impulse inputs. Its 114 Gaussian, motion and
constant-mask variable-blur cases produce 232 validated byte/float buffers. All 14 zero-radius/mask byte
controls reproduce their identity input. Gaussian's small-radius response integrates over pixel areas, rather
than sampling the density at each pixel center. Pixel-area weights with finite-support tail handling reproduce
all 18 Gaussian RGBA8 reference images within 1/255 in every channel, using the existing convolution kernels.

The compatibility Gaussian and Bloom nodes now select pixel-area weights explicitly; the internal point-sampled
Gaussian remains available to the existing variable-blur pyramid. The new native-reference fixture and test
cover all pixels of both inputs at nine radii. All 21 targeted compatibility tests pass, including existing
scalar, FFT and regional-rendering checks. The full image comparison improves from 126 to 128 passing cases,
with no regressed case: Gaussian Blur at radii 1 and 17 now pass. The default adjustment radius of 10 retains an
alpha discrepancy. The two filter Gaussian cases and all five Bloom cases continue to pass. All eight proposed
golden replacements keep their reviewed hashes, and tracked goldens remain untouched.

Native variable blur stays sharp at effective radii through 0.75 in the captured controls; its pyramid and
interpolation differ from the current Gaussian approximation. Nonzero-angle native motion blur also has an
additional resampling response. Those operators remain unchanged pending a verified model. Evidence is under
`coreimage-reference`, `coreimage-native-capture-validation.json`, `gaussian-kernel-native-comparison.json`,
`gaussian-area-*` and `native-variable-pyramid-levels.npz` in the local evidence root. Broader verification passes
all 181 XCTest cases, 48 serial Swift tests and 42 native Qt filter-control cases. Its 1,033-test parallel run
reports 24 issues: 15 unavailable-GPU assertions and nine Linux golden differences. The additional snapshot is
`filter/Tonal_Contrast.png`: 1,989 channels change, 441 by more than one, with a maximum difference of 2/255. Its
64×48 geometry is unchanged. Tonal Contrast also improves against both native corpus images. The combined
nine-image review is `.build/evidence/upstream-1.5.8/gaussian-golden-review/index.html`; the earlier eight
candidates retain their hashes. No tracked baseline was modified. Approval for those nine replacements is
pending; 36 image discrepancies and the GPU gate remain open.

The [default-radius control capture](https://github.com/chiddekel/Compositor/actions/runs/40119184869) adds
radius 10 and materialized 32-pixel padding, matching the adjustment's sampling halo. All 244 buffers validate;
the preceding 114 cases retain their byte/float hashes, and both unfiltered padding controls preserve the input.
Direct and padded radius-10 outputs each match the native corpus alpha exactly, while the candidate still
differs by up to 2/255. Input padding is therefore not the source of that remaining discrepancy. Evidence is in
`coreimage-padded-reference` and `coreimage-padded-validation.json`. The diagnostic is published as `3ead9d5`;
the Gaussian production candidate remains local pending the nine-image baseline decision.

## Format 18 follow-up

Upstream `7b5ba97` is integrated and pushed to both branches as `a822193`. The original nine Gaussian/compositing candidate hashes are unchanged. The new Tonal Contrast adjustment adds one proposed golden replacement (four channel values above one level, maximum 2/255), so the pending review now contains ten files. Rebuilding the combined candidate against format 18 passes the native Gaussian references and affected layer tests; all 173 corpus images render. A matching native capture is available from run 40122628134. After re-rendering Linux with its exact inputs, the combined unpublished candidate passes 135/173 comparisons. The old 164 native images are unchanged, so 128 previous passes remain, with seven of nine new layer cases passing. Default Anamorphic Flare and Prism remain outside the maximum color-difference gate. Details and artifact paths are in `docs/upstream-format18-integration.md`.

The [expanded sampling capture](https://github.com/chiddekel/Compositor/actions/runs/40125848219)
validates 266 cases and 536 buffers. Its 14 direct Lanczos cases expose the Linux shim's former affine-scaling
alias. A normalized Lanczos-3 model reproduces all direct byte outputs within two levels, with 13 within one;
the largest residual is the opaque gradient at an aspect ratio of 1/90. Native output extents round outward to
whole pixels. A dedicated, separable CPU resampler is under verification; it retains negative and HDR channels
and alpha overshoot, and does not change the application comparison thresholds.

The 12 scale–Gaussian–inverse-scale controls also expose a distinct sampling issue. Transparent bilinear
sampling of the blurred intermediate differs by up to 80 byte levels at its borders. Clamping the model to the
original scaled pixel centers reduces every captured byte difference to at most one. This is evidence about
that composition, not authorization to clamp arbitrary affine inputs: native raw affine controls retain partial
edge coverage. No global affine-clamping change has been applied. Model results are in
`.build/evidence/native-lanczos-model-comparison.json` and
`.build/evidence/native-lanczos-roundtrip-clamped-model-comparison.json`.

Materialized impulse shifts confirm that native Gaussian float output depends on sampling phase, despite
identical translated byte images for the eight captured positions. The phase comparison is in
`.build/evidence/native-gaussian-phase-comparison.json`. Expanded motion controls put all 80 cardinal-angle
cases within one byte using pixel-area weights, versus 50 with point weights. Arbitrary-angle sampling remains
unresolved, so production motion blur is unchanged; the 128-case comparison is in
`.build/evidence/upstream-1.5.8/native-expanded-angle-motion-model-comparison.json`.

The Lanczos candidate builds in release mode and passes all 12 focused XCTest cases plus 17 affected Swift
tests. Its 173-case comparison remains 135 passing: only Anamorphic Flare changes, improving channel maximum
from 21 to 20 and maximum color difference from 4.4043 to 4.2033, still above the gate. The ten proposed golden
replacement hashes and their tracked originals are unchanged. Two Lens Effects golden outputs change within
the existing one-level tolerance. Broader verification passes all 183 XCTest cases, 48 serial Swift tests and
the nine-case native adjustment journey. The 1,038-test parallel run reports 26 issues: 15 known unavailable-GPU
assertions, ten pending golden differences and a new `anamorphicThresholdDecidesWhichLightsFlare` assertion.
The resampler therefore remains unpublished pending its scale–blur boundary correction. Logs and image
comparison artifacts use the `.build/evidence/upstream-format18-lanczos-*` prefix.

Diagnostic commit `c6dc69d`, pushed to both branches, adds finite/infinite extent metadata, eight translated
Gaussian controls and 32 isolated pointwise-affine controls. The macOS-branch Swift parse, workflow syntax,
historical 536-buffer validator and peer review pass. Native run `40128219895` passes its expanded 306-case,
616-buffer corpus. All 266 earlier recipe outputs and both identity inputs retain their hashes. Native Gaussian
bounds use the same expanded halo as Linux, and translated Gaussian controls retain their tails. Isolated affine
controls confirm that interpolation precedes unpremultiplication and transfer conversion; alpha replacement
also remains visible beyond the reported finite transformed extent. A global edge clamp would not reproduce
these distinct behaviors. Evidence is in `.build/evidence/upstream-format18-boundary-native` and
`.build/evidence/upstream-format18-boundary-native-validation.json`. Production candidates and existing baselines
are excluded from that commit. The pre-push guard's two phone findings refer to the already-public native CI
run number in the diagnostic document, not personal data.
