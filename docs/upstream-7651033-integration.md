# Upstream through 8cdc2b6 (1.5.9)

This report records the 1.5.9 checkpoint. The protected trees have since advanced
to `2d75d91` (1.5.10, format 19); see the [current integration tracker](upstream-1.5.10-integration.md).
Measurements below belong to their recorded source revisions.

The protected application and test trees match upstream
`8cdc2b6604e54b4117ef2d8bbe453664816b75ea`. The four commits after format 18
add adjustment-result caching, processor-based Bokeh with shared aperture weights,
two-pass RGB Split, and shared-direction Starburst evaluation. The original
application algorithms remain unchanged; adaptation lives in the Linux API and
rendering backends.

The subsequent four commits add document-sized Lens Effects, bounded adjustment
surfaces, consistent canvas/export angles, smooth sampling and a settled canvas
image rendered by the export code. The Linux GPU override mirrors the new filter
logic. The adapter now provides explicit `samplingLinear()` and tracks the last
sampling choice through crop/clamp wrappers. Its timer wrapper now provides
`scheduledTimer`, adding the timer to the current run loop in default mode and
releasing its callback ownership after one-shot delivery. Upstream's new canvas tests and
updated adjustment reopening assertions are included. The build, 10 focused
XCTest cases and 37 Swift tests pass, including both new canvas/export zoom
cases, sampling precedence and scheduled-timer delivery/lifetime. Full-suite
qualification follows below. About metadata is 1.5.9, build 55. Incoming files were backed
up before applying the exact upstream patch.

## Completion audit

GitHub's upstream `main` was checked again on 2026-10-26 and points to
`8cdc2b6604e54b4117ef2d8bbe453664816b75ea` (committed at 20:59:05 UTC).
Behavioral results below identify their earlier source revision; they do not
qualify the four newly applied commits unless stated explicitly.

| Requirement | Current evidence | State |
| --- | --- | --- |
| Integrate the latest upstream application and tests | Protected trees match upstream; ledger accounts for all 125 commits and 95 code commits since `a1bd74c`; build and 56 focused tests pass; full qualification recorded below | Verified locally, with the recorded rendering limitations |
| Keep platform adaptation outside original Mac algorithms | Mac sources remain exact; `GPUCanvasRenderer.keep` adapts caching through the Linux Core Image facade | Verified locally |
| Include every upstream Swift source and account for upstream tests | Fresh SwiftPM evaluation accounts for 175 application files, 98 unchanged test files and four generated test mirrors; all 13 source-coverage audit tests pass | Verified locally |
| Preserve the new Bokeh and two-pass RGB Split behavior | Independent native shader captures, hardware-required adapter/graph tests, transfer counters and 173-image CPU/Vulkan comparison | Verified within the recorded matrices |
| Preserve cache invalidation and shared Starburst graph construction | Original cache and filter tests pass in the affected 56-test qualification | Verified within those tests |
| Keep resource ownership and failure handling in the backend | Swift immutable-image owner wraps the C API; C handles retain their device; lifetime, budget, cross-device and resource-release checks pass | Verified within those tests |
| Preserve shared spatial evaluation | Bounded per-render cache reuses matching spatial requests; five planner/cache regressions pass, including evaluation counts and affine/color fusion | Verified within those tests |
| Complete current Linux regression qualification | Current Release checkpoint passes 232 XCTest cases (one timing skip) and 48 serialized tests; 1,063 parallel Swift tests retain one text golden assertion. Separate native curve diagnostics retain one failing case | Open |
| Establish large-canvas adjustment performance | Original full-size benchmark completed on the qualified Release executable: 6,013.8 ms baseline, uncached Starburst 614,547.6 ms, cached Starburst 6,048.9 ms. Native performance comparison and acceptable interactive performance remain unproved | Open |
| Establish full native application rendering equivalence | Kernel captures and Linux-to-Linux exports do not prove complete Mac application output equivalence | Open |

The adapter boundary follows dependency inversion: original application code
uses its existing Core Image/Metal interfaces; Linux owns graph lowering,
immutable-image lifetime and Vulkan dispatch behind those interfaces. The new
GPU allocation API does not depend on application adjustment types. Unsupported
graphs continue through the existing CPU evaluator.

The fresh source-inclusion report is
`.build/evidence/upstream-7651033-source-coverage.json`, using the evaluated
`upstream-7651033-package-description.json`. It classifies 144 unchanged sources,
24 generated adapters, five replacements and two platform substitutions. These
counts account for compilation routes; they do not establish behavioral parity.

## GPU-owned results

`CIContext.keepOnGPU` lowers supported graphs to immutable Vulkan image handles.
`GPUCanvasRenderer.keep` uses this path before its CPU fallback. The original
canvas fingerprints, transient invalidation, folder masks and cache pruning run
unchanged. Cached images preserve CI coordinates and half-float values, including
HDR and negative channels. Retained half-float results now use packed RGBA16
storage, eight bytes per pixel. Full-float arithmetic retains RGBA32 storage.
Initial uploads use four-byte RGBA8 storage only when every float component
exactly matches a normalized byte value. Arbitrary floats, HDR values and
negative zero retain RGBA32 storage, without quantization.

`VulkanImage` owns its immutable allocation and retains its device. Subsequent
submissions cannot overwrite it, and destroying the context owner before its
images is safe. A 512 MiB resident budget bounds allocations; budget refusal
leaves the device usable. CPU pixels are copied back only by an explicit read at
a CPU consumer. Unsupported operators, linear working contexts, unavailable
hardware and memory limits retain the existing CPU evaluator/materialization.
The final Qt/CGImage presentation still consumes CPU pixels; this is not a
zero-readback presentation implementation.

Half storage, Bokeh and bottom-up RGB processor results use packed half pairs in
32-bit storage words. This needs no optional Vulkan 16-bit-storage capability.
Value-preserving crops, alpha replacement and nearest/integer affine placement
retain that format; general arithmetic stays full float. The C read API expands
half pixels to its existing float32 output, while memory and readback counters
measure the stored pixel payload. Half writes round to nearest, ties to even,
explicitly: the driver's pack intrinsic had truncated values such as 0.3.

The resident graph supports the operations around the original Bokeh filter:
pointwise matrices/clamps, alpha replacement, transfer conversion, tone curves,
source-over, masks, linear dodge, crop/clamp and affine sampling. The upstream
processor's encoder supplies its actual shader name and arguments, without a
dependency on application kernel types. Round, Hexagon and Oval weights are
computed once on the GPU and shared across pixels; Cat's Eye retains the global
region-relative coordinates for cropped and tiled outputs. Bokeh's input/output
half-float precision is preserved.

