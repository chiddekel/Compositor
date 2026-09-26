# Tool E2E and response-time results

Verified September 27, 2026 on Linux with KDE SDK 6.11, the release Swift/Qt host,
Skia rendering, the CPU brush backend, and native X11 input on a private Xvfb desktop.

## Tool inventory and coverage

All 15 tool families have native desktop journeys. Input goes through the visible
application; assertions inspect actual document pixels and application state.

| Tool | Covered behavior and modes |
| --- | --- |
| Move / Transform | Drag, placement, exposed transparency, undo |
| Marquee | Rectangle and Ellipse; selection-clipped painting, deselect, undo |
| Lasso | Freehand and Polygonal; selection-clipped painting, deselect, undo |
| Magic | Wand and Object selection paths; selection-clipped painting, undo |
| Crop | Cancel, apply, dimensions, exact retained pixels, undo |
| Brush / Eraser | Width, opacity, soft edges, smoothing, trajectory preservation, erase, undo/redo |
| Spot Healing | Content-Aware, Create Texture, Proximity Match; corrected spot, distant pixels, undo |
| Clone Stamp | Source sampling, copied pixels, preserved source, undo |
| Smear | Liquify, Blur, Smudge; pixels, live preview, undo, fresh-feedback latency |
| Gradient | Linear and Radial; preview, cancel, apply, falloff, undo |
| Shape | Rectangle, Ellipse, Line; geometry, fill, undo |
| Type | Native text entry, commit, rendered glyphs, undo |
| Eyedropper | Sample color and paint with that exact color |
| Hand | Pan with unchanged document pixels |
| Zoom | Zoom in/out with unchanged document pixels |

The suite also checks all tooltips, layer naming, color dialogs, save/reopen,
repeated brush workloads, and ten PSD import/conversion journeys. The deliberate
input-compression negative control detected its expected missing-trajectory failure
(3 of 180 path points), confirming that the input-loss assertion is effective.

## Fixes

- Working Liquify and Smudge pixels now appear before release. Dirty-region tracking
  follows newly interpolated dabs, and preview rendering preserves linked-mask placement.
- Corrected affine concatenation in the Linux Core Graphics shim while retaining
  CGContext and convenience-transform semantics. Masked and unmasked preview tests pass.
- Removed main-actor lifetime isolation from the stateless CPU brush worker, fixing
  the worker-thread deinitialization crash identified in the debugger.
- Soft-brush coverage skips exact saturated/zero-support cases and processes disjoint
  rows concurrently. Tests compare density and preview buffers against serial rendering.
- Large Gaussian results evaluate only requested regions and reuse 64 px tiles in a
  bounded cache (at most 256 packed RGBA tiles, approximately 4 MiB). Full-image byte
  access still materializes the complete image. A native vectorized convolution retains
  the original kernel and summation order; scalar-oracle and regional-equivalence tests
  cover edges, transparency, formats, cache eviction, and transformed drawing.
- Sparse mask clips expose conservative nonzero bounds with interpolation margins.
  The host's state poll uses partial painting updates instead of rebuilding the canvas
  and tool rail during a stroke.
- Liquify/Smudge cache exact radial weights for common tip sizes; larger tips retain
  the original calculation. This generated Linux override is compared byte for byte
  against the unmodified upstream stroke class. The source guard checks generation
  freshness; protected upstream trees remain unchanged.

## Acceptance results

- **52/52 native desktop checks passed**, with zero failures, errors, or skips:
  `/tmp/compositor-all-tools-20260926-d/junit.xml`.
- **498 regression tests passed**: 106 XCTest tests and 392 Swift Testing tests:
  `/tmp/compositor-native-final-swift.log`.
- `git diff --check` and `bash scripts/check-upstream-clean.sh` passed.

The desktop artifact directory also contains binary hashes, the working-tree summary,
input traces, screenshots, exported PNGs, and CPU/memory metrics. These `/tmp` artifacts
are local verification evidence and are not committed fixtures.

### Visible Smear feedback

Each mode uses a 1920 × 1080 image, a 256 px tip, 50% hardness, and 70% strength.
Five fresh edge crossings restore the original pixels before each sample. Timing starts
before native button-down and a 160 px move and ends when an independent X11 screenshot
patch changes. Every sample must meet the unchanged **100 ms** budget.

| Mode | Minimum | Maximum | Samples passing |
| --- | ---: | ---: | ---: |
| Liquify | 77.66 ms | 92.83 ms | 5/5 |
| Blur | 73.27 ms | 79.43 ms | 5/5 |
| Smudge | 67.78 ms | 74.12 ms | 5/5 |

Samples are retained in each `smear_feedback_*/visible-latency.json`. The measurement
includes stroke setup and screenshot overhead, but excludes hardware display scanout.
It establishes the budget for this workload and machine, not every operation or document.

### Sustained-input limitation

A separate stress workload supplies 81 path points at 3 ms intervals. After release,
the driver observed completion in 235–255 ms for Liquify, 317–353 ms for Blur, and
135–146 ms for Smudge (three measured strokes per mode, excluding warm-up). These
measurements include bridge/driver polling and queued work; they are distinct from
visible-feedback latency. Rapid sustained input can still leave a noticeable completion
backlog. The result does not establish sub-100 ms completion for this stress workload.

## Reproduce and scope

