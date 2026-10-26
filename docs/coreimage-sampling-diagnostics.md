# Core Image sampling diagnostics

## Variable-blur pyramid diagnostics

The graph capture appends 168 `CIMaskedVariableBlur` probes after the existing
recipes. Forty-eight constant-mask cases cover two inputs, radii 1, 10 and 35,
and eight mask intensities. Another 96 cases materialize an impulse at each of
16 two-dimensional bitmap sampling phases, at radii 1.5, 3, 6, 12, 24 and 48.
The final 24 cases clamp both source fixtures at radii 10 and 35 with six mask
intensities, isolating finite-image boundary effects. Each new case records
native graph descriptions and complete byte/float buffers with SHA256 hashes.
The workflow checks the exact recipe matrix, finite float values, buffer hashes
and zero-mask identity. Existing recipes retain their render order.

These probes investigate Progressive Blur's native pyramid and interpolation.
The initial constant-mask captures showed an identity boundary near effective
radius 0.75 and logarithmic blending between pyramid levels, which the preceding
variance-based Gaussian approximation did not reproduce. The phase captures
distinguish the level filters and sampling geometry. Implementation qualification
is recorded below; the diagnostic probes alone do not establish application parity.

Native run `40198914398` validates the first 96 probes. Its 48 constant-mask byte
and float outputs match the earlier capture exactly. Direct levels at radii 1.5
and 3 agree with logarithmic interpolation predictions within 0.000213 byte levels.
A prototype using a four-by-four cross reduction kernel and cubic B-spline
reconstruction with 1/256 sampler fractions matches all 48 low-level phase probes
within 0.00381 byte levels. After aligning the pyramid in Core Image coordinates,
four larger-radius finite-gradient controls still differ by up to 13.6 levels;
these are not resolved by the prototype. The coarser
and clamped probes investigate that limitation. Those initial probes preceded
the production replacement described below.

The capture also appends 36 request-region controls. Each renders the same
original view with margins 0, 16, 64 and 256, using a fresh unmanaged context to
avoid cache warming. Both float and RGBA8 bitmap buffers are sliced after
rendering. Request probes label their byte route as `CIContext.toBitmap`, which
can render beyond finite image extents; earlier CGImage exports remain unchanged.
No crop node is added
to the input graph. The matrix covers finite and clamped gradients at radii 10
and 35 with two mask intensities, plus an impulse control. The workflow checks
the exact matrix, expanded bounds, buffer hashes, finite values and agreement
of the zero-margin float controls with the earlier captures. Byte method
differences are measured separately from request-region differences.

The 168-probe run `40200643930` preserves all 306 preceding bitmap pairs.
The cross-reduction prototype matches all 96 phase probes, including the coarse
levels, within 0.00381 byte levels. It matches 22/24 clamped constant-mask controls
within one byte; two gradient cases still differ by up to 3.06 levels. The
request-region controls test whether those edge discrepancies depend on the
native request bounds before changing the Linux renderer.

Request run `40201272333` preserves all 378 preceding bitmap pairs. Increasing
the native radius-10 request by 16 pixels changes the original view by 13.5 byte
levels and brings the full-pyramid model's error below 0.17. Clamping the highest
pyramid level to its linear-sampling request bounds reproduces that behavior:
all 108 constant-mask and request controls are within one byte, worst 0.61.
Earlier levels receive extra coverage from the next reduction. These numerical
controls guide the compatibility implementation; they do not certify the app.

The capture appends 54 further controls before qualifying the replacement:
six mask inputs, 32 linear/radial-mask cases through the UI's maximum radius 250,
eight colored-mask cases, and eight finite-geometry cases. They distinguish mask
channel semantics, saturation, translated/cropped extents and spatially varying
selection from the already qualified constant-mask arithmetic.

## Variable-blur compatibility implementation

`VariableBlurRaster` owns the reduction, reconstruction and request-region planning,
separately from graph evaluation. The source is reduced with the native four-by-four
cross kernel. Cubic B-spline reconstruction uses 1/256 sampler fractions, and levels
blend logarithmically from the identity boundary at effective radius 0.75. The mask
uses its green channel at half-float working precision. The highest level clamps to
its requested linear-sampling bounds; earlier levels retain the next reduction's
footprint. Finite extents follow six integral half-scale reductions. Premultiplied
negative/HDR values remain intact.

Native run `40203326961` validates the final 54 controls, preserving all 414 earlier
bitmap pairs. `NativeVariableBlurReferenceTests` checks all 258 variable-blur controls,
including spatial masks, colored masks, translated/cropped geometry and request
margins, against independently captured bytes and floats with the unchanged one-byte
limit. Both CPU and required Vulkan configurations pass, along with all four upstream
Progressive Blur tests. A full varying-mask CPU render preserves extended colors
within `4.77e-7` at both 512×512 and 1920×1080; observed times were approximately
43 ms and 302 ms, respectively, without imposing a machine-dependent timing limit.
The published predecessor fails the focused native default-radius test by 13 levels.

