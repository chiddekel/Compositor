# Upstream 1.5.6 on GNU/Linux

The protected target is `47cb96b` (`upstream/main`, fetched October 23, 2026).
The two commits after `78de504` update the Xcode version to 1.5.6/build 52 and
publish the macOS update feed. They contain no application or test code changes.
The protected app, test and Xcode trees match upstream exactly.

Linux retains the existing compatibility architecture: upstream Swift models and
views use generic framework adapters, native services cross the C ABI, and Qt
supplies the host implementation. No feature-specific fork is added for this
release. The generated About header follows upstream's version/build. Flatpak
metadata, release notes and install descriptors prepare `1.5.6-linux-alpha.1`.

Animated GIF layers/export, layer search, adaptive toolbars and Canvas Size zoom
preservation were already integrated in the preceding Linux release. Its full
application verification is recorded in [the GIF integration report](upstream-bd76fc9-integration.md).
The source diff against that release confirms no changes under `Compositor`,
`CompositorTests`, `CompositorUITests`, `Sources`, `backends`, `include` or `shim`.
Only the generated version header changes under `host`.

## Verification

Current local logs are retained under `.build/evidence/upstream-1.5.6/`.

- Protected-source, generator, symbol, version, override-drift and ledger checks
  pass against `47cb96b`. The ledger covers 103 commits, including 80 code commits.
- All three release-descriptor tests and 14 release-script tests pass. The signed
  install descriptors and download page generate with the new version/tag.
- The native build and Swift/Qt application build pass. All 16 CMake tests pass
  without skips, including Skia rendering (`ctest-clean.log`).
- All 170 XCTest cases and 1,061 Swift tests pass: 1,013 parallel tests and 48
  serial tests (`swift-tests-hardware.log`). The hardware acceptance check
  confirms AMD RADV submissions and buffer recreation.
- Seven rebuilt-application checks pass: startup, preferences, GIF persistence
  and export, layer search, Canvas Size, the complete UI audit and application-mode
  dialogs (`native-checks.log`). The UI audit covers 23 tool states, 22 floating
  panels, four sheets, Export As, Command Palette, 12 adjustment layers and CMYK pills.
- Required shader verification and all 29 vendored archive checks pass
  (`integrity-required-shaders.log`, `vendored-sources.log`).
- The final diff review finds no issues; release metadata and generated install
  descriptors agree on `1.5.6-linux-alpha.1`.

An initial verification used the finished Flatpak directory, whose cleanup removes
static build dependencies. Reconfiguring the native build there produced the Skia
fallback and a skipped renderer test; the accompanying Swift run aborted. Those
runs are retained for diagnosis and are not accepted as passing release evidence.
Verification uses a fresh native build in the dependency-complete SDK instead.
An intermediate run omitted GPU device access and failed the hardware acceptance
check; it was stopped and replaced with the complete passing `--device=dri` run.

The tag-triggered Flatpak workflow builds/signs the package, verifies installation,
deploys the signed update repository and then publishes the release as Latest.
Existing macOS render-comparison differences and physical tablet validation limits
remain documented in [the preceding integration report](upstream-1.5.5-integration.md).
