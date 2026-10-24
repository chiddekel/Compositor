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
The Gaussian tile-sampling rule remains under review until the regional probes establish native behavior.
Existing golden baselines and application comparison thresholds are unchanged.