The lossless fixture records native-run, capture-commit and source SHA256 provenance.
Regenerate or verify it from the downloaded graph capture with:

```sh
python3 scripts/gen-variable-blur-reference.py coreimage-graph-reference.json \
  --source-run 40203326961 --source-commit 315cc14 --check
```

The isolated 173-image application corpus improves from 132 to 137 native comparisons;
all five Progressive Blur cases pass and no previously passing case is lost. With
matched device access, the other 168 decoded images remain identical. Removing GPU
access also changes one pixel in the pre-existing RGB Split case, reproducibly: the
Core Image CPU setting does not disable the separate Metal-compatible dispersion
driver. Evidence uses the `variable-pyramid-` prefix. Two Progressive Blur Linux golden
images are updated after native qualification and visual review; comparison limits
and all other baselines remain unchanged. This does not resolve the remaining
Gaussian, motion, RGB Split, RAW and text discrepancies in the combined development
worktree.

The manual `coreimage-reference.yml` workflow runs the native macOS capture with an unmanaged Core Image
context. It validates 358 cases and 720 byte/float buffers, including SHA-256 checks, dimensions, finite float
values and unique recipe metadata. The artifact contains synthetic pixels only.

The capture includes direct Gaussian, motion, masked blur and Lanczos controls, scale–blur–inverse-scale
compositions, affine translations and materialized impulse phases. Extent metadata records finite, infinite
and null bounds without serializing nonfinite JSON numbers. Eight translated Gaussian cases expose blurred
pixels crossing the original input boundary. Thirty-two additional affine cases isolate unpremultiplication,
alpha replacement and the sRGB transfer function from the complete preparation chain.
Four Gaussian magnification cases separate scaling from Lanczos intermediates. Eight alpha-rectangle controls
use smaller and disjoint bounds, both directly and after translation, to distinguish extent metadata from pixel
masking before changing alpha replacement behavior.
The alpha-rectangle byte buffers use `CIContext.render(toBitmap:)`, recorded in their recipe metadata, because
`createCGImage` can shrink or reject a hard-cropped image outside the requested bounds. All other byte recipes
retain their original CGImage export path; float buffers consistently use the fixed-size bitmap API.
Sixteen tone-curve controls cover identity, two lens highlight thresholds and contrast, with both ordinary and
doubled RGB inputs. They record the native extrapolation default when the filter exposes that parameter.
Apple specifies a gamma-2 perceptual working space for this filter in the
[Core Image Filter Reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/).
Twenty-four additional Gaussian magnification probes compare complete 192×72 renders with two interior 32×24
requests. Their `sampleBounds` metadata defines dimensions and world coordinates; both output types use the
bitmap API. They use both the shared context's default cache and fresh contexts with intermediate caching
disabled, recorded as `contextPolicy`. This separates request boundaries from cache reuse when checking
interior tile behavior. Other capture recipes retain their 96×72 output buffers.

These controls investigate two unresolved compatibility behaviors: sampling a blurred scaled intermediate
and sampling through pointwise color operations. They do not establish a replacement algorithm by themselves.
Compare the original 266 recipes with the preceding capture from run `40125848219`, matching recipe parameters
while excluding newly added extent metadata, and require unchanged byte and float hashes.

The production candidate remains local. Native pointwise, blur and tone references pass, and the perceptual
tone correction resolves the upstream faint-flare assertion. The CPU application corpus passes 137/173 comparisons,
including all nine format-18 adjustment cases. An AMD Vulkan run passes all 186 XCTest cases, 48 serial Swift
tests and nine native adjustment journeys; the 1,038-test parallel run reports only 12 proposed golden changes.
Native run `40131936749` validates all 358 cases and 720 buffers, preserving the preceding 334 outputs.
Its interior requests differ from cropping a full render by up to 0.7471 byte units, identically with both cache
policies. The regional regression checks native byte output within one level and tile-versus-full float
differences within `1/1024`; it passes in both CPU and AMD Vulkan configurations and resolves the tile review.
Existing golden baselines and application comparison thresholds are unchanged.

A separate Vulkan dispersion investigation found phase optimization and approximate-sine hash amplification.
The local shader correction uses precise phase reduction and an explicit reduced-angle sine polynomial;
native Metal source and CPU dispersion are unchanged. The automatic AMD corpus improves from 136 to 137 of
173 passing comparisons, with all nine new adjustment cases passing and no passing case lost. Five sharp-alpha
component probes now differ from CPU by less than 0.72 byte units; their new regression fails with the original
shader. All 93 decoded golden candidates are unchanged by the shader fix. See the spectral-sampling section of
`upstream-format18-integration.md` for evidence paths and the remaining gaps.
The complete rebuilt hardware run passes 187 XCTest cases, 48 serial Swift tests and nine native adjustment
journeys; the 1,038-test parallel Swift run retains only the same twelve unapproved golden differences.

