# Upstream 1.5.7 on GNU/Linux

Target: `574ea8d` (upstream main fetched October 23, 2026), following `a5c900d`.

The upstream application, Xcode project and tests are integrated unchanged. Lens Effects adds anamorphic flare,
starburst, mist, prism and bokeh, including round, hexagon, oval and cat's-eye apertures. RGB Split's blur now samples
both ways along the split instead of shifting the image to one side. The Linux About version follows 1.5.7, build 53.

The upstream optics and controls compile directly. Linux support lives in the compatibility modules:

- Core Graphics supplies `CGVector`.
- Core Image supplies bitmap-data images, sRGB transfer filters, five-point tone curves and rectangular morphology.
  `LensRaster` owns the regional morphology and spline calculation, reusing the existing float raster evaluator.
- Metal supplies half-float textures and dispatches the bokeh entry point to `BokehCompute`. Its CPU gather follows
  upstream's aperture, rim weighting, edge sampling and half-float output. Upstream still controls downsampling for
  large blur radii. This path does not require a physical GPU.
- Both CPU and Vulkan dispersion implementations use the centered blur interval; bundled SPIR-V is regenerated.

The new Linux tests cover HDR bitmap row order, transfer functions, tone-curve control points, morphology, all four
apertures' preservation of constant HDR pixels, resolution of the original controls for all five effects, and
RGB Split centering through the upstream Swift filter at horizontal and vertical angles. They
join the unchanged upstream `LensEffectsTests` in Linux CI. The standalone dispersion regression checks the blur's
centroid and light on both sides, and permits software Vulkan when the driver meets the backend's requirements.

## Verification

Evidence is under `.build/evidence/upstream-1.5.7/`.

- All 10 unchanged upstream Lens Effects tests pass in the KDE SDK with the Skia/Qt backends.
- All five compatibility/HDR tests pass, the original FilterSheet resolves its controls for all five effects, and
  the upstream Swift RGB Split filter passes both centering cases.
- The diagnostic follow-up passes all 175 XCTest cases, 1,013 unaffected Swift tests, and 48 serial Swift tests.
- Protected-source, generator, shader, override-drift and ledger integrity checks pass. The ledger covers 110 commits,
  including 85 code commits.
- Source coverage accounts for all 174 upstream Swift files: 144 unchanged, 23 generated, five replacements and two
  platform substitutions. It includes 98 unchanged test files and two generated mirrors. All 11 coverage fault tests pass.
- The final release application builds and links. The native Qt filter-controls journey exits successfully after
  42 cases, covering preview, Cancel/OK, pixels, history and undo/redo for existing filters.
- A fresh native CMake build passes all 16 CTest targets and the standalone CPU dispersion checks.
- The dispersion centering regression fails against the old one-sided sampling: its light centroid moves from
  30 to 38.02. The centered implementation passes.
- Vulkan execution remains unverified. A capability probe confirms that both host and SDK lavapipe report
  `shaderDenormPreserveFloat32 = 0`, while the raster backend requires it. No hardware `/dev/dri` device is present.
  `vulkan-sdk-probe.log` records the capabilities; device requirements have not been relaxed.

The macOS Xcode build and tests have not been run locally. Upstream's [1.5.7 release CI](https://github.com/robbietilton/Compositor/actions/runs/40000627289)
ran the filter suites and passed all four unit-test groups on macOS. The protected application, test and Xcode
project files at its tested commit `9537736` are identical to `574ea8d` and the current protected worktree. This
verifies the unchanged upstream Mac sources, not execution of the Linux compatibility modules on a Mac.
The old native CMake cache retained a missing local `build/poppler/install` path. Configuring a fresh
`.build/upstream157-native` directory against the SDK's `/app` dependencies resolves it without changing the build
configuration. `native-build-fresh.log` and `native-tests-fresh.log` retain the successful build and CTest results.
This native run complements the separately executed Swift suites and Qt journey; the entire combined contract
script has not passed because its unchanged upstream RGB Split assertion and GPU tests remain unresolved.

