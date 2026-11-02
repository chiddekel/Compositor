# Camera RAW decoding on GNU/Linux

The `CIRAWFilter` adapter hands LibRaw's developed sensor data to the shared
upstream `RawImporter`. Full imports retain RGBA16 samples until Core Image
renders the requested layer format. Eight-bit imports therefore reach upstream's
existing sixteen-bit render and dither stage without an earlier byte truncation.

The previous decoder always returned RGBA8, including for sixteen-bit imports.
A synthetic ramp with 512 sensor levels produced a sixteen-bit image containing
only 187 distinct red levels. The regression now requires more than 256 levels
at full resolution and after non-draft half-size scaling. Both paths pass with
the higher-precision decoder.

## Decoder interface

`compositor_raw_register_v2` extends the existing registration with an optional
`compositor_raw_develop16` callback. It returns opaque, native-endian RGBA16 in
packed top-down rows. The caller owns the returned allocation. Swift transfers
it to `Data` with a freeing deallocator and tags the image with the matching
sixteen-bit byte order, avoiding a second full-frame copy.

The original RGBA8 callback remains available. Legacy registrations clear the
optional wide callback, and each handle keeps its own decode/close functions.
Existing eight-bit providers retain their previous behavior. The bundled decoder
registers both precisions. Full develops use one common LibRaw pipeline, with
typed RGB-to-RGBA packing and a sixteen-bit scaling path.

Draft previews retain the existing cached RGBA8 path. The native RAW/lens smoke
test produces identical before/after results for full and draft vignette/warp
correction and the lensfun profile. Exposure, white balance, boost, noise and
highlight-recovery controls retain the existing processing rules. This change
does not establish matching Apple's default RAW tone interpretation; the five
native RAW color comparisons remain a separate investigation.

## Verification

`scripts/raw-precision-input.py <output.dng>` writes the deterministic test ramp
using Python's standard library. Its DNG metadata helper is shared with
`parity-inputs.py`; all five existing canonical sensor DNGs remain byte-identical.

The `RawPrecisionTests` suite runs in a separate test process with
`COMPOSITOR_RAW_PRECISION_INPUT` pointing to that generated file. It initializes
the real host decoder and exercises `RawImporter.develop(..., sixteenBit: true)`
and non-draft `CIRAWFilter` scaling. The separate process keeps Qt initialization
out of the ordinary golden-image test environment. The Linux workflow includes
this dedicated precision step after its existing contract checks.

Local evidence is under `.build/evidence/`: `raw-precision-before-fix.log`,
`raw-precision-after-fix.log` and `raw-precision-legacy-{before,after}.log`.

A separate checkout of published `4a6f894`, with only these RAW changes applied,
passes six precision/capability tests and 44 deep-layer/dither/golden tests.
All 93 decoded golden images are identical to their committed baselines, and
the native RAW/lens smoke passes. The complete CPU application corpus changes
only the five RAW images, by at most one byte; all other 168 images and all
existing golden candidates are unchanged. Native comparison remains 141/173
in the combined local renderer candidate, with the five RAW color gates still
unresolved. See `raw16-isolated-verification.json` and
`raw16-rendering-change-summary.json` for the independent and combined checks.

## Native tone diagnostics

The manual `raw-reference.yml` workflow captures Apple's decoder defaults and
seven explicit boost/exposure recipes for each of the five canonical DNGs and
the independent precision ramp. Every recipe uses a fresh `CIRAWFilter` and the
same half-float, extended-linear-sRGB working context as upstream `RawImporter`.
It retains an interior row as float linear sRGB, float encoded sRGB, and sixteen-bit
encoded sRGB. Raw samples, input hashes, decoder settings and buffer hashes remain
in the artifact; no averaging or curve fitting changes the captured values.

`scripts/validate-raw-reference.py` checks all six source hashes, 48 recipes and
144 buffers before upload. These diagnostic controls help distinguish Apple's
boost interpretation from color conversion and integer quantization. They do
not replace the full application corpus or establish a matching Linux tone curve.

Run `40148712057` at `7257c48` successfully captured and validated all controls on
macOS 26.6.2. On the precision ramp, Apple's -1 EV / 0 EV median linear-light
ratio is about 0.499 at zero boost and 0.519 at full boost. The original Linux
full-boost results differed by at most six sixteen-bit sample values across all
six inputs: auto-brightening almost entirely canceled the negative exposure.

## Exposure and automatic brightness

Full decoding now applies exposure through LibRaw's output brightness, after its
histogram chooses the white level and before the gamma curve. Its earlier sensor
exposure correction is disabled. Draft decoding likewise measures the white
level before applying the exposure multiplier. The LibRaw preview fallback resets
output brightness to one before caching its linear samples, so a prior full
develop cannot bake its exposure into later previews. Both paths support the Develop
sheet's full -3...3 EV range; the previous lower multiplier limit made -3 EV
identical to -2 EV.