## Core Graphics image minification

The separate Core Graphics downsample stage caused both remaining Dither export
failures. Applying the unchanged Linux Dither kernel to captured native
intermediates reproduces both complete native images byte for byte. The preceding
box prefilter produces alpha errors of 55 and 83 levels for 2x and 6x reduction.

Native ramp, checker and brightness controls establish a linear corner-aligned
Lanczos-2 sampler whose nearest tap is one before normalization, with extended
edge pixels. Byte intermediates are rounded after the horizontal pass. A separate
`ImageSampling.h` component now implements that behavior for supported complete
pixel grids; it does not change Core Image's Lanczos implementation or protected
upstream filter code. The image-sampling regression passes 172 native byte/float
frames within one level, preserving 62 legacy geometry controls and ten mixed-axis
controls exactly. Independent native stripe captures replace the smoke test's
incorrect box-average edge expectation without relaxing its tolerance.

Native runs `40160191965`, `40161126195` and `40161789782` retain all preceding
buffers. The application corpus passes 146/173 comparisons on CPU and AMD, with
both Dither images decoded-RGBA identical to native. Twenty-seven earlier
comparisons remain open; the full Swift run retains eighteen unapproved golden
differences. See the minification section of `upstream-format18-integration.md`
for supported geometry, performance and review artifacts.

The sampler regression's optional `--characterize-legacy` flag compares the 62
preserved controls with native separately from the 172 supported frames. With the
current candidate, 20/62 are within one level: 11/20 byte nearest draws, 9/20 float
nearest draws, and none of the 22 fractional high-quality draws. Maximum errors
are 248 byte levels for nearest and 56.108 for fractional high-quality sampling.
Preservation of previous Linux output therefore does not establish native parity.
The report is `.build/evidence/fractional-sampling-current-native-diagnostics.json`.

The nearest float controls isolate coverage from filtering: their premultiplied
ramps identify sampled source coordinates, and the independent checker channel
checks those selections. Across all 20 frames, multiplying the selected source
RGBA by `clamp(ceil(256 * area) - 1, 0, 255) / 255` reproduces coverage within
0.000022 byte levels. Here `area` is the exact intersection of the destination
rectangle and the pixel square. Exact area, rounded 255-level coverage, and the
existing floor-256 model each miss some captures by roughly one level. See
`.build/evidence/fractional-nearest-geometry-characterization.json`. Source-coordinate
placement remains unresolved, including the 65-by-49 vertical phase and float
bottom-right source selection. This is a characterization of these nearest
captures, not a general geometry rule or a production correction.

Applying that coverage model to the direct fractional Lanczos experiments still
passes none of the 22 high-quality controls. Thus coverage alone does not explain
the remaining error. The experiments in
`.build/evidence/fractional-sampling-native-coverage-models.json` retain all cases;
the production fallback and native tolerance remain unchanged.

Subsequent native runs `40164023743`, `40172422364`, and `40172910216` add
600 paired geometry recipes: 144 opaque controls, 432 alpha/single-fractional-axis
controls, and 24 periodic-pattern holdouts. Each recipe includes its source and
both fractional and aligned output. All preceding native sections remain exactly
unchanged. The capture-only changes through `728c5ea` are published on both
branches; `Tests/Fixtures/coregraphics-sampling-geometry-reference.json.gz` retains
the new buffers with their source commit and run. The analytic Lanczos model
matches all 300 aligned high-quality frames within one level, including reductions
slightly below 2x that the production adapter does not yet select.

Matched opaque ramps establish a second sampling stage at cache coordinate
`(pixel + 0.5) * cacheLength / realExtent - 0.5`. Its measured weights are
`[0, 1/16, 1/8, 1/4, 1/2, 3/4, 7/8, 15/16, 1]`, selected by the nearest eighth
of the fractional coordinate, with exact half-index ties selecting the lower
entry in the 32-by-24 controls. Nearest-anchor selection uses the original
coordinate fraction, rather than the quantized weight. With captured intermediate
images and opaque coverage masks, the float model matches all 150 new high-quality
fractional frames within 0.000092 byte levels. Its two-dimensional stencil uses
the anchor-row/X-neighbor pixel in the second horizontal interpolation; replacing
that pixel with the usual Y-neighbor breaks the independently captured checker
and corner controls. Zero-weight and clamped-edge cases use one-dimensional
interpolation. These are measured rendering rules, not claims about Apple's
source implementation.

