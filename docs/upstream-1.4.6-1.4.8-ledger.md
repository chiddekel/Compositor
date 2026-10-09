# Upstream 1.4.6–1.4.8 catch-up ledger

Branch: `GNU_Linux`. Previous catch-up tip: `11d8d7a` (Compositor **1.4.5** feed). New tip: `22c7b8d` (`upstream/main`, Compositor **1.4.8**).

Range: `git log --no-merges 11d8d7a..22c7b8d` — **54 commits**. Protected trees match `upstream/main` (`check-upstream-clean.sh`). Merge: `Merge upstream/main (Compositor 1.4.8)`.

Constraint: do not hand-edit product logic inside `Compositor/` / `CompositorTests/` after sync. Linux gaps stay in `Sources/`, `host/`, generators, and overrides.

This pass is **merge-first**: tip trees are clean; full Navigator / Scanlines / Export PDF / Command Palette UX ports are **follow-up**, not claimed here.

## Classification

| Bucket | Meaning |
| --- | --- |
| **Port** | User-visible; implement on Linux (compat / overrides / host) — **not done in this pass** unless noted |
| **Inherit** | Lands by advancing protected trees; Linux consumes via UpstreamCore / kernels when wired |
| **Adapter** | Platform API (Sparkle feed, Mac packaging) — Linux uses Flatpak / own update path |
| **Docs/meta** | README, version bumps, Xcode/test splits, merge noise |
| **Not ported** | Tip behavior exists upstream; Linux still on prior UX / override / Qt path |

## Themes for the next port pass

| Upstream theme | Examples | Linux follow-up |
| --- | --- | --- |
| Navigator minimap | `NavigatorMinimap`, `NavigatorGeometry`, canvas corner from 300% | Qt canvas overlay or defer |
| Scanlines / Dither | Filter sheets + tests; README filter list | C kernel / filter sheet wiring |
| Export As (PNG/JPEG/PDF) | `ExportAsSheet` (replaces JPEG-only sheet) | Qt export dialog + PDF path; keep `JPEGExportSheet` override until then |
| Command palette / shortcuts | `CommandPalette`, F / ⌘F / ⌃⌘F remaps, Canvas Only | Shell command palette + key map |
| Layers / dialog polish | footer colors, Don’t Save, rename field, reveal selection | Qt Layers panel / message boxes |
| Camera Raw | color noise, Shadows/Highlights order, RAW 8-bit dither | Upstream through existing CR path if ABI-stable |
| New Canvas / canvas-only | units/DPI/fill pills, F fullscreen / Canvas Only | Qt New Canvas + view modes |
| Rotate canvas | Image › Rotate 90° CW/CCW | Menu + session command wiring |
| Last Filter | Filter › Last Filter (⌃⌘F on tip) | Menu + session last-filter state |

## Commit ledger (`11d8d7a..22c7b8d`)

