# Upstream after 1.6.9 ledger

Branch: `GNU_Linux`. Previous tip: `a2a5812` (1.6.9). New tip: `cee4d09` (`upstream/main`).

Range: `git log --no-merges a2a5812..cee4d09` — **1 commit**. Protected trees match tip after merge. Linux gaps stay in `Sources/`, overrides, and bridges.

## Themes

| Upstream theme | Linux status |
| --- | --- |
| Remember last blank canvas size | **Done** — tip NewCanvasSheet `@AppStorage`; regenerated ContentView; SwiftUIBridge Welcome drops `onCreate` |

<!-- ledger-rows:begin -->
Code commits: **1** of 1 (rule: changes a Compositor Swift/C/header file). Docs/meta: 0; test-only: 0.

| # | Upstream | Subject | Files (consumption) | Evidence scope | Linux artifact | Evidence |
|---|---|---|---|---|---|---|
| 1 | `cee4d09` | Remember the last blank canvas size | `ContentView.swift` (generated override)<br>`EditorSession+Projects.swift` (compiled as-is)<br>`NewCanvasSheet.swift` (compiled as-is) | source/generation only | Tip NewCanvasSheet; regenerated ContentView; SwiftUIBridge Welcome without onCreate | generator checks; build:CompositorHostBootstrap |
<!-- ledger-rows:end -->

## Gates

1. `check-upstream-clean.sh` → protected trees match `upstream/main`.
2. `swift build -c release --product CompositorHostBootstrap` green.
