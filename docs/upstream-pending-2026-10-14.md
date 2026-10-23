# Upstream 1.5.2 catch-up: 2026-10-14

Live `git ls-remote upstream refs/heads/main` returned
`43d691b67995e924965bcd520f8b300f96b7d5b8` on October 14. The cached
`upstream/main` and protected working-tree source now match that tip.
Linux adaptations remain uncommitted; synchronization is not a history merge.

| Commit | mac | GNU_Linux | Status |
|---|---|---|---|
| `735c2cc` | Picture-adaptive Camera Raw Shadows | Unchanged upstream Swift/C pass and original picture/tone-order tests; both Camera Raw tables are installed for runtime, launcher, tests and Flatpak. | Implemented |
| `a3a0e29` | RAW Camera Raw… imports and opens the filter | Generated upstream button, staged replacement retains the RAW layer even when another file follows, Qt creates the first floating filter panel. Native single/mixed Import and Camera Raw journeys verify target, Cancel and import Undo/Redo; window rejection cancels the staged session. | Adapted |
| `f2d5754` | Version 1.5.2 | Protected Xcode metadata and derived Linux version 1.5.2/build 48. | Adapted |
| `43d691b` | Publish Mac update feed | Existing local appcast is preserved. The new upstream feed is retained with synchronization backups; Linux continues its separate Flatpak update mechanism. Installed-release update/relaunch remains unverified. | Adapted |

The upstream diff changes 11 files (392 additions, 34 deletions), including
`CameraRawShadows.swift` and the 25,254-byte `CameraRawShadows.bin`.
Ten source/resource/project/test files were synchronized after comparison with
the tested base `e8c9e29`. Existing local appcast changes were preserved.
Backups: `/tmp/compositor-catchup-backup-w7r8ax0h`; the new Mac feed is
`upstream-appcast.xml` there. Temporary evidence is not a shipped artifact.

Focused Camera Raw/import checks pass: 41 tests in two suites, plus the native
Qt preview journey (`/tmp/compositor-152-acceptance-build.log`,
`/tmp/compositor-152-acceptance.log`). The first full run found a stale Linux
RAW-sheet test expecting three buttons. It now requires all four, including
Camera Raw…. Full rerun result is recorded in the current test baseline.
Required-shader/protected-source integrity passes against `43d691b`:
`/tmp/compositor-152-integrity-final.log` (exit 0).

The remaining historical crosswalk and physical/Mac acceptance targets are
listed in [the completion audit](linux-status-completion-audit.md).
No Mac is available; these statuses describe the documented Linux scopes.