The byte model uses the usual four neighbors. Rounding down horizontally and up
vertically matches 149 of 150 new byte frames with captured intermediates and
coverage, retaining the one-level tolerance. The remaining periodic 17-by-13, 6x
case differs at one blue channel by two levels. An older 97-by-73, 3x holdout also
exposes a one-level intermediate filtering difference that can accumulate to two
levels after interpolation. Neither exception is skipped or assigned a different
tolerance. Fully analytic filtering, interpolation and area coverage now pass
all 11 older float fractional holdouts and 5/11 byte holdouts; a general renderer
correction is still unproven. The model reports are
`.build/evidence/sampling-alpha-geometry-native-analysis.json`,
`.build/evidence/sampling-periodic-intermediate-analysis.json`, and
`.build/evidence/fractional-sampling-end-to-end-model.json`.

Run `python3 tests/test_image_sampling.py <library> --characterize-legacy
--characterize-geometry --report <path>` to inspect the preserved and expanded
native gaps separately from the supported regression. The current combined
candidate, before the single-axis correction below, passes 172/172 supported frames and preserves 62/62 legacy
outputs; the expanded diagnostic passes 638/1,200 frames within one level, with
a maximum 255-level error. This is diagnostic evidence of unfinished geometry
support, not an additional passing test gate. Runtime and golden baselines remain
unchanged by these capture and diagnostic additions.

The native scale capture from run `40173414215` adds 256 whole-pixel recipes,
retained in `coregraphics-sampling-scales-reference.json.gz`. It preserves every
preceding section exactly and includes identity, single-axis, near-identity,
mixed-axis and mixed-magnification controls. The adapter's existing supported
range contributes 32 new required frames; the other 224 are preservation controls,
so minor-scaling failures remain visible rather than becoming passing assertions.

These controls confirm that a native float32 reduction repeats the final pixel
from its left neighbor when either axis is reduced. `ImageSampling.h` previously
required both axes to shrink. Changing that condition fixes all eight new float
single-axis cases; the preceding renderer fails those same cases by up to 254.776
byte levels. Identity and byte controls retain their previous behavior. The
regression now passes 204/204 native frames within one level and preserves all
62 older geometry controls plus 224 new scale controls byte for byte. This also
passes in the sampler-only checkout, independently of other local rendering work.

The rebuilt native smoke resolves the candidate library explicitly and passes
Vulkan execution and device-loss fallback. Fresh CPU and AMD application corpora
remain at 146/173, losing no passing comparison. The full Swift qualification
runs 1,044 tests in parallel with the same 18 golden issues and passes all 48
serialized shared-state tests. All 93 generated golden PNGs are byte-identical
to the preceding candidates. Existing baselines remain unchanged.

A broader minor-scale prototype improves 29/112 native controls to 93/112 but
still fails 19, including near-identity checker and periodic-pattern draws. That
adapter expansion and its tap-selection experiment remain outside the worktree;
the runtime change above addresses the independently confirmed float tail rule.
New verification artifacts use the `single-axis-sampling-` prefix under
`.build/evidence/`.

## Gaussian working precision

Native run `40176136505`, from capture commit `791defb`, preserves all 358
preceding recipes and adds 504 Gaussian controls: byte and float inputs,
rectangle/step/impulse fixtures, three opacity levels, seven radii, and default,
explicit half-float, and explicit full-float working contexts. All 1,512 new
bitmap buffers pass layout, SHA256, and finite-value checks.

Reproduce the numerical analysis with the dependencies in
`scripts/parity-requirements.txt`:

```bash
python3 scripts/analyze-gaussian-precision.py \
  .build/evidence/gaussian-working-precision-native/coreimage-reference/coreimage-reference.json \
  --previous .build/evidence/upstream-format18-regional-native/coreimage-reference.json \
  --source-run 40176136505 \
  --report .build/evidence/gaussian-working-precision-analysis.json
```

This command audits the captures and reports analytical model errors; its exit
status does not certify renderer parity. Default and explicit half-float outputs
match in all 168 pairs. The pixel-area Gaussian model matches 162/168 controls
within one byte level in each of the three contexts. For the opaque rectangle
at radius 10, the default context still differs by two levels at 15 alpha pixels;
the full-float context differs by two at six. Working precision alone therefore
does not explain the application mismatch. Float inputs at half and quarter
opacity retain proportional alpha within 0.000244 byte levels in the default
context, so these controls do not support an opacity-dependent correction.

The existing radius-10 materialized impulse controls also expose a small change
with pixel position: after undoing each source offset, phases 1 through 7 differ
from phase 0 by up to 0.005351 byte levels. Their captured total alpha ranges
from 0.9923717 to 0.9965896. A single fixed native impulse kernel therefore cannot
be assumed to reproduce every native rendering position.