RGB Split uses the same resident lowering for its original one- or two-pass graph.
The streak and spectrum passes share GPU-owned half-float values without a pixel
readback/upload between them. A clipped radial intermediate can require an
additional GPU placement pass. The legacy CPU and Vulkan dispatch paths remain
available. Parameter 18 of their raster ABI selects legacy gather (0), smear (1),
or spectrum (2); the resident adapter also records bottom-up processor storage.
Vignette/Tonal Contrast adapters accept both half and full floats, including
Tonal Contrast's second input. Starburst compiles the original shared graph.

The fallback graph planner builds its operation plan before evaluating CPU
leaves. Rejected plans therefore avoid rendering those leaves once for planning
and again for fallback. Within a successful frame it also shares immutable
geometry leaves independently of admission to the persistent 128 MiB geometry
cache. Cache admission and memory budgets are unchanged.

Spatial CIImage values now also retain their identity when used by several
branches. A graph prepass selects only shared spatial nodes for a separate
per-render CPU cache. `RenderCache.swift` owns its 512 MiB/64-entry LRU policy;
keys include image identity, exact requested region, working color space and
backend identity. Entries retain their identity owners and expire at the end
of the render. Different regions remain separate, and budget pressure can
require recomputation. This does not implement global union-ROI scheduling.
Single-use nodes retain GPU batching, and affine fusion remains unchanged.

## Changed boundaries

- `Sources/Compat/CoreImage/CoreImage.swift`: graph lowering, device-backed source
  nodes, explicit CPU reads and `keepOnGPU`.
- `Sources/Compat/CoreImage/RenderCache.swift`: bounded reuse of shared spatial
  results within one render, separate from persistent geometry and adjustment caches.
- `Sources/Compat/CoreImage/VulkanRaster.swift`: Swift ownership of immutable GPU
  images and resource operations.
- `Sources/Overrides/GPUCanvas.swift`: prefer resident adjustment results.
- `backends/coreimage/VulkanRaster.cpp`, `include/VulkanRaster.h` and
  `shaders/raster.comp`: allocation/lifetime/budget management, synchronization,
  counters, aperture weights/gather and resident graph operations; regenerated
  `raster_spv.h`.
- Metal compatibility adapters: processor formats, shared aperture table and
  legacy two-pass dispatch.
- `Tests/CompatTests/VulkanResidentTests.swift`,
  `Tests/LinuxOverrideTests/Upstream7651033Tests.swift`,
  `Tests/LinuxOverrideTests/NativeAdjustmentComputeTests.swift` and
  `tests/test_vulkan_resident.py`: native pixels, complete graphs, transfer
  accounting, ownership, geometry, precision and fallback boundaries.
- `Tests/CompatTests/GraphPlanningTests.swift`: rejected-plan evaluation counts
  and per-frame sharing when the original source exceeds the geometry cache.
- `Tests/CompatTests/ImageIOCompatTests.swift`: restore the previous codec after
  exercising a fake, preserving native GIF decoding for subsequent suites.
- `scripts/linux-contract-tests.sh`: run the resident backend checks alongside
  dispersion; parity manifest and upstream ledger include the new commits.

## Evidence

The existing native capture under
`.build/evidence/upstream765-adjustment-compute-native/adjustment-compute-reference.json`
validates against the exact upstream shader strings with
`scripts/validate-adjustment-compute-reference.py`. All 96 Bokeh cases and four
two-pass dispersion cases validate. The losslessly gzip-compressed copy at
`Tests/Fixtures/metal/adjustment-compute-reference.json.gz` retains its exact
uncompressed contents, source/script hashes, device metadata and commit
provenance. See `adjustment-compute-reference.md` for the capture recipe and scope.

On AMD Radeon Graphics (RADV RENOIR), `tests/test_vulkan_resident.py` passes all
96 native Bokeh cases in both row orders, with maximum half-float error
`0.0009765625`. All four native two-pass RGB Split cases pass for the half-float
intermediate and final byte output. The tests assert no pixel upload/readback
between resident operations; they also cover matrix bias, transfer conversion,
signed zero, tone curves, alpha, blending, placement, immutable branching,
allocation release, cross-device refusal, budget refusal and device lifetime.
`tests/test_dispersion.py` also passes on CPU and hardware Vulkan, retaining the
historical default reference within one byte.

The release build and affected hardware-required qualification pass all 56 Swift
tests in 10 suites and 12 XCTest cases. These include the original cache
comparison/invalidation tests, all 96 native Bokeh outputs through the Metal
adapter, all four complete Bokeh aperture graphs with zero intermediate pixel
readbacks, linear/radial RGB Split with blur on/off, the actual canvas `keep`
path, HDR/transforms, resource release, GPU uploads and affected adjustment/filter
suites. Cached Bokeh draws do not submit Bokeh again and require only the final
CPU-consumer readback. The log is
`.build/evidence/upstream-7651033-resident-final.log`.

The upstream guard passes protected content, generators, shader headers,
override drift and all ledger checks. Fresh CPU and Vulkan export corpora contain
173/173 identical decoded pixel buffers, equal numeric samples and equal ICC data.
Their manifest hashes verify the same current source/corpus/inputs. The report is
`.build/evidence/upstream-7651033-resident-corpus-comparison.json`. This compares two
Linux backends, not current native macOS application output.

The corpus helper now qualifies its Swift test filter as
`^RenderParityTests\.RenderParityTests/`. The previous module-wide filter also
selected glyph-geometry suites before the parity suite installed the Qt backend;
the corpus itself passed but the unrelated suites caused the command to fail.
Fresh corrected runs select exactly one corpus test and pass on both backends.
No glyph test or assertion was changed. All nine parity-tool unit tests also pass
in a temporary environment with their required NumPy/SciPy/Pillow dependencies.

The first release build encountered a full home filesystem. Generated scratch
artifacts now live under `/tmp/compositor-upstream765-swift-build`, with the
existing `.build/evidence/swift-build` path retained as a symlink. No source,
reference artifact or existing golden was deleted. Existing local rendering
candidates and golden changes predate this integration. Full native image parity
and native-equivalent performance remain separate open qualification work.