| Upstream | Subject | Linux disposition |
| --- | --- | --- |
| `cb139a1` | Command palette (⌥⌘P): search every menu command and tool | Not ported — CommandPalette* Mac UI |
| `6490bb3` | Navigator above the Layers panel | Not ported — panel layout / Qt docks |
| `a2718d9` | Camera Raw color noise: clear pixels unsaturated | Inherit (CR path) / verify ABI |
| `0415aa4` | Filter › Last Filter (⌘F) | Not ported — shortcut later remapped; menu wiring |
| `9287cf1` | File > Export PDF | Not ported — Export As supersedes |
| `07eee7e` | Slider snap test draws slider before press | Docs/meta (excluded Mac test) |
| `b0b4f01` | New Canvas in inches, cm or mm, at 72 or 300 DPI | Not ported — Qt New Canvas |
| `ab9779a` | New Canvas: transparent, white or black, pill settings | Not ported |
| `a00d8b6` | New Canvas always starts transparent, pixels, 72 DPI | Not ported |
| `e7e295e` | Color Overlay recolors translucent pixels fully | Inherit effects |
| `f25effa` | Layer effects button: "Add layer effect" | Port — Qt layers footer label |
| `9cb57db` | Inner Glow / Inner Shadow translucent recolor | Inherit effects |
| `710dd66` | Edit menu without macOS text extras | Adapter / CompositorApp regen |
| `6345432` | RAW imports round to 8 bits with fine noise | Inherit RAW / dither kernels |
| `0907f51` | RAW develop sheet shows Importing… | Port — Qt RAW sheet status |
| `196342c` | RAW import rounds in C (perf) | Inherit kernels |
| `754f188` | Image › Rotate Canvas 90° CW/CCW | Not ported — menu + session |
| `384632d` | Command palette on F, centered | Not ported |
| `231b7d3` | Command palette: keep three tests | Docs/meta |
| `07b8b1e` | Command palette: tools/modes, Return runs row | Not ported |
| `94b57f7` | Command palette: F anywhere, masks, ranking | Not ported |
| `bba92dc` | One View › Snap; palette shows toggles | Port partial — Snap; palette Not ported |
| `42a559b` | Camera Raw Color noise keeps brightness | Inherit CR |
| `ad4bddf` | Canvas Only (F); palette on ⌘F | Not ported |
| `75f3556` | README: command palette ⌘F, Canvas Only F | Docs/meta |
| `088a5c1` | Canvas Only covers rim/corners; narrower palette | Not ported |
| `e64f749` | Compositor 1.4.6 | Docs/meta |
| `6e6ca38` | RawDitherTests type-check split | Docs/meta |
| `fa41b9b` | Publish update feed for 1.4.6 | Adapter |
| `6b81d4a` | Last Filter on ⌃⌘F; ⌘F is command palette | Not ported — key map |
| `720c121` | Toggle Fullscreen on F and Esc; Search Commands ⌘F | Not ported |
| `c0a1cd0` | Hand stays closed for whole Space/Hand pan | Port — Qt canvas cursor |
| `7fb40a9` | Layers footer buttons use primary color | Port — Qt Layers footer |
| `283d360` | Don’t Save marked destructive | Port — Qt unsaved dialog |
| `8f7d344` | LayerCell rename: same size, layer background | Port — Qt layer rename |
| `68396ff` | Tool headers scroll when window narrow | Port — Qt tool headers / Inherit SwiftUI headers |
| `790195f` | Disabled Layers footer buttons dim like menus | Port — Qt Layers footer |
| `675d8a4` | Compositor 1.4.7 | Docs/meta |
| `af30c45` | Publish update feed for 1.4.7 | Adapter |
| `d2b8aaf` | Reveal selected layers in the Layers panel | Port — Qt Layers reveal |
| `0b4c56c` | Camera Raw Shadows/Highlights keep tone order | Inherit CR |
| `4e035bf` | Don’t Save matches Cancel; Save is colored | Port — Qt unsaved dialog |
| `cea9083` | README: translations on hold | Docs/meta |
| `b4e147b` | Layers panel reveal: no separate test file | Docs/meta |
| `06313a9` | Layers panel doesn’t flash gray for brief work | Port — Qt Layers busy/paint |
| `450af5f` | File › Export As… PNG, JPEG or PDF | Not ported — still `JPEGExportSheet` override |
| `b1db93d` | Export As previews transparency on checkerboard | Not ported |
| `06c3a22` | Filter › Scanlines | Not ported — filter + kernel |
| `1187736` | Scanlines: displacement, Dots by tone | Not ported |
| `cdde327` | Scanlines on solids: Black Level, glow | Not ported |
| `e1a5210` | README lists Dither and Scanlines | Docs/meta |
| `3e09948` | Navigator minimap from 300% zoom | Not ported — `NavigatorMinimap` |
| `24ef288` | Version 1.4.8 | Docs/meta |
| `22c7b8d` | Publish update feed for 1.4.8 | Adapter |

## Implementation on `GNU_Linux` (this pass)

1. Merge `upstream/main` (`22c7b8d`); protected `Compositor/` + `CompositorTests/` byte-identical to tip.
2. Move Linux Show Controls Free Transform arming out of protected `TransformInspector.swift` into `Sources/Overrides/TransformInspector.swift`; exclude tip UI path in `Package.swift`; record in `linux/upstream-parity.json`.
3. Regenerate Color Range / Smudge / CompositorApp / project-validation / preview-renderer / text-format-11 generators from tip.
4. Compile adapters only (not full UX ports): `NavigatorGeometry` excluded from `CompositorKernels`; tip `ExportAsSheet` symlinked; `ShellProjects.exportAs` → PNG/JPEG/PDF shell requests; `CommandPaletteController` stand-in; New Canvas `onCreate` resolution/background; SwiftUI/CoreImage/CoreGraphics stubs (`isEnabled`, `AnyShapeStyle`, `interactiveDismissDisabled`, `RGBAh`/`RGBA16`/`workingFormat`, `CGDataConsumer` PDF); `toggleCanvasOnly` on the Linux app-delegate stand-in.
5. Do **not** claim Navigator, Scanlines, Export As/PDF, or Command Palette Linux UX in this pass.
6. Gates: `UPSTREAM_REF=upstream/main sh scripts/check-upstream-clean.sh` → `UPSTREAM CLEAN`; `CompositorHostBootstrap --session-smoke` (release, offscreen) green.

## Explicitly out of scope (still open)

- Full Navigator / Scanlines / Export PDF / Command Palette ports.
- Flatpak alpha.11 / GitHub Latest badge bump.
- Editing protected trees for Linux-only fixes.

## Evidence

Fetched for catch-up: `upstream/main` at `22c7b8d` (tags `v1.4.6`–`v1.4.8`). Prior Linux merge of 1.4.5: `4b5fb23`.
