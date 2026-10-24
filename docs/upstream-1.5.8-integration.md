# Upstream 1.5.8 on GNU/Linux

Target: `c9c7531` (upstream main fetched October 24, 2026), following the
[1.5.7 integration](upstream-1.5.7-integration.md).

The seven changed upstream application, test, Xcode project and update-feed files are incorporated unchanged.
Linux platform support stays in the compatibility modules and Linux-owned tests.

## Behavior

- Projects written by 1.5.4 and 1.5.5 open again. Upstream's loader accepts versions 1–17 plus the GIF branch's 27;
  new saves still write format 17. This restores an accepted-version range and does not change the saved format.
- Prism makes crisp copies across the full frame, has Blur instead of Reach, and can echo to one side or both.
  Offset zero remains an applicable effect because its color fringe is still visible.
- Threshold reaches 100. Above 95, flare and starburst weigh the size and density of clipped-white lights against
  the picture's strongest source, rather than treating every small white glint as equally strong.
- The Linux About version follows upstream 1.5.8, build 54.

The original optics and controls compile directly. The compatibility layer adds `CIAreaMaximum`, `.Rf` bitmap
output, and `CIMorphologyMaximum`; `LensRaster` owns the circular dilation. Sliding maxima across the disc's spans
avoid searching a full disc at every output pixel. Reduction and float output retain HDR precision and working
color space, without passing through an 8-bit bitmap.

## Verification

Evidence is collected under `.build/evidence/upstream-1.5.8/`.

- The initial focused SDK run passes 10 XCTest cases and 25 Swift tests, including the new compatibility operations,
  Threshold 100 behavior, updated upstream Prism tests and restored project-version loading.
- Upstream's [1.5.8 macOS release CI](https://github.com/robbietilton/Compositor/actions/runs/40063779824) ran its filter
  suites and passed all four unit-test groups. Its protected sources match the integrated upstream files.
- The commit ledger covers 116 commits, including 89 code commits, with references for each new behavior.
- The C ABI UI-action follow-up passes 5 XCTest cases and 8 Swift tests. Prism's direction picker round-trips
  through the same JSON selection actions emitted by Qt, with Preview both off and on. Its asynchronous preview
  adds/removes the opposite-side echo, while original pixels and history remain unchanged; Cancel preserves them.
  The native-session lifetime and event/shortcut action regressions pass alongside it (`prism-native-actions.log`).
- All 180 XCTest cases, 48 serial Swift tests and 16 native CTest targets pass. The parallel Swift run executes
  1,032 tests before the UI-action follow-up and records exactly the existing 16 issues: 15 unavailable-GPU failures and the RGB Split tail-pixel
  discrepancy. No additional failures were reported. The full suite is not green.
- Protected-source/generator/shader checks pass. Source coverage accounts for 174 upstream Swift files and
  98 unchanged test files plus two generated mirrors; all 11 coverage fault tests pass.
- The final release application builds and links. The native filter journey passes all 42 cases, covering preview,
  Cancel/OK, pixels, history isolation and exact undo/redo. The verification script exits nonzero for the known
  parallel Swift test failures; it does not hide or permanently exclude them.

The selected checks include the unchanged upstream `LensEffectsTests` and `ProjectTests`, Linux controls and bokeh
tests, RGB Split centering, and new compatibility cases for area-reduction extents/HDR precision, red-float row
order and padding, working-space conversion, circular dilation and tiled output. A full-filter test checks that
Threshold 100 rejects small glints while retaining the stronger light source. Linux CI selects these suites.

The initial 1.5.8 verification retained the RGB Split tail-pixel discrepancy and device-availability limits
documented for 1.5.7; upstream 1.5.8 does not change that shader or its test. The first native Metal
[reference capture](https://github.com/chiddekel/Compositor/actions/runs/40099667440) passed on Apple's paravirtual
device, macOS 26.6.2. Both shader and fixture hashes match the local probe. At pixel (44, 30), the original shader
produces blurred alpha 9/255, with zero alpha in the unblurred tail. Its diagnostic jitter is 0.8752594, versus
Linux libm's 0.2852325. This confirms a platform arithmetic discrepancy rather than an obsolete upstream assertion.
The probe now observes phase, sine, noise and jitter with both default and disabled fast math to locate the
difference. The [follow-up capture](https://github.com/chiddekel/Compositor/actions/runs/40100150422) also passed:
disabling fast math returns sine/jitter values close to Linux libm. The default Metal values match float-cycle
range reduction and a fused dot product, which identifies the compatible arithmetic used below. These diagnostic
kernels do not modify the production shader.

The compatibility backend now performs that reduction and dot product explicitly on CPU and Vulkan, with a
regenerated shader header. On CPU, all nine captured blurred pixels match the Metal bytes exactly; the unblurred
pixels differ by at most one byte. The checked-in native reference includes device/OS, shader/fixture hashes,
arithmetic diagnostics and the capture URL. Its regression fails against the old CPU implementation and passes
with the fix, alongside the existing standalone spectrum/centering/ROI/alpha checks. The unchanged upstream
`rgbSplitSpreadsASpectrumAlongItsAngle` test now passes; all 16 selected Swift filter and centering tests pass.
The full follow-up executes all 180 XCTest cases successfully and 1,033 parallel Swift tests with exactly the
15 device-availability issues listed above; RGB Split passes and no additional failures appear. All 48 serial
Swift tests and 16 CTest targets pass, as do source/generator/shader/ledger integrity and coverage checks. The
release application builds and links; its Qt filter journey passes all 42 cases. The verification script reports
one failed gate, the parallel suite's unavailable-GPU assertions. Evidence is in
`.build/evidence/upstream-1.5.8/rgb-fix/`. The full suite remains nonzero for unavailable GPU devices, and Vulkan
execution remains unverified. This does not establish bitwise parity across all devices or images.

The first full macOS render-corpus job built and passed its native tests, then correctly rejected an incomplete
case catalog: upstream now emits `Lens Effects-default` and `Lens Effects-extreme`. Both cases are now included;
the catalog matches all 164 captured macOS images and all seven parity-tool tests pass. The full cross-platform
comparison remains pending.