The planner regressions fail on the previous implementation and pass after the
fix: a rejected graph evaluates its counted CPU leaf once rather than twice;
a shared resampled leaf from a 144 MB source uploads 1 MiB rather than 2 MiB.
Both tests also compare their actual pixels with software rendering. All 56
affected GPU/adjustment tests still pass. Fresh CPU/Vulkan corpora and the
pre/post-planner Vulkan corpora each have 173/173 identical pixel buffers,
numeric samples and ICC data. Evidence is under
`.build/evidence/upstream-7651033-planning-*`.

The broad validation initially loaded an outdated native ImageIO library,
missing `compositor_qt_imageio_decode_frame` and the straight-alpha callbacks,
and did not explicitly select Vulkan for generic contexts. The same failures
reproduce in the saved pre-planner executable. A current codec built in
`/tmp/compositor-upstream765-native-check` passes the independent GIF and
straight-PNG native checks. With that codec and
`COMPOSITOR_COREIMAGE_BACKEND=vulkan`, all 7 affected XCTest cases and 26 Swift
tests across GIF and Vulkan suites pass. The broader checks still identify
existing Lens Effects/Tonal Contrast golden differences and two native angular
motion-blur comparisons; a fully green suite is not claimed.

With the corrected backend setup, the complete parallel Swift run executes 1053
tests in 187 suites and reports exactly four golden comparisons (Lens Effects
and Tonal Contrast, in adjustment and filter forms). The 48 tests in nine suites
that require serialized execution pass separately. The combined XCTest run
also exposed test pollution: the fake-backend test cleared the installed codec
instead of restoring it, causing the later GIF reader-lifetime test to fail.
The failure reproduces in the pre-planner executable while the lifetime test
passes alone. The test now restores its previous codec.
The final combined XCTest run executes 214 cases with only the two previously
identified angular motion-blur assertions failing; GIF lifetime now passes.
Its log is `upstream-7651033-planning-xctest-final.log` in the evidence directory.

The unchanged upstream `AdjustmentPerformanceTests` large-canvas benchmark was
stopped for planner investigation after stack samples showed CPU leaf evaluation
and crop copying. It produced no timing attachment and is excluded from
performance evidence. Its source hashes, log path and stopped status are recorded
in `.build/evidence/upstream-7651033-resident-source.json`. The initial attempt
was also excluded because the runner discarded attachments. No large-canvas
per-frame performance result is claimed from either incomplete run.

A new unprofiled benchmark run uses the planner fix, the current native codec
and the normal hardware-canvas graph-selection policy. Its log is
`.build/evidence/upstream-7651033-planning-benchmark.log`, with attachments under
`upstream-7651033-planning-benchmark-attachments/` and source identity recorded
in `upstream-7651033-planning-source.json`. Its timing result remains pending.

## Current native-library qualification

The older `.build/linux-contract-native` Skia and ImageIO libraries were built
on October 21, before their current source changes. They are not evidence for
all current native code. Current Skia, ImageIO and PDF libraries are rebuilt in
`/tmp/compositor-upstream765-native-check`. The Skia smoke test verifies actual
Vulkan execution and device-loss fallback. Independent native fixtures pass all
52 straight-stroke cases, 204 image-sampling cases and 24 Hue/Saturation cases.
Curve coverage passes 93/94; `rounded-size-4-phase-0.25-affine` differs by two
levels at three pixels. That native C++ result is independent of the Swift cache.

The final shared-node implementation passes five planner/cache tests, four
affine/resource tests and 51 affected Swift tests. The counting regression fails
before the change (three evaluations per render, six across two) and passes
after it (one, then two), with identical output pixels. A separate test covers
shared affine/color stages. Domain/color/backend isolation, LRU eviction and
oversized-result refusal also pass.

With all three current native libraries, the complete run executes 217 XCTest
cases with only the same two assertions in one angular-motion test failing.
The parallel run executes 1053 Swift tests in 187 suites with 18 golden issues;
all 18 assertions, including their error magnitudes, reproduce identically in
the saved pre-sharing executable with the same libraries. The 48 serialized
tests in nine suites pass. No golden image or tolerance was changed.

Fresh current-library CPU and Vulkan corpora have 173/173 identical decoded
pixel buffers, numeric samples and ICC data. The saved pre-sharing executable
and final Vulkan corpus also match 173/173 under those same libraries. Evidence
uses the `upstream-7651033-shared-evaluation-` prefix, including source/library
hashes in `source.json`, both corpus comparisons and the golden assertion
comparison. The earlier benchmark still uses its recorded pre-sharing source
revision and overlaps builds/diagnostics; it cannot establish isolated performance
of this final implementation.

## Packed half storage

The allocation regression fails against the saved old backend: two RGBAh pixels
consume 32 bytes. It passes after packing at 16 bytes, with a 16-byte physical
readback. Mixed half/full inputs, every mask channel, padding, signed zero and
subnormals pass. Python's independent binary16 conversion validates all finite
half values, infinities and every finite adjacent-value midpoint, including
GPU half decoding. Real memory pressure also passes: a 128 MiB input and five
64 MiB results occupy 448 MiB; another result is refused safely within the
512 MiB budget, and the device remains usable.

On AMD Vulkan, all 96 native Bokeh cases pass in both row orders (maximum error
0.0009765625), and all four two-pass RGB cases pass without intermediate pixel
transfers. Legacy CPU and Vulkan dispersion retain the native default within one
byte. Seven planner/resource XCTest cases and 39 affected Swift tests pass with
the packed backend. Evidence uses the `upstream-7651033-packed-` prefix.

The complete packed-backend qualification executes 217 XCTest cases with the
same two angular-motion assertions failing, 1053 parallel Swift tests with the
same 18 golden assertions, and 48 serialized tests without failures. Both fresh
CPU/Vulkan and pre/post-packing corpora have 173/173 identical decoded pixel
buffers, equal numeric samples and equal ICC data. Shader regeneration and the
complete protected-source/generator/ledger guard pass. These checks preserve the
existing limits on full native application equivalence and performance claims.

## Lossless byte input storage

Resident uploads recognize exact normalized RGBA8 values and store them in four
bytes per pixel. The selector compares float bit patterns against all 256
decoded byte values; it rejects arbitrary intermediate floats, HDR, nonfinite
values and negative zero. These inputs retain the existing full-float path.
The shader decodes source, background and mask independently, and the C read API
continues returning float32 pixels.

