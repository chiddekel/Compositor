# Current Linux compatibility inventory

Checkpoint: **2026-10-11**, `GNU_Linux` at merge `74dbacf`, protected upstream `39d1257`. The four audited upstream commits are merged; Linux adaptations and regression checks are in the working tree.

## Source coverage

The SDK-evaluated SwiftPM target contains 171 Swift files. Resolving every source symlink against the protected checkout gives the following partition of all 151 upstream Swift files:

| Consumption | Files | What this proves |
|---|---:|---|
| Unchanged upstream source | 124 | The actual target includes the protected file. |
| Generated adaptation | 20 | The target includes its declared override; separate generator checks verify the output against tip. |
| Backend replacement | 5 | The target includes a declared Linux implementation. Pixel/behavior parity requires its own tests. |
| Platform substitution | 2 | The app delegate and Sparkle user driver are deliberately supplied by Qt/LinuxBridge and Flatpak. |

The remaining 22 target files are Linux additions: 20 bridge/support/rendering files and two override additions (`Sheets.swift`, `LayerRenameField.swift`). The upstream canvas, brush cursor and sampling overlay compile unchanged; Qt hosting and event forwarding are adapters around that code. They are not replaced source files.

The C targets compile eight protected pixel-kernel files directly. The ninth, `DitherPixels.c`, is included by `linux/kernels/DitherPixelsLinux.c`, which supplies serial `dispatch_apply`. This C inventory comes from the evaluated targets and wrapper source; the new automated coverage check below covers Swift sources.

## Generated adaptations and replacements

Each row is included in the evaluated `Compositor` target. Generator equality establishes the documented source transformation, not every runtime behavior.

| Upstream file | Mode | Adaptation |
|---|---|---|
| `UI/BlendModePicker.swift` | generated | Objective-C selectors by name |
| `UI/CameraRawSlider.swift` | generated | Objective-C selectors by name |
| `Document/ColorRangeSelection.swift` | generated | serialized preview worker |
| `UI/ColorRangeSheet.swift` | generated | Linux Alt labels |
| `UI/CommandPaletteView.swift` | generated | toggle presents the Qt palette dialog |
| `CompositorApp.swift` | generated | Objective-C selector adaptation |
| `ContentView.swift` | generated | Linux patch: shell-rendered pieces, Color Range panel, body split |
| `Document/EditorSession.swift` | generated | Color Range gates |
| `Rendering/GPUCanvas.swift` | replaced | Metal renderer replaced by the Vulkan present path (opt-in); Core Graphics canvas by default |
| `Rendering/GPUNoise.swift` | replaced | Metal compute replaced by the NoisePixels.c kernels |
| `UI/IndicatorlessScrollView.swift` | generated | Linux patch: nonisolated deinit (Swift 6.3.3 SILGen crash) |
| `Rendering/InlineTextEditor.swift` | generated | Objective-C selectors by name |
| `UI/KeyboardShortcuts.swift` | generated | Linux key names (patch); selectors by name |
| `UI/LayerMaskMenu.swift` | generated | Objective-C selectors by name |
| `Rendering/MetalBrushCoverage.swift` | replaced | Metal coverage replaced by backends/brush (CPU/Vulkan); parity in BrushCoverageBackendTests |
| `Rendering/MetalLayerEffects.swift` | replaced | Metal kernels replaced by backends/effects (CPU/OpenCV/Vulkan); parity in LayerEffectsBackendTests |
| `Rendering/MetalWarp.swift` | replaced | Metal kernels mirrored on a CPU working copy; parity in WarpStroke/Smudge tests |
| `UI/NativeLayerList.swift` | generated | Objective-C selectors by name |
| `UI/ProjectTabs.swift` | generated | Objective-C selectors by name |
| `UI/ProjectWindowBridge.swift` | generated | delegate forwarding written out per callback |
| `UI/SliderSnap.swift` | generated | Objective-C swizzle replaced by a compat cell hook |
| `Document/SmudgeLiquify.swift` | generated | Exact radial-falloff cache and deferred live snapshots; queued segments retain upstream interpolation across frame budgets. Final commit uses upstream coverage and sampling unchanged. |
| `UI/RawDevelopSheet.swift` | generated | Honest explanation that lens correction is unavailable on Linux |
| `Rendering/TransformOverlay.swift` | generated | Linux patch: wider handle hit slop |
| `UI/TypeControls.swift` | generated | Objective-C selectors by name |

The Smudge/Liquify adaptation keeps bounded live dab work and small dirty snapshots. New pointer samples wait in order; resumed segments retain their original starting point, step count and interpolation. Finalization drains pending work and uses upstream’s full-image sampling and 0.05 commit spacing. `WarpTipCacheTests` compares the working stroke with unchanged upstream source. `WarpCommitParityTests` also compares committed rendering, stored assets, exact points and Undo/Redo across both modes, synchronous/sliced input, fractional tips, selection/transformed layers, repeated continuation and canvas edges. It verifies that changed targets refuse commits. All five methods (14 parameter cases) pass. The earlier eight-case, 19-issue failure remains recorded in `/tmp/compositor-warp-commit-before.log` as the regression baseline.

## Tests and native evidence

All 81 upstream test files are accounted for: 80 compile unchanged in `CompositorUpstreamTests`; `LayerTests.swift` compiles as the generated selector mirror in `LinuxOverrideTests`. The mirror generator checks that only selector expressions change. No per-test runtime skips are declared. The one `CompositorUITests` Swift file uses macOS UI automation and is not a Linux SwiftPM test target.

