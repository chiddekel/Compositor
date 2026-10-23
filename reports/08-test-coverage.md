# 08 — Tests and verification

## What was executed by this audit (2026-10-18)

**Re-baseline run on `6f69273`:** `.build/evidence/full-contract-uifix.sh` (the full contract runner `scripts/linux-contract-tests.sh`, then `REQUIRE_SHADER_CHECK=1 scripts/check-upstream-clean.sh`), Flatpak SDK, required Vulkan (RADV RENOIR) and subject model. Exit **`0 0`** (`.build/evidence/full-contract-uifix.exit`).
- Swift Testing: 974 tests in 163 suites passed, run serially by the runner.
- XCTest: 150 tests, 0 failures. That's 148 plus the new `UIAuditCompatTests`, 2 tests.
- CTest kernels: passed.
- Native journeys: all 36 gates passed, including the new `--ui-audit-probe` ("Qt UI audit OK …"); 773 OK lines.
- Integrity: protected trees match `upstream/main`, ledgers OK, shaders checked, and `gen-lucide-icons.py --check` passed.
- Log: `.build/evidence/full-contract-uifix.log`.

The earlier runs on `959850f` are kept below for history.

| Run | Command / script | Environment | Result | Log |
|---|---|---|---|---|
| Swift Testing, parallel | `.build/evidence/audit/run-tests.sh` (first version, no `--no-parallel`) | Flatpak SDK (`build-flatpak`), prebuilt release bundle `CompositorPackageTests.xctest` (built 13:16), `env.sh` flags (Vulkan required, subject model required, forced GPU canvas) | **Stalled** after 84 passing tests, no output for >10 min; stopped | `.build/evidence/audit/tests-swift-testing-parallel-stalled.log` |
| Swift Testing, serial | same, `--testing-library swift-testing --no-parallel` | same | **974 tests in 163 suites passed** (147 s), 0 failures, 0 skips | `.build/evidence/audit/tests-swift-testing.log` |
| XCTest | same bundle, default library | same | **148 tests, 0 failures** | `.build/evidence/audit/tests-xctest.log` |
| Override drift | `python3 scripts/upstream-override-drift.py` | host | OVERRIDE DRIFT CLEAN (`a1bd74c..365b574`) | console |
| Protected tree + ledgers | `bash scripts/check-upstream-clean.sh` | host | UPSTREAM CLEAN; three ledgers OK | console |
| UI capture | `.build/evidence/audit/grab.sh` × 64 runs | SDK, offscreen | 62 captures; 2 modal dialogs not captured (Search Commands, Export As) | `.build/evidence/audit/logs-*.txt`, `shots/` |

Not executed by this audit (pre-existing evidence only): the native Qt journeys and CTest from the full contract runner. The latest full run, `.build/evidence/full-contract.log` (2026-10-18 13:48), has exit status `0 0` in `full-contract.exit`. It is cited as context, not as a result of this audit. The bundle was not rebuilt (disk: 12 GB free of 394 GB), so commits after 13:14 (`98dbefc`, `959850f`: version/CI only) are not in the tested binary.

## Inventory

| Suite set | Files | Notes |
|---|---:|---|
| Upstream `CompositorTests/` | 89 (652 `@Test` + 10 XCTest functions) | Compiled unmodified as target `CompositorUpstreamTests`. `LayerTests` and `KeyboardShortcutTests` run as generated mirrors (selectors by name; the `UserDefaults` type name), see `linux/UPSTREAM_TEST_EXCLUSIONS.md`. All 90 upstream suites passed today; none skipped |
| Upstream `CompositorUITests/ScreenshotTests.swift` | 1 | XCUITest; **not runnable on Linux**, no Linux counterpart (GAP-TEST-02) |
| `Tests/CompatTests` | 26 | Compat API behavior (Skia/CI/AppKit/SwiftUI hosting, inotify, dismantle) |
| `Tests/LinuxOverrideTests` | 72 | Bridge, overrides, native pointer/session/file-panel/alert ownership, Linux mirrors |
| CTest (`CMakeLists.txt`) | 13 | SkiaBridge, OpenCVBridge, HostJourney, PngCodec, FontTraits, NativeFilePanels, ImageIOColor, Thumbnailer, Abi, Kernels, ScanlinesInitialization, PatchPixels, RawLens |
| Native Qt journeys (contract runner) | 36 gates (incl. `--ui-audit-probe` since `6f69273`) | `--tab-smoke`, `--preview-smoke`, `--transform-smoke`, `--combo-smoke`, `--save-smoke`, `--package-smoke`, `--filter-controls-probe`, `--cmyk-proof-probe`, `--svg-import-probe`, `--scrub-probe`, `--transform-fields-probe`, `--zoom-cursor-probe`, `--upstream-153-probe`, … (`scripts/linux-contract-tests.sh`) |

