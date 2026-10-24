# Upstream format 18 integration

Target: `7b5ba975694b1462d6c13007c6aea1d01bbc69ff`, following the 1.5.8 checkpoint at `c9c7531`. A fresh upstream fetch still resolved to this target after verification.

Upstream adds Vignette, Lens Effects and Tonal Contrast adjustment layers, their persistent settings, editing, format-18 validation and a grouped Filter menu. The protected application and test sources match upstream unchanged. `docs/project-format.md` and `ProjectManifest.current` both specify 18; older supported formats remain readable.

Linux compiles the original `MetalFinishing` and `FinishingKernel` through its Metal and Core Image compatibility interfaces. `FinishingCompute` executes the two finishing kernels on float textures with the original arithmetic, premultiplied coverage and document coordinates. It checks texture sizes, formats and parameter-buffer length before execution. This is CPU execution through the compatibility API; it does not establish Vulkan hardware support. The Linux `GPUAdjustment` implementation contains the unchanged upstream adjustment block, including document-size propagation and HDR handling.

The app menu and project-validation adapters are regenerated from upstream. The C kernel target excludes the new Swift file. Linux icons cover the three new symbols, and native save journeys expect format 18. The shared parity corpus adds nine adjustment images, for 173 cataloged images overall.

## Settings ownership correction

The unchanged upstream editor tests initially reported three failures when reopening the new kinds: `beginAdjustmentEditing` overwrites every shared editor's Gaussian radius with `original.gaussianRadius` (default 10), while the new assertions compare against an independent `FilterSettings` object (radius 5). Complete diagnostic settings dumps matched after substituting only this unrelated radius. The initial 29-test run and bounded failure details remain in `upstream-format18-followup-tests.log` and `upstream-format18-test-summary.json`.

The generated Linux `AdjustmentEditing` adapter applies `linux/patches/adjustment-editing-linux.patch`: the three new kinds retain their independent settings objects; legacy adjustment fields are copied only for the earlier kinds. Saving updates the relevant object and retains the other stored fields; Cancel restores the original adjustment. The original upstream assertions remain unchanged and pass with this adapter. Regeneration applies the patch without fuzz and fails on upstream drift. Native macOS code remains upstream's; the Linux adapter does not correct that upstream unused-field mismatch on macOS.

## Verification

Logs and JSON evidence below are relative to `.build/evidence/` in the verification checkout.

- Protected-content, generator, override-drift, icon and ledger checks pass. Nine Python parity-tool regressions pass with the existing Python environment.
- The affected serial run passes 29 tests in six suites, including the three previously failing cases and an off-center vignette tile/alpha regression (`upstream-format18-independent-settings-tests.log`).
- The production executable builds successfully in 237.94 seconds. The extended native adjustment journey passes nine kinds, including all three new kinds: visible creation, thumbnail/Edit menu reopening, numeric preview, Cancel/OK, exact creation/edit Undo/Redo, format-18 nested settings, preserved source PNGs and exact package reopening (`upstream-format18-native-adjustments.log`).
- A separate native bridge is built from this integration's source, excluding the pending byte-compositing candidate. Its CTest passes (`upstream-format18-native-clean-build.log`). With this bridge, the full parallel run covers 180 XCTest cases and 1,038 Swift Testing tests; the latter reports only the 15 previously known GPU-availability issues. The entire Linux golden suite passes (`upstream-format18-clean-full-parallel.log`).
- All 48 shared-state serial tests and all 18 adjustment golden cases pass (`upstream-format18-clean-full-serial.log`, `upstream-format18-clean-adjustment-goldens-initial.log`). Three reviewed, previously nonexistent adjustment fixtures were added. No existing golden baseline was replaced.
- Both complete 173-image Linux renders pass their catalog/manifest checks. All 173 decoded images are unchanged by the settings adapter. With the separate native bridge, all 164 older cases are decoded-RGBA identical to the published checkpoint before the pending compositing changes (`upstream-format18-independent-settings-regression.json`, `upstream-format18-clean-corpus-regression.json`).

`upstream-format18-clean-verification-summary.json` records source, test-executable and native-library hashes and both full-suite issue breakdowns. The first full run used the existing native library containing the pending byte-compositing corrections and reported 23 issues: the same 15 GPU-availability issues plus eight known golden differences. The independent bridge removes those eight differences, separating the integration from the pending work.

## Remaining work

The pending Gaussian and byte-compositing corrections are excluded from this integration. Their nine proposed replacements of existing goldens remain unapproved. New fixture creation above does not approve those replacements.

A matching native macOS reference for the nine new corpus images is still required; the earlier 164-image comparisons describe `c9c7531` and do not prove parity for the new kinds. Native macOS unit verification has not been rerun here. Strict Vulkan execution remains unverified because this environment lacks the required device capabilities. Existing CPU/macOS rendering discrepancies remain open.
