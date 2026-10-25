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
tone correction resolves the upstream faint-flare assertion. The application corpus passes 137/173 comparisons,
including all nine format-18 adjustment cases. An AMD Vulkan run passes all 186 XCTest cases, 48 serial Swift
tests and nine native adjustment journeys; the 1,038-test parallel run reports only 12 proposed golden changes.
Native run `40131936749` validates all 358 cases and 720 buffers, preserving the preceding 334 outputs.
Its interior requests differ from cropping a full render by up to 0.7471 byte units, identically with both cache
policies. The regional regression checks native byte output within one level and tile-versus-full float
differences within `1/1024`; it passes in both CPU and AMD Vulkan configurations and resolves the tile review.
Existing golden baselines and application comparison thresholds are unchanged.

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