Twenty-four diagnostic models of half-float reduction order, paired terms, and
parallel accumulation lanes were also checked against all 168 default-context
controls. The best passes 164/168, retaining four two-level failures. These
experiments remain outside the renderer. The current application corpus remains
146/173; the Gaussian application failure and baseline images are unchanged.

## Motion blur pixel coverage

`RasterFilters.motionBlur` now integrates the Gaussian over each tap's pixel
footprint and retains the outer tails. Point weights previously made small
cardinal blurs too sharp: the native regression failed 30/80 captured frames,
with errors up to 27 byte levels. The corrected implementation matches all
80 within the unchanged one-level tolerance. The fixture
`Tests/Fixtures/coreimage-motion-reference.json` retains the byte buffers from
native run `40176136505`, covering two inputs, eight radii and five cardinal
angles. `NativeMotionReferenceTests` verifies these independently captured
outputs; `MotionBlurRasterTests` continues to check SIMD sampling, transparent
borders, fractional radii, regional rendering and distance calibration against
a scalar reference using Gaussian cumulative probabilities.

In the combined development worktree, all 19 selected component tests pass. Its
full qualification passes 203 XCTest cases, retains the same 18 golden issues in
1,044 parallel Swift Testing cases, and passes 48 serialized cases. CPU and AMD
application comparisons in that worktree both remain 146/173 with no passing case
lost. These application figures include other unpublished compatibility changes.
Only its five motion-blur PNGs change with this correction; the
default adjustment's maximum alpha error falls from one level to zero. The small
angled adjustment improves from 69 to 57 levels but still fails, so this weight
correction does not establish general angular resampling parity.

Two of the 93 generated golden candidates change; the other 91 are byte-identical.
All committed golden baselines remain unchanged. Logs, application reports and
the audited checkpoint use the `motion-pixel-area-` prefix under `.build/evidence/`.
The local monitor's stable checkpoint now records these results, including the
203 XCTest cases as well as the 1,092 Swift Testing cases.

The isolated motion-only patch, based on published commit `791defb`, separately
passes 196 XCTest cases, 1,044 parallel Swift Testing cases and 48 serialized
cases with no failures. Its native bridge is rebuilt from that checkout and
passes Vulkan execution and device-loss fallback. This verifies the published
correction independently of the other development-worktree changes.

## Angular motion and cropped preview sampling (local candidate)

Native graph diagnostics show a rotation in Core Image coordinates, a horizontal
Gaussian, then the inverse rotation. The source bitmap's vertical flip precedes
those rotations. The local motion graph now follows that order. At the original
rotation checkpoint, its 48 angular references improve from 12 to 46 passing
frames; the two remaining failures are
opaque gradients at radius `35 / sqrt(12)`, angles ±35°, with maximum errors of
two byte levels. The later pyramid qualification below resolves those two
failures. All 80 cardinal references continue to pass. No tolerance or
golden baseline changes.

Five additional native capture runs establish when motion omits its Gaussian:
the integrated off-center mass `erfc(0.5 / (radius * sqrt(2)))` is at most 0.003.
The shared-buffer fixture `coreimage-motion-small-radius-reference.json` retains
404 independently captured recipes around this boundary and the next kernel
transition. All 404 pass the unchanged one-level test. These recipes include
angled cases, where even a tiny surviving kernel prevents the inverse rotations
from cancelling. The capture workflow retains the original 164 recipe hashes.

Cropping a preview also changes the bitmap's local origin. Rotating that bitmap
at local zero changes the interpolation lattice. `regionSnapshot` now returns
its bottom-left origin in the full preview's pixel coordinates, and foreground
and background rendering pass it to the generated preview renderer. A scoped
`CISpatialSampling.origin` supplies that value during graph construction; each
motion node captures it immutably. Later evaluation does not depend on a caller's
scope. Saved project data and upstream macOS source are unchanged.

The six existing sampling-halo cases pass, including the previously failing
quarter-scale motion preview. New tests check captured-origin lifetime and
cropped foreground/background equality at three scales. The release Full HD
angled-motion check renders in about 240 ms on this host, below its 500 ms limit.
Focused logs use the `motion-origin-` prefix under `.build/evidence/`. That
checkpoint retains the two strict native failures resolved by the later pyramid
adapter; the port remains unpublished pending broader qualification.

At that checkpoint, full qualification executes 207 XCTest checks, 1,045 parallel
Swift Testing tests and 48 serialized tests. Only the two native motion assertions
and the same 18 golden issues remain. All 93 generated golden candidates are byte-identical
to the preceding angular-motion run. Both fresh CPU and AMD corpora remain
148/173, and every exported PNG is byte-identical to that preceding run. The
audited checkpoint is `.build/evidence/motion-origin-verification-summary.json`;
the live monitor reads the same results from its stable checkpoint. The original
four staged files and their exact cached patch remain unchanged.