The 4000 × 2600 photo regression initially reports 166,400,000 uploaded bytes
instead of the expected 41,600,000. This measures traffic and memory use, rather
than a device limit failure: the actual AMD Vulkan storage-buffer limit is
4 GiB; the 128 MiB limit belongs to the software device. Independent native
checks validate all 256 byte values through CPU and GPU decoding, distinct
backgrounds, all mask channels, the existing half-storage budget/rounding cases,
96 Bokeh cases in both row orders and four two-pass RGB cases. Legacy dispersion
also passes within its existing one-byte tolerance. Nine focused XCTest cases
pass. Both CPU/Vulkan and before/after upload corpora have 173/173 identical
decoded pixel buffers, numeric samples and ICC data at the `7651033` revision.
Evidence uses
the `upstream-7651033-bitmap-` prefix.

## 1.5.9 qualification and drawing-context concurrency

The first complete `8cdc2b6` qualification runs 220 XCTest cases with the two
known angular-motion assertions, 1058 parallel Swift tests with the 18 unchanged
golden assertions and one additional glyph-glow assertion, and 48 serialized
tests without failures. The glyph case passes alone in both the saved preceding
executable and the current executable. A full parallel repeat has only the same
18 golden assertions. All 18 assertion messages and maximum differences match
the preceding packed-backend run. CPU/Vulkan export parity is 173/173, including
numeric samples and ICC data.

Investigation found process-wide drawing state in the Linux `NSGraphicsContext`
adapter. A controlled two-thread test reproduces interference in the current
context and save/restore stack: `[false, false, false, true]` instead of four
successful isolation checks. The adapter now stores both in each thread's
dictionary. Its rebuild, 11 focused XCTest cases and 45 Swift tests in six suites
pass, including the controlled regression, Inner Glow and the new upstream
canvas checks. The full post-fix qualification follows below. Original
upstream test bodies and golden files remain unchanged. The evidence prefixes
are `upstream-8cdc2b6-` and `upstream-8cdc2b6-context-`.

The final post-fix qualification completes 221 XCTest cases with the same two
angular-motion assertions, 1058 parallel Swift tests with exactly the same 18
golden assertions and maximum differences, and 48 serialized tests without
failures. The glyph-glow case passes in this complete parallel run. Both
CPU/Vulkan and pre/post-context corpora match 173/173 decoded pixel buffers,
numeric samples and ICC data. The protected-source, generator, shader and ledger
guard passes, as do all 13 source-audit fault tests. The native curve reference
remains 93/94; full native application equivalence, global union-ROI scheduling
and native-equivalent performance are still open. The original earlier-source
benchmark continues, so it is not evidence for current performance.

## Files in the latest integration batch

The exact upstream patch updates `Filters.swift`, `LayerAdjustment.swift`,
`AdjustmentSurface.swift`, `EditorCanvas.swift`, `GPUCanvas.swift`,
`LiveMaskRenderer.swift`, `AdjustmentLayerTests.swift`, `GPUCanvasTests.swift`,
the Xcode project and `appcast.xml`.

Linux changes are in `Sources/Compat/CoreImage/{CoreImage,VulkanRaster,NormalizedByteStorage}.swift`,
`Sources/Compat/AppKit/GraphicsContext.swift`,
`Sources/UpstreamCore/LinuxSupport/Timer.swift`, `Sources/Overrides/GPUCanvas.swift`,
`backends/coreimage/{VulkanRaster.cpp,include/VulkanRaster.h,shaders/raster.comp,shaders/raster_spv.h}`
and generated `host/AppVersion.h`.

Regression coverage is in `Tests/CompatTests/{VulkanResidentTests,SamplingChoiceTests,GraphicsContextThreadTests}.swift`,
`Tests/LinuxOverrideTests/{ScheduledTimerTests,GPUCanvasTests}.swift` and
`tests/test_vulkan_resident.py`. The parity manifest, commit ledger and current
inventory record the new revision and qualification results.

Review tracked changes with `git diff` and additions with `git status --short`;
the worktree also contains preserved work from earlier integration phases.

## Curve follow-up: flattening is not the remaining error

The current backend again reproduces 93/94 native curve cases within one byte.
The remaining case has three failing pixels on its long straight bottom edge:

| Pixel | Linux RGBA | Native RGBA | Native opaque coverage |
| --- | --- | --- | --- |
| (20, 48) | 118, 44, 73, 147 | 119, 45, 74, 149 | 212 |
| (24, 49) | 82, 31, 51, 102 | 83, 31, 52, 104 | 148 |
| (25, 49) | 109, 41, 68, 136 | 110, 42, 68, 138 | 196 |

Changing subdivision tolerance from 0.05 to 0.00001 increases this polygon from
39 to 2967 vertices without changing any of these pixel areas. Exact-area
coverage codes remain 210, 146 and 194. Captured opaque, floating, pretransformed,
reversed and rotated-contour controls confirm the discrepancy without changing
paint alpha. A double-precision transform and 1/4096 fixed-slope model matches
these three codes but introduces failures elsewhere in the 94-case matrix;
floor, truncation and directed-edge variants are rejected. The renderer and
reference tolerances are unchanged. Evidence uses `upstream-8cdc2b6-curve-*`.

## Rectangular morphology: profiled scan replaced with a sliding queue

A live stack from the original benchmark identifies `LensRaster.morphology`'s
inner horizontal scan. It visits every sample in each window, making the work
grow with the kernel width and height. The Linux adapter now uses a monotone
queue: each input position enters and leaves at most once. The horizontal pass
only materializes the strip needed by the output and its vertical halo; a
one-pixel dimension bypasses its corresponding extrema pass. The upstream
filter graph, kernels and sampling margins are unchanged.

Signed-zero selection preserves the sequential Float extrema behavior. NaNs
use the original sequential implementation because they do not define the
ordering required by the queue. Four permanent tests cover an independent
two-dimensional window oracle, translated/cropped regions, even and odd sizes,
301-pixel horizontal and vertical windows, HDR, infinities, NaNs and signed zeros
that vary within each channel's spatial window. The original 16 affected XCTest
cases and 29 Swift tests pass; the added vertical case and strengthened zero
fixtures subsequently pass with the same production source. A standalone
driver comparing the actual old and new sources also passes 480 randomized
bit-for-bit comparisons. AddressSanitizer checks pass on that matrix; leak
detection is disabled for this standalone experiment.

