# GIF and adaptive toolbar integration

GNU/Linux integrates upstream `78de504`, fetched October 22, 2026. Application code is at
`bd76fc9`; the next two commits update writing documentation. Protected macOS application,
test and Xcode trees match upstream, including project format 17.

Linux ImageIO now supports animated sources, composed frame decoding, GIF timing and looping,
multiframe destinations and animated export. A source owns its decoder session: sequential reads
reuse the reader, backward seeks rewind, and releasing the source releases native state. The
portable writer preserves frame timing, transparent disposal and opaque black. Generated GIF
adapters retain readers while preserving upstream frame geometry and editing algorithms.

The Qt shell hosts upstream's GIF timeline and Export As flow. Preview snapshots retain animation
state, and render keys follow the displayed frame. Panels lease thumbnail bitmaps until replacement
or closure, so cache pressure and other windows cannot invalidate live timelines.

Generic SwiftUI compatibility supports ViewThatFits, plain-button and popover measurement, and
animated scrolling. Fitting replacements begin from the previous allocation, preventing transient
canvas resizing during a toolbar refresh. Held-pointer tracking queries live scroll offsets without
resolving the Layers panel. Native control revisions belong to their hosted window, preventing
unrelated toolbar and session invalidation while shared model changes continue through Observation.

## Verification

Final evidence is retained locally under `.build/evidence/upstream-bd76fc9/`.

- All 170 XCTest cases and 1,061 Swift tests pass (1,013 parallel, 48 serial):
  `swift-confirmation-cmyk-installed.log`.
- All 44 native gates pass, including six wand stress rounds, all 26 layer-nesting cases,
  active-stroke viewport stability, exact CMYK restoration, GIF persistence/export and the full UI
  audit. RAW lens, text, group rotation and separate-process grid persistence checks also pass:
  `native-confirmation.log`.
- The final offline Flatpak build passes all 16 CMake tests without skips: `flatpak-final-build.log`.
- Seven packaged KDE-runtime checks pass without the Swift SDK: startup, preferences, GIF,
  layer search, Canvas Size, UI audit and application-mode dialogs: `packaged-final-runtime.log`.
- Protected-source, generator, symbol, shader, override-drift, version and ledger checks pass:
  `integrity-release-final.log`. The ledger covers 101 commits, including 80 code commits.
- Independent GIF tests cover disposal modes 2/3, offsets, backward seeks, invalid indices,
  opaque black and exactly N native reads for 128/256/512 sequential frames. Swift regressions
  cover decoder lifetime and two 4,096-frame timelines under cache pressure.
- Source accounting covers 172 upstream Swift files: 140 unchanged, 25 generated, five replacements
  and two platform files, plus 97 unchanged upstream test files and two generated mirrors.
- All 29 pinned source archives and their license inventory pass offline integrity checks.

Linux release metadata prepares `1.5.5-linux-alpha.4`. The tag workflow builds and signs the
Flatpak, verifies installation including the native GIF journey, publishes the repository, and
marks the GitHub release Latest only after those steps succeed.

Existing macOS render-comparison differences and physical tablet validation limits remain documented
in `upstream-1.5.5-integration.md`; this integration adds no new macOS pixel-comparison result.
