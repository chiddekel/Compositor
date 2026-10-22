# Upstream 1.5.5 on GNU/Linux

The current protected target is `9ff443dbf3acabe5734b8068924cc1ab680f80f2` (`upstream/main`,
1.5.5). The integration retains upstream source unchanged. Local GNU/Linux acceptance is
complete. The Flatpak release workflow builds and signs the published artifacts.

The preceding checkpoint, `432de5c`, integrates RGB Split, filter adjustment layers, Channel Pack,
Split to Layers, and Photoshop artboard tabs through `fc02107`. Its evidence and remaining checks
are recorded in [upstream-1.5.4-integration.md](upstream-1.5.4-integration.md).

The three 1.5.5 follow-up commits update version/build metadata to 1.5.5/51, replace Channel Pack's
PNG encoding with an explicit straight-RGBA PNG writer, and publish the upstream macOS update feed.
The protected app, tests and Xcode project stay identical to upstream.

## Compression compatibility

The original PNG writer calls Compression's buffer API. The Linux `Compression` module supplies
`compression_encode_buffer` and `compression_decode_buffer` for `COMPRESSION_ZLIB` through the
SDK's existing zlib library. Encoding uses raw DEFLATE at level 5, matching
[Apple's documented format](https://developer.apple.com/documentation/compression/compression_zlib).
The writer itself supplies the PNG chunks, CRCs, zlib header, Adler-32 and resolution metadata.
No additional dependency archive is downloaded.

`Sources/CZlib/shim.h` bounds its buffers and releases zlib's working state on completion or error.
`CompressionCompatTests` checks a known raw stream, a payload spanning multiple blocks,
insufficient destinations, decoded prefixes, invalid streams/sizes and unsupported algorithms.
The unchanged upstream `ChannelPackTests` independently reads its PNG's raw stored samples.
The native Channel Pack journey decodes the exported file with Qt and checks every channel,
including color underneath zero alpha.

## Artboard prompt ownership

The generated workspace adapter adds one import-session registration hook to upstream's tab
attachment method. Task-local ownership carries the requesting `UpstreamEditor` across awaits;
each newly created artboard's conversion sheet is presented by its owning native window.
Replacement imports stage all boards before installing any document or tab.

The native regression first reproduced a hidden second-board conversion prompt, then passed all
four normal/replacement Accept/Cancel cases after the fix. See
`/tmp/compositor-fc02107-artboard-conversion-before.log` and
`/tmp/compositor-fc02107-artboard-conversion-after.log`.

## Validation status

- The preceding contract's Swift phases passed 1,036 Swift tests and 160 XCTest cases; its native
  phase was interrupted for the conversion ownership fix. That is not a complete native pass.
- The post-fix original artboard tests and five image-sample XCTest cases pass.
- The 1.5.5 scoped run passed all four Compression XCTest cases and four original Channel Pack
  Swift tests (`/tmp/compositor-upstream155-compression-tests.log`).
- Native Channel Pack export passed independent Qt decoding, transparent RGB samples, remembered
  choices and source/history isolation (`/tmp/compositor-upstream155-channelpack-native.log`).
- The 1.5.5 full contract passed all 1,036 Swift tests (988 parallel and 48 serial) and all
  164 XCTest cases. It passed 41 of 42 native gates, including the complete preview/font Undo,
  artboard conversion and transform/tab journeys. The long combination gate failed its
  touch/mouse/pen hit-region assertion; the fixture correction and successful rerun are described below.
  Evidence: `/tmp/compositor-upstream155-contract.log`.
- All protected-content, generator, shader, override-drift and ledger checks pass through
  `9ff443d` (`/tmp/compositor155-final-integrity.log`).
- Source coverage accounts for all 162 upstream Swift files: 133 compiled unchanged,
  22 generated adapters, five replacements and two platform files. Of 95 upstream test files,
  93 compile unchanged and two have generated Linux mirrors; the coverage audit reports no errors.
- The dashboard's 16 tests and release tools' 17 tests pass. Release descriptor generation
  for `linux-v1.5.5-linux-alpha.2` succeeds.
- The corrected full combination journey passes, followed by RAW lens, text backend, all six
  group/folder rotation cases and grid controls/restart persistence. The final script exits 0:
  `/tmp/compositor155-native-final.log`. Together with the initial 41 passing gates, this covers
  all 42 native journeys across the batch and rerun, rather than claiming one clean full batch.
  The initial batch passed all six repeated wand rounds; the rerun used the normal single round.
- All dependency modules and the complete Flatpak application built with downloads disabled.
  All 15 CMake tests passed. Final metadata finishing succeeded using the system AppStream tools:
  `/tmp/compositor155-flatpak-finish.log`.
- The packaged binary passed five checks against `org.kde.Platform` using `flatpak build --runtime`:
  session startup, RGB Split, Channel Pack, all four artboard conversion Accept/Cancel cases,
  and font history (`/tmp/compositor155-runtime-checks.log`). The build sandbox reports missing
  host font-directory/portal integration; normal installed desktop launch is a separate release check.
- The image contains the project license, vendored notices and pinned source inventory.
- Signing, installation checks, Pages deployment and the GitHub Latest label are handled by
  `.github/workflows/flatpak-release.yml` after the Linux tag is pushed.
- Physical tablet input remains unverified. Current macOS comparison evidence and
  its remaining failures are described below.

### Native input fixture correction

The failing touch assertion mixed a 200-pixel session document with the native shell's still-cached
64-pixel canvas rectangle immediately after resizing. A trace confirmed touch mode was active,
but the calculated click was 68 points away from the new transform corner. The fixture now waits
for the native canvas rectangle before calculating its pointer location; small-object hit-area
coverage remains in `TouchTargetsTests`.

`--combo-smoke --touch-targets-probe` passes finger, mouse, pen, all three synthesized mouse
sources and second-window destruction (`/tmp/compositor155-touch-final.log`). The temporary
device/geometry traces were removed. The successful full combination rerun and remaining backend checks
are recorded in `/tmp/compositor155-native-final.log`.

## Local build environment

The first build passed compilation and all 15 CMake tests, then failed metadata composition:
the Homebrew `appstreamcli` on this machine lacked its Compose addon. The complete system
installation succeeded. No global configuration was changed:

```sh
PATH=/usr/bin:/bin:/usr/sbin:/sbin flatpak-builder --user --disable-download \
  --disable-rofiles-fuse --force-clean --jobs=6 build-flatpak com.compositor.Client.yaml
```

The initial failure is in `/tmp/compositor155-flatpak-build.log`; the successful retry is in
`/tmp/compositor155-flatpak-finish.log`. The retry rebuilt the application stage while reusing
all dependency caches.

## GitHub parity exporter follow-up

Both Verify runs and the upstream guard passed for `dec953a`. The macOS parity exporter
failed before writing its first reference image; the ordinary macOS unit and screenshot tests
passed. Its disposable test app inherited the production sandbox while writing outside the
container. The exporter now overrides sandbox/signing entitlements only for that disposable
copy and retains a bounded XCTest failure summary. The protected production project and
entitlements are unchanged.

The corpus catalog also needed the 11 newly integrated filter/adjustment cases. A local run
of the existing `RenderParityTests` binary exported all 162 cases successfully, and its files
and deep sample sidecars exactly match the updated catalog. The six comparison tests pass.
Evidence: `/tmp/compositor155-parity-catalog-check.log`.

The first alpha.1 signing workflow was cancelled before publication while the exporter is
revalidated. No alpha.1 GitHub release was published. A new candidate will carry these harness
fixes; the application code and completed local Flatpak acceptance are unchanged.

The corrected Mac exporter produced 156 images, including the new RGB Split/filter-layer cases
and the deep-color samples. It then reported `.unreadable` while developing the synthetic RAW
fixtures. The fixtures now derive ASCII lengths from their NUL-terminated bytes and state their
crop/active area explicitly on 512-pixel sensor frames. A native `CIRAWFilter` preflight checks
actual development before the Mac app build; metadata recognition alone is insufficient.
An independent TIFF structure test checks the string termination, crop and strip bounds.
All seven parity tests and a real 162-case Linux export pass with the revised inputs
(`/tmp/compositor155-alpha2-parity-local.log`). GitHub run `39703686160`, Mac job
`119578815754`, subsequently passed the native RAW preflight and exported all 162
reference images from the unchanged upstream renderer.

The first comparison against those actual Mac images fails the existing parity
thresholds. It exposed additive Bloom compositing and unconditional glyph flipping
in the Linux compatibility layer, as well as RAW development, dither, blur, font
rasterization and smaller numeric differences. The thresholds have not been loosened.
Completing the exporter is not a claim that the complete cross-platform comparison passes.

### Corrections verified against the Mac oracle

Bloom now adds `intensity * max(blurred - source, 0)` to each premultiplied source
component, including alpha, instead of adding the complete blurred image. The five
Bloom cases pass the unchanged category thresholds on both CPU and Vulkan. The
three adjustment cases have mean Delta E 0.00004, 0.01460 and 0.02559, down from
roughly 7–21 before correction. A regression checks preserved translucent source
pixels and an extended halo at intensities 0.8 and 1.6. Only the two affected Bloom
goldens were updated; unrelated noise/grain baselines were preserved.

Text glyph images are now flipped only when the current graphics context is
flipped, preserving the production text layer's y-down drawing while matching
the oracle's unflipped text orientation. Font rasterization still differs.

Both complete comparisons pass 121 of 162 cases and fail 41. The category results
are identical for CPU and Vulkan:

| Category | Passing / total |
| --- | --- |
| Adjustments | 33 / 43 |
| Blends | 42 / 48 |
| Color / deep samples | 5 / 5 |
| Effects | 6 / 6 |
| Export | 0 / 1 |
| Filters | 29 / 36 |
| RAW | 0 / 5 |
| Shapes | 0 / 3 |
| Text | 0 / 9 |
| Transforms | 6 / 6 |

Actual Mac references are from [run 39703686160](https://github.com/chiddekel/Compositor/actions/runs/39703686160).
Local reports: `/tmp/compositor155-oracle-bloom-intensity-diff/report.json` (CPU)
and `/tmp/compositor155-oracle-final-vulkan-diff/report.json` (Vulkan). The remaining
gate failures are retained as alpha limitations rather than hidden by new tolerances.

After these corrections, the full Swift/XCTest rerun passes 988 parallel Swift
tests, 48 serial Swift tests and all 165 XCTest cases, including the new Bloom
regression (`/tmp/compositor155-final-swift-configured.log`). An initial rerun omitted
the contract runner's required CMYK profile setup and failed nine profile-presence
assertions; the successful rerun installs that fixture in an isolated test profile.
The freshly linked application also passes startup, native text rendering, the
complete filter-control probe and font history (`/tmp/compositor155-oracle-native.log`).

### File-picker CI readiness

The standalone native file-panel test could type before Qt finished loading the initial
directory. A failing trace showed the filename had subsequently been cleared and Open
disabled. The fixture now waits for its actual directory row before exercising the same
clipboard, Undo/Redo, Unicode input and submission assertions. The timeout stays at three
seconds, with diagnostic state emitted on failure. Twelve fresh-process runs pass in the
dependency-only Flatpak environment (`/tmp/compositor155-file-panel-fixed-{1..12}.log`).
