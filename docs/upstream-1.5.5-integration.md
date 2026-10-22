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
  for `linux-v1.5.5-linux-alpha.1` succeeds.
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
- Physical tablet input and a current macOS pixel comparison have not been verified locally.

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
