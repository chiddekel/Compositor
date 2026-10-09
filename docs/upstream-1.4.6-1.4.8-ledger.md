# Upstream 1.4.6–1.4.8 catch-up ledger

Branch: `GNU_Linux`. Previous catch-up tip: `11d8d7a` (Compositor **1.4.5** feed). New tip: `22c7b8d` (`upstream/main`, Compositor **1.4.8**).

Range: `git log --no-merges 11d8d7a..22c7b8d` — **54 commits**. Protected trees match `upstream/main` (`check-upstream-clean.sh`). Merge: `Merge upstream/main (Compositor 1.4.8)`.

Constraint: do not hand-edit product logic inside `Compositor/` / `CompositorTests/` after sync. Linux gaps stay in `Sources/`, `host/`, generators, and overrides.

Full UX port pass (1.4.6–1.4.8 Port / Not ported rows) landed on Linux below. Docs/meta and Adapter (Sparkle) remain skipped.

## Classification

| Bucket | Meaning |
| --- | --- |
| **Port** | User-visible; implement on Linux (compat / overrides / host) |
| **Inherit** | Lands by advancing protected trees; Linux consumes via UpstreamCore / kernels when wired |
| **Adapter** | Platform API (Sparkle feed, Mac packaging) — Linux uses Flatpak / own update path |
| **Docs/meta** | README, version bumps, Xcode/test splits, merge noise |
| **Done** | Ported on GNU_Linux (this pass or earlier) |
| **Not ported** | Tip behavior exists upstream; Linux still on prior UX / override / Qt path |

## Themes (port pass status)

| Upstream theme | Linux status |
| --- | --- |
| Navigator minimap | **Done** — `NavigatorMinimap` symlinked; Qt canvas overlay ≥300% when View › Navigator on |
| Scanlines / Dither | **Done** — tip FilterSheet + `CompositorDitherKernel` (serial glow); menu opens floating sheet |
| Export As (PNG/JPEG/PDF) | **Done** — tip `ExportAsSheet` via shell; PDF also via `exportPDF`; `JPEGExportSheet` kept as smoke fallback |
| Command palette / shortcuts | **Done** — Qt palette with tip fuzzy ranking; ⌘F / `commandPalette` shell; Canvas Only on F / Esc |
| Layers / dialog polish | **Done** — FooterIcon + isEnabled; rename field layer background; reveal without scroll spam; Don’t Save / Save accent |
| Camera Raw | **Inherit** — tip CR + Importing… via RawDevelopSheet |
| New Canvas / canvas-only | **Done** — tip NewCanvasSheet (units/DPI/fill); Canvas Only hides chrome + black surround |
| Rotate canvas | **Done** — tip AppMenus Image › Rotate |
| Last Filter | **Done** — tip Filter › Last Filter on ⌃⌘F; ⌘F is Search Commands |

## Commit ledger (`11d8d7a..22c7b8d`)