For the release-package synthetic 301-pixel window, the measured kernel falls
from 539 ms to 4–4.5 ms. Seven paired measurements in a separate `swiftc -O`
driver give medians of 1.170 seconds and 3.927 ms. The different compilation
contexts are recorded separately. These are kernel-only results; the original
older-source benchmark and other work overlap, so they do not establish
isolated application performance or native-equivalent performance.

Full qualification runs 225 XCTest cases with only the same two angular-motion
assertions, 1058 parallel Swift tests with exactly the same 18 golden assertions
and maximum differences, and 48 serialized tests without failures. Both fresh
CPU/Vulkan and pre/post-morphology corpora have 173/173 identical decoded pixel
buffers, numeric samples and ICC data. The protected-source, generator, shader
and ledger guard passes. Code changes are confined to
`Sources/Compat/CoreImage/LensRaster.swift`; regressions are in
`Tests/CompatTests/LensMorphologyTests.swift`. Evidence uses the
`upstream-8cdc2b6-morphology-` prefix.

## Timer ownership and current-source performance run

The timer adapter's initializer retained its own wrapper through the native
callback. Canceling the native timer did not break that cycle, so an
unscheduled timer, a canceled timer and a repeating timer that invalidated
itself could all retain their wrappers. Callback captures remained alive too.
Five lifecycle tests reproduce six failed ownership assertions before the fix.

The delivery state now holds a weak reference until `RunLoop.add` establishes
scheduled ownership. One-shot completion and cancellation clear that ownership
and the callback. Invalidated timers cannot regain it. Callback invocation and
reference release happen outside the state lock, so a callback can invalidate
itself without deadlocking. The same wrapper is passed back on delivery. Both
the scheduled factory and manual `RunLoop.add` path are tested. Original Mac
sources are unchanged; the implementation is in
`Sources/UpstreamCore/LinuxSupport/Timer.swift`, with regressions in
`Tests/LinuxOverrideTests/ScheduledTimerTests.swift`.

All 32 affected Swift tests pass, including the five lifecycle tests. Full
qualification runs 225 XCTest cases with the two known angular-motion
assertions, 1062 parallel Swift tests with exactly the same 18 golden assertions
and maximum differences, and 48 serialized tests without failures. Both
CPU/Vulkan and pre/post-timer export corpora match 173/173 decoded pixel buffers,
numeric samples and ICC data. Evidence uses `upstream-8cdc2b6-timer-*`.

The unchanged upstream `AdjustmentPerformanceTests` now also runs against a
separate immutable copy of the current executable: session 98292, process
256684 at the recorded live verification. Its source report hashes 422 selected
source files, the executable and the three native libraries. It uses the normal
hardware-canvas graph policy with `COMPOSITOR_COREIMAGE_BACKEND` unset and
requires actual Vulkan. The older session 40629/process 147676 remains active.
The runs overlap each other, regression checks, a short stack sample and a
test-only rebuild, so timing results are exploratory. The current run's final
attachment and exit status are pending under
`upstream-8cdc2b6-timer-benchmark-*`; neither run establishes isolated or native
macOS-equivalent performance yet.

## Prepared native macOS capture

The isolated local branch `verify/native-upstream-8cdc2b6`, at `b565090`,
contains four verification files and leaves the Linux port unpublished. Its
workflow archives the pinned upstream revision, captures the shared 173-image
corpus on macOS and runs the original Release adjustment benchmark. Repository
permissions are read-only and the job has a 60-minute limit. The capture helper
uses explicit testability and ad hoc signing settings for the Release test app.

Five Python tests pass, the workflow parses as YAML and all eight shell steps
pass syntax checks. The isolated worktree is clean and the main worktree's
preexisting staged patch is unchanged. No native runtime result is claimed:
publishing the verification branch and starting its job remain pending explicit
user authorization for `git push`. Preparation evidence is recorded in
`upstream-8cdc2b6-native-oracle-preparation.json`.

## Contained raster crop allocation

A second stack sample of the current benchmark shows CPU compositing through
blend and transform nodes. Together with the earlier crop-allocation sample,
this supports investigating allocation work but does not establish a dominant
bottleneck. `Raster.cropped` previously cleared its whole destination before
copying rows, including when the source covers every destination pixel. It now
uses uninitialized storage only for that fully covered case; partial and
disjoint crops retain transparent initialization.

An isolated source experiment compares 8,000 old/new crops bit for bit,
including empty dimensions, negative origins, padding and arbitrary float bit
patterns. All match. A permanent regression checks copied channel bits and
every padding pixel, including HDR, signed zero, infinity and NaN. All 26 focused
crop, graph, Gaussian, motion and sampling tests pass with actual Vulkan, and
the protected-source and ledger guard passes. Eight measured original-then-new
pairs for a 3200 × 2000 contained crop give medians of 67.2 ms and 56.6 ms on the
shared host. These kernel measurements overlap other work and are not isolated
application or native-equivalence evidence. Artifacts use the
`upstream-8cdc2b6-crop-` prefix.

The running performance executable remains the earlier immutable timer-fix
snapshot. Its original source hashes are preserved; a separate provenance
annotation records this later working-tree change.

## Motion pyramid and native scanlines

`Sources/Compat/CoreImage/MotionPyramid.swift` separates reduction planning,
discrete-variance Gaussian construction and cubic reconstruction from the Core
Image graph adapter. The graph requests the complete input footprint before
rendering. Native impulse phases identify fixed symmetric reduction kernels;
independent step/stripe and angular controls validate their use. Small radii
retain the existing full-resolution implementation.

A continuous-variance subtraction model fails 162 of 2,640 native scanlines,
so it was rejected. Solving for the discrete kernel's variance instead passes
all 2,640. The first independent selector exposes 32 failures at radius 3.99,
where native already uses factor four. Correcting that measured transition
removes all 32 failures in the actual Swift adapter. No native output or
tolerance is changed. The compressed regression fixture losslessly preserves
all native bytes using grayscale plus opaque alpha; its extraction is
reproducible from the capture with SHA-256
`0ab6c00bfb3d59c618081416e6c682dbe535298cc2d5c9fc248ff41012adc4b4`.

All 11 focused tests pass, including the previously failing ±35° native
gradients and full-frame/regional equality for negative origins, vertical motion
and fractional angles. Full XCTest qualification passes 228 tests with zero
failures; its one skip is the opt-in morphology timing measurement. Swift
Testing runs 1,062 parallel tests with exactly the same 18 golden assertions,
arguments and maximum differences as the timer baseline; all 48 serialized
tests pass. Fresh CPU/Vulkan application exports match 173/173 decoded pixel
buffers, numeric samples and ICC data. Evidence uses the
`upstream-8cdc2b6-motion-pyramid-` prefix.

