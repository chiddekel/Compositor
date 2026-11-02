# Independent macOS pixel equivalence

Target application revision: upstream `2d75d9172835e1dd6111cb2b659958ec33fa5abf`
(1.5.10). The initial Linux source checkpoint is `73df482`.

The goal is exact rendered pixel equivalence across the complete checked-in
178-image corpus. Existing perceptual thresholds remain useful diagnostics,
but passing them does not establish exact equivalence. No reference image,
capture provenance or threshold is changed to make a candidate pass.

## Independent reference

GitHub Actions run [40288248415](https://github.com/chiddekel/Compositor/actions/runs/40288248415)
builds the unmodified upstream application in a disposable macOS checkout and
injects the shared `RenderParityTests.swift` corpus. The Mac job uses native
AppKit, Core Graphics, Core Image, Metal and RAW decoding. It does not compile
the Linux compatibility libraries. The Mac job completed successfully on
macOS 26.6.2 arm64 with Swift 6.3.3; its corpus test passed with no skips or
failures. All 178 reference images were downloaded, and their manifest's
upstream, input and corpus identifiers match both Linux candidates.

Both platforms consume the same downloaded `parity-inputs` artifact. Its tree
SHA-256 is `fefba214b8b3c35fdb819f573b86bf1b4de3cc32ec60dd7c712c2bc5f8fc5b38`.
The shared corpus SHA-256 is
`ee5004f45175d4bd63a204405a2064b2a1308bc7c063b5e1613ce52f51260088`.
Older Linux exports are not reused: the fresh artifact's `p3.png` differs from
the previous input set. Fresh Linux CPU and Vulkan exports both exit zero and
account for all 178 cases under `.build/evidence/macos-equivalence-73df482/`.

## Exact gate

`scripts/compare-render-parity.py --require-exact` retains all provenance,
checksum, completeness and perceptual checks and additionally rejects any
visible pixel or recorded deep numeric sample difference. Reports distinguish
exact counts from tolerance results, including per-case equality and changed
pixel counts. Exact pixels are color-managed sRGB premultiplied RGBA8 values;
two deep color cases additionally compare every recorded higher-precision
sample. PNG file encoding and hidden RGB beneath zero alpha are not compared.

The nine comparator tests pass, including a one-channel-level change that
passes perceptual limits but fails exact comparison, and a 16-bit sample change
that leaves its PNG unchanged but fails exact sample comparison. The workflow
now requests this exact gate. These comparator tests validate measurement;
they do not establish that Linux matches macOS.

## Coverage and remaining work

The corpus contains 55 adjustment, 48 blend, 40 filter, nine text, six effect,
six transform, five color, five RAW, three shape and one export case. It is a
finite regression matrix, not proof for every possible project or parameter.
Every case has now been compared against the fresh independent Mac output.
The initial comparison, before the Sharpen correction, is:

| Category | Cases | Exact images and deep samples | Within existing limits |
| --- | ---: | ---: | ---: |
| Adjustment | 55 | 32 | 49 |
| Blend | 48 | 31 | 48 |
| Color | 5 | 1 | 5 |
| Effect | 6 | 5 | 6 |
| Export | 1 | 1 | 1 |
| Filter | 40 | 2 | 38 |
| RAW | 5 | 0 | 0 |
| Shape | 3 | 0 | 3 |
| Text | 9 | 0 | 0 |
| Transform | 6 | 2 | 6 |
| Total | 178 | 74 | 156 |

CPU and Vulkan have identical results. One of the two deep color cases has
identical numeric samples. Twenty-two cases exceed even the existing limits:
five Sharpen, five RAW, nine text, two RGB Split adjustments and Gaussian Blur's
default adjustment alpha. The reports and difference images are under
`.build/evidence/macos-equivalence-73df482/diff-{cpu,vulkan}`; `status.json`
records their hashes and the native environment.

## Sharpen alpha diagnosis

The five new Sharpen cases fail with errors up to 128 byte levels. An isolated
probe reproduces the opaque-gradient and translucent-overlay inputs and tests
blur-alpha normalization independently of the application implementation.
Normalizing the blurred straight color before adding detail reduces the
maximum difference to one level in all four distinct recipes; the default and
extreme overlay recipes have identical Sharpen settings. Without normalization,
missing blur coverage is incorrectly added back as bright color detail.

The compatibility correction and a constant-color/variable-coverage regression
pass four focused XCTest checks and 24 Swift tests. Five original native application results, with PNG and
decoded-pixel hashes, are retained in
`Tests/Fixtures/coreimage-unsharp-application-reference.json`. A new application
regression uses those independent captures and passes within one premultiplied
RGBA8 byte. Fresh CPU/Vulkan exports preserve decoded pixels and ICC data for
all 173 unrelated images. All five Sharpen cases now pass the existing limits,
raising the total to 161/178 on both backends. Exact image matches remain
74/178: the three opaque Sharpen exports still differ by up to one byte, and
the two translucent exports retain a maximum premultiplied channel difference
of 1.2549 levels after straight-PNG quantization. This is not exact equivalence.

Sixteen models of half-float source/intermediate/result rounding were also
tested independently; none establishes exact output across the distinct recipes.
No such precision model was applied to production. The two affected Linux
goldens were visually reviewed, checked for CPU/Vulkan equality and backed up
before recording the native-validated boundary correction. The complete Release
framework rerun passes 238 XCTest checks (one skip), 1,073 parallel Swift tests
and 48 serialized tests with zero failures. All three command exits are zero in
`sharpen-full-validation.exit`. Evidence uses the `sharpen-` and `diff-sharpen-`
prefixes under the same evidence directory.

## Native precision controls

The test-only branch `verify/macos-unsharp-20261026` adds an independent
standalone Swift capture, without building the Linux adapter or changing the
upstream application. Native run
[40292638801](https://github.com/chiddekel/Compositor/actions/runs/40292638801)
passes its validator with six source controls and 180 filter cases. The extended
run [40293933066](https://github.com/chiddekel/Compositor/actions/runs/40293933066),
at `9c5b1d3`, also passes: eight source controls and 240 cases add an impulse
input. The matrix covers opaque byte gradients, translucent byte gradients,
floating-point HDR/negative colors and impulses; radii 1, 2 and 5; intensities
0, 0.5, 1 and 2; explicit RGBAh/RGBAf working formats; and finite/clamped inputs.
Four local validator tests reject missing/duplicate recipes, altered provenance,
rehashed wrong sources, nonfinite/empty outputs and broken identity controls.

The captures retain raw float and byte buffers, hashes, procedural source bytes,
native graph descriptions, script hashes, OS and Metal-device metadata. Using
the captured Gaussian buffers to predict unclamped Sharpen verifies the
alpha-normalization arithmetic within `4.76837158203125e-7` in both native
working formats. The same transfer fails on the clamped path (maximum
`0.011785268783569336`), establishing a separate boundary/processing issue.
Simple nearest-half or toward-zero conversions alone do not explain the matrix.

At radius one, the listed native convolution coefficients match pixel-area
Gaussian weights with omitted tail mass distributed uniformly over all seven
taps. The adapter at the initial checkpoint folds those tails into its two end taps.
Larger-radius impulse responses also expose pass asymmetry and intermediate
precision. These measurements guide further kernel work; graph descriptions
alone do not establish which alternative processor rendered a case, and the
new controls do not qualify exact application pixels.

Artifacts and arithmetic probes are in
`.build/evidence/native-unsharp-precision-{783c3c9,9c5b1d3}/`. The extended
capture's `review.json` records its hash and checks the preceding native output
buffers for changes. The application's qualified comparison remains 74/178
exact and 161/178 within existing limits.

The expanded native run
[40298237277](https://github.com/chiddekel/Compositor/actions/runs/40298237277),
at `ce1468f`, succeeds with eight controls and 1,200 cases. It adds radii
0.1 through 1.2 around small-kernel transitions. The independently evaluated
five/seven-tap half-float model matches all 36,864 components at radii 0.5,
1 and 1.1 exactly: source reads truncate toward zero, coefficients round to
nearest binary16, and ascending horizontal then vertical taps accumulate with
one binary16 rounding per fused multiply-add. The support rounds `3 * radius`
to the nearest integer. Full-float controls differ by at most `4.76837158203125e-7`.
The extracted regression fixture retains 48 native buffers, source snapshots
and capture provenance. These are kernel measurements, not a qualification of
the application exports.

An intermediate full-float tail correction worsened the smaller Gaussian
application case from 56 to 121 differing pixels, with the same maximum error;
the other 177 application images stayed unchanged. Its `linux-convolution-*`
and `diff-convolution-*` exports are diagnostic candidates. It is not a
qualified improvement, and no Gaussian goldens were updated.

The binary16 kernel passes all 48 captured cases, with exact equality for the
half-float controls; the public context test verifies explicit half/full and
default precision using native impulse outputs. Nine focused XCTest checks and
the native Sharpen Swift check pass. Working precision propagates through CPU
fallbacks and participates in shared render-cache keys.

Fresh `linux-half-convolution-*` application exports and
`diff-half-convolution-*` strict comparisons remain 74/178 exact and 161/178
within existing limits on both backends. Their per-image metrics are identical.
Six cases change: the smaller Gaussian case improves from 56 to 45 differing
pixels; Lens Effects and Sharpen show small changes in both directions. No
additional application image becomes exact. The complete Release regression
rerun passes 240 XCTest checks (one skip), 1,073 parallel Swift tests and 48
serialized Swift tests, with zero failures. All three command exits are zero in
`half-convolution-full-validation.exit`. No Gaussian goldens were updated. The new native evidence is in
`.build/evidence/native-unsharp-precision-ce1468f/`.

## Axis and source-format controls

Native diagnostic run
[40302371104](https://github.com/chiddekel/Compositor/actions/runs/40302371104)
at `6fa71d7` adds horizontal/vertical byte stripes and a float-source impulse:
14 source controls and 2,100 cases pass the native validator. Its companion
[macOS application build/tests](https://github.com/chiddekel/Compositor/actions/runs/40302371115)
also succeeds. All 1,208 preceding input/filter float and byte output buffers
retain their recorded hashes, checked independently after download.

The larger Gaussian impulse responses are symmetric about each axis, but the
horizontal and vertical responses differ and are not exactly separable in
either working format. At radii 1.2 and 2, byte and float impulses produce
identical outputs. A direct paired-tap interpolation model, including source,
sample, coefficient, accumulator and intermediate precision variants, still
misses native stripe/impulse values. It is diagnostic, not an implementation.

Compact kernels below radius 0.5 use four bilinear samples at offsets
`(+/-a, +/-a)`, each weighted by 0.25, where
`a = erfc(0.5 / (radius * sqrt(2)))`. Sampling fractions round to a 1/256 grid;
byte texture samples additionally quantize to 1/4080. A zero rounded offset is
an identity. Source storage matters: finite inputs retain byte/float source
precision, whereas clamping introduces working-format-dependent sampling.
For example, radius 0.3's finite byte impulse has center alpha
`0.8213235139846802` in both working formats; clamping with RGBAf changes it to
`0.8212890625` despite identical mathematical border pixels.

Separating those paths explains 234 compact controls (359,424 components) with
maximum difference `2.384185791015625e-7`. The excluded paths are the 18
clamped, half-working-format controls with floating-point sources. For HDR on
that path, source truncation plus nearest-half interpolation explains most
values; a midpoint rule reduces the remaining discrepancies to 63 of 13,824
components, with maximum difference `0.000244140625`. That rule is not yet
qualified, and no compact or larger-kernel change was applied at that stage.
The next investigation must isolate texture sampling from blur arithmetic.

The capture, reproducibility review, stripe measurements and arithmetic probes
are in `.build/evidence/native-unsharp-precision-6fa71d7/`. These new controls
do not change the application qualification: 74/178 exact, 161/178 within
existing limits. The full original corpus remains the completion gate.

## Compact implementation and direct Metal controls

The compact byte/full-float sampler is now implemented in `CIRaster.swift` and
selected from source storage in `CoreImage.swift`. The extracted fixture
`coreimage-gaussian-compact-reference.json` contains 234 native controls and
explicitly records the 18 unqualified clamped-half float-source controls. Those
paths retain the prior implementation. Integer crops/transforms retain source
sampling; clamping a byte source in a full-float working context selects float
sampling. Finite Gaussian extents now use the native compact support and the
measured five/seven-tap support; a rounded zero offset is an identity.

The new low-level and public context tests pass alongside existing blur and
Sharpen tests: 11 focused XCTest checks and one Swift check. The complete
Release rerun passes 242 XCTest checks (one skip), 1,073 parallel Swift tests
and 48 serialized Swift tests, all with zero failures. Every command exit is
zero in `compact-full-validation.exit`. The 178 fresh CPU/Vulkan exports retain
identical decoded pixels and ICC profiles, both between backends and against
the previous qualified half-Gaussian exports. Strict comparison remains 74/178
exact and 161/178 within existing limits. Evidence uses `linux-compact-*`,
`diff-compact-*` and `compact-export-review.json` under the application evidence
directory. No goldens changed for this correction.

Native diagnostic runs
[40305278984](https://github.com/chiddekel/Compositor/actions/runs/40305278984),
[40306740217](https://github.com/chiddekel/Compositor/actions/runs/40306740217) and
[40307286103](https://github.com/chiddekel/Compositor/actions/runs/40307286103)
isolate Metal texture storage, sampler result type, clamp addressing and
fractional offsets. The latest run at `fe9238c` validates 12 texture sources
and 672 sample/four-sample recipes. It reproduces all 2,114 preceding Core
Image input/filter outputs and all 480 preceding direct Metal samples without
changing their recorded hashes. Three validator tests check matrix completeness,
source storage/provenance and point identities, including rejection controls.

Direct float sampling of byte textures matches the 1/4080 model exactly across
92,160 tested components. Half-return sampling additionally rounds to nearest
binary16 and also matches all 92,160 byte-texture components. GPU writes from
float to half textures truncate toward zero: all 4,608 recorded components
match that conversion, including 510 values distinguishing it from nearest-even.
Half-texture interpolation itself is not fully explained by nearest-half
rounding: the original sampler matrix retains 92 mismatches per 92,160
components for that simple model. A direct four-sample Metal kernel matches
byte/full-float Core Image controls to float-rounding accuracy, but still differs
from the clamped half-HDR controls by up to `0.000244140625`.

The revised larger-kernel probes fit the stripe data better with vertical then
horizontal passes, a truncating half store between passes and half-texture
sampling in the second pass. This remains an unqualified model, not proof of
the selected internal processor or a production change. The next investigation
must identify the actual intermediate textures and shader arithmetic rather
than treating a graph description's alternative branch as execution evidence.

Direct Metal captures, reproducibility reviews and compact comparisons are in
`.build/evidence/native-unsharp-precision-{08254df,0f33997,fe9238c}/`.

## Native execution captures and byte conversion

Native run
[40310521256](https://github.com/chiddekel/Compositor/actions/runs/40310521256)
at `3960348` captures three GPU trace documents: clamped half-HDR compact blur,
radius-2 full-float blur and radius-5 half-float blur. All captured float and
byte outputs match their native reference hashes. The finalized inventory
verifies every trace member. Two earlier attempts captured matching pixels but
failed the complete-inventory check because an IOSurface appears at process
teardown. A separate finalizer now runs after the Swift process exits, binds
its receipt to the original report and hashes the complete artifact. Four
validator tests cover output identity, missing/tampered members, unsupported
capture capability and late-file receipt binding.

Python binary parsing and LLVM 22.1.0 decode the captured Metal AIR libraries;
REA identifies the artifact but its native plist decoder requires macOS.
The radius-2 capture contains `F13H`/`F13V` MPS pipeline descriptors. The radius-5
capture additionally contains `D2F6H`/`D2F6V` reduction and `U2P3F3H`/`U2P3F3V`
upsampling descriptors. The recovered AIR expresses paired neighboring taps
and grouped Float32 arithmetic with fast-math flags. These observations do not
yet qualify a CPU implementation of those shaders.

The compact HDR source occupies a 26-by-18 padded region of a 64-by-64 half
texture. All 1,872 relevant components, including the edge padding, match
toward-zero conversion of the independently captured float input. The actual
radius-0.3 offset is Float32 bits `0x3dc3bfb7`. Run
[40312765815](https://github.com/chiddekel/Compositor/actions/runs/40312765815)
at `b498bf4` validates 768 direct sampler/compact recipes including that original
coordinate. Original and quantized coordinates produce the same HDR result at
that radius; the direct Metal result matches Core Image exactly there. Smaller
half-HDR compact radii still have unresolved differences.

A separate check compares every native float component with its captured byte
output after clipping RGB to alpha and channels to the unit interval. Scaling
the Float32 value in Double before byte rounding matches all 3,247,104 recorded
components; scaling in Float32 disagrees on 332 components by one byte level.
Those observations contain five distinct midpoint-side counterexamples. The
extracted `coreimage-rgba8-quantization-reference.json` records their exact
Float32 bits, native bytes, source observations and capture provenance, plus
zero/half/one boundaries.

`CIContext` now preserves the sample's side of the midpoint when converting
RGBA, alpha and grayscale components to bytes. The scalar native-fixture and
public RGBA8/A8 tests pass. Thirteen focused XCTest checks and the native
Sharpen Swift check pass; the complete Release suite passes 244 XCTest checks
(one skip), 1,073 parallel Swift tests and 48 serialized Swift tests, with zero
failures. All exits are zero in `byte-quantization-full-validation.exit`.
Every one of the 178 application PNGs retains decoded pixels and ICC profiles
from the preceding checkpoint, and CPU/Vulkan exports are identical. Strict
application comparison remains 74/178 exact and 161/178 within existing limits;
the byte-conversion correction gains no exact application case in this corpus.

Application evidence uses `linux-byte-quantization-*`,
`diff-byte-quantization-*` and `byte-quantization-export-review.json` under the
same application evidence directory. Execution evidence is under
`.build/evidence/native-unsharp-precision-{3960348,b498bf4}/`. During analysis,
the home filesystem filled and interrupted one artifact download. Completed
GPU evidence and the verified replacement download were preserved under
`/tmp/compositor-native-gpu-evidence-9mye25dg/` with SHA-verified relocation
receipts; symlinks retain their original evidence paths. The failed partial
download is preserved separately and is not used as the validated reference.

Full equivalence remains unproved. The current independent comparison confirms
unresolved text, RAW, blur, RGB Split and Sharpen differences. Earlier captures
remain diagnostic evidence and cannot replace the current reference.
CPU/Vulkan agreement alone is not a macOS comparison. The CPU Core Image
setting also retains the separate hardware dispersion driver.

## RGB Split byte texture interpolation

Native run [40318276957](https://github.com/chiddekel/Compositor/actions/runs/40318276957),
at `1b05dad`, executes the unchanged upstream dispersion shader on the corpus's
96-by-72 opaque and translucent gradients. Its 16 recipes cover angles zero
and 35 degrees with UNORM8, nearest-half, truncated-half and full-float input
storage. Eight source buffers, every parameter field, float/byte readbacks,
shader/script hashes and the native hash observer are retained and validated.
The observer is byte-identical to the earlier native observer over the shared
coordinates. The companion Mac build, unit and screenshot run
[40318277100](https://github.com/chiddekel/Compositor/actions/runs/40318277100)
also succeeds. The first attempt, `40318097823`, rendered successfully but its
validator incorrectly required 72 field bytes: Swift's fields occupy 68 bytes
in a structure with a 72-byte aligned stride. The corrected report records and
validates both values. Four validator tests cover missing/duplicate recipes,
rehashed wrong inputs, altered parameters, nonfinite outputs and provenance.

An isolated replay reproduces the default adjustment's 27-byte maximum error.
Substituting native jitter reduces that maximum to one byte. That is diagnostic
substitution only; production does not use captured jitter. Independently,
interpolating original integer bytes with eight fractional coordinate bits and
four fractional byte bits removes most smaller sampling errors. Recovering the
byte integers before interpolation matters: interpolating their binary32
representations can round an exact midpoint on the wrong side. With native
jitter held fixed, the four byte-texture recipes' mean float errors fall from
roughly `1e-5` to roughly `2e-8`; a few coordinate/fast-math discrepancies remain.
These component results do not establish exact application images.

The compatibility correction passes byte-storage metadata from the Metal
adapter to both dispersion backends and implements this UNORM8 sampling model.
Float and retained half-storage paths keep their previous sampling behavior.
The generated Vulkan shader is rebuilt and checked against source. A separate
22-case regression uses the independent native Metal sampler capture at the
same run, observing 33,792 float components on each of CPU and hardware Vulkan
through a translated, single-tap dispersion operation. It excludes the sine
hash from sampling qualification. Both backends pass a `1.2e-7` float error
limit; the original sampler fails at `7.659569382667542e-5`. Historical native
RGB Split, two-pass, alpha, ROI and edge checks also pass. Their earlier corpus
is archived verbatim with its original SHA-256 rather than relabeling those
reference buffers after unrelated corpus expansion; the current procedural
source-image recipe is checked against that archive.

Native evidence is under `.build/evidence/native-unsharp-precision-1b05dad/`,
with sampling experiments under its `analysis/` directory. The raw GPU trace
inventories also validate locally. The 22 point-sampling references are retained
in `Tests/Fixtures/metal/unorm8-sampling-reference.json.gz`. No application
reference PNG, threshold or golden image is changed by this correction.

The final Release rerun passes 244 XCTest checks (one skip), 1,073 parallel
Swift tests and 48 serialized Swift tests, with zero failures. Fresh CPU and
Vulkan exports account for all 178 cases and have identical decoded pixels
and ICC data. All 173 non-RGB-Split images are unchanged. The five RGB Split
images have 1,106 differing pixels in total, down from 1,246; the two blurred
recipes change in both directions, so this is not an across-the-board image
improvement. The default adjustment improves from 92 to 26 differing pixels,
and the positive-angle adjustment from 151 to 84. Their maximum errors remain
27 and eight channel levels because of the sine-hash discrepancy. No whole
image gains or loses exactness or tolerance status: the result remains 74/178
exact and 161/178 within existing limits on both backends. Strict comparison
continues to fail. Evidence uses `linux-byte-sampler-*`, `diff-byte-sampler-*`,
`byte-sampler-full-validation.exit` and `byte-sampler-export-review.json`.

Additional controls compare all 442,368 native shader float/byte components;
none distinguishes the four usual nearest rounding models at output storage.
For the translucent default filter, the native UNORM8 shader bytes followed by
exact nearest-away unpremultiplication reproduce the original native PNG's
4,128 visible pixels and entire alpha plane exactly. This rules out PNG
unpremultiplication as the cause of that case's remaining differences; it
does not qualify the Linux shader's output as exact.

## Dispersion half-texture stores

Native shader writes of Float32 values to RGBA16Float textures truncate toward
zero in the captured environment. The three independent `RGBAhGPU` controls
from run `40318276957` retain 4,608 source/store components; nearest-even
conversion disagrees in 510. A new regression copies those Float32 texels
through the real upstream zero-length, single-tap `smear` entry point. It fails
with the preceding adapter and matches all native half bits after correcting
the adapter's destination conversion. Both its hardware-backed run and its
software fallback with the Vulkan ICD disabled pass. Source half uploads and
other processor families are outside this correction.

The four older native two-pass dispersion controls also support this storage
model: for example, an isolated first-pass replay drops from 152 to 28 differing
half components in the linear distance-four case, and from 84 to 12 in the
radial distance-ten case. The remaining source/sampling arithmetic differences
are not classified as exact. The reference extraction is retained in
`Tests/Fixtures/metal/half-texture-store-reference.json`, with original capture,
script and source/store buffer hashes.

The full Release rerun passes 244 XCTest checks (one skip), 1,074 parallel
Swift tests and 48 serialized tests. Fresh CPU/Vulkan exports match each other
for all 178 decoded PNGs and ICC profiles. Only the two blurred RGB Split cases
change: the negative adjustment drops from 321 to 37 differing pixels, and the
extreme filter from 369 to 305. The extreme filter's maximum premultiplied
channel error changes from 1.2549 to 1.2706 levels, so the improvement in pixel
count does not imply every metric improves. Whole-image results remain 74/178
exact and 161/178 within existing limits. No application reference, threshold
or golden is changed. Evidence uses `linux-half-store-*`, `diff-half-store-*`,
`half-store-full-validation.exit` and `half-store-export-review.json`.

## Native CPU color-cube interpolation

The positive Hue/Saturation adjustment originally differs at one pixel, red
21 instead of 20 at `(17, 38)`. An isolated replay with the original C kernel
reproduces that Linux result; fused interpolation produces the native result.
Native run [40323679177](https://github.com/chiddekel/Compositor/actions/runs/40323679177),
at `1d58307`, independently compiles the unchanged `LevelsPixels.c` on arm64
macOS with default, disabled and explicit fast contraction. It also compiles
the protected Swift settings and pure table-building method bodies to retain
the native Hue/Saturation tables. All source, header, table, input and output
hashes, compiler flags/version and assembly are retained. The native default
and explicitly fused builds each contain 24 fused instructions; the unfused
build has none. The native hue tables match the Linux-generated tables exactly,
separating the C interpolation issue from table generation.

The 22 recipes cover identity, independently generated mixed-color and actual
hue tables; dimensions two, three, 17 and 33; and opaque/variable-coverage
inputs. Default native and unfused outputs differ in three components. The
portable explicit-`fmaf` implementation matches all 608,256 native RGBA8 output
components exactly. Its native hue outputs also match the original macOS
application captures at all three corpus settings. Four reference-validator
tests and a generator drift test pass. An initial 16-recipe capture,
`40322929301`, did not distinguish contraction at byte precision and failed
its nonvacuity assertion; the extended capture retains assembly and actual hue
tables rather than treating the nondistinguishing recipes as proof.

`scripts/gen-native-cube-kernel.py` generates the Linux mirror by changing only
the seven interpolation expressions to explicit fused operations. SwiftPM and
CMake both build that mirror, preserving protected upstream files and baseline
CPU support. The upstream-integrity check requires the generated source to
match. CMake's kernel contracts pass, and a public C-API regression rebuilds
every table/input and checks all 22 native output buffers and hashes. The
full Release run passes 244 XCTest checks (one skip), 1,075 parallel Swift tests
and 48 serialized tests, with zero failures. All nine exact-comparator tests
and the complete upstream/generated-source/shader checks pass.

Fresh CPU/Vulkan comparisons now reach **75/178 exact images**, up from 74;
161/178 remain within existing limits. Hue/Saturation +35 is the only image
changed from the qualified half-store checkpoint and now matches the original
native capture exactly. No case loses exactness or tolerance status. All 178
decoded CPU/Vulkan PNGs, ICC profiles and both recorded deep-sample files agree
between backends. The strict full-corpus gate still fails; this does not
establish complete macOS equivalence. No reference, threshold or golden is
changed. Application evidence uses `linux-cube-fma-*`, `diff-cube-fma-*`,
`cube-fma-full-validation.exit` and `cube-fma-export-review.json`; native evidence
is under `.build/evidence/native-unsharp-precision-1d58307/`. The matching
macOS unit/screenshot run `40323679097` also succeeds.

## Native PNG byte unpremultiplication

Motion Blur's default adjustment and filter initially differed at 8 and 545
pixels. Isolated replay reproduced both native images with the existing motion
kernel; plain and fused accumulation gave the same result. Sending those same
premultiplied bytes through the actual Qt PNG callback reproduced the Linux
differences. Qt's approximate reciprocal unpremultiplication, rather than the
motion kernel, was the cause.

Native capture [40331254861](https://github.com/chiddekel/Compositor/actions/runs/40331254861)
uses Core Graphics and ImageIO on Intel macOS 26.6.1, independently of the Linux
codec. Its 256 by 256 matrix covers all 32,896 valid byte color/alpha pairs and
all alpha values. Every native straight component matches integer nearest
rounding with half ties up: `(component * 255 + alpha / 2) / alpha`. The previous
Qt callback differs in 1,104 components across 1,003 pixels. The corrected
callback matches all 65,536 native pixels exactly. The raw PNG validator checks
all PNG filters, CRCs, layout and capture/source hashes; four validator tests
pass. The C++ regression compares every straight RGBA byte against the native
fixture and checks its sRGB profile. It failed before the correction and passes
afterward. The general ImageIO color contract also passes.

The correction applies to premultiplied RGBA8 PNG encoding. Straight RGBA8
encoding, including hidden transparent color, retains its separate callback.
The parity helper now honors an explicitly selected ImageIO library and fails
closed if it cannot load it. All 178 images, profiles and deep samples from
the routing-only baseline match the previous qualified checkpoint. Initial
`png-candidate-*` exports did not select the candidate library and are excluded
from candidate qualification; the missing-library `png-routed-candidate-*`
attempt failed. The correctly routed isolated experiment is
`png-codec-candidate-*`, and the integrated outputs agree with it.

Fresh integrated CPU and Vulkan exports reach **102/178 exact images**, up
from 75. All 27 gained exact cases retain their original native reference;
no previous exact case is lost. Existing tolerance results remain 161/178.
All 178 decoded PNGs and ICC profiles agree between CPU and Vulkan, and the
two recorded deep-sample files remain unchanged. The full Release suite passes
244 XCTest checks (one skip), 1,075 parallel Swift tests and 48 serialized
Swift tests. Nine exact-comparator tests and all upstream/generated checks
pass. No reference, threshold or golden is changed for this correction.
The strict full-corpus gate still fails: 76 images remain nonexact.

Evidence uses `linux-png-native-*`, `diff-png-native-*`,
`png-native-full-validation.exit` and `png-native-export-review.json`.
The native capture commit is `786aa87`. The matching macOS CI run
[40331254916](https://github.com/chiddekel/Compositor/actions/runs/40331254916)
builds and passes unit tests; its screenshot job was cancelled before any step
because a hosted runner could not be acquired. The earlier arm64 PNG capture
`40328057833` failed for the same allocation reason. Neither allocation failure
is counted as a renderer test result. The independent full application
reference remains the original arm64 macOS 26.6.2 capture.

## Native byte blend rounding

Native Core Graphics capture
[40334710500](https://github.com/chiddekel/Compositor/actions/runs/40334710500),
at `c579b71`, covers 16 blend modes, three opacities and opaque or variable-alpha
backdrops: 96 buffers and 6,291,456 pixels. It runs independently on Intel macOS
26.6.1 using premultiplied sRGB RGBA8 bitmap contexts. Source, backdrop, capture
script and output hashes are retained with the original raw buffers. Validation
checks complete coverage, transparency, opaque coverage and row orientation;
four corruption/coverage validator tests pass.

Darken, Lighten, Difference and Overlay differ because Skia's existing byte
pipeline rounds products differently from Core Graphics. The native controls
show that these modes quantize the opacity-adjusted source first and round
the complete premultiplied blend with the full 255 denominator. A runtime
blender reproduces all 24 native buffers exactly: 1,572,864 pixels and 6,291,456
RGBA components. The native regression fails against the previous library and
passes against both the isolated candidate and integrated library. It is
registered as `CompositorCore.NativeByteBlends`; the existing Skia, native
Source Over/Exclusion and Hue/Saturation contracts also pass. Deep surfaces
retain their existing path.

Fresh integrated CPU and Vulkan exports reach **109/178 exact images**, up
from 102. Seven images change and become exact: both Darken, Difference and
Overlay settings, plus Lighten at half opacity. The other 171 decoded images
and ICC profiles remain unchanged. All CPU/Vulkan images and profiles agree,
the two deep-sample files are unchanged, and integrated output agrees with the
isolated candidate. No case loses exactness or tolerance status; tolerance
results remain 161/178. The full Release rerun passes 244 XCTest checks (one
skip), 1,075 parallel Swift tests and 48 serialized Swift tests. Upstream and
generated-source/shader integrity checks pass. No reference, threshold or
golden is changed.

The full exact gate still fails: 69 images remain nonexact and only one of the
two recorded deep cases matches exactly. The same capture exposes low-alpha
Hard Light differences and distinct full-opacity Multiply rounding, including
alpha. Those modes remain unchanged pending further qualification. The
initial five-mode isolated probe included Hard Light and is explicitly
unqualified for that mode; the exported and integrated candidate contains
only the four fully verified modes.

Evidence uses `linux-byte-blend-*`, `diff-byte-blend-*`,
`byte-blend-full-validation.exit`, `byte-blend-export-review.json` and
`byte-blend-correction-source.json`. The complete native raw capture is under
`.build/evidence/native-byte-blends-c579b71/`; the checked-in fixture retains
all 96 native buffer hashes and capture provenance.

### Multiply image rounding follow-up

Core Graphics' Multiply image path rounds the outside-alpha contribution and
the source/backdrop product separately at full opacity, including alpha. At
reduced opacity it rounds their sum. The Skia byte canvas now uses a dedicated
image blender for this distinction; the ordinary blend-mode path and deep
surfaces are unchanged. The C API regression compares the actual canvas result
against 30 independent native Multiply/Darken/Lighten/Difference/Overlay
buffers (1,966,080 pixels) and passes against the rebuilt candidate library.

The fresh full-corpus CPU and Vulkan reports each rise to **111/178 exact PNGs**.
Both Multiply images become exact; all other PNG hashes match the immediately
preceding byte-blend candidate, and CPU/Vulkan PNGs remain identical. The exact
gate still fails: 67 PNGs and one deep numeric case remain nonexact. Color,
Hard Light, Hue and Saturation remain the nonexact blend-mode cases. The full
Swift/XCTest and upstream-integrity suites have not yet been rerun for this
follow-up, and the GitHub API was unavailable during this session.

Evidence is in `.build/evidence/macos-equivalence-73df482/diff-multiply-{cpu,vulkan}`;
the candidate bridge SHA-256 is `38694bc58750f90c36097a650df612f91fa660c3b1b11a206a201f6b093fb142`.

### Core Graphics byte-mode diagnosis before Screen correction

I replayed the pre-Screen candidate through the C API against every one of the 96
native buffers from run `40334710500`: 16 modes × three opacities × two
backdrop-alpha conditions, with 65,536 pixels per buffer. The table sums
changed pixels and components across each mode's six buffers; a pixel may be
counted in multiple buffers. These controls use the capture's fixed RGB source
pattern, so they characterize alpha and rounding behavior but do not cover all
possible source colors.

| Core Graphics mode | Native-different pixels | Native-different components | Maximum channel difference |
| --- | ---: | ---: | ---: |
| Normal | 0 | 0 | 0 |
| Multiply | 0 | 0 | 0 |
| Screen | 58,303 | 73,192 | 1 |
| Overlay | 0 | 0 | 0 |
| Darken | 0 | 0 | 0 |
| Lighten | 0 | 0 | 0 |
| Color Dodge | 384,433 | 565,173 | 155 |
| Color Burn | 386,612 | 783,783 | 254 |
| Soft Light | 150,455 | 179,004 | 1 |
| Hard Light | 256,589 | 386,285 | 2 |
| Difference | 0 | 0 | 0 |
| Exclusion | 0 | 0 | 0 |
| Hue | 52,396 | 67,782 | 1 |
| Saturation | 13,673 | 17,604 | 1 |
| Color | 280,794 | 398,458 | 3 |
| Luminosity | 228,402 | 362,044 | 4 |

This baseline separates byte rounding errors in Screen, Soft Light, Hue and Saturation
from the larger Color Dodge/Burn, Hard Light, Color and Luminosity differences.
The corpus currently has exact Screen and Soft Light images, while its
nonexact blend images include Color, Hard Light, Hue and Saturation. The
replay summary and all source hashes are retained in
`.build/evidence/macos-equivalence-73df482/native-blend-mode-matrix.json` (SHA-256
`7eadff7808256e7810042ec9d99858c5c4a3e9b3a0f78cb2b8c3163644ad906c`).

### Native Screen byte rounding correction

The Screen byte path now computes the premultiplied overlap as
`source × backdropAlpha + backdrop × sourceAlpha − source × backdrop`, then
rounds the full blend with the 255 denominator. The rebuilt candidate passes
the six native Screen controls (393,216 pixels) exactly. Replay of the actual
96×72 corpus layer inputs also matches both independent macOS Screen images
and the preceding Linux exports exactly at 50% and 100% opacity, so the strict
corpus result remains 111/178 exact PNGs. The broader exact gate still fails.

The post-correction 16-mode matrix is in
`.build/evidence/macos-equivalence-73df482/native-blend-mode-matrix-screen.json`
(SHA-256 `fc66d53819ce519b9f927b20f51d0525194936903d15d0894143a424c9969819`);
the rebuilt bridge SHA-256 is
`1e7528cd1a232f9b1bd3907a7efb3d283c37f157c26d5be2381b1c563f2b8b3e`.

### Native Soft Light byte rounding follow-up

The standard Soft Light formula reduced mismatches in the fixed-color native
controls but made the actual corpus renders differ by one byte. The retained
byte path rounds the premultiplied overlap term before applying the final 255
denominator. It matches the macOS and prior Linux Soft Light corpus images
exactly at both 50% and 100% opacity. Across the six fixed-color native
controls it reduces differing pixels from 150,455 to 62,571; the remaining
differences are one channel level. Other mode results in the 16-mode matrix
are unchanged from the Screen correction.

The current matrix is in
`.build/evidence/macos-equivalence-73df482/native-blend-mode-matrix-softlight-overlap.json`
(SHA-256 `864da245545c41babeee2469a8c8e0c4e8ffebe71b46bf0ef60a9351528b8e20`);
the candidate bridge SHA-256 is
`771117ff0359ee6c3dd30c932fdd986a6adfc2890bcfceb2e2f864bb751e5521`. At that
point the full corpus CPU/Vulkan rerender remained outstanding because the host
Swift test runner segfaulted before rendering. A later render from the KDE
Flatpak SDK is recorded below.

### Native Color blend corpus correction

The byte-output nonseparable blender now applies the Core Graphics luminance
step to Color using the premultiplied source/backdrop overlap. A C API replay
of the exact 96×72 corpus inputs matches the independent macOS Color outputs
at both 50% and 100% opacity: 13,824 pixels across two buffers are exact. The
existing 36 native fixed-pattern controls for Multiply, Screen, Overlay,
Darken, Lighten and Difference also remain exact. The Color fixed-pattern
control matrix improves from 280,794 differing pixels (maximum channel
difference 3) to 128,272 (maximum 1), so that broader control family is not
yet exact.

The corpus regression is in `tests/test_native_byte_blends.py`; its independent
RGBA references and provenance are in `Tests/Fixtures/coregraphics-color-corpus-*`.
The tested bridge SHA-256 is
`e4b9568e624c3060aab5e6a6dd2a51b521e01eb4052326682d7e7796cb2ee30b`. These
targeted C API results did not replace the outstanding full CPU/Vulkan corpus
render at that point; a later render from the KDE Flatpak SDK is recorded below.

### Native Color Dodge and Burn corpus correction

The byte separable blender now evaluates Color Dodge and Color Burn on the
unpremultiplied source and backdrop colors, then composites that result with
the byte alpha overlap. A direct Core Graphics canvas replay now matches the
four 96×72 Color Dodge/Burn corpus images exactly at 50% and 100% opacity
(27,648 pixels). Before this change, only the two 50% images differed, by at
most one channel level.

The current 32-image direct Core Graphics sweep has 28 exact images. Hue and
Saturation at 50% and 100% remain nonexact, with each image differing by at
most one byte. The separate fixed-pattern native controls still show substantial
Color Dodge/Burn differences (381,239 and 385,826 differing pixels across six buffers,
respectively), so the corpus match does not establish general byte equivalence
for those modes. The complete 32-image direct-mode replay report is
`.build/evidence/macos-equivalence-73df482/native-direct-blend-corpus-byte-dodge.json`;
it records the independent PNG hashes and per-image changed pixel counts. At
that point the full CPU/Vulkan corpus rerender remained outstanding; a later
render from the KDE Flatpak SDK is recorded below.

The regression uses four additional decoded macOS references in
`Tests/Fixtures/coregraphics-byte-blend-corpus-reference.json` and its `.rgba`
buffers. The native blend test passes 36 existing fixed-pattern controls plus
all six targeted Color, Color Dodge and Color Burn corpus buffers. The tested
bridge SHA-256 is
`9507df3ac770dba7c2af988f497dd70fe8d7fd0a39e0a027f03b379c3ceaa197`.

### Native Hard Light byte correction

Hard Light now uses the byte Overlay formula with the threshold selected from
the source channel. The custom shader matches both 96×72 macOS Hard Light
corpus images exactly. On the six fixed-pattern native controls, it reduces
the result from 256,589 differing pixels (maximum channel difference 2) to
2,487 (maximum 1). Four corpus images remain nonexact in the direct-mode sweep:
the Hue and Saturation images at both opacities. The current 28/32 report is
`.build/evidence/macos-equivalence-73df482/native-direct-blend-corpus-byte-dodge.json`.

The checked-in native references include Hard Light at both opacities in
`Tests/Fixtures/coregraphics-byte-blend-corpus-reference.json`; the C API
regression checks those with Color, Color Dodge and Color Burn. The tested
bridge SHA-256 is
`c37c690fbf2be2bb6a5e6e5cc5c40f879662fc5f636d710a5adde50630804bef`.

### Full CPU and Vulkan corpus rerender

The complete 178-image corpus was rendered with the current byte-blend bridge
inside the KDE Flatpak SDK using Swift 6.3.3 and the LibRaw/RawSpeed dependency
prefix. After rebuilding QtImageIO from the current `host/QtImageIO.cpp`, CPU
and Vulkan exports have the same exact-image set and the same per-image changed
pixel counts: 116/178 images are pixel-exact and one deep-sample case is exact.
The exact gate still fails on both backends.

Per-category exact counts are adjustment 34/55, blend 44/48, color 2/5,
effect 6/6, export 1/1, filter 27/40, RAW 0/5, shape 0/3, text 0/9 and
transform 2/6. Remaining tolerance failures are Gaussian Blur and RGB Split
adjustments, the highlights deep-sample import, all five RAW samples, and the
nine text samples. CPU/Vulkan parity here shows backend agreement, not macOS
equivalence.

The CPU output and official report are in
`.build/evidence/macos-equivalence-73df482/linux-byte-dodge-cpu-rebuilt-imageio-2`
and `.build/evidence/macos-equivalence-73df482/diff-byte-dodge-cpu-rebuilt-imageio-official`;
the exact-only report is in
`.build/evidence/macos-equivalence-73df482/diff-byte-dodge-cpu-rebuilt-imageio-exact`.
The Vulkan output and official report are in
`.build/evidence/macos-equivalence-73df482/linux-byte-dodge-vulkan-rebuilt-imageio`
and `.build/evidence/macos-equivalence-73df482/diff-byte-dodge-vulkan-rebuilt-imageio-official`;
the exact-only report is in
`.build/evidence/macos-equivalence-73df482/diff-byte-dodge-vulkan-rebuilt-imageio-exact`.
Both renders used corpus hash
`ee5004f45175d4bd63a204405a2064b2a1308bc7c063b5e1613ce52f51260088`, input
hash `fefba214b8b3c35fdb819f573b86bf1b4de3cc32ec60dd7c712c2bc5f8fc5b38`,
bridge SHA-256
`c37c690fbf2be2bb6a5e6e5cc5c40f879662fc5f636d710a5adde50630804bef`, and
rebuilt QtImageIO SHA-256
`75b66de4393b86c61bf2b2436656233bc744b8322e7b4a469e468bce39799338`.

The earlier 89/178 reports used the stale QtImageIO library
`5c70086ee4253c937a0bff75537f6ed8491812338b680cbcf1f9717cd800d64e`, which
predated the current source. Rebuilding raised the CPU count from 89 to 116;
for example, Add Noise, Black & White, Exposure, Gray Alpha and Sharpen cases
that had drifted now match again. The official comparator was run with system
Python 3.12 and `--require-exact`; its exact flags match the independent
`scripts/compare-render-exact.py` report on all 178 images.
