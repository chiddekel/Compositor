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

The upstream kernel's `sin`/`fract` sampling jitter depends on the device's transcendental precision.
The preceding Vulkan correction protected phase arithmetic and evaluated a degree-21 sine
polynomial in double precision after reducing the angle to −π/2…π/2. Five sharp-alpha comparisons
on AMD RADV improved from maximum errors of 3.98–94.18 byte levels to less than 0.72. Its pixel-level
regression fails against the original shader; native Metal edge references remain unchanged.
The shared Float32 fast-sine model described below replaces that earlier polynomial to improve
agreement with native sampling as well as preserving the CPU/Vulkan comparison limits.
The combined candidate's automatic-backend application corpus improved from 136/173 to 137/173
passing native comparisons at that checkpoint. This correction does not establish complete native
pixel parity. Existing golden thresholds and baseline PNGs are unchanged.
See `docs/upstream-format18-integration.md` for the other renderer candidates.

Fresh verification on AMD Radeon Graphics (RADV RENOIR) passes the independent CPU/Vulkan
contracts and 74 Swift hardware tests across 15 suites. Rebuilding the original committed shader
fails the new sharp-alpha regression with an 87.58-byte maximum error. Generated SPIR-V and the
complete upstream-content guard pass. All 93 fresh GPU golden candidates match the CPU candidates;
the shared worktree retains sixteen pending golden differences from other renderer changes.

A separate checkout of published `64e5df8`, with only the three dispersion code/test files
applied, builds its own native bridge and passes 81 tests across 16 suites. All 93 decoded
golden images are identical to the committed baselines. It also passes the original Skia
bridge contracts and the native RGB Split panel/history journey. Camera Raw lookup assets
are installed beside the test runner, as in `linux-contract-tests.sh`; without that setup,
two unrelated Camera Raw tests correctly report missing tables. The isolated verification
and source hashes are recorded under `.build/evidence/dispersion-isolated-*`.

`scripts/check-parity-rgb-macos.swift` reads the protected upstream shader and captures it on a native
Metal device. In addition to the original edge samples, the manual `rgb-metal-parity.yml` workflow
retains seven complete buffers: the 61×61 source and two RGBA8 outputs, default/strict 61×61 arithmetic
observers, and default/strict 192×144 observers. Observer float4 channels are phase, sine, noise and
jitter. SHA-256, packed sizes, finite float values and consistency with every edge sample are validated
before artifact upload. These diagnostics separate arithmetic from sampling and output quantization;
they do not by themselves establish a replacement algorithm. An additional default-math
513×257 observer extends the coordinate range beyond those earlier captures. The workflow
validates all eight buffers and requires the larger observer's overlapping rows to match
the 192×144 observer byte for byte.

Native run `40134093484` passes all seven buffer validations. The shader hash, source fixture, nine
edge samples, tail assertions and default/strict edge arithmetic are identical to the earlier capture.
The 192×144 default observer matches the CPU's phase at every pixel, but sine differs by at most
`1.7881393432617188e-7`; after hash amplification, 92 pixels differ by more than half a sampling interval.
An isolated replay of the application's default filter reproduces its 17-byte maximum error using CPU
jitter. Substituting the independently captured native jitter, with the source and gather unchanged,
reduces this to one byte. This establishes the remaining hash discrepancy's cause; captured jitter is
diagnostic data and is not used by the production renderer. The complete 61×61 production-kernel
captures already match CPU within two bytes for the flat split and one for the streaked split.

The contract script also runs upstream `FilterTests` and `FilterLayerTests`, and the native
`--combo-smoke --dispersion-probe` journey checks the visible panel, Cancel, commit, Undo/Redo,
and Split to Layers. The rebuilt local candidate passes this journey on AMD Vulkan, including exact
commit Undo/Redo and Split to Layers hierarchy/history (`upstream-format18-dispersion-native-journey.log`
under `.build/evidence/`). This does not close the remaining native comparison failures.

## Native fast-sine compatibility

The spectral jitter hash amplifies differences of a few sine ulps into jumps across
an entire sampling interval. The CPU and Vulkan implementations use the same odd,
degree-11 polynomial after reducing the phase to quarter cycles. Its six float
coefficients were fitted to the native default-math observer's rows 72–143 at
192×144; neither the application output nor the held-out coordinates set them.
Both implementations evaluate the polynomial with explicit fused multiply-adds.
The shader also preserves rounding at the final sine multiplication and the
noise multiplication; allowing their reassociation breaks the existing sharp-edge
CPU/Vulkan regression by up to 82 byte levels.

The independent 513×257 capture from native run `40190033692` preserves all seven
earlier buffers. Across 118,017 coordinates outside the fitting region, the model
reduces jitter differences above half an interval from 418 to 60, with maximum
sine error `1.1920928955078125e-7`. It approximates the captured fast-math behavior;
it does not establish exact arithmetic parity across Apple GPU models.

`Tests/Fixtures/metal/rgb-split-default-reference.json` retains the complete native
96×72 default-filter output, its upstream/corpus/input provenance, and hashes of
the source PNG and decoded premultiplied pixels. The independent dispersion test
checks every channel on CPU and Vulkan within two byte levels. The preceding
renderer fails this regression by 17 levels. Existing direction, radial, ROI,
edge-extension, alpha, and CPU/Vulkan comparison checks retain their limits.

In an isolated checkout, both backends improve the complete application corpus
from 130/173 to 132/173 passing comparisons: the negative RGB Split adjustment
and default destructive filter now pass. The other two RGB Split adjustment
cases remain open. Only the five RGB Split PNGs change; all 173 candidate PNGs
are byte-identical between CPU and Vulkan. The native reference regression
measures a one-byte maximum error on both backends. All 1,288 Swift/XCTest
checks and the native RGB Split panel/history journey pass. Verification uses
the `dispersion-model-isolated-` evidence prefix; baseline PNGs are unchanged.


`COMPOSITOR_COREIMAGE_BACKEND=cpu` selects the Core Image graph backend. The separate
Metal-compatible dispersion driver can still use an available Vulkan device. The
CPU/Vulkan corpus equality above used matching hardware access for that driver.
For a wholly software profile, remove hardware device access as well, and record
both settings: a controlled variable-blur qualification observed a repeatable
one-pixel difference in RGB Split when device access alone changed.
