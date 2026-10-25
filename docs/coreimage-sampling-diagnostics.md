# Core Image sampling diagnostics

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

All 19 selected component tests pass. The full qualification passes 203 XCTest
cases, retains the same 18 golden issues in 1,044 parallel Swift Testing cases,
and passes 48 serialized cases. CPU and AMD application comparisons both remain
146/173 with no passing case lost. Only their five motion-blur PNGs change; the
default adjustment's maximum alpha error falls from one level to zero. The small
angled adjustment improves from 69 to 57 levels but still fails, so this weight
correction does not establish general angular resampling parity.

Two of the 93 generated golden candidates change; the other 91 are byte-identical.
All committed golden baselines remain unchanged. Logs, application reports and
the audited checkpoint use the `motion-pixel-area-` prefix under `.build/evidence/`.
The local monitor's stable checkpoint now records these results, including the
203 XCTest cases as well as the 1,092 Swift Testing cases.
