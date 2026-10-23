# Upstream GIF playback update on GNU/Linux

Target: `a5c900d6ebdd159d0063aa040219b97888b5039e` (upstream main fetched October 23, 2026),
following the 1.5.6 release checkpoint `47cb96b`.

The four new commits route the timeline through the elapsed-time playback scheduler,
reuse one locked ImageIO reader per GIF source, and show the original frame delays in
milliseconds (or their range) below Play and in the delay menu. Decoding time no longer
extends saved frame delays; slow decoding skips expired frames.

All changed application and test files compile directly from the protected upstream
trees. The Linux-only GIFAnimation and GIFDecoder overrides and their patches are
retired: upstream now supplies the same reader lifetime through `GIFSource.withReader`.
The generator rejects stale copies, and the parity manifest and SwiftPM exclusions
reflect direct compilation. The generic ImageIO codec interfaces and Qt decoder
sessions remain responsible for platform decoding; no GIF feature fork is needed.

The Linux lifetime regression observes upstream's lazy reader through its locked
accessor and still checks linear sequential decoding and release. The new
`GIFTimelineIntegrationTests` resolves the actual upstream view through compat SwiftUI,
checking original and uniform delay labels with stable frame identities and edited
per-frame delays. Upstream's added playback tests cover saved timing, slow decoding,
and paused playback using an injected clock.

## Verification

Evidence is retained under `.build/evidence/upstream-a5c900d/`.

- Protected-source, generator, shader, override-drift and commit-ledger checks pass
  (`integrity.log`); the ledger covers 106 non-merge commits, including 83 code commits.
- Source coverage accounts for all 172 upstream Swift files: 142 unchanged,
  23 generated, five replaced and two platform substitutions. The evaluated test
  target includes 97 unchanged test files and two generated mirrors. All 11
  coverage-audit fault tests pass (`verification.log`, `source-coverage.json`).
- All 170 XCTest cases and 1,065 Swift tests pass: 1,017 in the parallel group and
  48 in the serial group (`swift-parallel.log`, `swift-serial.log`). The focused
  decoder-lifetime and playback tests also pass (`focused-tests.log`).
- The release application builds and links (`application-build.log`). The rebuilt
  native `--combo-smoke --gif-probe` journey passes the actual Qt delay button and
  menu labels, frame pixels/history, play/pause, project save/reopen, GIF export
  timing and short-window tool columns (`native-gif.log`).
- Linux CI selects the new timeline integration suite. Workflow YAML, README local
  links/images, Markdown structure and final diff whitespace checks pass.

An initial native run used a cached host object and did not contain the added
label assertions. Its logs are retained as `native-gif-before-rebuild.log` and
`application-build-initial.log`; only the final run, after recompiling
`HostRun/DialogJourney.cpp`, verifies those assertions.

The README refresh was published separately as `d9ab8bc` on both `main` and
`GNU_Linux`. That push contains only `README.md`; the subsequent branch
synchronization publishes this verified upstream code integration separately.

The macOS Xcode test target requires a macOS runner; this Linux integration runs its
portable tests in the manifest's KDE SDK with the actual Skia and Qt codec backends.
