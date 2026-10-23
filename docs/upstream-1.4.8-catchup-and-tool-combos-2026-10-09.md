<!-- /autoplan restore point: "/home/developer/Projekty/Compositor/.gstack/tmp/autoplan/GNU_Linux-autoplan-restore-20261009-185159.md" -->
# Upstream 1.4.6–1.4.8 catch-up closeout + tool-combination contract

Date: 2026-10-09. Branch: `GNU_Linux`. HEAD: `da59c93`. Upstream tip: `22c7b8d` (Compositor 1.4.8).

## Implementation plan

### 1. Premise: what is actually left

Request: "continue with upstream; do not touch upstream or the original Mac code; change only the compatibility layer;
list and catch up 37 commits from upstream; tool combinations must work as in a proper commercial app, for example
text + selection + gradient."

Ground truth measured today:

- `git log HEAD..upstream/main` is **empty**. Upstream 1.4.8 is merged (`c80117a`) and `check-upstream-clean.sh`
  prints `UPSTREAM CLEAN`. Nothing remains to *merge*.
- The merge brought **54 non-merge commits**. 9 touch no Swift (README, version bumps, appcast). 7 touch only tests.
  That leaves **38 commits that change Swift product code** under the count rule below; the request's "37" is one
  off, most likely from counting the Navigator dock commit `6490bb3` (superseded by the minimap `3e09948`) as docs.
  The ledger states the rule and the 38, and explains the difference.
- `docs/upstream-1.4.6-1.4.8-ledger.md` already marks every one of them Done / Inherit / Docs. It was written from
  themes, not from a per-file check. A mechanical check today (upstream added lines vs. each hand-kept override) shows
  the ledger overstates coverage:

| Override (hand-kept) | Upstream lines added in range | Missing in override | Gap |
|---|---|---|---|
| `Sources/Overrides/ContentView.swift` | 17 | 1 (+1 behavioral) | Last Filter's `repeating` gate: Last Filter must apply **without** opening the filter panel (`0415aa4`). `importError` alert `OK` must lose its `.cancel` role (upstream comment: an alert with only a cancel button gets a second OK). |
| `Sources/Overrides/KeyboardShortcuts.swift` | 4 | 4 | Shortcut list has no `Search Commands` (⌘F), `Last Filter` (⌃⌘F), `Export As` (⌥⇧⌘W), `Export PNG/JPEG` rows, nor the `Toggle Fullscreen` (F) tool-key row (`6b81d4a`, `720c121`, `450af5f`). Settings › Shortcuts lists stale keys and re-record cannot see them. |
| `Sources/Overrides/LayerMaskMenu.swift` | 6 | 2 | Footer mask button: `.disabled(!session.layersLookEditable …)` (`06313a9`) and `FooterIcon` (`7fb40a9`/`790195f`). |
| `Sources/Overrides/NativeLayerListOverride.swift` | 9 (AppKit) | 9 | AppKit-specific; behavior (reveal on active change, rename background, `layersLookEditable` dimming) must be checked on the Qt side, not copied. |
| `Sources/Overrides/MetalLayerEffects.swift` | 8 (Metal) | 8 | Color Overlay / Inner Glow / Inner Shadow now **recolor** the source keeping its alpha (`e7e295e`, `9cb57db`). The working tree already ports this into `backends/effects/{EffectsCPU,EffectsOpenCV,EffectsVulkan}.cpp` and `effects.comp`, **uncommitted**. |
| `Sources/Overrides/EditorSession.swift`, `CompositorApp.swift` | 44, 20 | 0 | Generated; fresh (`gen-color-range.py --check`, `gen-compositorapp-override.sh --check` clean). |

- The working tree also carries an **uncommitted** fix for the residual `done.txt` records: Show Transform Controls
  no longer arms a persistent Free Transform (deletes `Sources/Overrides/TransformInspector.swift`, removes the
  re-arm in `UpstreamEditor.swift` `setShowsTransformControls` / `transformCommit` / `transformCancel`, exposes
  `transformPending`, and reports `canUndo` from `s.canUndo`). While armed, `canEditLayers == false`
  (`EditorSession.swift:686`, `canEditLayers`, includes `transformEdit == nil`), which silently blocks **every** other tool:
  undo, New Layer, blend mode, brush, gradient. That is why `--dialog-smoke`, `--layers-smoke`, `--brush-smoke` fail.
  It is also the most likely cause of "tool combinations don't work": any gradient after a Move/selection hits
  `canPaint == false` and returns without a message.

So the work is: (A) a per-commit ledger that is *true*, (B) close the real override gaps above, (C) land the
transform-arming fix, (D) make tool combinations a tested contract, (E) gates.

### 2. Part A — truthful per-commit ledger (deliverable)

Rewrite the commit table in `docs/upstream-1.4.6-1.4.8-ledger.md` so every one of the 54 rows carries:
upstream subject, files touched, how Linux consumes each file (`compiled as-is` / `generated override` /
`hand override` / `Qt mirror` / `excluded test`), the Linux artifact, and the evidence (test name or smoke step).
The code commits (count rule in the accepted requirements) are listed first and numbered, so the request's "37" maps
onto a reproducible number; any difference from 37 is explained in the ledger.

Add `scripts/upstream-override-drift.py` (Linux-owned): for a commit range, list upstream added code lines missing
from each hand override named in `linux/upstream-parity.json`. Lines that are expected to be missing (AppKit/Metal) are listed per override in an allowlist in
`linux/upstream-parity.json`; any other missing line fails `check-upstream-clean.sh`. The ledger cites its output.

### 3. Part B — close the override gaps (compat layer only)