## Native spatial scanline probes

`scripts/capture-coreimage-spatial.swift` captures opaque impulse, step and stripe
inputs at 16 pixel phases. Each source is 512 by 8 pixels with repeated rows and
clamped boundaries; a scanline at CI y=3 isolates the horizontal response.
The workflow `coreimage-spatial-reference.yml` validates source identities, the
complete recipe matrix, finite float components and both raw buffer hashes.
Its optional `motion_radii` input accepts at most 64 unique finite numbers in
0...64, passed as a quoted argument and decoded as numbers.

Native run `40184101796`, source `562c9f2`, captured 912 filtered recipes. Run
`40185274992`, source `75cd308`, expanded this to 3,216 recipes across 64 motion
radii, retaining all 960 original source/output hash pairs. The expanded artifact
has SHA-256 `0ab6c00bfb3d59c618081416e6c682dbe535298cc2d5c9fc248ff41012adc4b4`.
Its local audit is `.build/evidence/native-spatial-diagnostics-audit.json`.
The default native invocation is:

```bash
swift scripts/capture-coreimage-spatial.swift > coreimage-spatial-reference.json
```

These probes distinguish Gaussian and Motion Blur despite similar-looking graph
stages. At radius 17, phase 0, their normalized impulse variances are approximately
287.91 and 271.40 respectively. The motion graph's reduction and cubic upsampling
must therefore be considered separately from the Gaussian path.

For radius-4 impulse phases 0...3, a fitted cubic B-spline model's maximum float
error falls from 0.0395 to 0.00373 byte units when its linear texture fractions
round to 1/256 steps. The reduction taps and residual Gaussian still require
reconstruction and independent step/stripe validation. These fitted intermediates
remain diagnostic artifacts; production taps are unchanged.

The analytical full-resolution Gaussian model passes 720 of the initial 768
motion scanlines within one byte level. Its failures are 32 phase/input controls
at radius 4 (up to four levels) and 16 at radius 17 (two levels). Separate models
that quantize either or both angular affine samples still retain the two known
large-radius angular failures. The diagnostic captures do not change application
parity or replace any golden baseline.

`scripts/analyze-motion-reduction.py` now makes the fixed factor-four reduction
experiment reproducible. Four impulse phases at radius 4 fit symmetric taps
around the reduction's half-pixel center. It evaluates the other impulse phases,
independent step/stripe inputs, and a held-out radius-16.25 graph containing two
factor-four reductions. Native float and byte buffer hashes are checked before
comparison. The script records fitted coefficients and all per-case errors;
those coefficients are diagnostic, not production renderer parameters.

With cubic B-spline reconstruction and texture fractions rounded to 1/256, the
normalized fixed kernel passes all 48 radius-four scanlines and all 48 held-out
radius-16.25 scanlines within one byte. Maximum float errors, expressed in byte
units, are 0.460 and 0.730 respectively. Half-float reduction intermediates also
pass all 96, with maxima 0.454 and 0.745. The larger-radius cases participate in
neither fitting nor kernel selection. These results support composition of the
reduction stages, but do not establish the residual Gaussian, the factor-two
reduction, arbitrary radii, angular output or full-application parity. Production
motion code and all existing tolerances remain unchanged.

Reproduce with the dependencies from `scripts/parity-requirements.txt`:

```sh
OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 python3 scripts/analyze-motion-reduction.py \
  .build/evidence/coreimage-spatial-dense-native/coreimage-spatial-reference/coreimage-spatial-reference.json \
  --report .build/evidence/native-motion-reduction-identification.json
```

`scripts/analyze-motion-reduction2.py` extends the probe to the factor-two
stage. It fits four radius-three impulse phases using the residual-blur
parameters recorded in that native graph, then compares eight radii and all
three input families at 16 phases. The five symmetric coefficient pairs are
positive, with support at source indices -4 through 5. After normalization,
all 384 recipes compare within one byte for both full-float and half-float
intermediates. Seven radii participate in no coefficient fitting, including
`10.103629710818451`, the radius in the remaining angular failures. The smaller
eight-tap model retains failures (up to three levels), which remain in the
report alongside the successful models.

The residual parameters for each comparison come from its captured native graph;
this probe does not derive a general radius-to-residual algorithm. It therefore
does not establish arbitrary-radius or two-dimensional angular equivalence.
Neither probe changes production rendering or existing test thresholds.

### Transfer to two-dimensional angular motion

