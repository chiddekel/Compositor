<!-- /autoplan restore point: "/home/developer/.gstack/projects/chiddekel-Compositor/GNU_Linux-autoplan-restore-20260928-125543.md" -->
# Upstream 1.3.4 catch-up ledger + tool-combination transition parity

Date: 2026-09-28. Branch: `GNU_Linux`. Base commit: `f3649f6`.

## Implementation plan

### 1. Premise and what is actually left

The request was "list and catch up 37 commits from upstream". Ground truth measured today:

- `upstream/main` is `c28f827` (Compositor 1.3.4). Protected trees in this working tree match `2309a85` (1.3.3 + readable ASCII dithering).
- The 1.3.3 batch (26 upstream commits) **is already merged**: `290bf5e` is an ancestor of `GNU_Linux`.
- The 1.3.4 batch is `git log 2309a85..upstream/main` = **10 commits** (not 37). 26 + 10 = 36, plus the catch-up merge commit = 37. That is the number in the request.
- Those 10 commits are **already implemented in the working tree but never committed**: 1,639 insertions across 23 tracked files plus 38 untracked files, built 2026-09-27. `linux/compatibility-gap-progress.md` records G01–G12 implemented with 425 passing tests, and `linux/upstream-parity.json` already pins several overrides to upstream 1.3.4.

So the catch-up is not a build task. It is a **prove-and-land task**: turn 61 dirty paths into a reviewed commit, and answer the request's "list the commits" literally with a commit-by-commit ledger.

The second half of the request is real, unfixed work: **tool combinations must behave as they do in the macOS original.** The reported example is text selection + gradient. Inspection today found a concrete, load-bearing defect in the Qt shell.

### 2. Part A — commit-by-commit upstream ledger (deliverable)

Produce `docs/upstream-1.3.4-ledger.md`: one row per upstream commit in `2309a85..c28f827`, with the upstream subject, the Linux artifact that covers it, and how it was verified. Row for row, no gaps. This is the "list" the request asks for, and it is the artifact a reviewer uses to decide whether Part B is safe to start.

### 3. Part B — the tool-transition contract (the reported bug)

**The defect.** Upstream has one authority for tool changes:

`Compositor/Document/EditorSession.swift:334` — `selectTool(_:)`:
- `if tool != value, !finishText() { return }` — a failed text commit **refuses the switch**.
- `if tool != value { commitTransform(); cancelCrop(); resolveGradient(); cancelLasso(); cancelShape() }` — a tool change resolves every other pending tool draft.

The Qt shell reimplements this lossily at `host/SessionWindow.cpp:4101`:

```cpp
if (m_tool == Tool::Type && tool != Tool::Type && m_textEditor && m_textEditor->isVisible()) {
    sendCommandQuiet({{"action", "textFinish"}});   // errors swallowed
    syncTextEditor();
    refreshImage();
}
m_tool = tool;                                       // set unconditionally
... sendCommand({{"action", "selectTool"}, ...});    // session may refuse; nobody notices
```

Four concrete failures follow:

1. **Commit skipped when the inline editor is not visible.** The gate is `m_textEditor->isVisible()`, but the real state is the session's `textDraft`. Headless/offscreen runs, a lost focus, or a draft opened through a non-editor path all leave `textDraft != nil` while this branch is skipped.
2. **Refusal is not modelled.** Upstream stops the switch when `finishText()` fails (locked/hidden layer, `canEditLayers == false`). Qt switches anyway, so the rail, options bar and status telemetry show a tool the session is not using.
3. **The failure is swallowed.** `sendCommandQuiet` discards the error, so the user gets a silent half-state instead of a message.
4. **Repair path re-enters the same code.** `syncToolFromSession` (`host/SessionWindow.cpp:6625`) detects the mismatch and calls `setTool` again on a queued connection, which re-runs the `textFinish` path and re-sends `selectTool`. The rail flickers and the commit path runs twice.

The reported example is exactly case 2: text editing with a live selection, then the Gradient tool. `Sources/LinuxBridge/UpstreamEditor.swift:506` does `if s.tool != .gradient { s.selectTool(.gradient) }` and then `s.beginGradient(at:)`, whose own guard is `tool == .gradient`. When `selectTool` bails, the drag fails with "gradient could not start" while the rail already shows Gradient. When the commit succeeds, the sequence runs a redundant second `selectTool` first.

**The fix, in order of blast radius:**

