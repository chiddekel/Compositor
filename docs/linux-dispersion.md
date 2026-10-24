# RGB Split on GNU/Linux

The protected upstream `Compositor/Rendering/MetalDispersion.swift` runs unchanged.
Its Metal command encoder submits the `disperse` entry point to the Linux compute adapter.
`Sources/Compat/Metal/MetalCompute.swift` translates the parameter buffer and native texture
formats into the raster backend's interface. Unsupported compute entry points fail explicitly.

`backends/coreimage/shaders/raster.comp` implements the spectral gather on Vulkan, operation 10.
`backends/coreimage/Dispersion.cpp` supplies the CPU implementation when hardware compute is
unavailable or rejects the operation. Both follow the upstream kernel's bilinear sampling,
spectral weights, radial direction, streak sampling, canvas-edge extension and premultiplied alpha.
The code is derived from the upstream MIT-licensed implementation; see the repository's LICENSE.

The C interface takes premultiplied RGBA Float32 samples in top-down rows. Source and destination
can have different dimensions. Its twenty Float32 parameters have this layout:

| Index | Value |
| --- | --- |
| 0–1 | Center |
| 2–3 | Linear direction |
| 4–6 | Distance, blur, reach |
| 7–10 | Radial flag, extended-edge bits, spectral sample count, streak sample count |
| 11–12 | Output origin |
| 13–14 | Input origin |
| 15 | Row direction, 1 or −1 |
| 16–17 | Source width and height |
| 18–19 | Reserved, zero |

The upstream Swift parameter structure keeps its original layout; the adapter reads its fields
at their ABI offsets rather than assuming this C layout matches the Swift structure.
RGBA8 textures are converted at the boundary; Float32 processor textures retain their precision.
Core Image requests each input's full ROI and flips rows at the processor boundary, so upstream's
CI-coordinate origins and negative row direction remain meaningful.

Run the independent backend checks inside the KDE SDK:

```sh
cmake --build "$COMPOSITOR_CONTRACT_NATIVE_BUILD" --target test_dispersion_backend
python3 tests/test_dispersion.py "$COMPOSITOR_CONTRACT_NATIVE_BUILD/libtest_dispersion_backend.so"
```

The check exercises the CPU implementation and, when available, hardware Vulkan. It verifies
spectral direction, blur streaks, the radial center, alpha bounds, different region sizes,
translated origins, negative row direction and edge extension. Hardware success requires actual
submissions; a CPU fallback cannot count as the Vulkan pass.

The published kernel's `sin`/`fract` sampling jitter depends on the device's transcendental precision.
A local shader correction protects phase arithmetic and evaluates the reduced sine accurately before
the amplified hash. Five sharp-alpha component comparisons on AMD RADV improve from maximum errors
of 3.98–94.18 byte levels to less than 0.72. The new pixel-level component regression fails against
the original shader and passes with the correction; native Metal edge references remain unchanged.
The local automatic-backend application corpus improves from 136/173 to 137/173 passing native
comparisons. Thirty-six native discrepancies remain. This correction is not yet committed; existing
golden thresholds and baseline PNGs are unchanged. See `docs/upstream-format18-integration.md`.

`scripts/check-parity-rgb-macos.swift` reads the protected upstream shader and captures it on a native
Metal device. In addition to the original edge samples, the manual `rgb-metal-parity.yml` workflow
retains seven complete buffers: the 61×61 source and two RGBA8 outputs, default/strict 61×61 arithmetic
observers, and default/strict 192×144 observers. Observer float4 channels are phase, sine, noise and
jitter. SHA-256, packed sizes, finite float values and consistency with every edge sample are validated
before artifact upload. These diagnostics separate arithmetic from sampling and output quantization;
they do not by themselves establish a replacement algorithm.

The contract script also runs upstream `FilterTests` and `FilterLayerTests`, and the native
`--combo-smoke --dispersion-probe` journey checks the visible panel, Cancel, commit, Undo/Redo,
and Split to Layers. These application checks still need a successful run for the current merge;
backend-only results do not establish complete application parity.