The diagnostic `probe-angular-motion-pyramid.py` under `.build/evidence/`
combines the two fitted reductions with the residual offset read from the
captured native graph at `35 / sqrt(12)`. It verifies that graph's factor-four
then factor-two stages, the 1/8 reconstruction scale and the scanline reports'
capture identities. Native byte and float output hashes are checked before
comparison. The two-dimensional gradient and impulse cases do not participate
in coefficient fitting.

On all 16 controls at that radius, the full-resolution model reproduces the
known 14/16 pass count and the two maximum-two-byte errors at ±35°. Both the
full-float and half-float pyramid models pass 16/16 within the unchanged
one-byte bound. For the two opaque gradients, the full-float model's maximum
errors against native float output fall from 1.351/1.389 byte units to
0.426/0.540. This identifies the missing reduction/reconstruction stages as a
supported cause of those failures; it does not derive a general residual-radius
rule or establish arbitrary-radius rendering. Production code and test
tolerances remain unchanged. Results and input hashes are recorded in
`.build/evidence/angular-motion-pyramid-probe.json`.

Reproduce using the existing local parity environment. This experiment used
NumPy 2.5.4 and SciPy 1.18.1; it has not been repeated with the versions pinned
in `scripts/parity-requirements.txt`:

```sh
OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 \
  /tmp/compositor-resident-parity-tools/bin/python \
  .build/evidence/probe-angular-motion-pyramid.py
```

```sh
OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 python3 scripts/analyze-motion-reduction2.py \
  .build/evidence/coreimage-spatial-dense-native/coreimage-spatial-reference/coreimage-spatial-reference.json \
  --reduction4-report .build/evidence/native-motion-reduction-identification.json \
  --report .build/evidence/native-motion-reduction2-identification.json
```

## Motion pyramid adapter qualification

The later discrete-variance experiment rejects a fixed continuous-sigma
subtraction rule: it passes only 2,478/2,640 scanlines, with failures near
reduction transitions. Solving the discrete Gaussian's second moment instead
passes 2,640/2,640, using calibrated removed variances of 4.5, 16, 83 and 264
for reduction scales 2, 4, 8 and 16. This model does not read residual offsets
from each captured graph. Its two-dimensional large-radius controls also pass
16/16 within one byte.

`Sources/Compat/CoreImage/MotionPyramid.swift` now implements that model with
explicit input-footprint planning and cubic reconstruction. The initial Swift
run reproduces 32 failures where a selector used factor two at radius 3.99;
native already uses factor four there. Correcting that measured transition
passes every native scanline. The precise boundary between 3.9 and 3.99 and
additional native levels above the radius-35 capture range remain unverified.

The unchanged angular/cardinal references and the new compressed native
scanlines pass in the actual adapter. Regional tests match full-frame pixels
at negative origins and five radii, including vertical and fractional-angle
motion. Full XCTest runs 228 tests with zero failures and one opt-in timing
skip. Parallel Swift Testing retains exactly the prior 18 golden assertions;
all 48 serialized tests pass. Both Linux backends agree on every decoded pixel,
numeric sample and ICC buffer in the 173-image export corpus. Native application
motion exports still have differences, so the adapter is not qualified as full
native-equivalent rendering. See `docs/upstream-7651033-integration.md` and
`.build/evidence/motion-pyramid-candidate.json` for results and remaining limits.

## Direct motion's byte-texture precision

`MotionKernel.swift` generates finite Gaussian tails and paired 1/256 texture
fractions for direct motion. Its 384-scanline float model has maximum error
0.01134 byte levels. The actual adapter's corresponding float regression rejects
the previous convolution and passes with these kernels; 96 held-out
two-dimensional controls also pass within one byte.

The remaining float differences identify another precision step. Rounding each
UNORM8 interpolated sample to 1/4080 with positive half ties upward lowers the
384-control model's maximum float error to 0.00002063 byte levels. A transparent
overlay model then reproduces the native default motion PNG exactly. This rule
is applied to known byte sources, with source-format provenance carried through
transparent graph operations. Explicit half/full-float inputs retain float
sampling even when every input value is exactly representable by a byte.

The separate C byte-sampling entry point preserves the original C row ABI.
Scalar/SIMD and source-format regressions pass, along with all native motion
references. Full qualification passes 232 XCTest cases with zero failures and
one opt-in timing skip; 1,062 parallel Swift tests retain the same 18 golden
assertions, and 48 serialized tests pass. Both Linux backends match on all 173
application exports. The default motion filter now compares within one byte to
the existing native capture; angular and extreme-motion application differences
remain. The latest-upstream native application capture is still pending.

Capture/model provenance and results are in
`.build/evidence/motion-direct-candidate.json`,
`.build/evidence/direct-motion-byte-sampling-probe.json` and
`.build/evidence/motion-byte-sampler-candidate.json`. See the integration report
for exact comparison scope and remaining requirements.

