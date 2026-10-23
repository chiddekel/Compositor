# Upstream 1.3.5–1.4 catch-up ledger

Branch: `GNU_Linux`. Previous catch-up tip: `c28f827` (1.3.4). New tip: `de442f2` (`upstream/main`, Compositor 1.4).

Range: `git log c28f827..de442f2` — **52 commits**. Protected trees advanced to match `upstream/main`.

Constraint: do not hand-edit product logic inside protected trees after sync. Linux gaps stay in `Sources/`, `host/`, generators, and overrides.

**Disposition: all user-visible behavior is portable.** Metal → Vulkan (same-API overrides + C backends); Quick Look / Sparkle / Apple-silicon packaging stay platform adapters. Canvas target is **Metal → Skia Ganesh Vulkan** with CPU/CG failover — not “CPU forever.” Tip Metal sources are excluded; Overrides supply the Metal-named surface (`MetalBrushCoverage`, `MetalLayerEffects`, `GPUCanvasRenderer`, …).

**Parity bar (technical + UX):** every Adapter/Port solution must match Mac **look, feel, and UX** — color (sRGB), orientation, sampling sharpness, brush/warp dab response, and interaction timing — not compile-only or “half-parity” stubs. Failover paths must produce the same pixels/feel as the GPU path when the user cannot tell them apart on Mac.

## Classification

| Bucket | Meaning |
| --- | --- |
| **Port** | User-visible; implement on Linux (compat / overrides / host) |
| **Inherit** | Lands by advancing protected trees; Linux consumes via UpstreamCore / kernels |
| **Adapter** | Platform API (Metal device, Finder Quick Look packaging, Sparkle feed) — behavior preserved via portable path |
| **Docs/meta** | README, version bumps, Xcode settings, trial/merge noise |

## Commit ledger (`c28f827..de442f2`)

| Upstream | Subject | Linux disposition |
| --- | --- | --- |
| `908bed9` | Hop to the main actor on activation | Inherit |
| `158cd53` | Fix external-changes watcher warnings | Inherit |
| `c580a38` | JPEG / Canvas Size use app color picker | Port — tip sheets + session wiring |
| `ac6f309` | Export JPEG zoomable preview | Inherit JPEGExportSheet via UpstreamCore |
| `d6e3e93` / `8b1369a` | Marquee/shapes/selection snap to Snap To | Inherit Guides + session snap flags; menus via CompositorApp |
| `1c819d0` / `db5eafa` | View › Grid Settings… (+ Restore Defaults) | Port — GridSettingsSheet + ShellProjects.gridSettings |
| `250578e` | Xcode 27 project settings | Docs/meta |
| `ee68ba9` | ⌘Z while typing | Inherit / Linux native text undo |
| `38ec6f7` | macOS 26 / Apple silicon only | Adapter (packaging) |
| `1bd1df4` | Font previews in the Type bar | Port — TypeControls SwiftUI picker + tip previewFont |
| `14aad18` / `4868465` | Finder thumbnails / Quick Look preview | Adapter — ProjectStore keeps QuickLook package write |
| `aaf3dc0` | New Canvas preset sizes in More menu | Inherit NewCanvasSheet |
| `fe7a83d` / `af3b568` / PSD / Soft Light / … | Pixel / renderer fixes | Inherit |
| `cdf8674`…`d04f159` | GPU canvas family | Adapter — Metal → Vulkan/Skia Ganesh (`GPUCanvasRenderer` + `vulkan_render_rgba`); CPU/CG failover |
| `60bde4f` | Shift constrains moved pixels | Inherit EditorCanvas (Linux canvas forwards NSEvents) |
| `451281e` | Cmd-A from Layers panel selects canvas | Port — LayerTableView.selectAll stand-in |
| `2fbf14f` / `de442f2` | 1.4 + update feed | Docs/meta / Adapter |

## Implementation on `GNU_Linux`

