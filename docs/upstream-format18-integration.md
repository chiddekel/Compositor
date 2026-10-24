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

The pending Gaussian and byte-compositing corrections are excluded from this integration. The combined format-18 revalidation now proposes ten replacements of existing goldens: the original nine candidates are unchanged, and the new Tonal Contrast adjustment adds four channel values differing by 2/255. These replacements remain unapproved. New fixture creation above does not approve those replacements.

The native macOS 173-image reference is now available from CI run `40122628134`. Its 164 older decoded images are identical to the earlier native reference. CI runs `40122628173` and `40122627994` report three failed `AdjustmentEditorTests.sharedEditorsKeepPixelsDynamicAndSupportCancel` cases in the unchanged macOS code; Linux passes these cases through the generated settings-ownership adapter. Both macOS screenshot jobs pass. Strict Vulkan execution remains unverified because this environment lacks the required device capabilities. Existing CPU/macOS rendering discrepancies remain open.

## Combined rendering candidate after format 18

The unpublished Gaussian/compositing candidate rebuilds successfully with format 18: ten selected XCTest cases, including the native Gaussian reference test, and 17 affected Swift Testing tests pass. All 173 corpus images render. No tracked baseline replacements were made. The ten-image review is recorded in `.build/evidence/upstream-format18-rendering-review/index.html` and `review.json`, including exact before/after hashes.

The first native comparison was rejected for mismatched input hashes. Only `p3.png` differed; the Linux corpus was rendered again with the exact downloaded CI inputs rather than bypassing provenance validation. With matching upstream, corpus, input and case-catalog identifiers, the combined candidate passes 135 of 173 cases (`upstream-format18-combined-matched-parity-diff/report.json`). All three Vignette and all three Tonal Contrast cases pass, as does Lens Effects Mist. The default Anamorphic Flare and Prism cases fail the maximum color-difference gate. These are candidate measurements, not results for the published rendering code.

Prism's differences above three channel levels occupy columns 38, 52, 66 and 81, at the translated copies' right edges. A standalone reconstruction reproduces the existing CPU image exactly; clamping finite image borders in that reconstruction reduces its largest difference from native from 14 to 1. This identifies a sampling hypothesis for direct native affine controls; the shared production sampler is unchanged. Anamorphic Flare also uses `CILanczosScaleTransform`, which currently aliases the generic affine transform in the compatibility layer.

The native capture script adds cardinal/near-cardinal motion angles, translated Gaussian impulses, fractional affine controls with and without Lens Effects' linear/alpha preparation, and Lanczos compression/blur/expansion controls. These diagnostic additions do not change production rendering. A standalone motion model matches all 16 angle-zero native captures within1/255 using pixel-area weights; the current point weights differ by up to 27/255. Results at other angles are mixed, so production motion blur is unchanged.