## Angular intermediate precision experiments

The source-format rule above does not establish the precision of affine or
convolution intermediates. Separate diagnostic models compare 36 captured
two-dimensional direct-motion controls at noncardinal angles, checking the
native float and byte output hashes before comparison. Every model remains
within one byte on these controls, so that byte bound cannot distinguish them.

The current float model has maximum float error 0.6313 byte levels and mean
absolute error 0.02434. Quantizing both affine sampling fractions to 1/256
changes those figures to 0.4430 and 0.02361. Byte quantization after convolution
worsens mean error to about 0.062. Nearest-half intermediates also fail to
identify a consistent precision rule.

Half conversion toward zero reduces average error: converting both
intermediates gives mean error 0.01293, but maximum error increases to 0.6341.
Combining that conversion with quantized affine fractions gives maximum 0.5954
and mean 0.01175. These results do not establish native intermediate storage or
arithmetic. In particular, the radius-35 capture's alpha near one half-float
step below one is only a clue; these controls use radii below three.

No renderer or tolerance changes follow from these experiments. Further work
needs controls that distinguish storage precision from sampling and arithmetic,
including explicit float sources and working formats. The diagnostic reports
are `.build/evidence/motion-affine-precision-probe.json`,
`motion-intermediate-precision-probe.json` and
`motion-rtz-intermediate-probe.json` in the same directory. They use the same
NumPy 2.5.4/SciPy 1.18.1 environment noted above and are exploratory models,
not additional qualification of the application renderer.

## Gaussian graph branches and reduction transfer

A follow-up tests whether the independently identified motion reductions can
replace the remaining radius-10 Gaussian approximation. The captured Gaussian
graph lists factor-four and factor-two reductions, a residual offset of
0.26353 and cubic reconstruction at scale 1/8. Using that captured offset with
the motion reduction taps, without fitting against Gaussian output, passes only
12/24 radius-10 controls in each native working format. Both float and half
intermediate models retain maximum three-level errors. This rejects that direct
transfer as a production correction; neither renderer nor tolerance changes.

An audit of 144 paired Gaussian/motion scanlines checks all raw byte and float
hashes. Gaussian graphs include a `CIBlurProcessor` alternative, while the motion
graphs do not. Identical listed horizontal residual parameters therefore cannot
establish that the same path produced the captured pixels. For phase-zero
impulses, normalized red-channel variances are:

| Radius | Native Gaussian | Native motion |
|---|---:|---:|
| 5 | 24.66354 | 24.02250 |
| 10 | 99.63170 | 97.10394 |
| 17 | 287.90886 | 271.39986 |

The alternative's presence does not prove it was selected. Further replacement
work needs evidence that distinguishes the actual Gaussian rendering branch;
the graph text alone is insufficient. The failed transfer and paired-output
audit are recorded in `.build/evidence/gaussian-pyramid-transfer-probe.json`
and `gaussian-motion-graph-route-comparison.json` in the same directory. They
use the local NumPy/SciPy versions documented above and remain diagnostics.

## Native font coverage and rejected text models

The eighteen native font controls from run `40111031733` retain the current
bundled Inter font hashes. Their ninety bitmap hashes validate. Default
transparent white text has exactly the same alpha as white-on-black RGB in
every control. Disabling font smoothing changes more than a pointwise alpha
curve: pixels with zero unsmoothed alpha reach 97–163/255 when smoothed, and
many identical unsmoothed values map to different smoothed values.

The paired opaque draws also reject a common geometric mask under a simple
transfer curve. Linear, sRGB and power curves retain maximum 127-level errors.
A gamma fitted only to Regular 24 (approximately 1.45254) also fails every
control, including the other seventeen held-out face/size combinations.
These measurements do not establish the renderer's internal smoothing rule.

A separate Qt outline probe preserves the bundled fonts and shapes in a
larger coordinate space, then tests fixed stroke widths of 0–4% of the font
size. No fixed width qualifies the controls. At 3% and 4%, only one of eighteen
default controls meets the corpus's 0.97 glyph-overlap requirement; the other
widths meet it in none. The probe needed `-fPIC` to avoid a standalone Qt
offscreen-initialization crash. No application build flags or rendering code
were changed by that diagnostic correction.

Three hypotheses—pointwise alpha conversion, a shared mask with a transfer
curve, and this outline/stroke model—were rejected. Text tuning stops here
pending direction rather than applying an unqualified approximation. Per-glyph
native positions and outlines would help separate placement from rasterization
in a future capture. Existing nine text corpus failures remain failures.

Reports are `.build/evidence/native-text-coverage-audit.json`,
`native-font-compositing-probe.json` and `native-font-outline-probe.json` in
the same directory. No font, text renderer or comparison bound changed.
