# Upstream format 18 integration

Target: `7b5ba975694b1462d6c13007c6aea1d01bbc69ff`, following the 1.5.8 checkpoint at `c9c7531`. A fresh upstream fetch still resolved to this target after verification.

Upstream adds Vignette, Lens Effects and Tonal Contrast adjustment layers, their persistent settings, editing, format-18 validation and a grouped Filter menu. The protected application and test sources match upstream unchanged. `docs/project-format.md` and `ProjectManifest.current` both specify 18; older supported formats remain readable.

Linux compiles the original `MetalFinishing` and `FinishingKernel` through its Metal and Core Image compatibility interfaces. `FinishingCompute` executes the two finishing kernels on float textures with the original arithmetic, premultiplied coverage and document coordinates. It checks texture sizes, formats and parameter-buffer length before execution. This is CPU execution through the compatibility API; it does not establish Vulkan hardware support. The Linux `GPUAdjustment` implementation contains the unchanged upstream adjustment block, including document-size propagation and HDR handling.

The app menu and project-validation adapters are regenerated from upstream. The C kernel target excludes the new Swift file. Linux icons cover the three new symbols, and native save journeys expect format 18. The shared parity corpus adds nine adjustment images, for 173 cataloged images overall.

## Settings ownership correction

The unchanged upstream editor tests initially reported three failures when reopening the new kinds: `beginAdjustmentEditing` overwrites every shared editor's Gaussian radius with `original.gaussianRadius` (default 10), while the new assertions compare against an independent `FilterSettings` object (radius 5). Complete diagnostic settings dumps matched after substituting only this unrelated radius. The initial 29-test run and bounded failure details remain in `upstream-format18-followup-tests.log` and `upstream-format18-test-summary.json`.

The generated Linux `AdjustmentEditing` adapter applies `linux/patches/adjustment-editing-linux.patch`: the three new kinds retain their independent settings objects; legacy adjustment fields are copied only for the earlier kinds. Saving updates the relevant object and retains the other stored fields; Cancel restores the original adjustment. The original upstream assertions remain unchanged and pass with this adapter. Regeneration applies the patch without fuzz and fails on upstream drift. Native macOS code remains upstream's; the Linux adapter does not correct that upstream unused-field mismatch on macOS.

## Published integration verification

Logs and JSON evidence below are relative to `.build/evidence/` in the verification checkout.

- Protected-content, generator, override-drift, icon and ledger checks pass. Nine Python parity-tool regressions pass with the existing Python environment.
- The affected serial run passes 29 tests in six suites, including the three previously failing cases and an off-center vignette tile/alpha regression (`upstream-format18-independent-settings-tests.log`).
- The production executable builds successfully in 237.94 seconds. The extended native adjustment journey passes nine kinds, including all three new kinds: visible creation, thumbnail/Edit menu reopening, numeric preview, Cancel/OK, exact creation/edit Undo/Redo, format-18 nested settings, preserved source PNGs and exact package reopening (`upstream-format18-native-adjustments.log`).
- A separate native bridge is built from this integration's source, excluding the pending byte-compositing candidate. Its CTest passes (`upstream-format18-native-clean-build.log`). With this bridge, the full parallel run covers 180 XCTest cases and 1,038 Swift Testing tests; the latter reports only the 15 previously known GPU-availability issues. The entire Linux golden suite passes (`upstream-format18-clean-full-parallel.log`).
- All 48 shared-state serial tests and all 18 adjustment golden cases pass (`upstream-format18-clean-full-serial.log`, `upstream-format18-clean-adjustment-goldens-initial.log`). Three reviewed, previously nonexistent adjustment fixtures were added. No existing golden baseline was replaced.
- Both complete 173-image Linux renders pass their catalog/manifest checks. All 173 decoded images are unchanged by the settings adapter. With the separate native bridge, all 164 older cases are decoded-RGBA identical to the published checkpoint before the pending compositing changes (`upstream-format18-independent-settings-regression.json`, `upstream-format18-clean-corpus-regression.json`).

`upstream-format18-clean-verification-summary.json` records source, test-executable and native-library hashes and both full-suite issue breakdowns. The first full run used the existing native library containing the pending byte-compositing corrections and reported 23 issues: the same 15 GPU-availability issues plus eight known golden differences. The independent bridge removes those eight differences, separating the integration from the pending work.

## Remaining work

