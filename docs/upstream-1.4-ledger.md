# Upstream 1.3.5–1.4 catch-up ledger

Branch: `GNU_Linux`. Previous catch-up tip: `c28f827` (1.3.4). New tip: `de442f2` (`upstream/main`, Compositor 1.4).

Range: `git log c28f827..de442f2` — **52 commits**. Protected trees advanced to match `upstream/main`.

Constraint: do not hand-edit product logic inside protected trees after sync. Linux gaps stay in `Sources/`, `host/`, generators, and overrides.

**Disposition: all user-visible behavior is portable.** Metal/Quick Look/Sparkle/Apple-silicon packaging stay API/platform adapters; canvas and tools keep working through Core Graphics / Qt / Skia. Metal source files are excluded and replaced by same-API stubs so the tip compiles; `GPUCanvasRenderer.shared` is nil so every frame uses the Core Graphics canvas.

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
| `cdf8674`…`d04f159` | GPU canvas family | Adapter — Metal excluded; CPU/CG canvas path (shared = nil) |
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