Only two exports differ from the timer baseline. Against the existing native
capture at `7b5ba97`, the +35° motion adjustment's maximum error improves from
10 to 3; the extreme motion filter's mean channel error improves from 1.938 to
0.659, while its maximum remains 127. The other three motion exports are
unchanged. These five application comparisons still contain differences and
do not establish complete native motion parity. Relevant upstream filter and
adjustment diffs since that capture affect Lens Effects, but the capture is
still older than the requested current upstream revision.

This is not arbitrary-radius native equivalence: captures bracket the early
factor-four transition between 3.9 and 3.99 without locating its exact boundary,
and native scanline validation stops at radius 35. Additional native reduction
levels at larger radii remain unverified. The immutable running performance
executable predates this change.

## Direct motion kernel precision

The remaining default motion PNG error of 255 occurs at alpha 1/255: a single
premultiplied channel quantum changes the decoded straight channel from 0 to
255. Float64 premultiplication of the decoded exports gives maximum RGB errors
of 1.318 byte levels for the default filter, 1.482 for the extreme filter and
1.953 for the +35° adjustment, with maximum alpha error one. These measurements
explain the amplification; the strict comparison and its limits are unchanged.

The captured direct-kernel parameters and float buffers are reproduced by a
finite Gaussian coefficient table, folding tails according to the selected
kernel and quantizing paired texture fractions to 1/256.
`Sources/Compat/CoreImage/MotionKernel.swift` generates these
taps from the requested radius. The Core Image adapter opts into those taps;
the existing raster convolution remains available for its scalar mathematical
tests. This keeps kernel construction separate from raster execution.

The generated model passes 384 native direct scanlines with maximum float error
0.0114 byte levels and 96 held-out two-dimensional controls within one byte.
`NativeMotionKernelTests` retains the captured red and alpha float buffers in a
losslessly extracted gzip fixture. Its initial control rejects the previous
convolution with color/alpha errors of 0.002620/0.001280 in normalized units.
The new generator passes the same 1/8192 color and 1/65536 alpha limits. All
12 focused tests pass, and full XCTest passes 229 tests with zero failures and
one opt-in timing skip. Parallel Swift Testing retains exactly the same 18
golden assertions in 1,062 tests; all 48 serialized tests pass. CPU/Vulkan
exports match 173/173 pixel, numeric-sample and ICC buffers. Against the existing
native capture, the default motion filter's maximum channel error falls from
255 to 2, and the default motion adjustment's falls from 2 to 1. Evidence uses
the `upstream-8cdc2b6-motion-direct-` prefix.

These finite capture sets do not establish every direct-kernel family boundary
or arbitrary-radius native equivalence. The other golden, curve and native
application/performance requirements remain open. The two running performance
executables predate both motion changes.

## UNORM8 sampling precision and source formats

A follow-up model rounds interpolated byte-texture samples to 1/4080, with
positive half ties upward. Across the same 384 native float controls, its
maximum error falls from 0.01134 to 0.00002063 byte levels. The transparent
overlay model reproduces the native default motion PNG exactly. This concerns
sample precision, independent of the lossless byte packing used for GPU uploads.

The Core Image source node now records whether its input uses byte storage.
Integral crops, clamps, sampling markers and aligned integer transforms preserve
that provenance. Computed intermediates and explicit half/full-float inputs use
float sampling. Byte precision is enabled for unmanaged evaluation; working-space
conversion uses float sampling.
The original C row API is retained; a separate byte-sampling entry point shares
its bounded scalar/SIMD implementation.

Tests distinguish byte, half and float inputs containing identical 0/1 values,
compare scalar boundary pixels with SIMD interiors, and verify all 384 captured
float buffers at a tighter 1/1048576 normalized color bound. The first routing
test accidentally requested linear output while expecting encoded values; its
output space was corrected to sRGB without changing renderer color conversion.
All 15 focused tests pass. Full XCTest passes 232 tests with zero failures and
one opt-in timing skip. Parallel Swift Testing retains the identical 18 issues
in 1,062 tests; all 48 serialized tests pass. The host C compiler also accepts
the source with `-Wall -Wextra -Werror` and a task-local ccache.

CPU/Vulkan exports match all 173 decoded pixel buffers, numeric samples and ICC
data. Only the default motion filter changes from the preceding direct-kernel
checkpoint. Its native maximum error improves from 2 to 1, satisfying the
existing one-byte comparison bound; the other four motion exports are unchanged.
The native capture remains the older `7b5ba97` revision, so this is a scoped
comparison, not latest-upstream full-application qualification. Full HD byte
sampling unit checks materialize horizontal and vertical results in about
25 ms on this shared host; these are not isolated or native-equivalent timing
claims. Evidence uses `upstream-8cdc2b6-motion-byte-sampler-` and
`motion-byte-sampler-` prefixes. Other golden, curve, angular/extreme-motion,
latest-native-capture and performance requirements remain open.

Additional angular-motion diagnostics compare byte, nearest-half and
toward-zero half intermediates on 36 native direct-motion controls. Some
variants reduce average float error, but none establishes a consistent native
precision rule. No renderer or comparison-bound changes were made from those
experiments; the 232-case XCTest and 173-export qualification above remains
the current production checkpoint. See the angular intermediate precision
section in `coreimage-sampling-diagnostics.md` for measured results and scope.
Both earlier benchmark sessions were still running at the latest poll and
had not produced final results; they predate the current motion implementation.

## Reviewed Hue and Saturation regression baselines

The four Linux Hue/Saturation baselines at full and half opacity now record
the native-qualified byte blend adapter. Fresh bridge verification passes all
24 independent native cases (1,179,696 pixels) within the existing one-byte
bound. All four current application exports also compare within one byte to
the older `7b5ba97` native capture, and their CPU/Vulkan decoded buffers match.
This remains a scoped comparison, not latest-upstream native qualification.

The fresh 64-by-48 regression images were visually reviewed before replacement;
the originals are backed up under the local evidence directory. At the largest
changed Hue pixel, (14, 40), the new `[112, 192, 190, 255]` matches the independently
captured native pair exactly. The previous Linux baseline was
`[56, 217, 215, 255]`; opacity collapses the nearly gray source to gray before
the byte blend. The other maximum baseline changes are two levels for Hue at
full opacity and three/two for Saturation at full/half opacity. Renderer code,
native reference buffers, and comparison limits are unchanged.