## Full-suite findings

The first full parallel run executes 1,028 Swift tests and reports 17 issues. Fifteen are GPU availability failures
(`CameraRawGPUTests`, one `Upstream153AcceptanceTests` test, one `GPUCanvasTests` test, and `GPUCanvasUploadTests`).
No usable Vulkan driver is available here. A missing golden for the newly added Lens Effects filter accounts for
one issue; the generated baseline was visually inspected and is included with this integration.

The remaining issue is upstream's unchanged `FilterTests.rgbSplitSpreadsASpectrumAlongItsAngle`, at line 252.
It expects nonzero blur at columns 44–48 from a light spanning 28–32, a split distance of 4 and blur length of 16.
Upstream's macOS release CI passes this test, so the initial diagnosis that the assertion was stale was incorrect.
The Linux result is still a parity discrepancy; the upstream test remains unchanged and failing.

The assertion examines a jitter-sensitive edge. The shader computes its per-pixel jitter from `fract(sin(dot(...))
* 43758.5453)`. For the decisive pixel at (44, 30), the CPU hash gives jitter 0.2852 and zero tail alpha. With the
same centered sampling and a controlled diagnostic jitter of 0.99, the tail alpha becomes 0.0668 and passes the
assertion. `jitter-tail.log` records this experiment, which changes only a temporary backend under `.build`.
The evidence shows the assertion can differ with jitter, but does not yet establish the exact jitter or arithmetic
on Apple's GPU. That pixel comparison remains open. The production hash and device requirements are unchanged.

The independent dispersion regression verifies the intended centroid and two-sided spread; restoring the old
one-sided interval fails it with an approximately eight-pixel shift. `RGBSplitCenteringTests` additionally checks
the actual upstream Swift filter at horizontal and vertical angles. No permanent test exclusion is added for the
parity discrepancy or GPU availability failures.

The diagnostic follow-up run omits only these known failing tests and the suites run separately for shared-state
isolation. Its results cannot be described as a passing full suite; the first full run is retained as
`swift-parallel.log` and the diagnostic run as `swift-unaffected.log`.

The first diagnostic invocation omitted the CMYK profile fixture in its fresh Flatpak session and failed five
profile-dependent tests. Its log is retained as `swift-unaffected-missing-profile.log`; the corrected run installs
the standard fixture before testing and is the passing diagnostic result above.

## Capturing the missing native Metal reference

`scripts/check-parity-rgb-macos.swift` reads the production MSL unchanged from `MetalDispersion.swift`, renders the
exact 61×61 white-square fixture for the flat and blurred settings, and reports columns 40–48 of row 30 as JSON.
A separate diagnostic kernel evaluates the extracted jitter expression; it does not alter the production shader.
The report includes the device and OS, shader and fixture SHA-256 hashes, tail alpha bytes and the original tail
assertion's result. An unavailable Metal device is an error, not a substituted CPU reference.

On a Mac, from the checkout root:

```sh
swift scripts/check-parity-rgb-macos.swift "$PWD" > rgb-metal-parity.json
```

The `RGB Metal parity reference` workflow can capture the same report on `macos-26`. It runs manually or on a push
to the diagnostic branch `verify/rgb-metal-parity`, with read-only repository permissions, and retains the JSON as
an artifact. Once the workflow is present on the default branch, it can be dispatched against `GNU_Linux` or
`main` without publishing a separate diagnostic branch.

The probe passes Swift syntax parsing and Linux type checking, and its unsupported-platform guard exits with an
error and no JSON on Linux. Workflow YAML, branch trigger and permission checks pass. Its native Metal branch is
prepared but remains unexecuted. Expected shader/fixture hashes are recorded in
`.build/evidence/upstream-1.5.7/rgb-probe-expected-hashes.json` for validating a returned reference artifact.