- **B1 (required).** Split `SessionWindow::setTool` into two functions: `applyToolLocally(Tool)` that only updates `m_tool`, the action check state, the options bar and telemetry, and `requestTool(Tool)` that is the single user-intent entry point. `syncToolFromSession` calls `applyToolLocally` only, never `requestTool` — this removes the re-entrancy in failure 4.
- **B2 (required).** `requestTool` decides whether a commit is owed by reading the session state's `textDraft`, not `m_textEditor->isVisible()`. Send the commit with `sendCommand` (not `sendCommandQuiet`) and, when it fails, do not switch: call `applyToolLocally(sessionTool)`, surface `brushError`, and return.
- **B3 (required).** After sending `selectTool`, reconcile `m_tool` from the returned `sessionState()["tool"]` rather than assuming the switch happened.
- **B4 (required).** `Sources/LinuxBridge/UpstreamEditor.swift:506` — when `selectTool` cannot take effect (a text commit failed), fail the `gradientBegin` command with `brushError` instead of falling through to a misleading "gradient could not start". Same treatment for `shapeBegin` at line 517.
- **B5 (verify, fix if wrong).** Upstream `selectTool` seeds `cropRect` from the current selection's bounds with the comment "C, then Return, crops to it". Qt seeds `m_pendingCropRect` from the whole canvas. Confirm the selection + crop combination matches; fix on whichever side is wrong.
- **B6 (systematic).** Today's checks cover individual tools. The reported class is *transitions*. Add a native journey that walks every ordered pair of the 15 tool families, plus each tool's own mode cycle, and after each transition asserts: the settled session tool equals the rail tool; a live `textDraft` was committed or the switch was refused with a message; pending gradient, shape, lasso and crop drafts were resolved or cancelled exactly as upstream's `selectTool` does. This is what makes "works like a commercial app" mechanical instead of a judgement call.

Not in this part: rewriting the Qt rail as a pure view of session state. That is the architecturally cleaner end state (B1 moves toward it) but it is a larger change and should be a separate decision after B1–B4 land.

### 4. Part C — verification gates

Part A cannot be committed until these pass on the working tree as it stands:

1. `sh scripts/check-upstream-clean.sh` — protected `Compositor/` and `CompositorTests/` match upstream `2309a85`; every generated override is fresh.
2. Full Swift suite in release: 425 tests in 75 suites, with the six documented skips from `linux/UPSTREAM_TEST_EXCLUSIONS.md`. Record pass/fail counts as separate metrics.
3. Rebuild `build/lib/libCompositorQtImageIO.so` (`scripts/build-qt-imageio.sh`) and the release `CompositorHostBootstrap`, then re-run every native journey: `--package-smoke`, `--preview-smoke`, `--save-smoke`, `--dialog-smoke`, `--color-range-smoke`, `--text-backend-smoke`, `--interchange`.
4. `git diff --check` clean.

Part B adds:

5. The new tool-transition journey from B6 passes, and each of B1–B5 has at least one assertion that fails on the current tree and passes after the fix.
6. `--preview-smoke` still passes unchanged (it already covers mask/pixel drags, format-11 save/reopen and native text undo).

Commit structure: Part A as one commit (the catch-up), Part B as a second (the tool contract), so a bisect can separate them.

### 5. What already exists (do not rebuild)

- The whole 1.3.3 baseline, merged at `290bf5e`.
- G01–G12 implemented with named test suites and native smoke journeys, per `linux/compatibility-gap-progress.md`.
- `scripts/check-upstream-clean.sh`, `linux/upstream-parity.json`, the generator freshness checks, and `linux/patches/{color-range,text-format-11}.patch`.
- `syncToolFromSession` and the tool-name mapping already exist; B1–B3 restructure them rather than adding a parallel mechanism.
- `linux/interchange-verification.md`, `docs/linux-gap-feasibility-2026-09-27.md` — the evidence base for the ledger.

### 6. NOT in scope

- Any edit to `Compositor/` or `CompositorTests/`. Both stay byte-identical to upstream.
- The V01–V07 validation backlog from `docs/linux-gap-feasibility-2026-09-27.md` (Gaussian Undo assertions, Inner Glow in the opt-in Skia tier, very large PSB, segmentation quality, tablet/Wayland/RAW portals, excluded-test mapping, sustained input backlog).
- A real macOS→Linux→macOS interchange run. `--interchange` produces the fixture and verifies retention; no Mac execution is claimed.
- Rewriting the Qt tool rail as a fully session-driven view (see Part B, end state).
- Pushing anything to `origin/GNU_Linux`.

### 7. Failure modes and rescue

| Failure | Detection | Response |
|---|---|---|
| Protected tree drift | `check-upstream-clean.sh` non-zero | Stop. Restore the tree, do not commit. |
| Generated override stale | freshness check in the same script | Re-run the generator, then re-run the affected suite. |
| Part A suite regresses vs. the 425 baseline | test count differs | Do not commit. Identify the suite, fix or document as an exclusion with a reason. |
| `libCompositorQtImageIO.so` stale | smoke journey finds no font metrics / SVG | Rebuild via `scripts/build-qt-imageio.sh` before trusting any smoke result. |
| B2 breaks interactive tool switching | the B6 journey's rail-vs-session assertion | Revert B2 alone; B1 and B3 are independent and safe to keep. |
| B6 flaky across tool pairs | non-deterministic settle window | Assert on a settled state with a bounded poll, never a fixed sleep. |

## Review record

Filled in by the review phases.