The precision suite checks that each negative stop darkens the ramp at both boost
endpoints, in full and draft decoding, and that positive exposure brightens it.
The original decoder fails eight assertions. A separate same-handle full-to-draft
test catches nonzero exposure leaking into a rebuilt LibRaw preview; both exposure
directions pass after the brightness reset. The corrected decoder passes all
eight precision/capability tests. This fixes the exposure control; matching
Apple's complete default tone curve remains separate work.

An isolated checkout with only the exposure fix passes 1,092 Swift tests in 192
suites and 180 XCTest dispatches, plus the eight dedicated RAW tests. All 93
tested golden images match the committed baselines exactly; the native RAW/lens
smoke log is unchanged. In the combined renderer checkout, all 173 canonical
images and 93 golden candidates are unchanged. Evidence is recorded in
`raw-exposure-final-isolated-verification.json` and
`raw-exposure-final-rendering-preservation.json` under `.build/evidence/`.

## Calibrated as-shot temperature and tint

Single-illuminant, three-channel DNGs now derive their displayed as-shot white
point from `AnalogBalance * CameraCalibration * ColorMatrix` and
`AsShotNeutral`. `host/RawWhitePoint.h` solves for XYZ, converts to CIE 1960 uv,
and interpolates Robertson's isotemperature lines to obtain temperature and
tint. Matrix solving and white-point conversion are separate from the LibRaw
adapter and pixel processing. The numerical table is from Wyszecki & Stiles,
*Color Science*, second edition, page 228, cross-checked against the
[published Robertson table](https://github.com/colour-science/colour/blob/e82dd140c02d66a174072281e667d595ac5b6951/colour/temperature/robertson1968.py); the conversion convention is also
described by the [published DNG SDK implementation](https://github.com/gopro/gpr/blob/446c736a38fb14f51343605c0780d347dc602f89/source/lib/dng_sdk/dng_temperature.cpp).

The real decoder previously reported 4484.90 K / +5.1457 for the canonical
identity-calibrated DNG. The independently captured native defaults are
5454.0088 K / -12.993514. The corrected calculation reports 5454.0278 K /
-12.993524, within 0.02 K and 0.00001 tint. The original decoder fails the same
regression; the corrected decoder and the actual Swift importer pass it.
The six captured inputs share this calibration, so this is not six independent
camera-profile validations.

LibRaw 0.22.2 retains the relevant DNG arrays with `parsedfields == 0` for these
files. Detection therefore validates the arrays rather than requiring those
presence bits. Its absent calibration array is zero-filled and is treated as
identity; analog balance defaults to one. Singular/nonfinite matrices and
nonphysical neutral values retain the gain-based fallback. Dual-illuminant
profiles also retain that fallback until matrix interpolation is implemented.
Non-DNG and four-channel cameras keep their existing metadata calculation.

As-shot multipliers and the full/draft processing rules are unchanged. Actual
before/after decoder comparisons preserve every full-resolution RGBA16 and
half-size draft RGBA8 byte for the five canonical DNGs and the precision ramp.
This corrects the displayed controls' starting point; it does not resolve the
five native RAW tone/color comparisons or establish native temperature-slider
response away from as-shot values.

C++ checks cover the native equal-energy white point, D65, calibration and
scale invariance, pivoting, and invalid profiles. The focused Swift run passes
all nine RAW precision/capability tests. Evidence uses the `raw-neutral-`
prefix under `.build/evidence/`.

Full qualification passes 232 XCTest cases (one opt-in timing skip) and all
48 serialized Swift tests. The 1,063-test parallel Swift run retains exactly
the preceding 12 golden assertions, with unchanged affected-channel counts
and maximum differences. All 173 exports preserve decoded pixels, numeric
samples and ICC buffers against the preceding CPU checkpoint; current CPU and
Vulkan exports also match on every one of those buffers. Separate real-decoder
checks confirm identical old/new fallback metadata for dual-illuminant and
singular DNGs. The upstream guard, strict C++ compilation and diff checks pass.

## Pending native white-balance controls

The existing native RAW artifact keeps temperature and tint at as-shot defaults
in every recipe. It cannot validate the Linux temperature/tint response, which
still uses relative channel-gain approximations. No change to those production
formulas is justified by the as-shot metadata correction alone.

`scripts/capture-raw-reference.swift --white-balance` now optionally adds four
independent controls at both zero and full boost: 3000 K, 8000 K, tint -50 and
tint +50. Exposure is zero; the other white-balance control retains its native
as-shot value. Every recipe uses a fresh decoder, with the same working context,
interior scanline and three output buffers as the original tone capture. This
produces schema 2 with 96 recipes and 288 buffers across the six inputs.
The original invocation still produces schema 1 with 48 recipes and 144 buffers.

The manual `raw-reference.yml` workflow exposes an optional `white_balance`
input, disabled by default. The validator checks the exact changed and unchanged
controls, complete recipe coverage, input hashes and output hashes for either
schema. Five local regression tests pass, including refusal of mislabeled or
missing controls and corrupt input/output hashes. The existing native artifact
still validates unchanged. Swift's macOS-target parser, YAML loading, all three
workflow shell syntax checks and Python compilation pass. macOS SDK type checking
and native execution of the new recipes have not run. This preparation does not
establish white-balance parity or alter the five unresolved RAW comparisons.