Source and before/after hashes, native comparison scope and boundary-pixel
evidence are recorded in
`.build/evidence/upstream-8cdc2b6-blend-baseline-review.json`. Exclusion and
the other unreviewed rendering baselines retain their previous pixels.

The fresh parallel Swift run executes 1,062 tests in 188 suites and reports
14 golden assertions, down from 18. The four removed assertions are exactly
these reviewed baselines; all remaining assertion messages, affected-channel
counts and maximum differences match the preceding checkpoint. The CPU blend
run also passes these four cases and retains only the two Exclusion assertions.
All 48 fresh CPU/Vulkan blend renders have identical decoded RGBA buffers.
No compiled source changed in this baseline-only step, so the previously
qualified 232-case XCTest and 48-case serialized results were not rerun.
The upstream guard and `git diff --check` pass; the preexisting staged patch
is preserved byte for byte.

## Reviewed Exclusion baselines and durable native byte matrices

The Source Over and Exclusion matrices from native run `40106852437` are now
retained in `Tests/Fixtures/coregraphics-byte-blend-reference.json.gz`. The
fixture preserves every captured source/input/output byte and its SHA-256,
records the original capture SHA-256 and macOS version, and adds explicit
eight-bit component metadata. It covers all source alpha and backdrop values
on opaque, translucent and clear backdrops at opacity 1, 0.5 and 0.25.

The existing contract check `tests/test_nonseparable_blends.py` now verifies
these 18 matrices as well as its unchanged 24 Hue/Saturation controls. All
1,179,648 Source Over/Exclusion pixels match exactly, with no one-byte allowance;
Hue/Saturation retains its existing one-byte bound. The contract script already
invokes this check. Python compilation and fixture hash validation pass.

After visual review and original-file backup, the two Linux Exclusion baselines
were updated to the qualified output. Each changes by at most two channel
levels. Both application exports are decoded-RGBA identical to the older
`7b5ba97` native capture and to each Linux backend; this does not establish
latest-upstream native application parity. No renderer source or tolerance
changed in this step.

The original two failing blend assertions are resolved: all 48 blend cases now
pass on CPU and Vulkan. The complete Linux golden suite reports 12 remaining
assertions, exactly the preceding 14 minus the two Exclusion cases, with all
other messages and maximum differences unchanged. The full 1,062-test run was
not repeated after these two baseline-only changes. Evidence and original/new
hashes are in `.build/evidence/upstream-8cdc2b6-exclusion-baseline-review.json`;
logs use the `upstream-8cdc2b6-exclusion-` prefix.

## Current older-capture diagnostic and benchmark interruption

A complete diagnostic comparison of the current 173 exports with the older
`7b5ba97` macOS capture meets the existing category thresholds for 154 images.
Both revision identities are preserved, all artifact hashes are checked, and
the corpus/input hashes and case catalog match. The strict comparator's
same-upstream requirement is unchanged: this diagnostic does not qualify
latest-upstream native application rendering.

The 19 failures are Gaussian Blur's default adjustment, four RGB Split cases,
five RAW cases and nine text cases. All five motion exports meet their category
thresholds, though the previously recorded strict channel differences remain.
Results are in `.build/evidence/upstream-8cdc2b6-current-native-diagnostic.json`.

A proposed Gaussian correction using the independently identified motion
reductions fails held-out native controls and was rejected. Gaussian's graph
contains a processor alternative, and its measured impulse variances differ
from motion despite matching listed residual parameters. The sampling
diagnostics document the measurements and why graph text is insufficient to
establish the selected native path. No renderer change follows from that model.

Benchmark session 98292 has now terminated with exit 143. Its known test process
(host PID 256684) is absent, the attachment directory is empty and the script
did not write its exit marker. The cause is unknown; this supplies no final
performance result and was not automatically restarted. The launch provenance
is retained, with this terminal observation appended separately. Session 40629
and its known test process remain live at the latest check; that executable
predates the current optimizations and is not current performance qualification.

## Reviewed Dither baseline

The Linux Dither regression baseline now records the already qualified
pixel-aligned downsampling correction. Fresh native sampling verification
passes 204 controls within one byte. Both current default/extreme Dither
application exports are decoded-RGBA identical to the older `7b5ba97` macOS
capture and each Linux backend. Latest-upstream native qualification remains
separate.

The fresh 64-by-48 Dither baseline was visually reviewed and its original bytes
backed up before replacement. The complete golden suite now retains eleven
assertions on both CPU and Vulkan, exactly the prior twelve minus Dither;
all other assertion messages, affected-channel counts and maxima are unchanged.
Renderer code and tolerances are unchanged. The full framework suites were
not repeated for this single baseline replacement. Source and before/after
hashes are in `.build/evidence/upstream-8cdc2b6-dither-baseline-review.json`.

Independent native text diagnostics reject three proposed smoothing models.
No text rendering correction was applied. See the sampling diagnostics for
their measurements and the remaining need for per-glyph native evidence.

## Reviewed tone, lens and layer-effect baselines

Ten remaining Linux regression baselines were reviewed together: adjustment
and filter Tonal Contrast, adjustment and filter Lens Effects, and the six
default ellipse layer effects. Every original/current pair was visually
inspected and the originals backed up before replacement. This records
previously implemented rendering corrections; no renderer or tolerance changed.

Fresh focused verification passes nine XCTest cases and the native Metal
adjustment-compute test. Sixteen corresponding application exports meet their
existing category thresholds against the older `7b5ba97` macOS capture, with
verified artifact/corpus/input hashes. CPU/Vulkan decoded buffers match for
every comparison. Five layer-effect exports match native exactly; Inner Glow
differs by at most one channel level. This is still older-capture evidence,
not latest-upstream native qualification.

The native curve check passes all thirty ellipse controls within one byte.
Its complete result remains 93/94: `rounded-size-4-phase-0.25-affine` still has
three pixels differing by two levels. That failure is retained in the review
report and was not removed or relaxed by these baseline updates.

Both complete golden suites now retain one assertion, exactly the preceding
eleven minus these ten reviewed cases. The untouched `text/text-and-shapes`
comparison still has 136 channels differing by up to twelve. All ten reviewed
64-by-48 images have identical decoded CPU/Vulkan pixels. Full framework
suites were not repeated for this baseline-only step; the prior RAW-metadata
qualification remains the latest compiled-code checkpoint.

