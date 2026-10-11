# Outside review (Codex), 2026-10-11

The TODO "Codex outside review for this plan": the CEO / Design / DX / Engineering outside voice on
`docs/upstream-1.4.8-catchup-and-tool-combos-2026-10-09.md`, run read-only against `GNU_Linux` at `20128a5`. Its findings are
tracked in TODOS.md.

Reviewed `GNU_Linux` at `20128a5`, including the last 15 commits. **The plan’s direction was sound, but its closeout claims exceed the current evidence.** Upstream is already beyond 1.4.9; several deferred improvements have shipped.

### CEO/scope

- **Right:** Separating “merged” from “working on Linux,” preserving upstream sources, and prioritizing tool combinations directly addressed the reported problem.
- **Risk now:** The plan mixes obsolete implementation tasks with unfinished acceptance criteria. Generated UI, shortcut integration, Navigator tests, and Linux contract CI have overtaken its scope. “Zero critical gaps” describes assigned work, not verified delivery.
- **Recommend:** Add a current acceptance table to the [plan](docs/upstream-1.4.8-catchup-and-tool-combos-2026-10-09.md): delivered, superseded, missing, evidence. Reconcile [TODOS.md](TODOS.md) against that table; prioritize missing behavioral proof before additional tooling.

### Design/UX

- **Right:** Session-driven tool state, display-only Show Transform Controls, preserving editable text through Undo, and matching upstream interaction semantics are appropriate.
- **Risk now:** The final refusal contract is not implemented consistently: [SessionWindow.cpp:4062](host/SessionWindow.cpp:4062) displays command errors in the status bar, despite the plan prohibiting busy-error text there. Generated AppKit views also introduce focus, keyboard, and accessibility risks that source parity cannot establish. The recent screenshot workflow runs on macOS.
- **Recommend:** Reconcile refusal behavior explicitly, then exercise real Qt text focus, refused switches, transform controls, and Undo in [DialogJourney.cpp](host/DialogJourney.cpp). Verify layer-row accessibility through [SwiftUIQtRenderer.cpp](host/SwiftUIQtRenderer.cpp), particularly the pixel-rendered `_AppKit` table.

### Developer experience

- **Right:** Generated overrides, reproducible ledger ranges, and `COMBO_PAIR` filtering improve maintainability. Linux contract CI now exists.
- **Risk now:** The promised catch-up driver, smoke runner, and generator registry are absent; the guard still stops at its first failure. Ledger validation checks generated text, not whether evidence proves behavior. It even labels macOS UI tests “compiled as-is” in the latest ledger.
- **Recommend:** Make [check-upstream-clean.sh](scripts/check-upstream-clean.sh) report all checks and their scope. Correct consumption classification and validate evidence references in [upstream-ledger-rows.py](scripts/upstream-ledger-rows.py). Update [platform-abstraction.md](docs/platform-abstraction.md): Qt value types avoid Qt Widgets dependency, but do not make those interfaces platform-neutral.

### Engineering

- **Right:** Awaiting gradient application, generating upstream adaptations, and testing both state transitions and pixels are good foundations.
- **Risk now:** [UpstreamEditor.swift:372](Sources/LinuxBridge/UpstreamEditor.swift:372) awaits `commitGradient()` without the promised bound or a postcondition. Upstream returns immediately when project-busy; the bridge can then dispatch a guarded operation such as `addLayer` and return success despite no edit. Test coverage also overstates gestures: “moved pixels” never moves pixels; “released transform drag” sends a field-edit command. No `--combo-smoke` implementation exists.
- **Recommend:** Check gradient completion before dependent commands and test busy, slow, and failed commits. Strengthen [ToolCombinationTests.swift:93](Tests/LinuxOverrideTests/ToolCombinationTests.swift:93) with actual move/release sequences and full outside-selection pixel comparisons. Add the native journey to Linux CI. Extend protected roots to `CompositorUITests` and `Compositor.xcodeproj`; make shader verification mandatory in CI rather than optional.

### Findings to act on

1. **P1 — False-success risk after unresolved gradient commits.** Enforce completion/error propagation before dependent edits.
2. **P1 — Missing native combination proof.** Implement `--combo-smoke`; replace gesture-shaped test names with actual gesture coverage.
3. **P2 — Incomplete integrity gate.** Protect all promised upstream trees and require shader verification.
4. **P2 — Refusal UX contradicts the final contract.** Resolve status-bar behavior and test visible recovery paths.
5. **P2 — Ledger evidence can misrepresent coverage.** Distinguish compiled, mirrored, platform-only, and behaviorally verified.
6. **P3 — Stale plan and architectural claims.** Publish a concise current closeout checklist and accurate abstraction boundaries.

Read-only checks passed: four upstream-tree diffs were empty, override-drift and latest-ledger checks passed, and `git diff --check` was clean. I did not run builds, GUI journeys, or the full generator gate. No files were modified.
