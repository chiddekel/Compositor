# 07 — Rendering, processing and color correctness

## Pipeline on each platform

| Stage | Upstream (macOS) | GNU/Linux | Correctness evidence (executed today unless noted) |
|---|---|---|---|
| Pixel storage | CGImage/CGContext 8-bit premultiplied, 16-bit, float HDR | compat CoreGraphics over canonical buffers; Skia raster bridge (`libCompositorSkiaBridge.so`) | `RasterSnapshotTests`, `TiledLayerTests`, `DeepLayerTests` ✔ |
| Layer compositing / blend modes | Core Graphics + Core Image (Soft Light through CI; Dodge/Burn in sRGB) | compat CG/CI: every blend mode implemented (`2d9e3ec`) | `LayerAppearanceTests`, `LivePreviewTests` (24 modes) ✔ |
| Canvas frame | **Metal** `GPUCanvas` (1.4+) | Core Graphics canvas by default; Vulkan present path behind `COMPOSITOR_FORCE_GPU_CANVAS=1` | `GPUCanvasTests` ✔ (on Vulkan, RADV RENOIR). The default differs (GAP-PERF-01) |
| Layer effects | Metal kernels | `backends/effects` (Vulkan → OpenCV → CPU chain) | `OuterGlowTests`, `InnerGlowTests`, `ColorOverlayTests`, `LayerEffectsBackendTests` ✔ |
| Brush coverage | Metal | `backends/brush` (Vulkan/CPU) | `BrushTests`, `LargeCanvasBrushTests`, `BrushCoverageBackendTests` ✔ |
| Liquify/Smudge | Metal warp | CPU/Vulkan working copy; resumable dabs | `MetalWarpTests`, `WarpCommitParityTests`, `WarpTipCacheTests`, `VulkanWarpPackingTests` ✔ |
| Filters / adjustments | Core Image + Accelerate + C kernels | compat CI graph (Vulkan raster backend), compat vImage, the same protected C kernels (`Compositor/Rendering/*Pixels.c`) | `FilterTests`, `FinishingFilterTests`, `ImageAdjustmentTests`, `LevelsTests`, `HueSaturationTests`, `ScanlinesTests`, `ProgressiveBlurTests` ✔ |
| Camera Raw | C tables + Metal lookup (1.5.3) | same C tables; Vulkan lookup (`backends/cameraraw`) with upstream CPU rounding repair | `CameraRawTests`, `CameraRawGPUTests`, `CameraRawResetTests` ✔ |
| Healing / Content-Aware Fill | protected `PatchPixels` C kernel | same kernel | `SpotHealingTests`, `SmartEditTests` ✔ |
| Resampling | CG `.high` interpolation | Skia with area-averaged minification (`630172a`) | `test_skia_bridge` (CTest; pre-existing contract log) |
| Text | Core Text | Qt text engine behind compat text layout | `TypeToolTests` ✔; glyph smoke journeys (contract log) |
| Color management | ColorSync, ICC through ImageIO | LittleCMS + Qt codecs; gray/gray-alpha/P3/HEIF BT.709/PQ/HLG fixtures | `CMYKTests`, `CMYKProofDisplayTests` ✔; `test_imageio_color` (CTest, contract log) |
| Subject masks | Vision | U²-Net-small via OpenCV dnn | model tests ✔ with `COMPOSITOR_REQUIRE_SUBJECT_MODEL=1` |

Test run: `.build/evidence/audit/tests-swift-testing.log` reports "Test run with 974 tests in 163 suites passed after 147.093 seconds"; `.build/evidence/audit/tests-xctest.log` reports 148 XCTests, 0 failures. Environment: Flatpak SDK, `COMPOSITOR_COREIMAGE_BACKEND=vulkan`, `REQUIRE_COREIMAGE_VULKAN=1`, `COMPOSITOR_REQUIRE_WARP_VULKAN=1`, `COMPOSITOR_FORCE_GPU_CANVAS=1`, AMD Radeon (RADV RENOIR). These tests use upstream's own expected values, which were authored against macOS output. So passing means Linux reproduces what upstream asserts, within each assertion's tolerance.

## What is *not* established

1. **Pixel identity with macOS** for anything outside upstream assertions, for example filter looks at non-default settings, text anti-aliasing and RAW demosaicing. There is no Mac (GAP-VER-04).
2. **Default canvas path performance and 16-bit display**. The default CPU canvas draws 16-bit layers dithered by upstream code. The Vulkan path is opt-in (GAP-PERF-01).
3. **HiDPI canvas rendering** (DPR > 1), not exercised offscreen.
4. **GPU vendor spread**. Only RADV was exercised; NVIDIA proprietary, Intel ANV and llvmpipe were not.

## Deterministic test set to close GAP-VER-04

Each case is rendered on macOS once (golden images, committed under `Tests/Fixtures/golden/`), then compared on Linux in CI:

| Case | Input | Metric | Tolerance |
|---|---|---|---|
| Blend modes | 2 layers (gradient over photo) × 24 modes (`LayerBlendMode`, `Document/LayerAppearance.swift:4`) × opacity {100, 50} | per-channel max abs diff | ≤ 1/255 (8-bit), ≤ 4/65535 (16-bit) |
| Adjustments | 12 kinds at default + 2 extreme settings | ΔE2000 mean / max | ≤ 0.5 / ≤ 2 |
| Filters | 12 filters at default + 1 extreme | ΔE2000 mean / max; SSIM | ≤ 1 / ≤ 3; SSIM ≥ 0.99 |
| Layer effects | 6 effects on text and on a soft-edged shape | max abs diff on alpha; ΔE on color | ≤ 2/255; ≤ 1 |
| Transform sampling | rotate 17°, scale 37%, scale 263% (High / nearest) | PSNR | ≥ 45 dB |
| Text | 3 faces × 3 sizes, per-letter color | glyph coverage IoU | ≥ 0.97 (font engines differ) |
| RAW | 5 sample files in `build/raw-samples`, as-shot | ΔE2000 mean | ≤ 3 (different RAW engines; documented deviation) |
| Export | PNG/JPEG q=0.9/PDF/EXR/CMYK TIFF | decode → compare to canvas render | exact for PNG/EXR; PSNR ≥ 40 dB for JPEG |

Accepted deviations, to be documented as such: RAW engine look (LibRaw vs Apple), text rasterization (Qt vs Core Text) within the glyph IoU bound, and subject-mask edges (U²-Net vs Vision) within the IoU bound in GAP-PLAT-01.
