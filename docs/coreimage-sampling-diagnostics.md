# Core Image sampling diagnostics

The manual `coreimage-reference.yml` workflow runs the native macOS capture with an unmanaged Core Image
context. It validates 306 cases and 616 byte/float buffers, including SHA-256 checks, dimensions, finite float
values and unique recipe metadata. The artifact contains synthetic pixels only.

The capture includes direct Gaussian, motion, masked blur and Lanczos controls, scale–blur–inverse-scale
compositions, affine translations and materialized impulse phases. Extent metadata records finite, infinite
and null bounds without serializing nonfinite JSON numbers. Eight translated Gaussian cases expose blurred
pixels crossing the original input boundary. Thirty-two additional affine cases isolate unpremultiplication,
alpha replacement and the sRGB transfer function from the complete preparation chain.

These controls investigate two unresolved compatibility behaviors: sampling a blurred scaled intermediate
and sampling through pointwise color operations. They do not establish a replacement algorithm by themselves.
Compare the original 266 recipes with the preceding capture from run `40125848219`, matching recipe parameters
while excluding newly added extent metadata, and require unchanged byte and float hashes.

The production Lanczos candidate remains local. Its direct reference tests pass, but broad testing exposes
an additional upstream faint-flare assertion, and the application corpus still passes 135/173 comparisons.
Existing golden baselines and application comparison thresholds are unchanged.