The Gaussian, byte-compositing, Lanczos, affine and tone corrections remain local. Twelve replacements of existing goldens are proposed: the original ten comparisons retain their hashes and maximum 2/255 differences; two Lens Effects comparisons change by up to 18/255 (filter) and 21/255 (adjustment) after the native tone correction. The review is `.build/evidence/upstream-format18-tone-rendering-review/index.html`, with exact before/after hashes in `review.json`. It supersedes the ten-image proposal. These replacements remain unapproved; no tracked baseline has been replaced.

The native macOS 173-image reference is available from CI run `40122628134`. Its 164 older decoded images are identical to the earlier native reference. CI runs `40122628173` and `40122627994` report three failed `AdjustmentEditorTests.sharedEditorsKeepPixelsDynamicAndSupportCancel` cases in the unchanged macOS code; Linux passes these cases through the generated settings-ownership adapter. Both macOS screenshot jobs pass. The candidate has 36 earlier rendering discrepancies: nine adjustment, four blend, six filter, five raw, three shape and nine text cases. Hardware verification below resolves the earlier GPU-availability uncertainty.

## Combined rendering candidate after format 18

The candidate now passes 137/173 native comparisons, with matching upstream, corpus, input and case-catalog identifiers (`upstream-format18-tone-parity-diff/report.json`). All nine new adjustment cases pass. Prism improves from a 14-byte maximum channel error to one byte; Anamorphic Flare improves from 20 to two; Mist improves from five to one. No previous passing case is lost. These are unpublished candidate measurements.

The first comparison was rejected for mismatched input hashes: only `p3.png` differed. Linux was rendered again with the exact CI inputs; provenance checks and application thresholds remain unchanged.

The compatibility changes are separated by responsibility:

- `Lanczos.swift` implements separable antialiased reconstruction, preserving negative/HDR values and alpha overshoot. Fourteen direct native cases validate byte output and integral bounds.
- Affine planning samples before connected transfer, unpremultiplication and alpha replacement operations, retaining genuine crop boundaries. Fifty-six native pointwise/rectangle cases validate fractional geometry and sampled float rows.
- Gaussian affine intermediates use the requested inverse-mapped region as their sampling domain. Twenty-four native blur/affine cases pass. Separate regional captures confirm that native interior requests differ from cropping a larger render by up to 0.7471 byte units, independently of caching. The new regional regression passes on CPU and AMD Vulkan, checking byte output within one level and tile-versus-full float differences within `1/1024`. This resolves the sampling-boundary review concern (`native-regional-sampling-comparison.json`, `upstream-format18-regional-targeted.log`, `upstream-format18-regional-hardware.log`).
- `ToneCurve.swift` implements the native perceptual working-space response separately from `CIColorCurves`. Sixteen native byte/float cases cover two highlight thresholds, contrast, identity and doubled RGB inputs. Native identity recipes preserve HDR; the upstream faint-flare assertion now passes. A natural spline with sRGB-shaped encode/decode matches the captured float response within approximately 0.001 byte units; the earlier raw-curve model differs by up to 46.

The native tone capture in run `40130017115` validates 334 cases and 672 buffers; all 318 preceding recipes and both identity inputs retain their hashes. Regional run `40131936749` extends this to 358 cases and 720 buffers, with all preceding 334 recipes unchanged. Earlier native cardinal-motion controls support pixel-area weights, but arbitrary-angle sampling remains unresolved, so production motion blur is unchanged.

## Hardware candidate verification

The SDK sees the host's AMD Radeon Graphics (RADV RENOIR) when `flatpak build` includes `--device=dri`. Removing the CPU-only `COMPOSITOR_COREIMAGE_BACKEND` and `COMPOSITOR_FORCE_GPU_CANVAS` overrides lets the existing tests exercise the real Vulkan backend. Thirty-four dedicated GPU tests pass, including verified Camera Raw submissions, padded rows, buffer recreation and all texture upload formats (`upstream-format18-tone-hardware.log`).

The full hardware run passes all 186 XCTest cases, all 48 serial shared-state Swift tests and the nine-kind native adjustment journey. The 1,038-test parallel Swift run reports only the twelve proposed golden replacements (`upstream-format18-tone-hardware-full-parallel.log`, `upstream-format18-tone-hardware-full-serial.log`, `upstream-format18-tone-hardware-native-adjustments.log`). The earlier fifteen GPU-availability assertions pass with device access. The finishing kernels remain the CPU compatibility implementation described above; these checks also exercise their integration with the Vulkan canvas.