See [Linux desktop UI tests](linux-ui-e2e.md) for dependencies, commands, metrics,
and extension instructions. Run performance workloads sequentially, using the SDK
in `com.compositor.Client.yaml` and the matching libraries in `build/lib`.

```sh
UI_E2E_ARTIFACTS=/tmp/compositor-tools-new-run bash scripts/run-ui-e2e.sh
```

Use a fresh artifact directory. With an already built matching release executable,
add `--no-build`; focus Smear feedback with the three `--case smear_feedback_*` names
listed in the desktop-test guide.

Coverage does not include physical tablets/pressure, Wayland, hardware display latency,
RAW dependencies, or optional OpenCV model quality. The optional 1.27 GiB PSB stress
fixture is outside the default suite. These are not claims of universal feature or
performance coverage.

## Motion Blur follow-up, September 27, 2026

Adding a Motion Blur adjustment exposed a separate UI stall. `UpstreamEditor.settle`
waited for a `preparedPreview` even though adjustment editors render through the layer
composite and never create that image. Revision checks and frame reads each exhausted
the three-second timeout. The bridge now waits only for an actual preview task; tests
cover idle Motion Blur, Gaussian Blur, and Levels adjustment editors.

The scalar Motion Blur sampler was also replaced with a row-parallel native kernel
that precomputes tap offsets and interpolates four color channels together. Its output
matches the independent scalar reference within 0.000002 in float channels, including
fractional radii, diagonal/negative angles, single-pixel images, and transparent borders.

- The new `effect_motion_blur` desktop regression failed against the original binary:
  **9953 ms** to open the editor (`/tmp/compositor-motion-regression-before-2`).
- The fixed desktop journey passed in `/tmp/compositor-motion-regression-fixed-3`,
  including distance/angle changes, preview off/on, commit, and both undo steps.
  The opening budget is 1500 ms; the final passing run opened in **634 ms**.
- The full suite passed **108 XCTest + 393 Swift Testing tests (501 total)**:
  `/tmp/compositor-motion-full-tests.log`.
- Default full-HD kernel measurements were approximately 19–20 ms in the focused
  regression run (`/tmp/compositor-motion-tests.log`). This excludes UI and composition.

The earlier 52-check desktop result above predates this additional case. This follow-up
added the 53rd check and ran the new desktop case and the full Swift
suite, rather than claiming a new full-desktop-suite result.

Flatpak packaging now uses `com.compositor.Client`: manifest, desktop entry, icons,
AppStream component/launchable, host desktop identity, scripts, CI, and documentation
use the new name. `flatpak-builder --show-manifest`, `desktop-file-validate`, and offline
AppStream validation passed. This source rename does not migrate an existing installed
Flatpak's application data or install a new Flatpak package.

## Whole-image blur performance follow-up, September 27, 2026

Large Gaussian kernels now use overlap-save FFT convolution of the same finite,
normalized kernel. Small kernels and brush tiles retain direct convolution. The native
direct kernels select AVX2 on supported x86 CPUs and retain a portable fallback.
Motion Blur checks its sampling footprint once per row and processes eight interior
pixels together, retaining the bilinear interpolation and accumulation order. Filter
slider drags defer layer-thumbnail and tool-panel refreshes until release.

A paired native-desktop measurement on the Ryzen 5 7430U used the same 1920 × 1080
white image with a black rectangle. Times start before clicking OK and end when the
editor closes; they include driver polling, panel refreshes, and the full composite.

| Adjustment | Before | After |
| --- | ---: | ---: |
| Gaussian Blur, radius 50 | 953 ms | 399 ms |
| Motion Blur, distance 240, angle 0° | 579 ms | 330 ms |

Artifacts: `/tmp/compositor-blur-baseline-{gaussian,motion}-3` and
`/tmp/compositor-blur-optimized-{gaussian,motion}`. Each contains `performance.json`
and exported images at multiple blur amounts. Motion outputs match byte for byte;
Gaussian output differs by at most one 8-bit level at radius 50. Independent scalar
oracles cover transparent borders, fractional radii, FFT block boundaries, narrow
images, and regional rendering, with a maximum allowed float-channel error of 0.000002.

These are operation timings for this workload, not a sustained 25 fps claim. The
desktop tests check visible canvas changes while a slider is held and preserve the
final value on release, Preview off/on, Apply, and Undo. They do not measure continuous
frame rate. Full-resolution filter preview and destructive Apply/Undo are also covered
by `UpstreamEditorTests.blurPreviewAndApplyAtFullHD`.

Validation for this follow-up:

- **503 regression tests passed**: 109 XCTest and 394 Swift Testing tests in
  `/tmp/compositor-blur-full-tests-verified.log`. The full-HD destructive filter
  tests measured Apply plus compositing at 105 ms for Gaussian radius 25.6 and
  90 ms for Motion distance 120 at 45°; these exclude the desktop shell.
- `effect_motion_blur` and `effect_gaussian_blur` pass in
  `/tmp/compositor-blur-desktop-final-2` (editor openings 585 ms and 599 ms).
- `smear_feedback_blur` passes in `/tmp/compositor-blur-smear-regression`, including
  all five visible-feedback samples at 60–63 ms against the existing 100 ms budget.
- `git diff --check` and `bash scripts/check-upstream-clean.sh` pass.
- The default desktop suite now contains 54 cases; only the affected journeys were
  rerun for this follow-up, not the entire desktop suite.