1. Advance protected `Compositor/` + `CompositorTests/` to `de442f2`.
2. Exclude Metal GPU sources (`GPUCanvas`, `GPUNoise`, `MetalWarp`) + tip `ColorRangeSelection`; Overrides supply portable surfaces. Tip `TypeTool` / `ProjectStore` compile directly (no stale format-11 override).
3. Regenerate Color Range / Smudge / CompositorApp overrides from tip.
4. Port Grid Settings, font previews, Cmd-A layers, sheet session APIs (Canvas Size / JPEG take `session`).
5. Gates: `check-upstream-clean.sh`, release build/tests.

## Evidence

Fetched 2026-09-29: `upstream/main` at `de442f2` (v1.3.5–v1.4). Prior 1.3.4 Linux catch-up: `6e40891`, `2b8a1bc`.

---

# Upstream 1.4.1 catch-up ledger

Branch: `GNU_Linux`. Previous tip: `de442f2` (1.4). New tip: `3b50e5d` (`upstream/main`, Compositor 1.4.1).

Range: `git log de442f2..3b50e5d` — **15 commits**. Protected trees match `upstream/main`. Merge commit: `6a7f62a`.

## Commit ledger (`de442f2..3b50e5d`)

| Upstream | Subject | Linux disposition |
| --- | --- | --- |
| `133c34a` | Say why a brush can't paint; Select All then Inverse deselects | Inherit brush/selection; Port — `brushError` in session state → status bar |
| `d3170ab` | Clone Stamp and Blur paint at layer resolution | Inherit BrushStroke / clone |
| `67cc31e` | Cancel/Apply only when edit waits; scaled layers keep scale | Inherit TransformInspector / LayerTransform |
| `c8295cc` | Merge PR #162 painting-and-transform-fixes | Docs/meta |
| `b3419ab` | Mask button reveals selection; Option-click mask alone | Port — `toggleMaskAlone` in layer list; `addMask(revealing:)` from Qt footer; SwiftUI `MaskAloneBadge` override; status when `viewsMaskAlone` |
| `bca8f13` | Command flips Auto Select; Shift flips aspect lock live | Port — `HeldModifiers` + `NSEvent.applyChordModifiers` / `compositor_modifiers_changed` |
| `1faf7a0` | Tabs: drag reorder + overflow menu | Port — Qt `QTabBar` movable + `moveTab` ABI; ProjectTabs OverflowMenuAnchor → SwiftUI Menu override |
| `1318f1e` | Ungroup Layers (⇧⌘G) | Inherit LayerGroups; menus via regenerated CompositorApp; context menu Ungroup |
| `03d692c` | Drop held-Command checkbox test | Docs/meta |
| `6c3b9a5` | Ungroup in folder right-click menu | Port — NativeLayerListOverride context menu |
| `6955a6f` | Option over mask: duplicate pointer with eye | Port (partial) — Option-click alone; cursor glyph deferred |
| `686d8c7` | Move bar values apply without Apply | Inherit TransformInspector field finish |
| `c459f88` | Resize handles snap | Inherit EditorCanvas (NSEvent path) |
| `0d9986f` / `3b50e5d` | 1.4.1 + appcast | Docs/meta / Adapter |

## Implementation on `GNU_Linux`

1. Merge `upstream/main` (`3b50e5d`); link `HeldModifiers` + `ProjectTabLayout` into UpstreamCore.
2. Regenerate Color Range / Smudge / CompositorApp / text-format-11 test mirrors from tip.
3. Overrides: ProjectTabs (Menu overflow), LayerMaskMenu (SwiftUI badge), ContentView badge, NativeLayerList mask-alone + Ungroup.
4. Compat: `CGSize.applying`, `zIndex`, `NSMenu.didEndTrackingNotification`, chord → HeldModifiers.
5. Host: tab reorder, modifier flags, Option-click add mask, brushError / mask-alone status.
6. Gates: `check-upstream-clean.sh`, release `CompositorHostBootstrap` build.