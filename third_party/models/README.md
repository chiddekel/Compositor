# Subject segmentation model

`u2netp.onnx` — **U²-Net-small** ("u2netp", 4.7 MB), the salient-object model by Xuebin Qin et al., *U²-Net: Going
Deeper with Nested U-Structure for Salient Object Detection* (Pattern Recognition 2020).

- Weights and architecture: https://github.com/xuebinqin/U-2-Net — **Apache License 2.0** (see `LICENSE-U2Net.txt`).
- ONNX export used: https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2netp.onnx
- sha256: recorded in `u2netp.onnx.sha256` once the file is added.

Used by `backends/vision/U2NetSegmenter.cpp` (OpenCV DNN) behind the Vision compat layer: upstream's Select Subject,
Object Selection and Remove Background — Apple Vision's foreground-instance model on macOS. Installed by the Flatpak
manifest to `/app/share/compositor/models/u2netp.onnx`. Without the file the classical segmenter is used.

## Depth (Volumetric Light)

Tip macOS downloads Apple's DepthMini Core ML package. On GNU/Linux, `Sources/Overrides/DepthModel.swift` downloads
**Depth Anything V2 Small** uint8 ONNX (Apache-2.0, via Hugging Face `onnx-community/depth-anything-v2-small`) on first
use and runs it through `Sources/Compat/CoreML` → `backends/depth` (OpenCV DNN). Override with
`COMPOSITOR_DEPTH_MODEL=/path/to/model.onnx`. sha256 of the checked uint8 file:
`fcf51f1b230362b28690bb9d1809bf0431f29cad20534e3f589bd7285547f20d`.