Hashes, native measurements, the complete curve result and backup provenance
are recorded in `.build/evidence/tone-effects-baseline-review.json`.

## RGB Split CPU edge rounding and reference scope

The CPU dispersion fallback now uses a reciprocal/FMA spectral parameter.
The preceding division-first form fails the new independent native adjustment
alpha regression by three byte levels; the corrected form matches every alpha
byte. The native alpha fixture binds the procedural source, original shader
prefix and application capture provenance. CPU and AMD Vulkan pass this check,
the existing native default-filter reference, all four native two-pass cases
and the existing direction/ROI/alpha/HDR contracts without relaxed bounds.

Full qualification passes 232 XCTest cases (one timing skip), 39 focused Swift
checks and 48 serialized tests. The parallel run executes 1,063 tests with only
the unchanged text assertion (136 channel values, maximum twelve). All 173
application exports preserve decoded pixels, numeric samples and ICC data;
current CPU/Vulkan settings also agree. Those runs retain the hardware
dispersion driver, while the direct CPU regression explicitly passes no driver.
The correction therefore proves CPU kernel edge coverage, not wholly software
application equivalence. The source checkpoint is
`.build/evidence/rgb-parameter-candidate.json`.

The older native application capture predates upstream's two-pass blur change.
The negative RGB Split adjustment and extreme filter use changed orchestration
and fine-grain placement; their older PNGs do not qualify the current algorithm.
They remain unqualified, not newly passing cases. The two unblurred adjustment
comparisons still use the byte-identical original shader and retain sine/jitter
color differences. This scope classification does not alter the older-capture
diagnostic's measurements or claim latest-upstream native parity. See
`linux-dispersion.md` and
`.build/evidence/rgb-upstream-comparison-scope.json`.

## Current Release benchmark

The old earlier-planner benchmark was deliberately superseded on 2026-10-26.
Its exact task-owned executable and host PID 147676 were checked before SIGTERM;
session 40629 then returned terminal exit 1. This was an intentional stop of an
obsolete executable, not a timeout or evidence of a current rendering failure.
Its original logs and launch manifest remain intact; the termination record is
`.build/evidence/upstream-7651033-planning-benchmark-superseded.json`.

The unmodified upstream `AdjustmentPerformanceTests.adjustmentLayerFrameTimes`
completed on the current qualified Release executable in session 10704, exit 0
after 10,855.805 seconds. It keeps
the original 4000-by-2600 source, 3200-by-2000 output, twelve adjustment cases
and cached/uncached frame measurements. No other builds or rendering checks were
scheduled alongside it. The launch manifest records 524 source-file hashes,
the executable hash and native-library hashes in
`.build/evidence/upstream-8cdc2b6-rgb-parameter-benchmark-source.json`.
The strict timing parser validates the baseline and exactly twelve named cases
in the final attachment. All recorded source, executable and native-library
hashes still match at completion. Results are retained in
`.build/evidence/upstream-8cdc2b6-rgb-parameter-benchmark-result.json`, with the
original `frame-times.txt` in the companion attachment directory.

| Case | Uncached median (ms) | Cached median (ms) |
| --- | ---: | ---: |
| No adjustments | 6,013.8 | — |
| Curves | 9,784.5 | 5,555.9 |
| Gaussian Blur 20 | 6,437.1 | 5,633.9 |
| Bloom / Glow | 7,128.6 | 5,578.1 |
| RGB Split | 4,419.9 | 5,530.9 |
| Vignette | 2,479.6 | 5,508.8 |
| Tonal Contrast | 10,888.8 | 5,475.9 |
| Anamorphic Flare | 158,836.4 | 3,863.8 |
| Starburst | 614,547.6 | 6,048.9 |
| Mist | 36,256.5 | 6,088.9 |
| Prism | 135,484.1 | 6,092.7 |
| Bokeh | 81,534.0 | 6,043.0 |
| Curves/Tonal/Bloom/Vignette/Mist stack | 44,792.4 | 3,943.4 |

The host has a Ryzen 5 7430U, twelve logical CPUs available to the process,
and about 22.6 GiB RAM. Bounded host observations are in the companion
`-benchmark-host.json`. General desktop activity is uncontrolled; no other
qualification builds or rendering checks were scheduled alongside this run.
The variation across cases, including cached values exceeding some uncached
values, precludes attributing timing differences to one kernel without profiling.
This measures the Linux host, not macOS-equivalent speed. Successful test
completion does not qualify the multi-second baseline or very large uncached
lens costs as acceptable interactive performance.

## Starburst profiling diagnostic

`Tests/LinuxOverrideTests/StarburstPerformanceTests.swift` adds an opt-in single
render through the existing `LensEffectSettings.apply` entry point. Set
`COMPOSITOR_STARBURST_PROFILE_WIDTH` to an integer from 400 through 4000 and run
`StarburstPerformanceTests` with the normal Linux backend environment. The input
is a dark opaque image with one white rectangle, using unchanged default
Starburst settings and a hardware-canvas context. It records a timing attachment
and checks hardware availability when required and the rendered dimensions.
Without the variable, it does no rendering. This supplements the original
benchmark; it does not replace its image, canvas path or measurements.

The Release build and opt-in runs pass at 2000 by 1300 (21,592.7 ms) and 3000 by
1950 (95,167.9 ms). Debugger attachments perturb these diagnostic timings. The
existing upstream 400-by-240 Starburst test separately passes in 0.436 seconds.
The first stack attempt lacked executable symbols across the Flatpak boundary;
the next attach missed the completed process. Three subsequent automated,
bounded samples resolve executable symbols using the container filesystem and
GDB's `--readnever`, avoiding unsupported Swift DWARF parsing.

Those three samples observe `RasterFilters.projective`, `alignedAffine` and
`colorMatrix` in CPU evaluation beneath nested shared-node requests. They do not
establish time proportions or a complete root cause, and do not justify treating
Lanczos alone as the bottleneck. No production renderer or protected upstream
source changed in this profiling step. The upstream guard and diff checks pass;
full framework suites were not repeated for this opt-in diagnostic alone.
Source hashes, attachments and limitations are recorded in
`.build/evidence/starburst-profile-diagnostic.json`; stack files use the
`starburst-3000-profile-stack-` prefix. The completed original benchmark binary is
preserved separately, with its hash checked after the diagnostic build.
