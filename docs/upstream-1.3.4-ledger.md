# Upstream 1.3.4 catch-up ledger

Branch: `GNU_Linux`. Protected trees pinned at `2309a85` (1.3.3 + readable ASCII dithering). Comparison tip: `c28f827` (`upstream/main`, Compositor 1.3.4).

Range: `git log 2309a85..c28f827` — **10 commits**. The earlier “37” count was 26 (1.3.3, already merged at `290bf5e`) + these 10 + the catch-up merge commit.

Constraint: `Compositor/` and `CompositorTests/` stay byte-identical to `2309a85`. Linux ports 1.3.4 behavior through overrides, generators, patches, and the Qt/compat shell — Mac Swift remains the behavior source of truth.

| Upstream | Subject | Linux artifact | Verified |
| --- | --- | --- | --- |
| `0eaeb98` | Type: apply a font change to the selected letters | `linux/patches/text-format-11.patch` → `Sources/Overrides/{TypeTool,ProjectStore}.swift` via `scripts/gen-text-format-11.py`; Qt attributed text in `Sources/Compat/AppKit/TextBackend.swift` + `host/QtImageIO.cpp`; `Sources/Overrides/TypeControls.swift`; format docs in `docs/project-format.md` | G10–G11: TypeToolTests / FontRunValidationTests / NativeTextEditingTests; `--text-backend-smoke`; `--preview-smoke` mixed-font + format-11 save/reopen (2026-09-27) |
| `1ffc8f4` | Type: let a mixed selection take the face the menu already shows | Same TypeTool override + TypeControls selection-aware binding | Covered by TypeToolTests font-selection cases and `--preview-smoke` font picker (2026-09-27) |
| `9593bf5` | Add the review of the per-letter font change | Upstream-only `PR_REVIEW_140.md` (later dropped). No Linux product code | n/a — review note only |
| `bc29006` | Drop the review note and the font-width assertion | Upstream test/doc cleanup. Linux TypeToolTests generated from pinned 1.3.4 tip after this drop | `scripts/gen-text-format-11.py --check` / freshness via `check-upstream-clean.sh` |
| `9d3d1b7` | Trial: merge PR #140 (font for selected letters) | Superseded by `7b22492`. Same Linux font-run / format-11 stack | Same as `0eaeb98` / `7b22492` |
| `916d1ab` | Type: the font menu says (Multiple) for a selection in several faces | `Sources/Overrides/TypeControls.swift` (mixed-face indicator) | `--preview-smoke` Qt font-picker mixed-state display (2026-09-27) |
| `7b22492` | Merge PR #140: apply a font change to the selected letters | Final merge of the font-run / format-11 feature set above; `linux/upstream-parity.json` pins TypeTool, ProjectStore, TypeControls to 1.3.4 | Integrated suite: 48 tests across TypeTool / NativeText / FontRunValidation / ProjectManifest / SaveSnapshot / Group / LayerMask / LayerAppearance; smokes listed under G10–G11 |
| `c3e360a` | Select › Color Range | `linux/patches/color-range.patch` → `Sources/Overrides/{EditorSession,ColorRangeSelection,ColorRangeSheet,CompositorApp}.swift` via `scripts/gen-color-range.py`; kernel `backends/selection/ColorRange.c`; host wiring in FloatingPanels / SessionWindow / DialogJourney | G12: ColorRangeTests; `--color-range-smoke`; `--preview-smoke` / `--dialog-smoke` re-run (2026-09-27) |
| `ab99b60` | Compositor 1.3.4 | macOS Xcode marketing version bump only. Linux package version stays independent (`1.2.0-linux-alpha.1` lineage) | n/a — no Linux feature gap; version strings intentionally diverge |
| `c28f827` | Publish update feed for Compositor 1.3.4 | macOS Sparkle `appcast.xml`. Linux Flatpak updates are the platform replacement | n/a — platform update channel, not editor behavior |

## Supporting evidence (not per-commit)

| Check | Evidence |
| --- | --- |
| Protected trees match `2309a85` | `UPSTREAM_REF=2309a85 sh scripts/check-upstream-clean.sh` (recorded pass 2026-09-27; re-run required before land) |
| Generator freshness | Same script checks `gen-text-format-11.py`, `gen-color-range.py`, related override generators |
| Full Swift suite | **425 tests / 75 suites** with six documented skips (`linux/UPSTREAM_TEST_EXCLUSIONS.md`), 2026-09-27 |
| Native journeys | `--package-smoke`, `--preview-smoke`, `--save-smoke`, `--dialog-smoke`, `--color-range-smoke`, `--text-backend-smoke`, `--interchange` |
| Interchange retention | `linux/interchange-verification.md` + `scripts/test-interchange.py` (Linux fixture retention; no Mac runtime claimed) |
| Gap narrative | `linux/compatibility-gap-progress.md` (G01–G12), `docs/linux-gap-feasibility-2026-09-27.md` |

## Still open after this ledger (Part B)

Tool **transitions** are not covered by the per-feature smokes above. Qt `SessionWindow::setTool` still diverges from upstream `EditorSession.selectTool` (text finish / refusal / re-entrancy). That work is Part B of `docs/upstream-catchup-and-tool-combos-2026-09-28.md`, with scope decisions: critical-pair journey in existing DialogJourney; shell mirrors session (including crop seed); Mac Swift remains SSOT.


## Part A gates re-run (2026-09-28)

| Gate | Result |
| --- | --- |
| `UPSTREAM_REF=2309a85 sh scripts/check-upstream-clean.sh` | pass |
| `git diff --check` (tracked) | pass |
| `swift test -c release` with six documented skips | **425 tests / 75 suites** pass (~29s after build) |
| Rebuild `libCompositorQtImageIO.so` + release `CompositorHostBootstrap` | pass |
| `--package-smoke` | pass (120 MP images+masks) |
| `--preview-smoke` | pass |
| `--save-smoke` | pass (2467 UI ticks) |
| `--dialog-smoke` | pass |
| `--color-range-smoke` | pass |
| `--text-backend-smoke` | pass |
| `--interchange fixture` + `scripts/test-interchange.py` | pass (13 cases) |

Ready for Part A land commit when requested. Part B (tool transition) still open.