The final unfiltered runner at protected `39d1257` passed **869/869 framework tests** (121 XCTest; 748 Swift Testing across 122 suites), all nine source-coverage checks, native kernel/backend checks and the complete combination, preview and text journeys. No runtime tests were skipped. Required-shader integrity and protected-tree equality also pass. See [the test baseline](upstream-test-baseline.md) for scope and logs.

Before the new warp oracle checks were added, the complete release runner at protected `b2a0c45` passed **856 framework tests** (121 XCTest and 735 Swift Testing in 120 suites), then the native combination, preview and text journeys. Details and the run log are recorded in [the test baseline](upstream-test-baseline.md). The source-inventory integration separately runs nine Python coverage checks and the existing native journeys. Those nine checks are not included in the 856 framework count.

## Automated enforcement

`scripts/linux-contract-tests.sh` evaluates `swift package describe --type json` inside the SDK, then runs `scripts/check-linux-source-coverage.py` and `tests/test_linux_source_coverage.py`. Reports are retained at `.build/linux-contract-native/package-description.json` and `source-coverage.json` (or the directory selected by `COMPOSITOR_CONTRACT_NATIVE_BUILD`).

Seven injected faults and two valid controls verify the gate. The coverage check rejects missing originals, missing/undeclared overrides, original-plus-override duplicates, unaccounted platform substitutions, and missing or duplicate selector test mirrors. It uses the tracked protected checkout and the actual target description; `scripts/check-upstream-clean.sh` separately verifies that protected trees match upstream and that generators, drift and ledgers are clean.

The prior catch-up merged two upstream commits at `83a8cd5`: narrow Layers panel bounds/custom pop-up sizing and direct-child folder image imports. The 44-test import/hosting run includes both new upstream folder tests unchanged. Native mixed file/folder selection and import ordering passed in the complete runner. Native portal directory grants remain unverified. The Qt Layers dock now resizes across 222–352 points, persists its width, and feeds the unchanged upstream body. Three width-model regressions pass; the native preview verifies endpoint control containment and a pointer-driven splitter drag without document edits. Real desktop/Mac visual comparison remains unverified.

Earlier audit inputs: `/tmp/compositor-package-inventory.json` and `/tmp/compositor-source-coverage.json`. Fault-injection log: `/tmp/compositor-source-coverage-faults.log`. SDK integration log: `/tmp/compositor-source-inventory-contract.log`; all nine final checks: `/tmp/compositor-source-coverage-sdk-final.log`.


## Latest upstream changes implemented

| Commit | Upstream change | Linux implementation |
|---|---|---|
| `9a0ad3e` | Gaussian Blur Preserve Transparency, solid canvas edges, default radius 5 | Unchanged filters and sheet; compat alpha normalization and numeric bridge setting. Original FilterTests and native transparent-image toggle/commit/Undo/Redo checks. |
| `248d4d4` | RAW Noise Reduction, Lens Correction and Highlight Recovery; capabilities/defaults/reset | LibRaw noise/highlight controls reach preview and full processing. Engine capabilities and defaults feed the unchanged importer/reset logic. Lens correction stays disabled with an honest Linux explanation. |
| `23913d3` | Multi-scale PatchMatch healing and fill | Protected PatchPixels kernel replaces removed ContentFill C source in SwiftPM/CMake; checked strides and matching C/header links. Original healing/fill suites plus native seed, outside-hole, allocation-failure, no-source and stride checks. |
| `39d1257` | Texture-aware fill boundary | Current protected PatchPixels source compiles unchanged in both kernel paths. |

RAW verification uses generated Bayer DNGs through the actual LibRaw backend, covering noise/highlight pixel changes in draft/full develops, unsupported small-sensor noise and lens controls, stable dimensions/capabilities, and exact baseline preview restoration at two sizes. The native upstream sheet checks enabled controls, disabled lens explanation, Reset and Cancel. Its modified Group previously lost every child after Exposure; the compat resolver now applies modifiers to each sibling without changing stack layout, and a regression checks all five sliders, both toggles and all three buttons. The pinned LibRaw 0.22.2 OpenMP wavelet routine used an uninitialized allocation count; a one-line dependency patch initializes it in both Flatpak and local builds. Sensor dimensions, color metadata and CFA mapping remain immutable across processing so draft scaling and reset do not use LibRaw’s mutated output state.

The RAW controls are transient develop settings, so no project-format fields or version changes are needed. Lens-profile dependencies remain outside this change.

## Behavior still to verify or implement

Source accounting is complete for this checkout; the full API and feature-behavior inventory remains open. Known unresolved work includes:

- Busy/import/modal refusal recovery beyond the exercised active-brush path.
- Viewport autoscroll during layer-eye tracking: upstream calls `NSView.autoscroll(with:)`, but the current compatibility implementation returns false.
- Layers panel real desktop/Mac visual comparison; offscreen Qt endpoint containment and pointer-driven resizing pass.
- Remaining table keys/type selection and disjoint-selection semantics; basic Up/Down and Shift navigation are verified.
- Native window-manager forwarding of hosting bounds, positional/soft constraints and broader text-layout/scroll fitting.
- HDR/PQ/HLG and floating-point TIFF import, actual Mac color/project round-trip comparisons, physical touch/tablet and native Wayland verification.
- Current feature coverage of ledger references and old manual/screenshot claims, plus broader native focus/accessibility behavior.

See [TODOS.md](../TODOS.md) for the remaining closeout work. The [1.3.1 element inventory](mac-linux-parity-inventory.md) remains historical; its broad feature statuses have not all been re-audited at this tip.