- **B1** `Sources/Overrides/ContentView.swift`: take upstream's `.onChange(of: session.filterEdit == nil ||
  session.filterEdit?.repeating == true)` and `Button("OK") { … }` lines verbatim; refresh the header's
  "Refreshed … against upstream" note to `22c7b8d`. Check the Qt shell's Last Filter path (`⌃⌘F`) also skips the
  panel; if the shell opens its own Qt FilterDialog for a repeating edit, gate it on the same flag.
- **B2** `Sources/Overrides/KeyboardShortcuts.swift`: add `scripts/gen-keyboard-shortcuts.py` (with `--check`) that
  regenerates the override from tip; the only deviation is the ShortcutRecorder swap. Point the file header and its
  `upstream-parity.json` row at the generator. Qt accelerators stay hard-coded in `host/SessionWindow.cpp`; a
  `--dialog-smoke` step asserts the Qt actions for Search Commands (Ctrl+F), Last Filter (Ctrl+Meta+F), Export As
  and Toggle Fullscreen (F) carry the same keys as the generated table. Table-driven Qt accelerators are deferred.
- **B3** `Sources/Overrides/LayerMaskMenu.swift`: add `layersLookEditable` to the footer mask button's `.disabled`
  and use `FooterIcon` (already ported to compat per `da59c93`).
- **B4** Qt Layers panel: verify, with `--layers-smoke` steps, the three NativeLayerList behaviors (reveal only when
  the active id changes; rename field keeps its size and shows a layer background; footer dims via
  `layersLookEditable` instead of flashing gray during a stroke). Fix host-side only where a step fails.
- **B5** Edit menu (`710dd66`): confirm the Qt Edit menu has no macOS text extras (Start Dictation, Emoji &
  Symbols, Writing Tools, AutoFill). Ledger row says so with evidence.
- **B6** Layer effects recolor: land the working-tree change in `backends/effects/*`. CPU, OpenCV and Vulkan paths
  must agree: a translucent pixel under Color Overlay (opacity 1) takes the overlay color fully and keeps its alpha.
  Existing `LayerEffectsBackendTests` (modified in the working tree, see Part E rule) and upstream
  `ColorOverlayTests` are the evidence.

### 4. Part C — Show Transform Controls no longer arms Free Transform

Land the working-tree change: Show Controls is a display flag again (tip `TransformInspector` behavior on
1.4.8), Free Transform is armed only by ⌘T / a handle drag, `transformPending` tells the shell when Apply/Cancel
apply, and `canUndo/canRedo` come from the session (`s.canUndo`) so a pending edit's undo is honest.
Delete `Sources/Overrides/TransformInspector.swift`; remove its row from `linux/upstream-parity.json`;
`scripts/gen-compositorapp-override.sh --check` stays clean.

### 5. Part D — tool-combination contract (the reported bug class)

Principle: the Swift `EditorSession` is the single source of truth (active decision, 2026-09-28). A combination
works on Linux exactly when the bridge sends the same sequence of session calls the Mac `EditorCanvas` does. So
combinations are tested at two levels.

- **D1 Session-level matrix (Swift, `Tests/LinuxOverrideTests/ToolCombinationTests.swift`, new file).** Drives
  `UpstreamEditor` commands only (the same JSON the Qt shell sends), asserts on session state and pixels. Cases:
  1. Rectangle selection → Gradient drag → Apply: pixels change only inside the selection; outside bytes identical.
  2. Type tool editing (live `textDraft`) → Gradient drag: text is committed first, then the gradient starts on the
     active layer; one undo step each (Undo twice restores the pre-text state).
  3. Text layer selected, marquee selection, Gradient: upstream rasterizes on pixel edits (`TypeTool.swift:204`,
     "Pixel edits rasterize the layer"; `canPaint` has no text clause). Expected: after Apply the layer's `text` is nil,
     pixels change only inside the selection, and one Undo restores the editable text layer.
  4. Selection → Brush stroke: clipped to the selection.
  5. Selection → Move (pixel move drag, released) → Gradient: `finishPixelMove()` has cleared `pixelMove` on release,
     so the gradient starts and clips to the moved selection.
  6. Show Transform Controls on → Gradient / Brush / New Layer / blend mode / Undo: all work (regression for Part C).
  7. Pending Gradient → switch to Brush: `resolveGradient()` applies it (upstream `selectTool` order).
  8. Pending Crop → Gradient: crop cancelled, gradient works.
  9. Selection → Crop: crop rect seeded from selection bounds.
  10. Gradient on a mask target with a selection: gray ramp clipped to the selection.
  11. Hidden / adjustment / group / multi-selected / disabled-mask target → Gradient: the `paintRefusal` text
      (`EditorSession+Brush.swift:14`) reaches the command's error. (Upstream has no layer lock.)
  Each case also asserts `canEditLayers == true` once settled, so a stuck pending edit fails loudly.
- **D2 Native journey (`--combo-smoke` in `host/DialogJourney.cpp`).** Real Qt widgets, offscreen: rail clicks and
  canvas mouse events for cases 1, 2, 5 and 6, asserting that the rail tool equals `sessionState().tool` after each
  step and that the refusal reason (same order as D3) is shown in the status bar on refusal.
- **D3 Fix whatever D1/D2 expose**, in the bridge (`UpstreamEditor.swift`) or host (`SessionWindow.cpp`) only.
  Known sites: `UpstreamEditor.swift` gradientBegin (587, already `brushError ?? …`), shapeBegin (603), text
  begin (625, 630) and brushBegin (715) return bare strings. All use one helper `refusal(s)` =
  `s.paintRefusal ?? s.brushError ?? busyReason(s)`, where `busyReason` is Linux bridge text naming the pending
  state (transformEdit, cropRect, gradientEdit, pixelMove, textDraft, filterEdit, levels, hueSaturation, colorRange)
  e.g. "Free Transform is pending: press Return to apply or Esc to cancel". These strings are Linux-only (upstream
  waits silently while busy) and are listed in the helper's doc comment.

### 6. Part E — gates

1. `sh scripts/check-upstream-clean.sh` → `UPSTREAM CLEAN`; `git diff --stat da59c93 -- Compositor
   Compositor.xcodeproj CompositorTests CompositorUITests` empty.
2. Generators, each `--check` clean and each run by `check-upstream-clean.sh`: `gen-color-range.py`,
   `gen-text-format-11.py`, `gen-smudge-liquify-override.py`, `gen-preview-renderer.py`, `gen-project-validation.py`,
   `gen-compositorapp-override.sh`, new `gen-keyboard-shortcuts.py`. (`gen-lucide-icons.py` has no check mode.)
3. Full `swift test` (Flatpak SDK, release) with only the documented skips; record pass/fail counts.
4. Release `CompositorHostBootstrap` smokes: `--session-smoke`, `--io-smoke`, `--transform-smoke`,
   `--dialog-smoke`, `--layers-smoke`, `--brush-smoke`, new `--combo-smoke` all pass (three fail today).
   `--transform-smoke` is the one exception: if it encodes the old armed behavior, the user decides (failure table).
5. `git diff --check` clean.
6. Test-file rule: tests are immutable. The working tree modifies four existing test files under
   `Tests/LinuxOverrideTests/`. Before committing, show the user each diff and get an explicit yes; otherwise revert
   those test edits and fix code instead. New test files (D1) are additions and are named in the commit message.

Commits, in order (bisectable): (1) effects recolor port, (2) Show Controls un-arm, (3) override re-syncs B1–B5,
(4) tool-combination tests + fixes, (5) ledger generator + ledger + drift script/allowlist + TODOS.md entry for
the deferred CI job. Ordering dependency: the drift gate in (5) passes only because (3) landed first; never move
(5) before (3). No push to `origin`.

### 7. What already exists (reuse, do not rebuild)

- Upstream 1.4.8 merge and `UPSTREAM CLEAN` gate; generator `--check` modes.
- `SessionWindow::requestTool` / `applyToolLocally` split and session-mirroring `syncToolFromSession`
  (from the 2026-09-28 plan, landed).
- `UpstreamEditor` command surface for gradient/shape/selection/transform; `DialogJourney.cpp` journey harness.
- `docs/upstream-1.4.6-1.4.8-ledger.md` (rewritten, not replaced).

### 8. NOT in scope

- Any edit to `Compositor/`, `CompositorTests/`, `CompositorUITests/`, `Compositor.xcodeproj`.
- Compiling tip `CommandPaletteView` / `NavigatorTests` (still excluded, reasons in `UPSTREAM_TEST_EXCLUSIONS.md`).
- Sparkle / appcast; Flatpak release bump; pushing to `origin/GNU_Linux`.
- Rewriting the Qt tool rail as a pure view of session state.

### 9. Failure modes and rescue

| Failure | Detection | Response |
|---|---|---|
| Protected tree drift | `check-upstream-clean.sh` | Stop; restore; never commit. |
| Override re-sync breaks the type checker (ContentView `.onChange` chain) | `swift build` timeout | Keep the `bodyCore` split; move the new `.onChange` into whichever half keeps the chain short. |
| Effects backends disagree (CPU vs Vulkan) | `LayerEffectsBackendTests` per-backend | Fix shader; regenerate `effects_spv.h` via its build script; never relax tolerance. |
| Un-arming transform regresses `--transform-smoke` | that smoke | The smoke encodes the old armed behavior; ask the user before changing it (tests immutable). |
| D1 case reveals upstream itself refuses (e.g. gradient on a folder or hidden layer) | case 11 | That is the Mac behavior; Linux must show the same message. Not a bug to "fix". |
| Combo journey flaky | repeated runs | Bounded poll on settled state, no fixed sleeps. |


<!-- autoplan-accepted:ceo -->
- Ledger: every one of the 54 commits in `11d8d7a..22c7b8d` has a row; the code commits (count rule below) are numbered first; each row names files, consumption kind, Linux artifact, evidence (test or smoke step). Rows are generated by a Linux-owned script from git + `linux/upstream-parity.json`; evidence is filled by hand. Verify: script output has 54 rows and the numbered count equals the generator's printed code-commit count.
- Drift check: `scripts/upstream-override-drift.py` lists upstream added code lines missing from each hand override; `linux/upstream-parity.json` carries an allowlist of expected-missing lines (AppKit/Metal) per override; `check-upstream-clean.sh` fails on any non-allowlisted missing line. Verify: a manual pre-commit run fails on today's tree before B1–B3 and passes after; the script lands in commit (5), after (3).
- `Sources/Overrides/KeyboardShortcuts.swift` is generated from tip by `scripts/gen-keyboard-shortcuts.py` with a `--check` mode; the only deviation is the ShortcutRecorder swap. Verify: `--check` clean; Settings › Shortcuts lists Search Commands ⌘F, Last Filter ⌃⌘F, Export As, Toggle Fullscreen F.
- `ToolCombinationTests` is table-driven over every ordered pair of tool families, asserting after each switch: settled session tool == requested or a refusal message; no pending gradient/shape/lasso/crop/transform draft survives a switch except as upstream `selectTool` keeps it; `canEditLayers` true once settled. Plus the 11 named cases in Part D. Verify: see fail-first proof below.
- Every refused tool action surfaces its reason (`paintRefusal`, else `brushError`, else a named busy state such as "Free Transform is pending: press Return or Esc") in the command error and the Qt status bar; no command returns the bare "could not start". Verify: D1 case 11 + combo-smoke status-bar assertion.
- Baseline replacement (E1): Part A's drift script is no longer advisory-only; non-allowlisted missing lines fail `check-upstream-clean.sh`.
- Baseline replacements (spec review 1): B2 generator + smoke key assertion (Qt rewire deferred); D1 case 3 expects rasterize-on-paint; case 5 expects `pixelMove == nil` after release; D2/D3 use one refusal order `paintRefusal ?? brushError ?? busyReason`; Gate 2 lists generators explicitly; Gate 4 transform-smoke exception; commit (5) ordering + TODOS entry.
- 37-count rule: a commit counts as "code" when it changes at least one `Compositor/**/*.swift` file outside `CompositorTests/`, excluding commits whose only product change is a version/feed bump. The ledger generator applies this rule and prints its count; the ledger states the rule and the printed number (the rule yields 38; the ledger says 38 and explains the request's 37).
- Ledger generator: `scripts/upstream-ledger-rows.py <from> <to>` prints Markdown rows `| # | upstream | subject | files (consumption kind) | Linux artifact | evidence |` into the "Commit ledger" table of `docs/upstream-1.4.6-1.4.8-ledger.md`; artifact/evidence cells start as `TODO` and the script's `--check` fails while any `TODO` remains.
- Drift allowlist schema in `linux/upstream-parity.json`: new key `"drift": {"<override path>": {"upstream": "<Compositor/... path>", "allow_missing": ["<exact trimmed line>", ...]}}`. Covered: hand overrides ContentView, LayerMaskMenu, NativeLayerListOverride, MetalLayerEffects, UIStandIns-backed files. Not covered: generated overrides (their `--check` is the gate) and Qt adapters with no Swift override.
- Tool families for the ordered-pair matrix: marquee, lasso, magic wand, move, brush, eraser, clone/heal, smudge/blur, gradient, shape, type, crop, eyedropper, hand/zoom. Transition table from `EditorSession.selectTool` (`EditorSession.swift:387`): live text draft -> `finishText()` commits or refuses the switch; transformEdit -> committed; cropRect -> cancelled; gradientEdit -> committed (async `commitGradient`); lassoDraft -> cancelled; shapeDraft -> cancelled; selection -> kept; crop entry seeds `cropRect` from the selection bounds. The test asserts exactly this table.
- Part C vs test immutability: before commit (2), show the user the `TransformInspectorProbeTests.swift` diff. If declined, keep the original probe test by resolving `TransformInspector(session:)` against tip `Compositor/UI/TransformInspector.swift` (compiled as-is once the override is deleted); if that does not compile, Part C waits for the user's decision.
- B1 Last Filter: a `--dialog-smoke` step applies a filter, then Ctrl+Meta+F, and asserts the layer changed again with no filter dialog visible.
- Baseline replacements (spec review 2): `canEditLayers` cited at `EditorSession.swift:686`; case 11 drops "Locked" (no upstream lock) and lists the real `paintRefusal` clauses; failure-table example corrected (text layers rasterize, case 3).
- `busyReason` covers every `canEditLayers` term (`EditorSession.swift:688` body): selectionAmountOperation, colorRange, textDraft, document == nil, brushStroke, warpStroke, isProjectBusy, isImporting, showsNewDocument, showsImporter, renamingLayerID, transformEdit, cropRect, gradientEdit, pixelMove, hueSaturation, levels, filterEdit, adjustmentEditingID. Each has one fixed string in a single table in the bridge; a unit test iterates the table so a new upstream term without a string fails.
- Refused tool switch: the bridge `selectTool` command compares `s.tool` after the call; if unchanged it fails with `refusal(s)` (text commit failure surfaces `brushError` from `finishText()`; the guard surfaces `busyReason` for isProjectBusy / brushStroke / warpStroke / levels). Transition table adds: `levels`, `brushStroke`, `warpStroke`, `isProjectBusy` -> switch refused; `pixelMove` -> untouched by `selectTool` (cleared by `finishPixelMove` on release).
- Matrix fixture and settle: each pair starts from a 64x64 document, one raster layer, a 16x16 rectangle selection, and the "from" tool's typical pending draft (type: live textDraft; gradient: gradientEdit with a line; crop: cropRect; shape: shapeDraft; lasso: lassoDraft; move: none after release; others: none). Settled means `await` of the command plus a bounded poll (max 2 s, 10 ms steps) until `gradientEdit == nil` when a commit was owed. Per pair, state-only asserts; pixel asserts only in the 11 named cases.
- Status-bar contract (D2): the Qt status bar shows exactly the bridge error string, for at least 4 s, and the combo smoke reads it within 1 s of the refused action.
- `--transform-smoke` decision format: if it fails after Part C, show the user the failing `require` line, the old vs new behavior, and ask Keep-old-smoke (revert Part C) or Approve-smoke-change; no edit to the smoke without that answer.
- B7 (working tree, previously unlisted): `backends/brush/BrushCoverageValidation.h` raises the coverage radius cap from 1000 to 1050 so Smudge/Liquify commits above the 2000 px UI limit validate; evidence `BrushCoverageBackendTests.internalWarpCommitRadiiFitTheCoverageBackend` (new test in a modified file). Lands in commit (1) with the effects port.
- WIP mapping: `linux/graphics/SkiaBridge.cpp` (inside/recolor filter) -> B6; `host/SwiftUIQtRenderer.cpp` (mask effect with opacity) -> B3/B4 footer dimming; `host/DialogJourney.cpp`, `host/SessionWindow.cpp`, `Sources/LinuxBridge/SwiftUIBridge.swift`, `UpstreamEditor.swift`, `Package.swift`, `gen-compositorapp-override.sh`, `UpstreamEditorTests.swift`, `TransformInspectorProbeTests.swift` -> Part C; `LayerEffectsBackendTests.swift` -> B6.
- Declined test edits: each modified test file is approved separately. If declined, that file is reverted to HEAD and its Part ships only if HEAD's tests pass with the code change; otherwise the Part waits. B6 without its Linux test edit still requires upstream `ColorOverlayTests` passing plus a CPU/Vulkan/OpenCV agreement check in the new `ToolCombinationTests`-adjacent file `Tests/LinuxOverrideTests/EffectsRecolorParityTests.swift` (a new file, not an edit).
- Gate 2 also runs `scripts/upstream-override-drift.py --check` and `scripts/upstream-ledger-rows.py --check`, both from `check-upstream-clean.sh`.
- Deviation log: `busyReason` strings are a deliberate Linux-only behavior (upstream waits silently while busy); recorded in `linux/upstream-parity.json` under `deviations`.
- E7 deferral reason corrected: `.github/workflows/ci-guard.yml` exists and runs `check-upstream-clean.sh`, but no workflow runs `swift test` on Linux; the TODO is "add a Linux swift-test job running ToolCombinationTests".
- Baseline replacement (spec review 3): §1 count is 38 under the rule (54 = 9 non-Swift + 7 test-only + 38), with the 37 explained.
- Refusal scope: every `fail(-5, "... could not start ...")` site in `UpstreamEditor.swift` routes through `refusal(s)`, including tools (587, 603, 625, 630, 715, 984) and dialog/filter actions (753, 758, 761, 772, 884, 1045). Final fallback when `refusal(s)` is nil: `"<action> could not start: <specific cause>"`, where the cause is the concrete reason known at that site (e.g. clone source out of range). A fallback without a cause counts as bare and fails the test.
- Stale error: each tool command clears `s.brushError` before calling the session; `refusal(s)` reads only an error set during this command.
- UI contract: `paintRefusal` keeps the Mac behavior (modal "Couldn't paint" alert, as upstream sets `brushError`) and is mirrored in the status bar; `busyReason` and site fallbacks are status-bar only (no alert). The combo smoke asserts the alert for case 11 and the status bar for busy cases.
- `busyReason` completeness test: parses the `canEditLayers` body from tip `Compositor/Document/EditorSession.swift` (between `var canEditLayers: Bool {` and its closing brace), extracts the `&&` terms, and fails if any term lacks a key in the bridge table.
- Drift range: `linux/upstream-parity.json` gains `"ledger_base": "11d8d7a"`; the drift and ledger checks use `ledger_base..upstream_ref`. Each catch-up advances `ledger_base` when its ledger is complete.
- Drift allowlist covers exactly these hand overrides: `Sources/Overrides/ContentView.swift`, `LayerMaskMenu.swift`, `NativeLayerListOverride.swift`, `MetalLayerEffects.swift`, `UIStandIns.swift`, `CameraRawSlider.swift`, `MetalBrushCoverage.swift` (the `upstream-parity.json` override rows whose value names a non-generated `Sources/Overrides/*.swift`). The implementer derives the final list from that rule and prints it.
- Ledger `--check`: regenerates the subject, files and consumption-kind columns from git and compares them; ignores the hand-edited artifact/evidence cells except that they must not be `TODO`.
- Fail-first proof: case 6 (Show Controls) uses only the existing command surface (`setShowsTransformControls`, `gradientBegin`, `addLayer`, `undo`, `setBlendMode`) in its own `@Test`. Proof = it fails when run with Part C's diff reverted (`git stash` of Part C files) and passes with it. The refusal-text assertions are verified after D3 only.
- CEO voice integration (F1, F2, F9): commit order is (1) Part C + ToolCombinationTests named cases 1, 2, 3, 5, 6 + D3 refusal routing, (2) B6 effects recolor, (3) B7 brush radius cap, (4) B1–B5 override work + new generators, (5) D2 combo-smoke + key-parity smoke, (6) ledger generator + ledger + drift + TODOS entry. Fail-first proof for cases 1, 2, 3, 5, 6: run them with Part C and D3 stashed, record which fail; if 1/2/3/5 pass on HEAD, report that the user's combo bug has another cause and investigate before claiming a fix. No test is weakened or marked as a known issue to land red.
- F3: `Sources/Overrides/ContentView.swift` and `LayerMaskMenu.swift` become generated from tip by `scripts/gen-content-view.py` and `scripts/gen-layer-mask-menu.py` (copy tip + `linux/patches/*.patch`, with `--check`), run by `check-upstream-clean.sh`; the drift allowlist then covers only NativeLayerListOverride, MetalLayerEffects, UIStandIns, CameraRawSlider, MetalBrushCoverage. The drift compare normalizes whitespace and tokens and prints a suggested allowlist diff.
- F5: each named case's doc comment cites the Mac source line that fixes its call order (e.g. `EditorCanvas.swift:1833` for gradient, `EditorSession.swift:387` for tool switch).
- F6: the `busyReason` parser fails with "canEditLayers parser out of date" when it finds zero terms or a non-`&&` shape.
- F7: the matrix reports total runtime and fails above 60 s; a settle timeout message names the pair and the still-pending field.
- F8: the key-parity smoke covers every row of the generated shortcut table; TODOS.md records the rail rewrite with trigger "first combo-smoke rail/session mismatch".
- F10: the ledger generator writes `n/a (docs)` / `n/a (test-only, compiled as-is)` evidence for non-code commits; hand evidence is required only for the 38 code commits.
- F11: before/after screenshots of cases 1, 2, 3 in a real Qt window via `COMPOSITOR_GRAB_PATH`, saved under `docs/references/combos-2026-10/` and linked from the ledger.
- Async order (Section 4): a test pauses the gradient commit after a switch, asserts the next paint action is refused with the busy reason, releases, and asserts it then succeeds.
- Precedence: where accepted bullets conflict, the later bullet wins. Concretely: commit order and B7 as its own commit (3) follow F1/F9, superseding the §6 order and the B7 bullet's "commit (1)"; the drift allowlist covers only NativeLayerListOverride, MetalLayerEffects, UIStandIns, CameraRawSlider, MetalBrushCoverage (F3); Gate 2 also lists `gen-content-view.py` and `gen-layer-mask-menu.py`; B1/B3 are delivered as patches applied by those generators instead of hand edits.
<!-- /autoplan-accepted:ceo -->

<!-- autoplan-accepted:design -->
- Supersedes CEO bullets on busy feedback (status-bar contract, "status bar shows busyReason", busy-case smoke assertion, Section 4 "next action refused"): `busyReason` is command error + log only, never shown in the Qt UI; `paintRefusal` keeps the Mac alert, mirrored nowhere else. combo-smoke asserts the alert for case 11 and asserts NO visible change for busy cases.
- Every tool change path in the Qt shell and bridge (rail, tool keys, `*Begin` auto-switch, command palette) goes through `selectTool`; the matrix asserts no pending state from another tool survives into a paint command.
- The bridge awaits an in-flight `commitGradient` before handling the next paint or tool command; the async-order test asserts the next action completes after the commit (not refused).
- Show Transform Controls visuals follow tip `TransformInspector.swift` / `TransformOverlay.swift`; Qt Apply/Cancel enabled only when `transformPending`; switching to Gradient commits the transform. Screenshot pair (idle vs ⌘T armed) in F11.
- `gen-keyboard-shortcuts.py` patch preserves the Linux key-name display (`KeyboardShortcuts.swift:60` mapping ⌘→Ctrl, ⌥→Alt, ⌃→Meta) and updates the help text that still says "Meta+Ctrl+F toggles full screen" to tip 1.4.8 (F = Toggle Fullscreen, Meta+Ctrl+F = Last Filter). The Meta+Ctrl+F desktop-shortcut conflict is recorded as Category C in `upstream-parity.json` deviations; no rebinding.
- Tool keys (incl. F) are inert while a text field or live `textDraft` has focus; combo-smoke: press F while editing text → the text receives "f", Canvas Only stays off.
- Case 3 asserts Edit › Undo's title equals upstream's history name for the gradient; no Linux notice.
- Rail never shows a refused tool: combo-smoke checks rail state after the click's event-loop turn.
- Last Filter: smoke asserts menu label "Last Filter: <name>" after a filter, "Last Filter" and disabled before any (tip `CompositorApp.swift:304`).
- Case 2 also covers an empty/whitespace text draft, asserting upstream `finishText()`'s outcome.
- Footer disabled look uses the compat `.disabled` opacity; no tooltip or extra debounce.
- Rename field follows tip NativeLayerList treatment (layer background, unchanged row height).
- F11 screenshots add: Show Controls pair, one paintRefusal alert, Settings › Shortcuts rows, Last Filter menu label.
- Case 9 asserts upstream's selection state after crop cancel and after crop apply.
<!-- /autoplan-accepted:design -->

