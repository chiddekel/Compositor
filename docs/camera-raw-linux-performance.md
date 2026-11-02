# Camera Raw on Linux: Vulkan measurements

Measured October 15, 2026 on AMD Radeon Graphics (RADV RENOIR), using the
Flatpak SDK's Swift 6.3.3 release build. Protected upstream is `365b574`
(1.5.3), merged as `94cf71e`, with the Linux Vulkan adapter in the working tree.

The unchanged upstream `CameraRawGPUPerformanceTests` ran with
`CAMERA_RAW_GPU_BENCHMARK=1`. It compares CPU/GPU pixels before timing every
workload, performs two warmups per variant and alternates order across eleven
paired measurements. It also explicitly requires successful GPU lookup calls
for each Temperature workload, including 48 MP. The complete run passes in
`/tmp/compositor-upstream-153-gpu-benchmark.log` (exit 0, 158.871 seconds).
[Raw measurements](benchmarks/camera-raw-linux-vulkan.json) retain all samples.

After building the dependencies and release test executable with
`scripts/linux-contract-tests.sh`, repeat the benchmark inside the same SDK:

```sh
flatpak build --filesystem=/tmp --device=dri build/flatpak-full sh -c '
  export PATH=/usr/lib/sdk/swift6/bin:$PATH
  export QT_QPA_PLATFORM=offscreen COMPOSITOR_COREIMAGE_BACKEND=vulkan
  export COMPOSITOR_SKIA_BRIDGE=$PWD/.build/linux-contract-native/libCompositorSkiaBridge.so
  export COMPOSITOR_IMAGEIO_BACKEND=$PWD/.build/linux-contract-native/libCompositorQtImageIO.so
  CAMERA_RAW_GPU_BENCHMARK=1 swift test -c release --skip-build --no-parallel --filter CameraRawGPUPerformanceTests
'
```

The suite writes `/tmp/compositor-camera-raw-gpu.json`. Run it separately from
builds and other test suites to avoid competing workloads.

| Size | Profile | CPU preview median (ms) | GPU-enabled preview median (ms) | Ratio |
|---|---|---:|---:|---:|
| 2 MP | Temperature | 38.9 | 39.8 | 0.98× |
| 2 MP | Light | 48.1 | 50.6 | 0.95× |
| 6 MP | Temperature | 107.9 | 95.7 | 1.13× |
| 6 MP | Light | 127.8 | 125.4 | 1.02× |
| 12 MP | Temperature | 203.7 | 199.7 | 1.02× |
| 12 MP | Light | 212.1 | 198.7 | 1.07× |
| 24 MP | Temperature | 504.1 | 453.8 | 1.11× |
| 24 MP | Light | 439.5 | 403.1 | 1.09× |
| 24 MP | Light + Shadows + Clarity | 1805.3 | 1817.1 | 0.99× |
| 48 MP | Temperature | 786.6 | 661.7 | 1.19× |
| 48 MP | Light | 755.6 | 656.0 | 1.15× |

Direct lookup median speedups are 0.93×, 1.26×, 1.26×, 1.41× and 1.42×
at 2, 6, 12, 24 and 48 MP respectively. Preview timings include raster/scope
work and the unchanged CPU operations surrounding lookup. Small workloads and
mixed spatial adjustments therefore need not benefit. The adapter retains
upstream's 8,000,001-pixel activation threshold. GPU evaluation uses reusable
Vulkan buffers and upstream CPU rounding repair; unsupported devices or failed
GPU work retain the upstream CPU fallback.

At 2 and 6 MP, the GPU-enabled **preview** deliberately uses the CPU path;
differences between those preview variants measure run variation. The direct
lookup measurements explicitly execute the GPU at every size. Preview gains
above the threshold range from 1.02–1.19× for Temperature/Light here.

These measurements describe this machine and these fixtures. They establish
pixel-correct hardware execution and measured gains for the stated workloads;
they do not establish Metal-equivalent latency or gains on other GPUs.