| Upstream | Subject | Linux disposition |
| --- | --- | --- |
| `cb139a1` | Command palette (⌥⌘P): search every menu command and tool | **Done** — Qt `CommandPaletteDialog` (tip ranking); menus call shell |
| `6490bb3` | Navigator above the Layers panel | Docs/meta layout note — minimap is canvas overlay (tip 3e09948), not a dock |
| `a2718d9` | Camera Raw color noise: clear pixels unsaturated | Inherit (CR path) |
| `0415aa4` | Filter › Last Filter (⌘F) | **Done** — remapped; menu via AppMenus (⌃⌘F) |
| `9287cf1` | File > Export PDF | **Done** — `exportPDF` shell + `ImageExporter.pdfData`; Export As also writes PDF |
| `07eee7e` | Slider snap test draws slider before press | Docs/meta (excluded Mac test) |
| `b0b4f01` | New Canvas in inches, cm or mm, at 72 or 300 DPI | **Done** — tip NewCanvasSheet on Welcome |
| `ab9779a` | New Canvas: transparent, white or black, pill settings | **Done** |
| `a00d8b6` | New Canvas always starts transparent, pixels, 72 DPI | **Done** |
| `e7e295e` | Color Overlay recolors translucent pixels fully | Inherit effects |
| `f25effa` | Layer effects button: "Add layer effect" | **Done** — tip LayersPanel label |
| `9cb57db` | Inner Glow / Inner Shadow translucent recolor | Inherit effects |
| `710dd66` | Edit menu without macOS text extras | Adapter / CompositorApp regen |
| `6345432` | RAW imports round to 8 bits with fine noise | Inherit RAW / dither kernels |
| `0907f51` | RAW develop sheet shows Importing… | **Done** — tip RawDevelopSheet |
| `196342c` | RAW import rounds in C (perf) | Inherit kernels |
| `754f188` | Image › Rotate Canvas 90° CW/CCW | **Done** — tip AppMenus |
| `384632d` | Command palette on F, centered | **Done** — F is Canvas Only; palette ⌘F; dialog sized 460×290 |
| `231b7d3` | Command palette: keep three tests | Docs/meta (excluded until Mac UI compiles) |
| `07b8b1e` | Command palette: tools/modes, Return runs row | **Done** — Qt list Return / double-click |
| `94b57f7` | Command palette: F anywhere, masks, ranking | **Done** — tip-style fuzzy tiers in `SessionDialogs` |
| `bba92dc` | One View › Snap; palette shows toggles | **Done** — Snap menu + palette checkmarks |
| `42a559b` | Camera Raw Color noise keeps brightness | Inherit CR |
| `ad4bddf` | Canvas Only (F); palette on ⌘F | **Done** — host chrome hide + `setCanvasOnly` |
| `75f3556` | README: command palette ⌘F, Canvas Only F | Docs/meta |
| `088a5c1` | Canvas Only covers rim/corners; narrower palette | **Done** — black surround; narrower dialog |
| `e64f749` | Compositor 1.4.6 | Docs/meta |
| `6e6ca38` | RawDitherTests type-check split | Docs/meta |
| `fa41b9b` | Publish update feed for 1.4.6 | Adapter |
| `6b81d4a` | Last Filter on ⌃⌘F; ⌘F is command palette | **Done** |
| `720c121` | Toggle Fullscreen on F and Esc; Search Commands ⌘F | **Done** |
| `c0a1cd0` | Hand stays closed for whole Space/Hand pan | **Done** — tip EditorCanvas + Qt cursor map |
| `7fb40a9` | Layers footer buttons use primary color | **Done** — tip FooterIcon + `isEnabled` |
| `283d360` | Don’t Save marked destructive | **Done** — Qt `DestructiveRole` |
| `8f7d344` | LayerCell rename: same size, layer background | **Done** — `LayerRenameField` plain + quaternary fill |
| `68396ff` | Tool headers scroll when window narrow | **Done** — ScrollView axes → Qt scrollbars |
| `790195f` | Disabled Layers footer buttons dim like menus | **Done** — FooterIcon opacity via `isEnabled` |
| `675d8a4` | Compositor 1.4.7 | Docs/meta |
| `af30c45` | Publish update feed for 1.4.7 | Adapter |
| `d2b8aaf` | Reveal selected layers in the Layers panel | **Done** — scroll only when active id changes |
| `0b4c56c` | Camera Raw Shadows/Highlights keep tone order | Inherit CR |
| `4e035bf` | Don’t Save matches Cancel; Save is colored | **Done** — default + accent Save |
| `cea9083` | README: translations on hold | Docs/meta |
| `b4e147b` | Layers panel reveal: no separate test file | Docs/meta |
| `06313a9` | Layers panel doesn’t flash gray for brief work | **Done** — tip `layersLookEditable` |
| `450af5f` | File › Export As… PNG, JPEG or PDF | **Done** — `exportAsSheet` + `writeExport` |
| `b1db93d` | Export As previews transparency on checkerboard | **Done** — tip sheet preview |
| `06c3a22` | Filter › Scanlines | **Done** — FilterSheet + kernel |
| `1187736` | Scanlines: displacement, Dots by tone | **Done** — tip settings |
| `cdde327` | Scanlines on solids: Black Level, glow | **Done** — Linux dither kernel serial glow |
| `e1a5210` | README lists Dither and Scanlines | Docs/meta |
| `3e09948` | Navigator minimap from 300% zoom | **Done** — canvas overlay panel |
| `24ef288` | Version 1.4.8 | Docs/meta |
| `22c7b8d` | Publish update feed for 1.4.8 | Adapter |

## Implementation on `GNU_Linux`

1. Merge `upstream/main` (`22c7b8d`); protected trees byte-identical to tip.
2. Show Controls Free Transform in Overrides; generators refreshed; PDF / `isEnabled` / Export As adapters.
3. **Port pass:** Export As end-to-end; Export PDF shell; horizontal tool-header ScrollView; Canvas Only; command palette ⌘F + ranking; Navigator overlay; layers rename/reveal/Save accent; Scanlines via tip FilterSheet + dither kernel.
4. Gates: `check-upstream-clean.sh` → `UPSTREAM CLEAN`; `CompositorHostBootstrap --session-smoke` (release, offscreen) green.

## Explicitly out of scope

- Flatpak alpha.11 / GitHub Latest badge bump.
- Editing protected trees for Linux-only fixes.
- Perfect pixel-match of Mac NSAlert chrome beyond Save / Don’t Save roles.
- Compiling tip `CommandPaletteView` / `CommandPaletteTests` (Mac `NSPanel`); Qt dialog covers UX.

## Evidence

Fetched for catch-up: `upstream/main` at `22c7b8d` (tags `v1.4.6`–`v1.4.8`). Prior Linux merge of 1.4.5: `4b5fb23`.