<!-- autoplan-accepted:dx -->
- `scripts/upstream-catchup.sh`: after a merge, runs every gate non-fatally and prints one table (protected trees, each generator OK/STALE + regenerate command, drift lines with port-or-allowlist remedy, ledger rows N/54 + TODO evidence count, smokes to run) with wall time per stage; first actionable report ≤ 5 min excluding the Flatpak build.
- `check-upstream-clean.sh` runs all sub-checks, prints a per-check table, exits nonzero at the end; success line "ALL UPSTREAM GATES PASS"; local-only `--skip <check>` (refused when `CI` is set, prints a reminder).
- Ledger and drift scripts default to `ledger_base..upstream_ref` from JSON, accept `--from/--to`, print the range used.
- Ledger `--check` is structural (rows match git, consumption kind present); `--strict` additionally requires no TODO evidence and verifies structured evidence (`test:<Suite>/<name>` exists in Tests/, `smoke:<flag>#<step>` exists in host); `--strict` runs when advancing `ledger_base` and in the final pre-commit gate, not in every CI run.
- Generators share `--check`/`--write` (default)/`--diff` and are listed in `scripts/generators.txt`, which the gate iterates; `gen-lucide-icons.py` gains `--check`.
- Drift script reuses `upstream-audit.py`'s walker; allowlist entries store the normalized line, a `reason`, and the upstream commit; stale entries are reported; failures print override path, upstream file:line@commit, the missing line, and either the patch/generator command or a copy-paste JSON allowlist snippet.
- `linux/upstream-parity.schema.json` validates `upstream-parity.json` (incl. `drift`, `deviations`, `ledger_base`) inside the gate; unknown keys fail.
- `scripts/run-smokes.sh [--only a,b]` builds/locates the release `CompositorHostBootstrap` and prints a pass/fail table for all smokes.
- Ledger doc top: runbook (step 1: per-file approval of modified tests), summary block, consumption-kind legend, count rule, and a "Linux deviations" section rendered from `deviations`, all written by the generator.
- `refusal(s, cause:)` takes a non-optional cause; the `canEditLayers` parser error names file, found range, expected shape and the bridge table to update; settle-timeout prints every false `canEditLayers` term; Mac citations use symbols with line hints.
- `COMBO_PAIR=from>to` filters the matrix; the `swift test --filter` command is documented in the test file header.
- `COMPOSITOR_LOG_REFUSALS=1` prints every refusal (busy, site, paintRefusal) to stderr.
- The bridge's wait on an in-flight `commitGradient` is bounded at 2 s; on expiry the command returns its busyReason (logged) instead of blocking input.
- Deviations + TODOS record that re-recorded shortcuts do not change Qt accelerators until table-driven accelerators land.
- Eng phase writes one normative "Final contract" section collapsing all superseded bullets (commit order, refusal UI contract, allowlist set, gate list).
<!-- /autoplan-accepted:dx -->

<!-- autoplan-accepted:eng -->
- The FINAL CONTRACT section in Review record (Phase 3) is normative and supersedes earlier implementation-plan text and earlier accepted bullets where they differ (commit order 0–7, refusal UI, error detection, gradient ordering, tool switching, drift/ledger range and modes, gate list, count).
- Bridge never clears `brushError`; a command's own error is detected by comparing `brushError` (or a session revision) before/after the call.
- Bridge calls `await s.commitGradient()` before handling any tool, layer or paint command while `s.gradientEdit != nil`; a 2 s backstop logs and returns the command error; tests cover fast commit, slow commit, and `isProjectBusy` early return.
- `selectTool` command fails only when `requested != before && s.tool != requested`; same-tool requests succeed. `SessionWindow.cpp:1854` blur-mode send routes through `requestTool`.
- Busy states: never status-bar text; each keeps visible Mac-equivalent chrome; combo-smoke asserts the chrome for transform pending, crop pending, gradient pending and open dialog.
- `upstream-parity.json` overrides gain `mode: tip|pinned|replaced` and `upstream: [paths]`; drift covers every non-generated hand override per its mode; compares per hunk with context and flags upstream-deleted lines still present.
- `ledger_to: "22c7b8d"` added; ledger/drift range is `ledger_base..ledger_to`.
- `canEditLayers` parser skips `_ =` lines, strips `return`, normalizes `!x` / `x == nil` / `x != nil`; locates tip source via `#filePath`.
- Ledger rows escape `|` and backticks; scripts read git with `-z` and argument lists.
- Generators apply patches with `git apply --check` first and fail closed; ContentView generator failure prints the `bodyCore` re-split recipe.
- `scripts/build-brush-shader.py --check` is listed in `scripts/generators.txt` and run by the gate.
- ToolCombinationTests adds: handle drag released → Gradient/Brush/New Layer/Undo; typed transform field → leave field → Brush; asserts non-persistent transform commits on field finish and mouse release.
- Fail-first proof uses `git worktree add <tmp> HEAD` plus only the new test file.
- Parity JSON validated by a hand-written checker (no `jsonschema` dependency).
- Matrix warms fonts once outside the timed region; 182 ordered pairs.
- EffectsRecolorParityTests reports "skipped: no Vulkan device" explicitly; never a silent pass.
<!-- /autoplan-accepted:eng -->
## Review record

### Phase 1 — CEO review (SELECTIVE EXPANSION, autoplan override)

**System audit.** No stashes. 20 dirty tracked files + `done.txt` from the previous session (effects recolor,
Show-Controls un-arm, four modified test files). Hot files last 30 days: `host/SessionWindow.cpp` (89 commits),
`UpstreamEditor.swift` (47). The 2026-09-28 plan (`docs/upstream-catchup-and-tool-combos-2026-09-28.md`) shipped
B1–B3 (`requestTool`/`applyToolLocally`, mirror-only `syncToolFromSession`) but **not** B4 (bridge error text) or
B6 (transition journey). Recurring problem: the same "tool combinations" complaint returned 11 days later because
the class was fixed by inspection, never by a test. That is an architectural signal, not bad luck.

Taste calibration: good references are `scripts/gen-color-range.py` (generated override with `--check`) and
`Tests/LinuxOverrideTests/UpstreamEditorTests.swift` (drives the bridge JSON surface). Pattern to avoid: hand-kept
"verbatim" overrides with no drift check (`KeyboardShortcuts.swift` claims "verbatim tip logic" and is 4 rows stale).

Landscape check: skipped web search (internal port parity, no market question). Layer 1: commercial editors
(Photoshop, Affinity) treat tool switching as "commit or refuse with a message", never a silent no-op. Layer 3:
here the Mac app already defines the contract; the only Linux job is to not lose it in the bridge.

**0A Premise.** The user believes 37 upstream commits are not yet caught up. Measured: 0 unmerged; 37 of the 54
merged commits change Swift product code, and the existing ledger marks all Done on theme-level evidence.
Real problem: Linux 1.4.8 claims parity it does not have (4 stale hand overrides, uncommitted effects port) and
tool combinations fail silently because Show Controls arms a Free Transform that sets `canEditLayers = false`.
Do-nothing cost: three smokes stay red, gradient/brush/new-layer after a Move silently refuse, Last Filter
re-opens its panel, Settings › Shortcuts lists stale keys. The plan addresses the pain directly.

**0B Leverage.** Every sub-problem maps to existing code: ledger (rewrite existing doc), drift (extend
`check-upstream-clean.sh`), overrides (copy tip lines), un-arm (WIP diff already written), combos (bridge command
surface + `UpstreamEditorTests` patterns + `DialogJourney.cpp` harness). Nothing is rebuilt.

**0C Dream state.**
```
  CURRENT                         THIS PLAN                          12-MONTH IDEAL
  merge done, ledger by theme,    per-commit ledger with evidence,   upstream merge -> generators
  4 stale overrides, WIP not      overrides re-synced + drift        regenerate every override,
  committed, combos untested,     warning, un-arm landed, combo      drift + combo matrix gate every
  3 smokes red                    matrix in swift test + smoke       catch-up automatically; zero
                                                                     hand-kept "verbatim" copies
```

**0D Approach.** A) this plan; B) smallest: land WIP + re-sync overrides, no combo tests; C) larger: make the Qt
rail a pure session view and generate every override. Auto-decided A (P1 completeness: B repeats the
2026-09-28 failure of fixing combos without a test; C is a multi-week rewrite outside blast radius).

**0E Mode.** SELECTIVE EXPANSION (autoplan override). Planned changed files ≈ 26 (20 WIP + ~6 new/edited),
mostly already-written WIP.

