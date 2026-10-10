# TODOS (collected by /autoplan, 2026-09-21; proposed, review before relying on)

- **Colour management**: ICC profiles, bit depth, blend space, export profiles. Deferred by CEO phase (R30 only states assumptions). Needs owner input. Depends on: R51 pixel contract.
- **Command palette**: Qt host Command Palette (`Ctrl+Shift+P` / `F1`) implemented with fuzzy action search, keyboard navigation, and smoke verification. (DONE)
- **Finger-touch large-target mode**: larger hit areas when touch is used. Deferred by design phase.
- **Crash-recovery autosave implementation (R61)**: Periodic background autosave snapshot (`autosave.comp` + `autosave.info`), startup recovery check, recovery restore, and clean shutdown clearing implemented and smoke verified. (DONE)
- **HEIC and TIFF import**: separately gated after decoder hardening (R56).
- **Research-risk features** (Content-Aware Fill, Remove Background, Liquify, Lens Correction, Healing): need their own decision per R6.
- **Cancelled new adjustment sheet discard (R26)**: Discard/undo newly created adjustment layer on dialog rejection implemented and smoke verified. (DONE)
- **Layers tree multi-selection (R22)**: `ExtendedSelection` in `m_layersView` + multi-layer selection deletion implemented and smoke verified. (DONE)
- **Stage 4 & 5 (CoreGraphicsCompat Shim & Skia Raster Backend)**: 100% complete (`3d617c7`, `39f1d88`, `02a8178`, `835a7f0`). 22 canvas ops mapped to Skia C ABI, dynamic `.so` loader, comprehensive parity tests passing, `COMPOSITOR_RENDERER=skia|swift` env switch verified.
- **README / Manifest alignment**: Resolved (updated README to KDE 6.11 and swift6//26.08 matching `com.compositor.Client.yaml`).
- **All Stages 0 - 12 verification**: 100% green (426/426 Swift tests, 6/6 CTest tests, 5/5 Qt smoke test modes).

## Linux port: upstream catch-up and tool combinations (from /autoplan 2026-10-09)

### Linux `swift test` CI job
**What:** Add a workflow next to `.github/workflows/ci-guard.yml` that runs `ToolCombinationTests`, `EffectsRecolorParityTests` and `UpstreamEditorTests` in the Flatpak Swift SDK.
**Why:** The tool-combination contract only holds if something runs it on every push; today no workflow runs Linux Swift tests.
**Context:** ci-guard runs only `check-upstream-clean.sh` and the audit. Swift builds only in the Flatpak SDK (see memory linux-port-swift-sandbox-verify).
**Effort:** M
**Priority:** P2
**Depends on:** commits 1 and 4 of docs/upstream-1.4.8-catchup-and-tool-combos-2026-10-09.md

### Table-driven Qt accelerators
**What:** Build Qt `QAction` shortcuts from the generated `KeyboardShortcuts` table instead of hard-coded `QKeySequence`s in `host/SessionWindow.cpp`.
**Why:** Shortcuts re-recorded in Settings don't change Qt accelerators; the key-parity smoke only catches defaults.
**Context:** ~77 hard-coded sites. Recorded as a deviation in `linux/upstream-parity.json`.
**Effort:** L
**Priority:** P3
**Depends on:** gen-keyboard-shortcuts.py

### Tool rail as a pure view of session state
**What:** Make the Qt rail render only from `sessionState().tool` with no local tool state.
**Why:** Structurally prevents "rail shows X, session in Y".
**Context:** Trigger: the first `--combo-smoke` rail/session mismatch. `applyToolLocally` already mirrors; the rewrite removes `m_tool` as authority.
**Effort:** L
**Priority:** P3
**Depends on:** --combo-smoke

### Retire remaining hand overrides behind AppKit/Metal
**What:** Convert NativeLayerListOverride, UIStandIns, CameraRawSlider, MetalBrushCoverage to generated or tip-compiled forms where the compat layer allows.
**Why:** Every hand override needs drift policing; generated ones don't.
**Context:** ContentView, LayerMaskMenu and KeyboardShortcuts move to generators in this plan.
**Effort:** XL
**Priority:** P4
**Depends on:** compat-layer AppKit coverage

### Codex outside review for this plan
**What:** Re-run the CEO/Design/DX/Eng outside voices once the Codex quota resets (2026-10-14 13:55).
**Why:** Every phase of the 2026-10-09 autoplan ran single-voice; no cross-model confirmation.
**Context:** Plan: docs/upstream-1.4.8-catchup-and-tool-combos-2026-10-09.md.
**Effort:** S
**Priority:** P3
**Depends on:** quota reset