## Coverage by feature (catalog, report 04)

- 155 of 179 features have at least one upstream test suite; all of those suites passed today.
- 24 features have no upstream test. These are app chrome, platform services and UI-only items: APP-02/03/04/05/06/07/08/10/11/12/15, FILE-02/05/18/24, EDIT-09, VIEW-07/10/15, FLT-13, LAY-17, TOOL-17, KEY-04/05. Some of them have Linux-only coverage:
  - FILE-24: `--svg-import-probe`.
  - FLT-13: `ReadmeFeatureAcceptanceTests`.
  - VIEW-10: `test_grid_settings`.
  - APP-06/07: `--app-visibility-probe`.
  - KEY-04: touch smoke.
  - FILE-18: `Thumbnailer` CTest.
  - APP-05: `scripts/test-flatpak-updates.sh`, not run here.

## Why the gaps found here were not caught

Upstream's tests assert model and command behavior; they never look at what the Linux renderer draws. The native journeys drive controls by accessible name and read session state. Two cases illustrate this:
- `--filter-controls-probe` sets values through the FilterSheet sliders and passes, even though the titles beside them are clipped (GAP-UI-02).
- No journey looks for the New Canvas ⋯ button (GAP-UI-01), the proof pills (GAP-UI-03) or icon pixels (GAP-UI-04/05).

So "every test passes" and "the UI matches" were different claims on `959850f`. Since `6f69273`, the `--ui-audit-probe` gate makes the drawn UI part of the contract: it failed with 26 findings before the fixes and passes now.

## Missing tests (to add)

| Kind | Test | Closes |
|---|---|---|
| Visual regression | ✅ Generic checks done (`--ui-audit-probe`, `6f69273`). Still missing: baseline PNG diffs, and coverage of Export As and Search Commands | GAP-TEST-02 (partial) |
| Symbol table | ✅ `gen-lucide-icons.py --check` in `check-upstream-clean.sh` (`6f69273`) | GAP-UI-04/05 (resolved) |
| Compat layout | ✅ `UIAuditCompatTests` (Picker struct tags; per-occurrence background readers). The ZStack, Menu-label and fixedSize cases are covered by the probe, not by unit tests | GAP-UI-01/02/06 (resolved) |
| UI state | ✅ The probe toggles both pills and closes them | GAP-UI-03 (resolved) |
| Bridge completeness | Enumerate upstream commands (menus, palette catalog, shortcut catalog) and assert none returns −7 "not supported by this bridge" | regression guard |
| Golden images vs macOS | Report 07 table | GAP-VER-04 |
| Document compatibility | Mac-generated `.comp` corpus v1–v14 (report 06) | GAP-VER-04 |
| Packaging | Installed Flatpak update + relaunch (`scripts/test-flatpak-updates.sh` in CI); thumbnailer in a file manager | GAP-PLAT-04, GAP-VER-02 |
| Concurrency | Parallel Swift Testing completes 3× | GAP-TEST-01 |
| Performance | GPU vs CG canvas at 1400×900 and 7680×4320 | GAP-PERF-01 |
| Physical input | Manual matrix: Wayland/X11 × mouse/trackpad/touch/pen | GAP-VER-03 |

## Acceptance test per feature

Report 04 gives an acceptance criterion in every row. For rows without a gap it is "listed upstream suites pass + UI interaction journey". For rows with a gap it is the gap's test from report 09.