**0F/0G Cherry-picks** (HOLD checks first: >8 files is driven by WIP that already exists; minimum change set is
Parts B–E; nothing deferrable without breaking the user's two asks).

| # | Proposal | Effort | Decision | Principle |
|---|---|---|---|---|
| E1 | Drift check knows expected-missing AppKit/Metal lines (allowlist in `upstream-parity.json`) so it can **fail** on new drift instead of only warning | S | ACCEPTED | P2 in blast radius, 2 files |
| E2 | Generate `KeyboardShortcuts.swift` override from tip with a `gen-*.py --check` script (patch is only the ShortcutRecorder swap), like `gen-color-range.py` | M | ACCEPTED (TASTE) | P1/P2; borderline 3 files |
| E3 | D1 covers every ordered pair of tool families (not 11 hand cases) as a table-driven test, plus the 11 named cases | M | ACCEPTED | P1; one test file |
| E4 | Ledger rows 1–37 generated by a script from `git log` + parity json; humans fill only evidence | S | ACCEPTED | P2/P5 |
| E5 | Photoshop-style "Rasterize text layer?" prompt on gradient/brush over text | M | SKIPPED | Exceeds Mac behavior; Linux mirrors Mac (active decision 2026-09-28) |
| E6 | Status-bar shows the refusal reason for every refused tool action, not only gradient | S | ACCEPTED (merged into D3) | P4 dedupe with D3 |
| E7 | CI job running combo matrix on every push | M | DEFERRED | No CI on this branch; outside blast radius |

<!-- autoplan-accepted:ceo -->
- Ledger: every one of the 54 commits in `11d8d7a..22c7b8d` has a row; the code commits (count rule below) are numbered first; each row names files, consumption kind, Linux artifact, evidence (test or smoke step). Rows are generated by a Linux-owned script from git + `linux/upstream-parity.json`; evidence is filled by hand. Verify: script output has 54 rows and the numbered count equals the generator's printed code-commit count.
- Drift check: `scripts/upstream-override-drift.py` lists upstream added code lines missing from each hand override; `linux/upstream-parity.json` carries an allowlist of expected-missing lines (AppKit/Metal) per override; `check-upstream-clean.sh` fails on any non-allowlisted missing line. Verify: a manual pre-commit run fails on today's tree before B1–B3 and passes after; the script lands in commit (5), after (3).
- `Sources/Overrides/KeyboardShortcuts.swift` is generated from tip by `scripts/gen-keyboard-shortcuts.py` with a `--check` mode; the only deviation is the ShortcutRecorder swap. Verify: `--check` clean; Settings › Shortcuts lists Search Commands ⌘F, Last Filter ⌃⌘F, Export As, Toggle Fullscreen F.
- `ToolCombinationTests` is table-driven over every ordered pair of tool families, asserting after each switch: settled session tool == requested or a refusal message; no pending gradient/shape/lasso/crop/transform draft survives a switch except as upstream `selectTool` keeps it; `canEditLayers` true once settled. Plus the 11 named cases in Part D. Verify: see fail-first proof below.
- Every refused tool action surfaces its reason (`paintRefusal`, else `brushError`, else a named busy state such as "Free Transform is pending: press Return or Esc") in the command error and the Qt status bar; no command returns the bare "could not start". Verify: D1 case 11 + combo-smoke status-bar assertion.
- Baseline replacement (E1): Part A's drift script is no longer advisory-only; non-allowlisted missing lines fail `check-upstream-clean.sh`.
- Baseline replacements (spec review 1): B2 generator + smoke key assertion (Qt rewire deferred); D1 case 3 expects rasterize-on-paint; case 5 expects `pixelMove == nil` after release; D2/D3 use one refusal order `paintRefusal ?? brushError ?? busyReason`; Gate 2 lists generators explicitly; Gate 4 transform-smoke exception; commit (5) ordering + TODOS entry.
- 37-count rule: a commit counts as "code" when it changes at least one `Compositor/**/*.swift` file outside `CompositorTests/`, excluding commits whose only product change is a version/feed bump. The ledger generator applies this rule and prints its count; the ledger states the rule and the printed number (the rule yields 38; the ledger says 38 and explains the request's 37).
- Ledger generator: `scripts/upstream-ledger-rows.py <from> <to>` prints Markdown rows `| # | upstream | subject | files (consumption kind) | Linux artifact | evidence |` into the "Commit ledger" table of `docs/upstream-1.4.6-1.4.8-ledger.md`; artifact/evidence cells start as `TODO` and the script's `--check` fails while any `TODO` remains.
- Drift allowlist schema in `linux/upstream-parity.json`: new key `"drift": {"<override path>": {"upstream": "<Compositor/... path>", "allow_missing": ["<exact trimmed line>", ...]}}`. Covered: hand overrides ContentView, LayerMaskMenu, NativeLayerListOverride, MetalLayerEffects, UIStandIns-backed files. Not covered: generated overrides (their `--check` is the gate) and Qt adapters with no Swift override.
- Tool families for the ordered-pair matrix: marquee, lasso, magic wand, move, brush, eraser, clone/heal, smudge/blur, gradient, shape, type, crop, eyedropper, hand/zoom. Transition table from `EditorSession.selectTool` (`EditorSession.swift:387`): live text draft -> `finishText()` commits or refuses the switch; transformEdit -> committed; cropRect -> cancelled; gradientEdit -> committed (async `commitGradient`); lassoDraft -> cancelled; shapeDraft -> cancelled; selection -> kept; crop entry seeds `cropRect` from the selection bounds. The test asserts exactly this table.
- Part C vs test immutability: before commit (2), show the user the `TransformInspectorProbeTests.swift` diff. If declined, keep the original probe test by resolving `TransformInspector(session:)` against tip `Compositor/UI/TransformInspector.swift` (compiled as-is once the override is deleted); if that does not compile, Part C waits for the user's decision.
- B1 Last Filter: a `--dialog-smoke` step applies a filter, then Ctrl+Meta+F, and asserts the layer changed again with no filter dialog visible.
- Baseline replacements (spec review 2): `canEditLayers` cited at `EditorSession.swift:686`; case 11 drops "Locked" (no upstream lock) and lists the real `paintRefusal` clauses; failure-table example corrected (text layers rasterize, case 3).
- `busyReason` covers every `canEditLayers` term (`EditorSession.swift:688` body): selectionAmountOperation, colorRange, textDraft, document == nil, brushStroke, warpStroke, isProjectBusy, isImporting, showsNewDocument, showsImporter, renamingLayerID, transformEdit, cropRect, gradientEdit, pixelMove, hueSaturation, levels, filterEdit, adjustmentEditingID. Each has one fixed string in a single table in the bridge; a unit test iterates the table so a new upstream term without a string fails.
- Refused tool switch: the bridge `selectTool` command compares `s.tool` after the call; if unchanged it fails with `refusal(s)` (text commit failure surfaces `brushError` from `finishText()`; the guard surfaces `busyReason` for isProjectBusy / brushStroke / warpStroke / levels). Transition table adds: `levels`, `brushStroke`, `warpStroke`, `isProjectBusy` -> switch refused; `pixelMove` -> untouched by `selectTool` (cleared by `finishPixelMove` on release).
- Matrix fixture and settle: each pair starts from a 64x64 document, one raster layer, a 16x16 rectangle selection, and the "from" tool's typical pending draft (type: live textDraft; gradient: gradientEdit with a line; crop: cropRect; shape: shapeDraft; lasso: lassoDraft; move: none after release; others: none). Settled means `await` of the command plus a bounded poll (max 2 s, 10 ms steps) until `gradientEdit == nil` when a commit was owed. Per pair, state-only asserts; pixel asserts only in the 11 named cases.
- Status-bar contract (D2): the Qt status bar shows exactly the bridge error string, for at least 4 s, and the combo smoke reads it within 1 s of the refused action.
- `--transform-smoke` decision format: if it fails after Part C, show the user the failing `require` line, the old vs new behavior, and ask Keep-old-smoke (revert Part C) or Approve-smoke-change; no edit to the smoke without that answer.
- B7 (working tree, previously unlisted): `backends/brush/BrushCoverageValidation.h` raises the coverage radius cap from 1000 to 1050 so Smudge/Liquify commits above the 2000 px UI limit validate; evidence `BrushCoverageBackendTests.internalWarpCommitRadiiFitTheCoverageBackend` (new test in a modified file). Lands in commit (1) with the effects port.
- WIP mapping: `linux/graphics/SkiaBridge.cpp` (inside/recolor filter) -> B6; `host/SwiftUIQtRenderer.cpp` (mask effect with opacity) -> B3/B4 footer dimming; `host/DialogJourney.cpp`, `host/SessionWindow.cpp`, `Sources/LinuxBridge/SwiftUIBridge.swift`, `UpstreamEditor.swift`, `Package.swift`, `gen-compositorapp-override.sh`, `UpstreamEditorTests.swift`, `TransformInspectorProbeTests.swift` -> Part C; `LayerEffectsBackendTests.swift` -> B6.
- Declined test edits: each modified test file is approved separately. If declined, that file is reverted to HEAD and its Part ships only if HEAD's tests pass with the code change; otherwise the Part waits. B6 without its Linux test edit still requires upstream `ColorOverlayTests` passing plus a CPU/Vulkan/OpenCV agreement check in the new `ToolCombinationTests`-adjacent file `Tests/LinuxOverrideTests/EffectsRecolorParityTests.swift` (a new file, not an edit).
- Gate 2 also runs `scripts/upstream-override-drift.py --check` and `scripts/upstream-ledger-rows.py --check`, both from `check-upstream-clean.sh`.
- Deviation log: `busyReason` strings are a deliberate Linux-only behavior (upstream waits silently while busy); recorded in `linux/upstream-parity.json` under `deviations`.
- E7 deferral reason corrected: `.github/workflows/ci-guard.yml` exists and runs `check-upstream-clean.sh`, but no workflow runs `swift test` on Linux; the TODO is "add a Linux swift-test job running ToolCombinationTests".
- Baseline replacement (spec review 3): §1 count is 38 under the rule (54 = 9 non-Swift + 7 test-only + 38), with the 37 explained.
- Refusal scope: every `fail(-5, "... could not start ...")` site in `UpstreamEditor.swift` routes through `refusal(s)`, including tools (587, 603, 625, 630, 715, 984) and dialog/filter actions (753, 758, 761, 772, 884, 1045). Final fallback when `refusal(s)` is nil: `"<action> could not start: <specific cause>"`, where the cause is the concrete reason known at that site (e.g. clone source out of range). A fallback without a cause counts as bare and fails the test.
- Stale error: each tool command clears `s.brushError` before calling the session; `refusal(s)` reads only an error set during this command.
- UI contract: `paintRefusal` keeps the Mac behavior (modal "Couldn't paint" alert, as upstream sets `brushError`) and is mirrored in the status bar; `busyReason` and site fallbacks are status-bar only (no alert). The combo smoke asserts the alert for case 11 and the status bar for busy cases.
- `busyReason` completeness test: parses the `canEditLayers` body from tip `Compositor/Document/EditorSession.swift` (between `var canEditLayers: Bool {` and its closing brace), extracts the `&&` terms, and fails if any term lacks a key in the bridge table.
- Drift range: `linux/upstream-parity.json` gains `"ledger_base": "11d8d7a"`; the drift and ledger checks use `ledger_base..upstream_ref`. Each catch-up advances `ledger_base` when its ledger is complete.
- Drift allowlist covers exactly these hand overrides: `Sources/Overrides/ContentView.swift`, `LayerMaskMenu.swift`, `NativeLayerListOverride.swift`, `MetalLayerEffects.swift`, `UIStandIns.swift`, `CameraRawSlider.swift`, `MetalBrushCoverage.swift` (the `upstream-parity.json` override rows whose value names a non-generated `Sources/Overrides/*.swift`). The implementer derives the final list from that rule and prints it.
- Ledger `--check`: regenerates the subject, files and consumption-kind columns from git and compares them; ignores the hand-edited artifact/evidence cells except that they must not be `TODO`.
- Fail-first proof: case 6 (Show Controls) uses only the existing command surface (`setShowsTransformControls`, `gradientBegin`, `addLayer`, `undo`, `setBlendMode`) in its own `@Test`. Proof = it fails when run with Part C's diff reverted (`git stash` of Part C files) and passes with it. The refusal-text assertions are verified after D3 only.
- CEO voice integration (F1, F2, F9): commit order is (1) Part C + ToolCombinationTests named cases 1, 2, 3, 5, 6 + D3 refusal routing, (2) B6 effects recolor, (3) B7 brush radius cap, (4) B1–B5 override work + new generators, (5) D2 combo-smoke + key-parity smoke, (6) ledger generator + ledger + drift + TODOS entry. Fail-first proof for cases 1, 2, 3, 5, 6: run them with Part C and D3 stashed, record which fail; if 1/2/3/5 pass on HEAD, report that the user's combo bug has another cause and investigate before claiming a fix. No test is weakened or marked as a known issue to land red.
- F3: `Sources/Overrides/ContentView.swift` and `LayerMaskMenu.swift` become generated from tip by `scripts/gen-content-view.py` and `scripts/gen-layer-mask-menu.py` (copy tip + `linux/patches/*.patch`, with `--check`), run by `check-upstream-clean.sh`; the drift allowlist then covers only NativeLayerListOverride, MetalLayerEffects, UIStandIns, CameraRawSlider, MetalBrushCoverage. The drift compare normalizes whitespace and tokens and prints a suggested allowlist diff.
- F5: each named case's doc comment cites the Mac source line that fixes its call order (e.g. `EditorCanvas.swift:1833` for gradient, `EditorSession.swift:387` for tool switch).
- F6: the `busyReason` parser fails with "canEditLayers parser out of date" when it finds zero terms or a non-`&&` shape.
- F7: the matrix reports total runtime and fails above 60 s; a settle timeout message names the pair and the still-pending field.
- F8: the key-parity smoke covers every row of the generated shortcut table; TODOS.md records the rail rewrite with trigger "first combo-smoke rail/session mismatch".
- F10: the ledger generator writes `n/a (docs)` / `n/a (test-only, compiled as-is)` evidence for non-code commits; hand evidence is required only for the 38 code commits.
- F11: before/after screenshots of cases 1, 2, 3 in a real Qt window via `COMPOSITOR_GRAB_PATH`, saved under `docs/references/combos-2026-10/` and linked from the ledger.
- Async order (Section 4): a test pauses the gradient commit after a switch, asserts the next paint action is refused with the busy reason, releases, and asserts it then succeeds.
- Precedence: where accepted bullets conflict, the later bullet wins. Concretely: commit order and B7 as its own commit (3) follow F1/F9, superseding the §6 order and the B7 bullet's "commit (1)"; the drift allowlist covers only NativeLayerListOverride, MetalLayerEffects, UIStandIns, CameraRawSlider, MetalBrushCoverage (F3); Gate 2 also lists `gen-content-view.py` and `gen-layer-mask-menu.py`; B1/B3 are delivered as patches applied by those generators instead of hand edits.
<!-- /autoplan-accepted:ceo -->

<!-- autoplan-baseline-edits:ceo {"sourceSha256":"eafdfbb03e2cc994cbcaa81fb842ee9b608f295c7effce104b911818de450984","replacements":[{"oldText":"Output is advisory (AppKit/Metal lines are expected\nto be missing); the ledger cites it. Run it in `check-upstream-clean.sh` as a warning, never a failure.","newText":"Lines that are expected to be missing (AppKit/Metal) are listed per override in an allowlist in\n`linux/upstream-parity.json`; any other missing line fails `check-upstream-clean.sh`. The ledger cites its output."},{"oldText":"- **B2** `Sources/Overrides/KeyboardShortcuts.swift`: re-sync the entries table verbatim from tip (the override's\n  stated contract is \"verbatim tip logic\"). Then confirm the Qt menu accelerators come from this table (not a second\n  hard-coded list in `host/SessionWindow.cpp`); if both exist, the Qt list reads the table.","newText":"- **B2** `Sources/Overrides/KeyboardShortcuts.swift`: add `scripts/gen-keyboard-shortcuts.py` (with `--check`) that\n  regenerates the override from tip; the only deviation is the ShortcutRecorder swap. Point the file header and its\n  `upstream-parity.json` row at the generator. Qt accelerators stay hard-coded in `host/SessionWindow.cpp`; a\n  `--dialog-smoke` step asserts the Qt actions for Search Commands (Ctrl+F), Last Filter (Ctrl+Meta+F), Export As\n  and Toggle Fullscreen (F) carry the same keys as the generated table. Table-driven Qt accelerators are deferred."},{"oldText":"  3. Text layer selected, marquee selection, Gradient: matches upstream's result for a text layer (rasterize or\n     refusal message, whatever `canPaint`/`paintRefusal` say). Never a silent no-op.","newText":"  3. Text layer selected, marquee selection, Gradient: upstream rasterizes on pixel edits (`TypeTool.swift:204`,\n     \"Pixel edits rasterize the layer\"; `canPaint` has no text clause). Expected: after Apply the layer's `text` is nil,\n     pixels change only inside the selection, and one Undo restores the editable text layer."},{"oldText":"  5. Selection → Move (pixel move) → Gradient: the move is committed by `selectTool`, gradient then clips.","newText":"  5. Selection → Move (pixel move drag, released) → Gradient: `finishPixelMove()` has cleared `pixelMove` on release,\n     so the gradient starts and clips to the moved selection."},{"oldText":"  step and that `brushError` is surfaced in the status bar on refusal.","newText":"  step and that the refusal reason (same order as D3) is shown in the status bar on refusal."},{"oldText":"  Known candidate: `gradientBegin` / `shapeBegin` report \"could not start\" instead of the session's `brushError`\n  or `paintRefusal` when `canPaint` is false; return `s.paintRefusal ?? s.brushError`.","newText":"  Known sites: `UpstreamEditor.swift` gradientBegin (587, already `brushError ?? …`), shapeBegin (603), text\n  begin (625, 630) and brushBegin (715) return bare strings. All use one helper `refusal(s)` =\n  `s.paintRefusal ?? s.brushError ?? busyReason(s)`, where `busyReason` is Linux bridge text naming the pending\n  state (transformEdit, cropRect, gradientEdit, pixelMove, textDraft, filterEdit, levels, hueSaturation, colorRange)\n  e.g. \"Free Transform is pending: press Return to apply or Esc to cancel\". These strings are Linux-only (upstream\n  waits silently while busy) and are listed in the helper's doc comment."},{"oldText":"2. Generators: every `scripts/gen-*.py --check` and `gen-compositorapp-override.sh --check` clean.","newText":"2. Generators, each `--check` clean and each run by `check-upstream-clean.sh`: `gen-color-range.py`,\n   `gen-text-format-11.py`, `gen-smudge-liquify-override.py`, `gen-preview-renderer.py`, `gen-project-validation.py`,\n   `gen-compositorapp-override.sh`, new `gen-keyboard-shortcuts.py`. (`gen-lucide-icons.py` has no check mode.)"},{"oldText":"   `--dialog-smoke`, `--layers-smoke`, `--brush-smoke`, new `--combo-smoke` — **all** pass (three fail today).","newText":"   `--dialog-smoke`, `--layers-smoke`, `--brush-smoke`, new `--combo-smoke` all pass (three fail today).\n   `--transform-smoke` is the one exception: if it encodes the old armed behavior, the user decides (failure table)."},{"oldText":"Commits, in order (bisectable): (1) effects recolor port, (2) Show Controls un-arm, (3) override re-syncs B1–B5,\n(4) tool-combination tests + fixes, (5) ledger + drift script. No push to `origin`.","newText":"Commits, in order (bisectable): (1) effects recolor port, (2) Show Controls un-arm, (3) override re-syncs B1–B5,\n(4) tool-combination tests + fixes, (5) ledger generator + ledger + drift script/allowlist + TODOS.md entry for\nthe deferred CI job. Ordering dependency: the drift gate in (5) passes only because (3) landed first; never move\n(5) before (3). No push to `origin`."},{"oldText":"(`EditorSession.swift:688` includes `transformEdit == nil`)","newText":"(`EditorSession.swift:686`, `canEditLayers`, includes `transformEdit == nil`)"},{"oldText":"  11. Locked/hidden/adjustment/group target → Gradient: the `paintRefusal` text reaches the command's error.","newText":"  11. Hidden / adjustment / group / multi-selected / disabled-mask target → Gradient: the `paintRefusal` text\n      (`EditorSession+Brush.swift:14`) reaches the command's error. (Upstream has no layer lock.)"},{"oldText":"| D1 case reveals upstream itself refuses (e.g. text layer + gradient) | case 3 | That is the Mac behavior; Linux must show the same message. Not a bug to \"fix\". |","newText":"| D1 case reveals upstream itself refuses (e.g. gradient on a folder or hidden layer) | case 11 | That is the Mac behavior; Linux must show the same message. Not a bug to \"fix\". |"},{"oldText":"The 37 code commits are listed first and numbered 1–37 so the request's count maps one-to-one.","newText":"The code commits (count rule in the accepted requirements) are listed first and numbered, so the request's \"37\" maps\nonto a reproducible number; any difference from 37 is explained in the ledger."},{"oldText":"- The merge brought **54 non-merge commits**. 9 touch no Swift (README, version bumps, appcast). 8 touch only tests.\n  That leaves **37 commits that change Swift product code**. That is the \"37\" in the request.","newText":"- The merge brought **54 non-merge commits**. 9 touch no Swift (README, version bumps, appcast). 7 touch only tests.\n  That leaves **38 commits that change Swift product code** under the count rule below; the request's \"37\" is one\n  off, most likely from counting the Navigator dock commit `6490bb3` (superseded by the minimap `3e09948`) as docs.\n  The ledger states the rule and the 38, and explains the difference."}]} -->

**0H.** CEO plan: `~/.gstack/projects/chiddekel-Compositor/ceo-plans/2026-10-09-upstream-148-closeout-tool-combos.md`.
Spec review loop: 3 launches (6/10, 6/10, 7/10), 39 issues found, 29 confirmed fixed by later launches, 10 applied
after the last launch and not re-reviewed. Metrics appended to `analytics/spec-review.jsonl`. Document approval:
auto-decided A (P6, autoplan).

**0I Temporal interrogation** (human / CC+gstack):
- Hour 1: Swift only builds inside the Flatpak SDK (`flatpak-builder --run … swift test`); host smokes need the release
  `CompositorHostBootstrap` and a fresh `libCompositorQtImageIO.so`. Budget the first build. (human ~1h / CC ~10 min wall)
- Hours 2–3: the ContentView `.onChange` chain can hit the type-checker timeout; `resolveGradient` is async so matrix
  pairs need the bounded settle; the 196-pair matrix must stay state-only to keep `swift test` fast.
- Hours 4–5: the four modified test files need user approval before commits (1)/(2); the `--transform-smoke`
  decision may block Part C.
- Hour 6+: the ledger evidence column is hand work for 54 rows (~2h human / ~20 min CC).
Feasibility blockers: none beyond the user approvals above. Total ≈ human 3–4 days / CC ~3–4 h.


#### CEO dual voices

- Claude CEO subagent: completed on snapshot `bb1a3b0f…6718` (full 217-line read). 12 findings (4 high, 8 medium).
- Codex CEO voice: **unavailable**. `MODEL_QUOTA_EXHAUSTED`, "You've hit your usage limit … try again at Oct 14th, 2026 1:55 PM". No outside coverage this phase. Tag: `[subagent-only]`.

```
CEO DUAL VOICES — CONSENSUS TABLE:  [subagent-only]
  Dimension                             Claude              Codex   Consensus
  1. Premises valid?                    yes (37->38 fixed)  N/A     N/A
  2. Right problem to solve?            yes, re-weight to   N/A     N/A
                                        the bug (F1)
  3. Scope calibration correct?         too much process    N/A     N/A
                                        tooling (F3, F10)
  4. Alternatives sufficiently explored? no: generate-not-  N/A     N/A
                                        police (F3)
  5. Competitive/market risks covered?  partly (F12)        N/A     N/A
  6. 6-month trajectory sound?          no CI = rot (F4)    N/A     N/A
Outside unavailable: every Consensus cell N/A, never CONFIRMED.
```

Native finding dispositions (auto-decided; single-voice criticals flagged):

| F | Finding | Sev | Decision | Class | Principle |
|---|---|---|---|---|---|
| F1 | Order by user pain: fail-first repro of text+selection+gradient first; ledger tooling last and the first thing cut | high | ACCEPT | mechanical | P1/P6 |
| F2 | Fail-first evidence for cases 1, 2, 3, 5 on HEAD, not only case 6; if they pass on HEAD, the cause is elsewhere | high | ACCEPT | mechanical | P1 |
| F3 | Generate, don't police: ContentView and LayerMaskMenu become patch-generated overrides like KeyboardShortcuts; drift compares whitespace-normalized tokens and prints a suggested allowlist diff | high | ACCEPT (TASTE) | taste: 2 more generators, borderline scope | P1 vs P5 |
| F4 | Run Linux `swift test` (filtered: ToolCombination, EffectsRecolorParity, UpstreamEditor) in CI in this plan | high | KEEP DEFERRED, add trigger (TASTE) | taste: new infra (Flatpak SDK in CI) outside blast radius | P3 vs P1 |
| F5 | Cite the Mac EditorCanvas line that fixes each named case's call order | med | ACCEPT | mechanical | P1 |
| F6 | `busyReason` parser fails with "parser out of date" on zero terms or an unknown shape | med | ACCEPT | mechanical | P5 |
| F7 | Matrix: total runtime cap (60 s) reported; a timeout names the pair and the stuck field | med | ACCEPT | mechanical | P1 |
| F8 | Explicit trigger for the rail rewrite; key-parity smoke covers every generated shortcut row, not 4 | med | ACCEPT | mechanical | P2 |
| F9 | Split B7 into its own commit | med | ACCEPT | mechanical | P5 |
| F10 | Evidence only for the 38 code commits; generator writes `n/a (docs)` / `n/a (test-only)` for the other 16 | med | ACCEPT | mechanical | P3 |
| F11 | Real-window before/after screenshots of the named combos via `COMPOSITOR_GRAB_PATH`, linked from the ledger | med | ACCEPT | mechanical | P1 |
| F12 | Time budget per catch-up; tooling must lower the next catch-up's cost | med | ACCEPT (note) | mechanical | P6 |

F5 evidence: the Mac drives Gradient only after the tool is already selected (`Compositor/Rendering/EditorCanvas.swift:1833`,
`else if session.tool == .gradient { beginGradientDrag(at:) }`), and the rail goes through `selectTool`, so a text
draft is finished by `selectTool`'s `finishText()` before any gradient call. The bridge's `gradientBegin` calling
`selectTool(.gradient)` first reproduces that order.

#### Section 1 — Architecture

Current scope: mode SELECTIVE EXPANSION. Accepted: Parts A–E, E1–E4, E6 (merged into D3), F1–F3, F5–F12. Deferred: E7/F4 (CI), table-driven Qt accelerators, the rail rewrite. Skipped: E5.

```
 upstream/main (Mac, read-only)            Linux compat layer (this plan)
 ┌─────────────────────────┐   compiled    ┌───────────────────────────────┐
 │ Compositor/Document/*    │──as-is──────▶│ CompositorCore (Swift)         │
 │  EditorSession.selectTool│               │                               │
 │  canPaint / paintRefusal │               │  Sources/Overrides/*  ◀─gen── scripts/gen-*.py (+ NEW:
 │ Compositor/UI/*          │──patch/gen──▶│   ContentView, LayerMaskMenu,  │   keyboard, contentview,
 └─────────────────────────┘               │   KeyboardShortcuts            │   layermaskmenu)
                                            │  Sources/LinuxBridge/          │
                                            │   UpstreamEditor (JSON cmds)   │◀── NEW refusal(s)/busyReason
                                            └──────────────┬────────────────┘
                                                C ABI      │ compositor_session_command
                                            ┌──────────────▼────────────────┐
                                            │ host/SessionWindow (Qt)        │── status bar / alert
                                            │  requestTool / applyToolLocally│
                                            └──────────────┬────────────────┘
 backends/effects (CPU/OpenCV/Vulkan) ◀─ B6 recolor     backends/brush ◀─ B7 radius cap
 gates: check-upstream-clean.sh ─▶ drift.py (NEW) + ledger-rows.py (NEW) + gen --check
 tests: ToolCombinationTests (NEW) · EffectsRecolorParityTests (NEW) · --combo-smoke (NEW)
```

Data flow, refused gradient (new path):
```
 Qt drag ─▶ gradientBegin ─▶ clear brushError ─▶ selectTool(.gradient)
   happy: tool==.gradient ─▶ beginGradient ─▶ gradientEdit!=nil ─▶ preview
   nil:   no document ─▶ busyReason["document"] ─▶ status bar
   empty: selection.isEmpty ─▶ canPaint false, paintRefusal nil ─▶ site fallback with cause "selection is empty"
   error: finishText fails ─▶ tool unchanged ─▶ brushError ─▶ alert (Mac) + status bar
```
Findings: coupling is unchanged (bridge→session only); new state is none (refusal is computed). Rollback: each commit
is independent; revert the commit (minutes). Security: no new external surface. **No new issues** beyond F1–F12.

#### Section 2 — Error & Rescue Map

```
 CODEPATH                         | WHAT CAN GO WRONG                     | CLASS
 bridge gradient/shape/text/brush | canPaint false (hidden/group/adj/...) | PaintRefusal
 begin                            | editor busy (19 canEditLayers terms)   | Busy
                                  | site-specific (clone out of range)     | SiteFailure
 bridge selectTool                | finishText fails / guard busy          | SwitchRefused
 drift.py / ledger-rows.py        | upstream refactor, unparseable source  | ParserOutOfDate
 gen-*.py --check                 | upstream changed patched hunk          | PatchConflict
 effects backends                 | CPU/Vulkan/OpenCV disagree             | ParityMismatch

 CLASS            | RESCUED | ACTION                                    | USER SEES
 PaintRefusal     | Y       | alert (Mac text) + status bar             | why it can't paint
 Busy             | Y       | status bar busyReason                     | "Free Transform is pending: …"
 SiteFailure      | Y       | "<action> could not start: <cause>"       | specific cause
 SwitchRefused    | Y       | rail mirrors session tool, reason shown   | tool stays, reason
 ParserOutOfDate  | Y       | gate fails loudly "parser out of date"    | dev only
 PatchConflict    | Y       | --check fails, names hunk                 | dev only
 ParityMismatch   | Y       | test fails per backend                    | dev only
```
No GAP rows after D3 and F6.

#### Section 3 — Security
No new endpoints, inputs, secrets or dependencies. The scripts read git and repo files only. The busy strings are
static. **No issues found**: the plan adds no new attack surface beyond in-process JSON commands that already exist.

#### Section 4 — Data flow & interaction edge cases
Async ordering: `resolveGradient()` starts `Task { await commitGradient() }`, so after a switch away from Gradient the
commit lands later. Invariant: no second gradient begins on a layer before the first commit applies. Order A: commit
finishes, then the new tool acts, which is fine. Order B: the new tool starts first. `canEditLayers` is false while
`gradientEdit != nil`, so the new action refuses (busyReason "gradient is being applied"). Mechanism: the
`canEditLayers` gate. The test pauses the commit and asserts a refusal, then releases it and asserts success.

| Interaction | Edge case | Handled | How |
|---|---|---|---|
| Rail click during text edit | finishText fails | Y | switch refused + reason |
| Drag gradient twice fast | pending commit | Y | busyReason, then works after settle |
| Gradient with empty selection | canPaint false | Y | site fallback with cause |
| Ctrl+Meta+F with no previous filter | no repeating edit | Y | menu disabled (upstream) — smoke asserts |
| Show Controls toggled mid-drag | transformEdit live | Y | case "explicitTransformKeepsDraftWhenControlsToggle" (WIP test) |

#### Section 5 — Code quality
One `refusal(s)` helper with one busy table replaces scattered strings (DRY). The drift and ledger scripts reuse the
parsing in `upstream-audit.py` (it already walks Swift declarations) rather than a new parser. **WARNING**: three
new generators plus two scripts is the most code in the plan; F3 keeps each generator to "copy tip + apply patch" on the
`gen-color-range.py` pattern. No method over 5 branches is expected except `busyReason` (a table, not branches).

#### Section 6 — Tests
```
 NEW THING                          TYPE         HAPPY                 FAILURE                  EDGE
 refusal(s)/busyReason              unit         gradient on layer     each canEditLayers term  parser out of date
 selectTool refusal                 unit         switch succeeds       finishText fails         guard busy
 196-pair matrix                    unit(state)  every pair settles    stuck field named        60 s cap
 11 named cases (+fail-first 1,2,3,5,6) unit(px) clip/rasterize/undo  case 11 refusal          mask target
 effects recolor parity             unit         translucent recolor   backend mismatch         alpha 0 / 1
 B7 radius cap                      unit (WIP)   1000..1050 valid      1050.5 rejected          rim pixels
 combo-smoke                        E2E offscr.  rail == session       alert / status bar       1 s / 4 s timing
 key-parity smoke                   E2E          every generated row   mismatch named           —
 drift / ledger / gen --check       script       clean tree            injected drift           unparseable
 screenshots (F11)                  manual       before/after          —                        —
```
2am-Friday test: the text + selection + gradient case fails on HEAD and passes after. Hostile QA: switch tools
during a pending gradient commit (Section 4 order B). Flakiness: only the async gradient commit, which uses a bounded poll.

#### Section 7 — Performance
The 196-pair matrix with state-only asserts runs in about 196 × (64×64 ops) and should take seconds, capped at 60 s (F7).
Drift and ledger scripts run on git diffs in under a second. **No issues** beyond F7.

#### Section 8 — Observability
Refusals are now visible to users (status bar/alert) instead of silent. Developer-side: matrix timeouts name the pair
and field; gates print the drift and allowlist suggestion. A bug reported three weeks later can be reproduced by
replaying the JSON command sequence in `ToolCombinationTests`. **No gaps.**

#### Section 9 — Deployment
Local branch only, no push. A red test is never committed and tests are never weakened, so the fail-first
ToolCombinationTests land in the same commit as Part C + D3, and the fail-first proof is a stash run recorded in the
commit message. The full order is in the accepted requirements. Rollback: revert one commit. Risk flagged: commit (1)
is the largest; if Part C needs the user's `--transform-smoke` decision, (1) waits.

#### Section 10 — Long-term trajectory
Reversibility 5/5. Debt: the Linux-only busy strings (logged deviation); two more generators to maintain (F3, cheaper than
hand drift). Path: the next catch-up runs `ledger-rows.py` + gates and fills evidence only for code commits.
Trigger for the deferred rail rewrite (F8): the first combo-smoke rail/session mismatch.

#### Section 11 — Design & UX
UI scope is small: the status bar refusal line, the Mac alert, Settings › Shortcuts rows, the Layers footer dimming, and Last Filter
without the panel.
```
 [tool action] ─▶ allowed ─▶ preview ─▶ Apply/Esc
        └─▶ refused ─┬─ paintRefusal ─▶ Mac alert "Couldn't paint" + status bar
                     └─ busy/site ───▶ status bar (≥4 s), rail shows the real tool
```
States: LOADING n/a; EMPTY (no document) gives a busy string; ERROR gives an alert or the status bar; SUCCESS is a preview;
PARTIAL (pending commit) is a busy string. Accessibility: the status bar text is readable by screen readers through Qt
accessibility. **Recommend /plan-design-review**, which Phase 2 of this run covers.

#### CEO registries

NOT in scope: Mac trees (rule); CommandPaletteView/NavigatorTests compile (excluded, AppKit); Sparkle/appcast;
push; rail-as-pure-view (DEFERRED, trigger F8); table-driven Qt accelerators (DEFERRED); Linux swift-test CI
(DEFERRED E7/F4 → TODOS.md); E5 rasterize prompt (SKIPPED, exceeds Mac).

What already exists: merge + UPSTREAM CLEAN gate; generator `--check` pattern; requestTool/applyToolLocally;
UpstreamEditor JSON surface; DialogJourney harness; `upstream-audit.py` Swift walker; COMPOSITOR_GRAB_PATH screenshots;
existing ledger doc.

Dream state delta: after this plan, combos are tested and refusals are visible, and three of the hand overrides are
generated. Left for the 12-month ideal: CI running swift test, the rail as a pure session view, and the remaining hand overrides
(NativeLayerList, UIStandIns, Metal) behind AppKit/Metal walls.

Failure Modes Registry:
```
 CODEPATH            | FAILURE MODE                 | RESCUED | TEST | USER SEES        | LOGGED
 gradientBegin       | busy (transform armed)       | Y       | Y    | busy reason      | status bar
 selectTool          | text commit fails            | Y       | Y    | reason, rail ok  | status bar
 effects backends    | Vulkan≠CPU                   | Y       | Y    | —                | test
 gen ContentView     | type-checker timeout         | Y       | build| —                | build log
 drift gate          | false positive on refactor   | Y       | Y    | —                | allowlist diff
 matrix              | async commit stuck           | Y       | Y    | —                | pair+field
```
CRITICAL GAPS: 0.

```
  +====================================================================+
  |            MEGA PLAN REVIEW — COMPLETION SUMMARY                   |
  +====================================================================+
  | Mode selected        | SELECTIVE EXPANSION                         |
  | System Audit         | 0 unmerged; 38 code commits; 4 stale        |
  |                      | overrides; WIP uncommitted; 3 smokes red    |
  | Step 0               | approach A; 7 proposals, 5 accepted         |
  | Section 1  (Arch)    | 0 new issues (F1-F12 integrated)            |
  | Section 2  (Errors)  | 7 classes mapped, 0 GAPS                    |
  | Section 3  (Security)| 0 issues, 0 High                            |
  | Section 4  (Data/UX) | 5 edge cases mapped, 0 unhandled            |
  | Section 5  (Quality) | 1 warning (generator count)                 |
  | Section 6  (Tests)   | Diagram produced, 0 gaps                    |
  | Section 7  (Perf)    | 0 issues (F7 cap)                           |
  | Section 8  (Observ)  | 0 gaps                                      |
  | Section 9  (Deploy)  | 1 risk (red-test commit ordering)           |
  | Section 10 (Future)  | Reversibility: 5/5, debt items: 2           |
  | Section 11 (Design)  | 0 issues; design phase follows              |
  +--------------------------------------------------------------------+
  | NOT in scope         | written (8 items)                           |
  | What already exists  | written                                     |
  | Dream state delta    | written                                     |
  | Error/rescue registry| 7 rows, 0 CRITICAL GAPS                     |
  | Failure modes        | 6 total, 0 CRITICAL GAPS                    |
  | TODOS.md updates     | 1 item (Linux swift-test CI)                |
  | Scope proposals      | 7 proposed, 5 accepted (+F3 taste)          |
  | CEO plan             | written                                     |
  | Outside voice        | codex unavailable (quota); native completed |
  | Lake Score           | N/A (no scored questions)                   |
  | Diagrams produced    | arch, data flow, error flow, UX flow        |
  | Stale diagrams found | 0                                           |
  | Unresolved decisions | 0 (taste F3, F4 surfaced at final gate)     |
  +====================================================================+
```


### Phase 2 — Design review

**Scope.** UI touched: refusal feedback (alert, status bar), the tool rail on refused switches, Show Transform Controls
states, Settings › Shortcuts rows and Linux key names, Last Filter menu item, Layers footer dimming and rename field,
text→pixels on gradient. **DESIGN.md: absent.** The design system of record is `MACOS_UI_PARITY_RULES.md` (§0: the
Mac app is authoritative; Linux must not add visible convenience or Qt-native substitutes; platform-only items need a
Category C justification). All decisions below calibrate against it, which settles most taste questions.

**Step 0.** Initial design completeness: **4/10**. The plan specifies correctness and tests but not what the user sees on
refusal, pending, shortcut and Show Controls states, and its one visible choice (status-bar `busyReason`) conflicts
with §0. A 10 would cite, for every visible state, the Mac source that defines it and screenshot-check it.
Focus: all 7 passes (P1). **Mockups: skipped** (auto-decided, P5): the designer is ready, but the only valid visual
target is the Mac app itself (§0); AI variants would be design input the parity rules forbid. Evidence instead =
real Qt screenshots vs Mac source (F11, extended below).

**Design voices.** Claude subagent: completed on snapshot `3df84959…cbfa`, 15 findings (2 critical, 5 high, 8 medium).
Codex: **unavailable** (same quota limit, resets 2026-10-14 13:55). `[subagent-only]`.

```
DESIGN OUTSIDE VOICES — LITMUS SCORECARD  [subagent-only; classifier: OPERATE / APP UI]
  Check                                    Claude           Codex  Consensus
  1. Brand unmistakable in first screen?   n/a (Mac clone)  N/A    N/A
  2. One strong visual anchor?             yes (canvas)     N/A    N/A
  3. Scannable by headlines only?          n/a              N/A    N/A
  4. Each section has one job?             yes              N/A    N/A
  5. Cards actually necessary?             none used        N/A    N/A
  6. Motion improves hierarchy?            no motion added  N/A    N/A
  7. Premium without decorative shadows?   yes              N/A    N/A
  Hard rejections triggered:               0                N/A    N/A
```

Finding dispositions (Design phase: P5 explicit + P1 completeness; §0 parity decides visible changes):

| # | Finding | Decision | Class | Why |
|---|---|---|---|---|
| D1 | Refusal is a dead end; pending states should resolve like Photoshop | ACCEPT (reframed) | mechanical | On the Mac a pending transform/crop/gradient/shape/lasso/text from another tool cannot coexist with a paint tool: every route to a tool goes through `selectTool`, which resolves them (`EditorSession.swift:387`). Linux must make the same states unreachable: every Qt/bridge path that changes tool (rail, keys, `*Begin` auto-switch, palette) goes through `selectTool`; the matrix asserts no foreign pending state survives. Same-tool pending (gradient re-drag) follows upstream (replaces the line). |
| D2 | Async gradient commit makes the next action fail | ACCEPT | mechanical | Bridge awaits an in-flight `commitGradient` before handling the next paint/tool command (no visible change; the Mac commits within one run-loop turn). Supersedes CEO Section 4 "next action refused": the async test now asserts the action **completes** after the commit. |
| D3 | Refusal feedback via HUD/toast near pointer, pulse Apply/Cancel | REJECT HUD/pulse; REVISE busy text | taste (surfaced) | §0 forbids Linux-only visible UI. Mac: busy "press just waits" (`EditorSession+Brush.swift:13`), refusal = alert. With D1/D2 the busy states are unreachable by normal input, so `busyReason` becomes **command error + log only, never shown**. Supersedes CEO bullets "status bar shows busyReason" and the status-bar contract. `paintRefusal` keeps the Mac alert. |
| D4 | Full busy copy table | ACCEPT (developer-facing) | mechanical | Strings exist for logs/tests; plain "<state> is pending/active" form; not user-visible after D3. |
| D5 | Show Controls visual states unspecified | ACCEPT | mechanical | Specify by citation: unarmed vs armed handles and Apply/Cancel visibility follow tip `TransformInspector.swift` + `TransformOverlay.swift` (`showsTransformControls`, `transformEdit?.persistent`); Linux shell enables Apply/Cancel only when `transformPending`. Screenshot pair (Show Controls on, idle vs ⌘T armed) added to F11. Switching to Gradient commits the transform (selectTool) and hides armed chrome. |
| D6 | Linux shortcut mapping / conflicts / display | ACCEPT | mechanical | Existing Linux mapping is already defined in the override (`KeyboardShortcuts.swift:60`: ⌘→Ctrl, ⌥→Alt, ⌃→Meta, labels spelled out) and must survive generation as part of the `gen-keyboard-shortcuts.py` patch. Conflict found: the override's help text says "Meta+Ctrl+F toggles full screen", but tip 1.4.8 puts Toggle Fullscreen on F and Last Filter on ⌃⌘F (= Meta+Ctrl+F). The patch must update that text. Single-key F (and every tool key) is inert while a text field or live `textDraft` has focus (matches Mac key-equivalent routing); combo-smoke adds "press F during text editing → text gets 'f', no Canvas Only". Desktop conflicts on Meta+Ctrl+F are Category C: document in `upstream-parity.json` deviations; no rebinding (rebinding would diverge from Mac). |
| D7 | Rasterize-on-gradient notice | REJECT notice; ACCEPT undo naming | mechanical | Mac shows no notice (§0). Assert Edit › Undo title after case 3 equals upstream's history name for the gradient. |
| D8 | De-duplicate repeated alerts | REJECT | mechanical | Mac re-raises per press; parity wins. |
| D9 | Refused rail switch visuals | ACCEPT no-optimistic-highlight; REJECT shake | mechanical | Rail highlight only via `applyToolLocally` from session state (already landed); no Linux-only animation. combo-smoke asserts the rail never shows a refused tool, even for one frame (state check after the click's event loop turn). |
| D10 | Last Filter states | ACCEPT | mechanical | Mac: `"Last Filter: <name>"` label, plain "Last Filter" when none (`CompositorApp.swift:304`), disabled per its `.disabled`; long filters show the status bar's existing "Working…" (`ContentView.swift:352-354`, `showsBusy`). Smoke asserts label + disabled state. |
| D11 | Empty text draft on switch | ACCEPT | mechanical | Assert upstream `finishText()` outcome for empty/whitespace drafts (no stray layer if upstream discards; whatever upstream does is the expectation, cited). |
| D12 | Footer dimming value | ACCEPT (parity) | mechanical | Use the compat layer's SwiftUI `.disabled` opacity (same as other disabled controls; `SwiftUIQtRenderer.cpp` mask-effect opacity), no tooltip, no debounce beyond upstream's `layersLookEditable` (which already avoids flashing for brief work, `06313a9`). |
| D13 | Rename field metrics | ACCEPT | mechanical | Cite tip `NativeLayerList` rename treatment (layer background `quaternaryLabelColor`, unchanged row height); screenshot in F11. |
| D14 | Wider visual evidence | ACCEPT | mechanical | F11 adds: case 6 pair (D5), one paintRefusal alert, Settings › Shortcuts rows, Last Filter menu label. |
| D15 | Crop seeded from selection: selection after cancel/apply | ACCEPT | mechanical | Assert upstream behavior (cancelCrop leaves `selection` unchanged; apply follows `applyCrop`'s handling), cited in case 9. |

#### Pass 1 — Information architecture: 6/10 → 9/10
What the user sees first is the canvas and the active tool; the change must not add chrome (§0). Before: the status bar was
planned to carry refusals, which competes with the Mac's tool-hint slot (`ContentView.swift:359`). After D3 the status
bar keeps the Mac hierarchy (zoom · size · color on the left, hint/"Working…" on the right). One point short: the screenshot
comparison only proves this once implemented.
```
 ┌ options bar (tool header; Apply/Cancel only when transformPending) ┐
 │ rail │            canvas (primary)                    │ layers    │
 └ status: zoom · W×H px · sRGB · Transparent ...... tool hint | Working… ┘
   refusal (paintRefusal) → Mac alert sheet; busy → no visible change
```

#### Pass 2 — Interaction states: 3/10 → 8/10
```
 FEATURE            | LOADING             | EMPTY                      | ERROR                    | SUCCESS            | PARTIAL
 gradient on target | —                   | empty selection: refusal   | paintRefusal → Mac alert | preview, Enter     | commit in flight: next action waits (D2)
 tool switch        | —                   | no document: rail disabled | text commit fails: stays | rail = session     | —
 Last Filter        | "Working…" (Mac)    | no last filter: disabled   | refusal → alert          | layer changed      | —
 Show Controls      | —                   | no layer: hidden (tip)     | —                        | armed on ⌘T        | idle handles (tip)
 Shortcuts settings | —                   | —                          | conflict msg (tip text)  | row lists key      | —
 text→gradient      | —                   | empty draft: upstream rule | —                        | rasterized + undo  | —
```
The remaining gap is that each state's exact Mac text is cited but not yet captured; it is closed by the F11 screenshots.

#### Pass 3 — Journey: 4/10 → 8/10
| Step | User does | User feels (before) | Plan specifies now |
|---|---|---|---|
| 1 | Selects area | fine | selection kept across switches |
| 2 | Edits text, picks Gradient | **"nothing happened"** | text committed by `selectTool`, gradient starts (case 2) |
| 3 | Drags gradient | confident | clipped to selection (case 1) |
| 4 | Immediately brushes | **refused (old plan)** | waits for commit, then paints (D2) |
| 5 | Undo ×2 | trust | named undo steps restore text (D7) |
5-sec: the drag responds. 5-min: combos never stall. 5-year: Linux feels like the Mac.

#### Pass 4 — AI slop: 9/10 → 9/10
Classifier OPERATE. No hard rejections. Nothing generic is added; all chrome is the Mac's. The one remaining point is the
unverified rendered output.

#### Pass 5 — Design-system alignment: 4/10 → 9/10
DESIGN.md is absent, so `MACOS_UI_PARITY_RULES.md` is the system. Before: busy status text, which violates §0. After: every
visible state cites a Mac source; Category C deviations (Linux key names, Meta+Ctrl+F desktop conflict) are recorded in
`upstream-parity.json`. Recommend `/design-consultation` only if the project ever wants a Linux-native look (out of scope).

#### Pass 6 — Responsive and accessibility: 6/10 → 8/10
Desktop-only Qt window; there is no mobile surface. The narrow-window tool headers already scroll (`68396ff`, ported). Keyboard:
tool keys inert in text focus (D6); the alert is keyboard-dismissable (Mac sheet → Qt dialog with default button).
Screen readers: the Qt accessible names of the alert and status bar keep the Mac `accessibilityIdentifier`s (`zoomStatus`,
`canvasDimensions`). Gap: no contrast audit (inherited Mac palette).

#### Pass 7 — Unresolved design decisions
| Decision | Status |
|---|---|
| Visible feedback for busy states (Mac-silent vs commercial-app message) | TASTE → final gate (D3) |
| Meta+Ctrl+F desktop-environment conflict | Category C documented; no rebinding |
All others are resolved above.

NOT in scope (design): Linux-native HUD/toasts, shake animations, rasterize notices, alert de-dupe (all §0); mockups
(Mac is the reference); `/design-consultation` (no new design system).
What already exists: Mac `statusBar` / alert semantics, `KeyboardShortcuts` Linux key naming, `applyToolLocally`, compat
`.disabled` opacity, `COMPOSITOR_GRAB_PATH` screenshots, `MACOS_UI_PARITY_RULES.md`.
TODOS: none new.

```
  +====================================================================+
  |         DESIGN PLAN REVIEW — COMPLETION SUMMARY                    |
  +====================================================================+
  | System Audit         | no DESIGN.md; MACOS_UI_PARITY_RULES is system|
  | Step 0               | 4/10; all passes; mockups skipped (Mac ref) |
  | Pass 1  (Info Arch)  | 6/10 → 9/10 after fixes                     |
  | Pass 2  (States)     | 3/10 → 8/10 after fixes                     |
  | Pass 3  (Journey)    | 4/10 → 8/10 after fixes                     |
  | Pass 4  (AI Slop)    | 9/10 → 9/10 after fixes                     |
  | Pass 5  (Design Sys) | 4/10 → 9/10 after fixes                     |
  | Pass 6  (Responsive) | 6/10 → 8/10 after fixes                     |
  | Pass 7  (Decisions)  | 13 resolved, 1 taste to gate, 1 Category C  |
  +--------------------------------------------------------------------+
  | NOT in scope         | written (6 items)                           |
  | What already exists  | written                                     |
  | TODOS.md updates     | 0 items proposed                            |
  | Approved Mockups     | 0 generated (skipped: Mac is reference)     |
  | Decisions made       | 15 added to plan                            |
  | Decisions deferred   | 1 (busy visibility taste → gate)            |
  | Overall design score | 3/10 → 8/10                                 |
  +====================================================================+
```

<!-- autoplan-accepted:design -->
- Supersedes CEO bullets on busy feedback (status-bar contract, "status bar shows busyReason", busy-case smoke assertion, Section 4 "next action refused"): `busyReason` is command error + log only, never shown in the Qt UI; `paintRefusal` keeps the Mac alert, mirrored nowhere else. combo-smoke asserts the alert for case 11 and asserts NO visible change for busy cases.
- Every tool change path in the Qt shell and bridge (rail, tool keys, `*Begin` auto-switch, command palette) goes through `selectTool`; the matrix asserts no pending state from another tool survives into a paint command.
- The bridge awaits an in-flight `commitGradient` before handling the next paint or tool command; the async-order test asserts the next action completes after the commit (not refused).
- Show Transform Controls visuals follow tip `TransformInspector.swift` / `TransformOverlay.swift`; Qt Apply/Cancel enabled only when `transformPending`; switching to Gradient commits the transform. Screenshot pair (idle vs ⌘T armed) in F11.
- `gen-keyboard-shortcuts.py` patch preserves the Linux key-name display (`KeyboardShortcuts.swift:60` mapping ⌘→Ctrl, ⌥→Alt, ⌃→Meta) and updates the help text that still says "Meta+Ctrl+F toggles full screen" to tip 1.4.8 (F = Toggle Fullscreen, Meta+Ctrl+F = Last Filter). The Meta+Ctrl+F desktop-shortcut conflict is recorded as Category C in `upstream-parity.json` deviations; no rebinding.
- Tool keys (incl. F) are inert while a text field or live `textDraft` has focus; combo-smoke: press F while editing text → the text receives "f", Canvas Only stays off.
- Case 3 asserts Edit › Undo's title equals upstream's history name for the gradient; no Linux notice.
- Rail never shows a refused tool: combo-smoke checks rail state after the click's event-loop turn.
- Last Filter: smoke asserts menu label "Last Filter: <name>" after a filter, "Last Filter" and disabled before any (tip `CompositorApp.swift:304`).
- Case 2 also covers an empty/whitespace text draft, asserting upstream `finishText()`'s outcome.
- Footer disabled look uses the compat `.disabled` opacity; no tooltip or extra debounce.
- Rename field follows tip NativeLayerList treatment (layer background, unchanged row height).
- F11 screenshots add: Show Controls pair, one paintRefusal alert, Settings › Shortcuts rows, Last Filter menu label.
- Case 9 asserts upstream's selection state after crop cancel and after crop apply.
<!-- /autoplan-accepted:design -->


### Phase 2.5 — DX review (DX POLISH)

Product type: **contributor tooling** (CLI scripts, generators, gates, smoke modes, test matrix, ledger doc). The
end-user app is covered by Design; this phase reviews the experience of the person who runs the *next* catch-up.

```
TARGET DEVELOPER PERSONA
========================
Who:       the Linux-port maintainer (today: the repo owner plus Claude Code sessions) running an upstream catch-up
Context:   upstream ships a release (1.4.9); they must merge, regenerate overrides, find drift, prove parity, commit
Tolerance: one sitting; abandons the gates (bypasses or ignores red CI) if failures are opaque or always red
Expects:   one command that says what is left, failures that name the fix, tests they never edit
```
Persona auto-decided (P6) from README/CLAUDE.md/memory: two catch-ups in 11 days were run by exactly this person.

**Developer perspective (empathy narrative).** "Upstream tagged 1.4.9. I fetch and merge, and `check-upstream-clean.sh`
says UPSTREAM CLEAN, so I think I'm done. Last time that was a lie: the ledger said Done while four hand overrides had
drifted. Now there's a drift script, a ledger script with positional from/to, three new generators, eight smoke flags
and a JSON file growing new keys. The gate goes red on 'TODO evidence' minutes after my merge and stays red until I hand-fill
38 rows, so CI is red all afternoon. When it fails, I get one generator's raw diff and don't know whether the other checks
even ran. I want one command that tells me the next step." (Partly predicted: the drift/ledger tools don't exist yet; the
gate's `set -eu` abort-on-first and success text are observed in `scripts/check-upstream-clean.sh`.)

**Competitive DX benchmark** (search not run; reference benchmarks, labeled estimates):
| Tool | Start → result | Time + evidence | DX choice |
|---|---|---|---|
| `git rebase` + CI (typical fork) | fetch → green CI | estimated 30–60 min, no guidance | none |
| Chromium/Electron "roll" scripts | roll → bot report | reported minutes; one command, structured failure list | one driver, per-check table |
| This port today | fetch → "what's left" | estimated 2–4 h of archaeology (observed: this session needed ~25 tool calls to find the 4 stale overrides) | per-script, abort-on-first |
| This plan + DX fixes | fetch → printed checklist | target ≤ 5 min to the first actionable report (excluding Flatpak build) | `upstream-catchup.sh` + gate table |
Target: **Competitive (≤ 5 min to the first actionable report)**, auto-decided P5. The Flatpak build time is outside the clock.

**Magical moment:** `scripts/upstream-catchup.sh` after a merge prints one table: protected trees OK, each generator
OK/STALE with the exact regenerate command, drift lines with copy-paste allowlist JSON or "port via patch X",
ledger rows generated N/54 with TODO evidence count, smokes to run. Vehicle: existing scripts + one thin driver (P5).

**Developer journey map:**
```
STAGE        | DEVELOPER DOES                       | FRICTION                                   | STATUS
1 Discover   | reads ledger doc top                 | no runbook                                 | fixed (runbook + summary block)
2 Install    | Flatpak SDK, release build           | build steps scattered                      | fixed (run-smokes.sh documents/builds)
3 Hello World| upstream-catchup.sh after merge      | none today (no driver)                     | fixed (driver + table)
4 Real Usage | regenerate, port drift, fill evidence| allowlist format conflict; red-all-day CI  | fixed (normalized allowlist; --strict evidence)
5 Debug      | matrix pair fails / parser out of date| 196 pairs, opaque parser error             | fixed (COMBO_PAIR filter, rich messages)
6 Upgrade    | next release: advance ledger_base    | two range sources                          | fixed (JSON default range)
```

**First-time developer report** (predicted, grounded in the current scripts):
```
T+0:00  git merge upstream/main; check-upstream-clean.sh → "UPSTREAM CLEAN" (observed text) → assumes done
T+0:05  gen-keyboard-shortcuts --check fails, script aborts (set -eu) → unsure what else failed
T+0:20  finds drift script; allowlist wants "exact trimmed line" but the compare normalizes → allowlist misses
T+0:40  ledger --check red on TODO evidence; CI red; considers skipping the gate
T+1:00  matrix fails on one pair; reruns all 196 pairs to debug
```

**DX voices:** Claude subagent completed on snapshot `0e2af410…3789`, 23 findings (9 high, 14 medium). Codex **unavailable**
(quota). `[subagent-only]`.
```
DX DUAL VOICES — CONSENSUS TABLE  [subagent-only]
  Dimension                           Claude           Codex  Consensus
  1. Getting started < 5 min?          no (no driver)   N/A    N/A
  2. API/CLI naming guessable?         partly           N/A    N/A
  3. Error messages actionable?        no (no remedy)   N/A    N/A
  4. Docs findable & complete?         no (no runbook)  N/A    N/A
  5. Upgrade path safe?                partly           N/A    N/A
  6. Dev environment friction-free?    no (red CI)      N/A    N/A
```

Dispositions (DX POLISH; error messages need problem + cause + fix, P1; naming consistency, P5):
| # | Finding | Decision | Class |
|---|---|---|---|
| X1 | No runbook/driver | ACCEPT: `scripts/upstream-catchup.sh` + runbook at the ledger top | mechanical |
| X2 | Two range sources | ACCEPT: both scripts default to `ledger_base..upstream_ref`, `--from/--to` override, print range | mechanical |
| X3 | No single smoke command | ACCEPT: `scripts/run-smokes.sh [--only …]` with pass/fail table | mechanical |
| X4 | Gate red all window on TODO evidence | ACCEPT: ledger `--check` structural only; `--strict` (TODO evidence) is required only when advancing `ledger_base` and in the final pre-commit gate | mechanical |
| X5 | Gate aborts on first failure, misleading name/line | ACCEPT: run all sub-checks, print a table, exit nonzero at end; success line "ALL UPSTREAM GATES PASS" | mechanical |
| X6 | Inconsistent generator interfaces | ACCEPT: common `--check/--write/--diff`; registry `scripts/generators.txt` iterated by the gate; `gen-lucide-icons.py` gets `--check` | mechanical |
| X7 | Overlap with `upstream-audit.py` | ACCEPT: the drift script reuses its declaration walker; the audit stays as inventory, documented in both headers | mechanical |
| X8 | Allowlist exact vs normalized conflict | ACCEPT: allowlist stores normalized form + `reason` + upstream commit; stale entries reported | mechanical |
| X9 | JSON schema ad hoc | ACCEPT: `linux/upstream-parity.schema.json`, validated by the gate; unknown keys fail | mechanical |
| X10 | busyReason invisible = original complaint | KEEP Design D3 + ADD debug channel `COMPOSITOR_LOG_REFUSALS=1` (stderr) | taste (same gate item as D3) |
| X11 | Drift failure lacks remediation | ACCEPT: prints override, upstream file:line@commit, missing line, "port via linux/patches/X.patch + gen-X.py" or a copy-paste JSON allowlist snippet | mechanical |
| X12 | Parser error opaque | ACCEPT: names file, found range, expected shape, bridge table location | mechanical |
| X13 | Bare fallback enforced by prose | ACCEPT: `refusal(s, cause:)` non-optional cause | mechanical |
| X14 | Settle timeout lacks snapshot | ACCEPT: print every false `canEditLayers` term | mechanical |
| X15 | Ledger navigability | ACCEPT: generator writes summary block, consumption legend, count rule, deviations section rendered from JSON | mechanical |
| X16 | Free-text evidence | ACCEPT: `test:<Suite>/<name>` or `smoke:<flag>#<step>`, verified by `--strict` | mechanical |
| X17 | Line-number citations drift | ACCEPT: cite symbol, line as hint | mechanical |
| X18 | No local bypass | ACCEPT: `--skip <check>` local-only; refused when `CI` is set; loud reminder | mechanical |
| X19 | Matrix not scopable | ACCEPT: `COMBO_PAIR=from>to` filter + documented `swift test --filter` | mechanical |
| X20 | Unbounded wait on commitGradient | ACCEPT: 2 s bound; on expiry return busyReason (logged) instead of blocking | mechanical |
| X21 | Re-recorded shortcut vs Qt accelerator mismatch | ACCEPT: recorded in deviations + TODOS (table-driven accelerators) | mechanical |
| X22 | Stack of superseding amendments | ACCEPT: Eng phase writes a single normative "Final contract" section; history stays in Review record | mechanical |
| X23 | Test-file approval before commit (1) | ACCEPT: first runbook step | mechanical |

TTHW: current estimated 2–4 h to know "what's left"; target ≤ 5 min to the first actionable report (Competitive).

```
+====================================================================+
|              DX PLAN REVIEW — SCORECARD                             |
+====================================================================+
| Dimension            | Score (before → after) | Prior | Trend      |
| Getting Started      | 2 → 8                   | —     | new        |
| API/CLI/SDK          | 4 → 8                   | —     | new        |
| Error Messages       | 4 → 8                   | —     | new        |
| Documentation        | 3 → 8                   | —     | new        |
| Upgrade Path         | 5 → 8                   | —     | new        |
| Dev Environment      | 4 → 7 (Flatpak build)   | —     | new        |
| Community            | 5 → 5 (solo repo; n/a)  | —     | new        |
| DX Measurement       | 2 → 7 (driver timings)  | —     | new        |
| TTHW                 | 120–240 min → ≤5 min    | —     |            |
| Competitive Rank     | Red Flag → Competitive                       |
| Magical Moment       | designed via upstream-catchup.sh table        |
| Product Type         | contributor tooling (CLI)                     |
| Mode                 | POLISH                                        |
| Overall DX           | 2 → 5 (min of dims; community stays 5)        |
+====================================================================+
```
Community stays 5: single-maintainer repo, so a contributing guide is out of scope (NOT in scope). DX Measurement: the driver
prints wall time per stage, which is how /devex-review measures TTHW later.

```
DX IMPLEMENTATION CHECKLIST
[ ] upstream-catchup.sh prints the first actionable report ≤ 5 min after merge (excl. build)
[ ] check-upstream-clean.sh runs all checks, prints a table, "ALL UPSTREAM GATES PASS"
[ ] every gate failure: problem + cause + exact fix command / snippet
[ ] generators share --check/--write/--diff and a registry
[ ] ledger: runbook, summary, legend, deviations rendered; structured evidence
[ ] --skip local-only escape hatch, refused in CI
[ ] COMBO_PAIR filter + documented swift test --filter
[ ] COMPOSITOR_LOG_REFUSALS=1 debug channel
[ ] parity JSON schema validated
```

NOT in scope (DX): CONTRIBUTING guide / community channels (solo repo); hosted CI for swift test (E7, TODO).
What already exists: `check-upstream-clean.sh`, generator `--check` pattern, `upstream-audit.py` walker, `ci-guard.yml`,
`COMPOSITOR_GRAB_PATH`, smoke flags in `host_run.cpp`.

<!-- autoplan-accepted:dx -->
- `scripts/upstream-catchup.sh`: after a merge, runs every gate non-fatally and prints one table (protected trees, each generator OK/STALE + regenerate command, drift lines with port-or-allowlist remedy, ledger rows N/54 + TODO evidence count, smokes to run) with wall time per stage; first actionable report ≤ 5 min excluding the Flatpak build.
- `check-upstream-clean.sh` runs all sub-checks, prints a per-check table, exits nonzero at the end; success line "ALL UPSTREAM GATES PASS"; local-only `--skip <check>` (refused when `CI` is set, prints a reminder).
- Ledger and drift scripts default to `ledger_base..upstream_ref` from JSON, accept `--from/--to`, print the range used.
- Ledger `--check` is structural (rows match git, consumption kind present); `--strict` additionally requires no TODO evidence and verifies structured evidence (`test:<Suite>/<name>` exists in Tests/, `smoke:<flag>#<step>` exists in host); `--strict` runs when advancing `ledger_base` and in the final pre-commit gate, not in every CI run.
- Generators share `--check`/`--write` (default)/`--diff` and are listed in `scripts/generators.txt`, which the gate iterates; `gen-lucide-icons.py` gains `--check`.
- Drift script reuses `upstream-audit.py`'s walker; allowlist entries store the normalized line, a `reason`, and the upstream commit; stale entries are reported; failures print override path, upstream file:line@commit, the missing line, and either the patch/generator command or a copy-paste JSON allowlist snippet.
- `linux/upstream-parity.schema.json` validates `upstream-parity.json` (incl. `drift`, `deviations`, `ledger_base`) inside the gate; unknown keys fail.
- `scripts/run-smokes.sh [--only a,b]` builds/locates the release `CompositorHostBootstrap` and prints a pass/fail table for all smokes.
- Ledger doc top: runbook (step 1: per-file approval of modified tests), summary block, consumption-kind legend, count rule, and a "Linux deviations" section rendered from `deviations`, all written by the generator.
- `refusal(s, cause:)` takes a non-optional cause; the `canEditLayers` parser error names file, found range, expected shape and the bridge table to update; settle-timeout prints every false `canEditLayers` term; Mac citations use symbols with line hints.
- `COMBO_PAIR=from>to` filters the matrix; the `swift test --filter` command is documented in the test file header.
- `COMPOSITOR_LOG_REFUSALS=1` prints every refusal (busy, site, paintRefusal) to stderr.
- The bridge's wait on an in-flight `commitGradient` is bounded at 2 s; on expiry the command returns its busyReason (logged) instead of blocking input.
- Deviations + TODOS record that re-recorded shortcuts do not change Qt accelerators until table-driven accelerators land.
- Eng phase writes one normative "Final contract" section collapsing all superseded bullets (commit order, refusal UI contract, allowlist set, gate list).
<!-- /autoplan-accepted:dx -->


### Phase 3 — Eng review (FULL_REVIEW, runs last)

**Scope Challenge.** Code read: tip `EditorSession.swift` (`selectTool` :387, `canEditLayers` :686), `Gradient.swift`
(`beginGradient` :54, `commitGradient`, `resolveGradient` :122 = untracked `Task`), `EditorSession+Brush.swift`
(`canPaint`/`paintRefusal` :5/:14), `TypeTool.swift` :204, `EditorCanvas.swift` :1833, bridge `UpstreamEditor.swift`
(12 `could not start` sites; `selectTool` callers :581/:597/:697/:969/:980/:1057), host `SessionWindow::requestTool`
:4723 and a direct `selectTool` send at `SessionWindow.cpp:1854` (blur mode) that bypasses `requestTool`.
Complexity: ~30 changed files, 5+ new scripts. Above the 8-file threshold → structure selector auto-decided
**Original arrangement** (P2: Eng never reduces scope; most files are existing WIP). Search: skipped (no new infra
pattern; Layer 1 reuse of existing generator/gate pattern). TODOS cross-ref: none of the existing TODOS block this.
Result: **scope accepted as-is**.

**Eng voices.** Claude subagent completed on snapshot `e14569a7…f2e0`, 22 findings (6 high). Codex **unavailable** (quota).
```
ENG DUAL VOICES — CONSENSUS TABLE  [subagent-only]
  Dimension                           Claude                 Codex  Consensus
  1. Architecture sound?               yes, contract gaps     N/A    N/A
  2. Test coverage sufficient?         gaps (transform paths) N/A    N/A
  3. Performance risks addressed?      mostly (2 s cap)       N/A    N/A
  4. Security threats covered?         yes (local tooling)    N/A    N/A
  5. Error paths handled?              no (brushError clear)  N/A    N/A
  6. Deployment risk manageable?       yes                    N/A    N/A
```
Factual correction to the voice: "no shader build step" is false. `scripts/build-brush-shader.py` compiles
`effects.comp → effects_spv.h` with `--check`, and today it passes (rc 0, run 2026-10-09). The real gap is that no gate
runs it; fixed by E10.

#### Section 1 — Architecture
```
 Qt SessionWindow ── rail/keys/palette ──▶ requestTool ──▶ JSON "selectTool" ─┐
   (SessionWindow.cpp:1854 blur send ── must route via requestTool, E5)        │
 Qt canvas mouse ──▶ JSON "*Begin" ────────────────────────────────────────────┤
                                                                                ▼
 UpstreamEditor (bridge)                                               EditorSession (tip, SSOT)
  ├ before any tool/layer/paint cmd: if gradientEdit → await s.commitGradient()  ─▶ commitGradient
  ├ snapshot brushError/revision ─▶ call session ─▶ changed? → this cmd's error   ─▶ selectTool/beginX
  ├ refusal(s, cause:) = paintRefusal ?? newBrushError ?? busyReason ?? "<a> could not start: <cause>"
  ├ busyReason table ◀── parsed canEditLayers terms (test, tip source via #filePath)
  └ COMPOSITOR_LOG_REFUSALS → stderr
                                                                                │ state JSON
 Qt: alert(paintRefusal, Mac sheet) · status bar = Mac hints only · busy affordance per state
 Gates: check-upstream-clean.sh ─▶ generators.txt (gen-*, build-brush-shader --check) ─▶ drift (mode tip|pinned|replaced,
        hunk+deletion compare, ledger_base..ledger_to) ─▶ ledger-rows --check (structural)
```
Findings and dispositions:
- [P1] (9/10) refusal UI contract contradicts itself across bullets → **E1 ACCEPT Final contract** (below).
- [P1] (9/10) clearing `brushError` dismisses the user's alert and loses async `commitGradient` errors (Gradient.swift sets it) → **E2 ACCEPT**: snapshot/compare; never clear from the bridge. Supersedes the spec-review-3 "clear brushError" bullet.
- [P1] (9/10) "await in-flight commitGradient" is unbuildable (`resolveGradient` spawns an untracked `Task`) → **E3 ACCEPT**: the bridge calls `await s.commitGradient()` itself before any tool/layer/paint command while `gradientEdit != nil`; the 2 s bound is only a logged backstop (commit returns early when `isProjectBusy`).
- [P2] (8/10) 2 s cap drops input silently → **E4 ACCEPT**: on backstop expiry, command error + log, and the pending gradient's visible chrome stays (it is the busy affordance).
- [P2] (9/10) `selectTool` refusal false positive for same-tool requests → **E5 ACCEPT**: fail only when `requested != before && s.tool != requested`; route the `SessionWindow.cpp:1854` blur send through `requestTool`.
- [P2] (8/10) drift scope contradiction; flat schema can't express pinned/replaced/multi-upstream → **E6 ACCEPT**: per-override `mode: tip|pinned|replaced`, `upstream: [..]`; every non-generated hand override covered (pinned ColorRange* skipped with reason; replaced NativeLayerList/MetalLayerEffects skipped with reason; others tip-checked).

#### Section 2 — Code quality
- [P2] (9/10) `canEditLayers` body is `_ = showsBusy` + `return a && …` → **E7 ACCEPT** parser skips `_ =`, strips `return`, normalizes `!x`/`x == nil`/`x != nil`; tip path via `#filePath`.
- [P3] (8/10) commit subjects with `|`/backticks break ledger rows → **E8 ACCEPT** escape; git via `-z` and arg lists.
- [P3] (7/10) generators apply patches → **E9 ACCEPT** `git apply --check` first, fail closed, no fuzz; ContentView generator error explains the `bodyCore` re-split recipe.
- DRY: one `refusal` helper replaces 12 strings; drift reuses `upstream-audit.py` walker (DX X7). No new duplication.

#### Section 3 — Tests
```
CODE PATHS                                              USER FLOWS
[+] UpstreamEditor bridge                               [+] Text + selection + gradient (reported)
  ├ refusal(s,cause:)  [GAP→NEW] each branch             ├ [GAP→NEW] session case 2/3   [→E2E] combo-smoke
  ├ brushError change-detect [GAP→NEW]                   ├ [GAP→NEW] empty draft
  ├ await commitGradient [GAP→NEW] fast + slow + busy    [+] Show Controls / transforms
  ├ selectTool refusal [GAP→NEW] same-tool, text fail    ├ [★★ WIP] showingTransformControlsKeeps… (modified test, needs approval)
  └ busyReason table   [GAP→NEW] parser + coverage       ├ [GAP→NEW] handle drag released → tools
[+] Qt SessionWindow                                     ├ [GAP→NEW] typed field → leave → Brush
  ├ requestTool        [★★ existing dialog-smoke]        [+] Refusal
  ├ blur send :1854    [GAP→NEW] routes via requestTool  ├ [GAP→NEW][→E2E] paintRefusal alert (offscreen modal-safe)
  └ tool keys in text focus [GAP→NEW][→E2E]              └ [GAP→NEW] busy affordance visible
[+] backends/effects recolor [★★ WIP LayerEffectsBackendTests] + [GAP→NEW] parity file, Vulkan skip explicit
[+] backends/brush radius 1050 [★★ WIP BrushCoverageBackendTests]
[+] scripts: drift / ledger / generators / shader --check [GAP→NEW] script self-tests on fixtures
COVERAGE today: 3/22 paths (WIP tests, unapproved)  |  GAPS: 19 (3 E2E)  |  LLM/eval: none (no prompt code)
```
- **E11 ACCEPT**: add transform-from-fields and handle-drag cases; assert field-finish/mouse-release commit non-persistent edits (bridge :932).
- **E12 ACCEPT**: fail-first proof via `git worktree add` at HEAD with only the new test file (not a partial stash).
- **E13 ACCEPT**: schema validation by a small hand-written checker (no `jsonschema` dependency in CI).
- Regression rule: Part C changes existing behavior (Show Controls). Contract = Show Controls is display-only; ⌘T / handle drag arm; Apply/Cancel only when `persistent`. Carried from accepted Part C; no new question.
- Test plan artifact: `~/.gstack/projects/chiddekel-Compositor/developer-GNU_Linux-eng-review-test-plan-20261009-191356.md`.

#### Section 4 — Performance
- Matrix: 14×13 = 182 pairs, 64×64 docs; warm fonts once outside the timed region (**E15 ACCEPT**); cap 60 s (F7).
- `await commitGradient` on large docs: blocking is correct (matches Mac's single-run-loop commit); backstop logs. No other hot paths change.

#### Outside voice
Codex unavailable (quota, resets 2026-10-14 13:55). The eng-skill's own native fallback outside voice was not run separately: the
autoplan native eng voice above already used the same harness, and its findings are integrated. Coverage: **unavailable**.

#### Scope-creep finding (E14, P1 by the voice)
The voice recommends cutting `upstream-catchup.sh`, `run-smokes.sh`, the schema, `--strict` evidence, lucide `--check` and
the extra screenshots. Eng override says never reduce (P2); DX accepted them. **TASTE → final gate.** Interim: keep them,
ordered last (commit 6/7) so they are the first thing cut if time runs short.

### FINAL CONTRACT (normative; supersedes every earlier bullet where they differ)

1. **Commits, in order:**
   0. *(pre)* per-file user approval of the 4 modified test files and the `--transform-smoke` decision if it fails.
   1. Part C (Show Controls display-only) + D3 refusal plumbing (E2, E3, E5) + `ToolCombinationTests` named cases 1, 2, 3, 5, 6, transform-path cases (E11). Fail-first via worktree (E12).
   2. B6 effects recolor (CPU/OpenCV/Vulkan/Skia) + `EffectsRecolorParityTests`; `build-brush-shader.py --check` clean.
   3. B7 brush radius cap 1000→1050.
   4. Remaining D1 cases 4, 7–11 + 182-pair matrix + busyReason table/parser test.
   5. B1–B5 via generators: `gen-keyboard-shortcuts.py`, `gen-content-view.py`, `gen-layer-mask-menu.py` (+ patches); B4/B5 host checks.
   6. D2 `--combo-smoke` + key-parity smoke + Last Filter smoke step.
   7. Tooling: drift script (E6 modes, hunk+deletion compare), ledger generator (structural `--check`, `ledger_base..ledger_to`), `generators.txt` incl. `build-brush-shader.py`, gate table, then (taste E14) catchup.sh / run-smokes.sh / schema checker / `--strict` / screenshots; ledger rewritten; TODOS.
2. **Refusal UI:** `paintRefusal` → Mac "Couldn't paint" alert (`brushError`-driven, as upstream). Busy states → command error + `COMPOSITOR_LOG_REFUSALS` log, never status-bar text; every busy state keeps its visible Mac-equivalent chrome (Apply/Cancel, crop overlay, gradient line, open dialog), and combo-smoke asserts that chrome is present. Status bar shows only Mac content (hints / "Working…").
3. **Errors:** `brushError` read by change detection, never cleared by the bridge. `refusal(s, cause:)` with non-optional cause.
4. **Gradient ordering:** bridge `await s.commitGradient()` before tool/layer/paint commands while `gradientEdit != nil`; 2 s backstop logs.
5. **Tool switching:** every path → `requestTool` → bridge `selectTool`; same-tool requests succeed; refusal only when the switch did not happen.
6. **Drift/ledger:** `ledger_base: 11d8d7a`, `ledger_to: 22c7b8d`; per-override `mode`; generated overrides gated by their `--check`.
7. **Gates (all must pass before each commit lands):** protected trees; every entry in `generators.txt` `--check`; drift `--check`; ledger structural `--check`; full `swift test` (documented skips only); smokes `--session --io --transform --dialog --layers --brush --combo`; `git diff --check`.
8. **Count:** 38 code commits (rule in accepted reqs); the request's 37 explained in the ledger.

<!-- autoplan-accepted:eng -->
- The FINAL CONTRACT section in Review record (Phase 3) is normative and supersedes earlier implementation-plan text and earlier accepted bullets where they differ (commit order 0–7, refusal UI, error detection, gradient ordering, tool switching, drift/ledger range and modes, gate list, count).
- Bridge never clears `brushError`; a command's own error is detected by comparing `brushError` (or a session revision) before/after the call.
- Bridge calls `await s.commitGradient()` before handling any tool, layer or paint command while `s.gradientEdit != nil`; a 2 s backstop logs and returns the command error; tests cover fast commit, slow commit, and `isProjectBusy` early return.
- `selectTool` command fails only when `requested != before && s.tool != requested`; same-tool requests succeed. `SessionWindow.cpp:1854` blur-mode send routes through `requestTool`.
- Busy states: never status-bar text; each keeps visible Mac-equivalent chrome; combo-smoke asserts the chrome for transform pending, crop pending, gradient pending and open dialog.
- `upstream-parity.json` overrides gain `mode: tip|pinned|replaced` and `upstream: [paths]`; drift covers every non-generated hand override per its mode; compares per hunk with context and flags upstream-deleted lines still present.
- `ledger_to: "22c7b8d"` added; ledger/drift range is `ledger_base..ledger_to`.
- `canEditLayers` parser skips `_ =` lines, strips `return`, normalizes `!x` / `x == nil` / `x != nil`; locates tip source via `#filePath`.
- Ledger rows escape `|` and backticks; scripts read git with `-z` and argument lists.
- Generators apply patches with `git apply --check` first and fail closed; ContentView generator failure prints the `bodyCore` re-split recipe.
- `scripts/build-brush-shader.py --check` is listed in `scripts/generators.txt` and run by the gate.
- ToolCombinationTests adds: handle drag released → Gradient/Brush/New Layer/Undo; typed transform field → leave field → Brush; asserts non-persistent transform commits on field finish and mouse release.
- Fail-first proof uses `git worktree add <tmp> HEAD` plus only the new test file.
- Parity JSON validated by a hand-written checker (no `jsonschema` dependency).
- Matrix warms fonts once outside the timed region; 182 ordered pairs.
- EffectsRecolorParityTests reports "skipped: no Vulkan device" explicitly; never a silent pass.
<!-- /autoplan-accepted:eng -->

**NOT in scope (Eng):** CI `swift test` job (TODO); table-driven Qt accelerators (TODO); rail as pure session view (TODO
with trigger); a Codex re-run (quota). **What already exists:** `build-brush-shader.py --check`, generator `--check` pattern,
`upstream-audit.py` walker, `requestTool`/`applyToolLocally`, bridge `transformPending` (:1177) and non-persistent commit
(:932), `DialogJourney` harness, `ci-guard.yml`.

**Failure modes registry**
```
 CODEPATH                     | FAILURE                         | TEST    | HANDLING         | USER SEES
 bridge await commitGradient  | commit hangs (isProjectBusy)    | NEW     | 2 s backstop+log | gradient chrome stays
 bridge brushError detect     | stale error masks real reason   | NEW     | compare, no clear| correct alert
 selectTool via 1854 blur     | bypasses requestTool text finish| NEW     | route fix        | text kept
 transform from fields        | non-persistent edit left open   | NEW     | commit on finish | tools work
 gen-content-view patch       | upstream touched body           | gate    | fail closed+recipe| dev only
 drift pinned ColorRange      | false drift flood               | gate    | mode pinned      | dev only
 effects Vulkan stale spv     | old shader ships                | gate    | shader --check   | dev only
```
CRITICAL GAPS: 0 (each row now has a test or gate plus handling).

**Worktree parallelization:** Lane A: commits 1→4 (bridge + Tests/LinuxOverrideTests, sequential). Lane B: commits 2→3
(backends/, independent). Lane C: commit 7 tooling (scripts/, linux/ json), independent of A/B except the ledger evidence
step. Commits 5–6 touch host/ + Sources/Overrides after A. Launch A + B + C(scripts only); merge; then 5, 6, ledger evidence.

**Completion summary (Eng)**
- Step 0: scope accepted as-is (structure: original arrangement, auto-decided P2)
- Architecture: 6 issues · Code quality: 3 · Test gaps: 19 paths (all assigned) · Performance: 1
- NOT in scope / What already exists: written · TODOS.md: 5 items written
- Failure modes: 0 critical gaps · Unresolved: 0 in this review (2 taste items to gate)
- Outside voice: codex unavailable (quota) · Parallelization: 3 lanes, 2 parallel / 1 sequential tail
- Lake Score: N/A (no scored questions)

<!-- AUTONOMOUS DECISION LOG -->
## Decision Audit Trail

| # | Phase | Decision | Classification | Principle | Rationale | Rejected |
|---|-------|----------|----------------|-----------|-----------|----------|
| 1 | CEO | Approach A (this plan) | Mechanical | P1 | B repeats the untested-combo failure; C is a multi-week rewrite | B smallest, C rail rewrite |
| 2 | CEO | Mode SELECTIVE EXPANSION | Mechanical | autoplan override | Fixed by /autoplan | other modes |
| 3 | CEO | E1 drift gate fails on new drift | Mechanical | P2 | 2 files, in blast radius | advisory-only |
| 4 | CEO | E2 generate KeyboardShortcuts | Taste | P1/P2 | Removes the drifted hand copy; 3 files | hand re-sync |
| 5 | CEO | E3 ordered-pair matrix | Mechanical | P1 | Bug class is transitions | 11 hand cases only |
| 6 | CEO | E4 generated ledger rows | Mechanical | P2/P5 | Stops theme-level overclaiming | hand table |
| 7 | CEO | E5 rasterize prompt skipped | Mechanical | P4 / active decision | Exceeds Mac behavior | add prompt |
| 8 | CEO | E6 merged into D3 | Mechanical | P4 | Duplicate | separate item |
| 9 | CEO | E7 CI deferred | Mechanical | P3 | New infra outside blast radius | add now |
| 10 | CEO | 0H document approval A | Mechanical | P6 | Spec loop done (cap 3) | revise/pause |
| 11 | CEO | Spec review fixes (39 issues) | Mechanical | P1 | All concrete and in scope | — |
| 12 | CEO | F1/F2/F9 reorder + fail-first + split B7 | Mechanical | P1/P5 | User pain first; bisectable | audit-first order |
| 13 | CEO | F3 generate ContentView/LayerMaskMenu | Taste | P1 vs P5 | Cheaper than policing; +2 generators | allowlist-only |
| 14 | CEO | F4 CI kept deferred with trigger | Taste | P3 vs P1 | Needs Flatpak SDK in CI | add in this plan |
| 15 | CEO | F5–F8, F10–F12 | Mechanical | P1/P2/P5 | Concrete, small, in radius | — |
| 16 | Design | Mockups skipped (Mac is the visual reference) | Mechanical | P5 / parity §0 | AI variants would be forbidden design input | generate variants |
| 17 | Design | D1, D2, D4–D7(undo), D9(no optimistic), D10–D15 accepted | Mechanical | P5/P1 | Mac-cited, structural | — |
| 18 | Design | D3 busy feedback: hidden (Mac-silent) instead of status bar | Taste | §0 vs commercial feel | Parity rule; states unreachable after D1/D2 | status bar / HUD |
| 19 | Design | D3 HUD, D7 notice, D8 de-dupe, D9 shake rejected | Mechanical | §0 | Linux-only visible UI | add them |
| 20 | Design | Meta+Ctrl+F desktop conflict = Category C, no rebinding | Mechanical | §0 | Rebinding diverges from Mac | rebind |
| 21 | DX | Persona = port maintainer; target Competitive ≤5 min; vehicle upstream-catchup.sh | Mechanical | P6/P5 | Evidence: two catch-ups in 11 days by this person | other personas |
| 22 | DX | X1–X9, X11–X23 accepted | Mechanical | P1/P5 | In blast radius, existing scripts | — |
| 23 | DX | X10 keep UI silent (Design D3) + debug channel | Taste | parity §0 vs complaint | Same gate item as D3 | show in UI |
| 24 | Eng | Structure: original arrangement | Mechanical | P2 | Eng never reduces; files are WIP | smaller arrangement |
| 25 | Eng | E1–E13, E15 accepted; shader-gap claim corrected (script exists) | Mechanical | P5/P3 | Code-verified | — |
| 26 | Eng | E14 tooling scope: keep, ordered last | Taste | P2 vs P3 | DX accepted; single voice wants cut | defer to TODOS |
| 27 | Eng | TODOS.md: 5 deferred items auto-written | Mechanical | autoplan rule | Eng collects all phases | — |

**Final gate (2026-10-09):** user chose **A) Approve as-is**. All 4 taste choices stand as recommended (busy states silent with Mac-equivalent chrome; tooling kept, ordered last; KeyboardShortcuts, ContentView and LayerMaskMenu generated from tip). Status: **APPROVED**.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` (via /autoplan) | Scope & strategy | 1 | ISSUES OPEN (mapped to tasks) | 7 proposals, 5 accepted, 1 deferred; 0 critical gaps |
| Outside Review | codex via /autoplan | Independent 2nd opinion | 1 | unavailable | quota exhausted (resets 2026-10-14 13:55); no completed external review |
| Eng Review | `/plan-eng-review` (via /autoplan) | Architecture & tests (required) | 1 | ISSUES OPEN (mapped to tasks) | 29 issues, 0 critical gaps |
| Design Review | `/plan-design-review` (via /autoplan) | UI/UX gaps | 1 | CLEAR | score: 3/10 → 8/10, 15 decisions |
| DX Review | `/plan-devex-review` (via /autoplan) | Developer experience gaps | 1 | ISSUES OPEN (community 5/10) | score: 2/10 → 5/10, TTHW: 120–240 min → ≤5 min |

- **OUTSIDE COVERAGE:** codex — CEO unavailable, Design unavailable, DX unavailable, Eng unavailable (usage quota). Native Claude subagent completed in every phase (12 / 15 / 23 / 22 findings); native results are not outside coverage.
- **VERDICT:** Design CLEAR. CEO, DX and Eng carry open findings, all assigned to tasks in the FINAL CONTRACT; plan APPROVED by the user at the final gate. Eng review required: rerun `/plan-eng-review` with Codex after the quota resets to clear it.

NO UNRESOLVED DECISIONS
