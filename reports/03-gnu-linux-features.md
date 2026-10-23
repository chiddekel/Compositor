# 03 — GNU/Linux feature inventory

GNU_Linux `a13f27d`. How each upstream file is consumed on Linux comes from the build's own source-coverage audit (`.build/linux-contract-native/source-coverage.json`, written 2026-10-18 13:06 by `scripts/check-linux-source-coverage.py`).

## Source consumption

| Mode | Files | Meaning |
|---|---:|---|
| unchanged | 128 | protected upstream file compiled as is |
| generated | 20 | generated from tip by a checked generator (selectors by name / small patch) |
| replaced | 6 | Linux implementation of a Metal/GPU file |
| platform | 2 | Qt/Flatpak replacement of an AppKit/Sparkle file |

### Non-unchanged upstream files

| Upstream | Mode | Linux implementation |
|---|---|---|
| `Compositor/CompositorApp.swift` | generated | Sources/Overrides/CompositorApp.swift |
| `Compositor/ContentView.swift` | generated | Sources/Overrides/ContentView.swift |
| `Compositor/Document/ColorRangeSelection.swift` | generated | Sources/Overrides/ColorRangeSelection.swift |
| `Compositor/Document/EditorSession.swift` | generated | Sources/Overrides/EditorSession.swift |
| `Compositor/Document/SmudgeLiquify.swift` | generated | Sources/Overrides/SmudgeLiquify.swift |
| `Compositor/Rendering/InlineTextEditor.swift` | generated | Sources/Overrides/InlineTextEditor.swift |
| `Compositor/Rendering/TransformOverlay.swift` | generated | Sources/Overrides/TransformOverlay.swift |
| `Compositor/UI/BlendModePicker.swift` | generated | Sources/Overrides/BlendModePicker.swift |
| `Compositor/UI/CameraRawSlider.swift` | generated | Sources/Overrides/CameraRawSlider.swift |
| `Compositor/UI/ColorRangeSheet.swift` | generated | Sources/Overrides/ColorRangeSheet.swift |
| `Compositor/UI/CommandPaletteView.swift` | generated | Sources/Overrides/CommandPaletteView.swift |
| `Compositor/UI/IndicatorlessScrollView.swift` | generated | Sources/Overrides/IndicatorlessScrollView.swift |
| `Compositor/UI/KeyboardShortcuts.swift` | generated | Sources/Overrides/KeyboardShortcuts.swift |
| `Compositor/UI/LayerMaskMenu.swift` | generated | Sources/Overrides/LayerMaskMenu.swift |
| `Compositor/UI/NativeLayerList.swift` | generated | Sources/Overrides/NativeLayerList.swift |
| `Compositor/UI/ProjectTabs.swift` | generated | Sources/Overrides/ProjectTabs.swift |
| `Compositor/UI/ProjectWindowBridge.swift` | generated | Sources/Overrides/ProjectWindowBridge.swift |
| `Compositor/UI/RawDevelopSheet.swift` | generated | Sources/Overrides/RawDevelopSheet.swift |
| `Compositor/UI/SliderSnap.swift` | generated | Sources/Overrides/SliderSnap.swift |
| `Compositor/UI/TypeControls.swift` | generated | Sources/Overrides/TypeControls.swift |
| `Compositor/Rendering/GPUCanvas.swift` | replaced | Sources/Overrides/GPUCanvas.swift |
| `Compositor/Rendering/GPUNoise.swift` | replaced | Sources/Overrides/GPUNoise.swift |
| `Compositor/Rendering/MetalBrushCoverage.swift` | replaced | Sources/Overrides/MetalBrushCoverage.swift |
| `Compositor/Rendering/MetalCameraRawLookup.swift` | replaced | Sources/Overrides/MetalCameraRawLookup.swift |
| `Compositor/Rendering/MetalLayerEffects.swift` | replaced | Sources/Overrides/MetalLayerEffects.swift |
| `Compositor/Rendering/MetalWarp.swift` | replaced | Sources/Overrides/MetalWarp.swift |
| `Compositor/IO/CompositorApplicationDelegate.swift` | platform | Qt application composition root and LinuxBridge project/window callbacks |
| `Compositor/IO/UpdateDriver.swift` | platform | Flatpak update service replaces the Sparkle AppKit user driver |

## Linux layers

| Layer | Path | Role |
|---|---|---|
| Composition root | `Sources/CompositorHostBootstrap/hostMain.swift` | Swift `@main`, runtime bootstrap, defaults, then Qt |
| Qt shell | `host/host_run.cpp`, `host/SessionWindow.cpp` (+ dialogs, journeys) | window, header/tab bar, canvas widget, menus, docks, overlays, file panels, native journeys |
| SwiftUI → Qt renderer | `host/SwiftUIQtRenderer.cpp` | draws upstream SwiftUI render trees as Qt widgets |
| Bridge | `Sources/LinuxBridge/*.swift` | C ABI to upstream `EditorSession`, menus, panels, canvas hosting, project store |
| Apple-API compat | `Sources/Compat/{AppKit,SwiftUI,CoreGraphics,CoreImage,ImageIO,Vision,Accelerate,…}` | source-compatible stand-ins backed by Skia, Qt, OpenCV, Vulkan, LittleCMS, LibRaw |
| Overrides | `Sources/Overrides/*.swift` (28) | generated tip files and GPU replacements, drift-checked by `scripts/upstream-override-drift.py` |
| Backends | `backends/{brush,effects,coreimage,cameraraw}` | Vulkan compute + CPU kernels for brush coverage, effects, Core Image graphs, Camera Raw lookup |
| Packaging | `com.compositor.Client.yaml`, `flatpak/` | Flatpak build with vendored Skia/OpenCV/LibRaw/RawSpeed/OpenEXR, thumbnailer, MIME |

## Linux-only features (preserve)

| Feature | Evidence |
|---|---|
| Flatpak packaging, signed alpha releases, in-app Flatpak updates | `27e500f`, `host/FlatpakUpdateService.cpp` |
| RawSpeed-v3 behind LibRaw (2.4–2.5× faster CR2/NEF unpack); sensor-data preview | `6cee379`, `b2997ec` |
| Display-resolution rendering for very large documents; SIMD Lanczos | `e2180d7` |
| U²-Net-small subject segmentation bundled | `0a95226` |
| Global desktop menu where available | `2a68319` |
| SQLite-backed UserDefaults (Flatpak-safe) | `dc628e2` |
| XDG recently-used.xbel integration | TODOS.md (recent-document XML) |
| Hide Others on X11 via EWMH | `630172a` |
| Autosave and crash recovery (no upstream counterpart) | `host/SessionWindow.h:110-116,508`, `--autosave-crash-probe` |
| Shared inotify instance for project watching | `630172a` |
| Headless grab/probe hooks and native Qt journeys (contract runner) | `host/host_run.cpp`, `host/DialogJourney.cpp`, `scripts/linux-contract-tests.sh` |
| Area-averaged high-quality minification in Skia bridge | `630172a` |

## Per-feature Linux path

Codes: **M** upstream menu (`Sources/Overrides/CompositorApp.swift` generated, `Sources/LinuxBridge/AppMenus.swift`); **C** upstream canvas hosted (`Sources/LinuxBridge/UpstreamCanvas.swift`); **S** upstream SwiftUI via compat (`Sources/Compat/SwiftUI`, `host/SwiftUIQtRenderer.cpp`); **L** upstream layer list (`Sources/Overrides/NativeLayerList.swift`, NativeLowering); **R** Qt re-implementation (`host/SessionWindow.cpp` and peers); **B** backend replacement (`Sources/Overrides/Metal*.swift`, `GPUCanvas.swift`, `backends/`); **P** platform substitution (Qt codecs, LibRaw, LittleCMS, U²-Net, XDG, Flatpak); **U** unchanged upstream code

| ID | Feature | Linux path | Linux-specific notes |
|---|---|---|---|
| APP-01 | Launch into documentless window with New canvas welcome | S,R | GAP-UI-01: New Canvas preset-size menu (⋯) is invisible (resolved 6f69273) |
| APP-02 | First launch fills screen, later launches restore placement | R | — |
| APP-03 | Always-dark appearance incl. alerts and panels | S,R | — |
| APP-04 | About panel with version | R | — |
| APP-05 | Check for Updates / automatic update check | P | GAP-PLAT-04: Updates through Flatpak; installed update + relaunch unverified (resolved 585f080) |
| APP-06 | Hide Compositor | P | — |
| APP-07 | Hide Others / Show All | P | GAP-PLAT-03: Hide Others / Show All unavailable on Wayland |
| APP-08 | Quit, incl. mid-gradient or with a dialog open | M,R | — |
| APP-09 | Unsaved-changes prompt (Don't Save matches Cancel) | R | — |
| APP-10 | Window menu (Minimize, Zoom) | R | GAP-UI-09: Window menu has Minimize and Zoom only (resolved 9e21ce2) |
| APP-11 | Help menu | R | — |
| APP-12 | Open a project while the app is quit shows its window | P | GAP-VER-02: Desktop integration: .comp thumbnails absent in file managers (Flatpak exports no thumbnailers) |
| APP-13 | Title-bar free space drags the window | R | — |
| APP-14 | Canvas Only / Toggle Fullscreen (F, Esc) | M,R | — |
| APP-15 | Enter Full Screen (window) | R | — |
| APP-16 | Memory budgets for large documents (per-surface 200 MP, document total) | U | — |
| FILE-01 | New Canvas (size, units in/cm/mm, 72/300 DPI, transparent/white/black) | S | — |
| FILE-02 | New Canvas preset sizes (More ⋯ menu) | S | GAP-UI-01: New Canvas preset-size menu (⋯) is invisible (resolved 6f69273) |
| FILE-03 | Paste an image on the New canvas screen to make the canvas | S,P | — |
| FILE-04 | Open Project (.comp package) | M,P | — |
| FILE-05 | Open Recent / Clear Menu | M,P | — |
| FILE-06 | Import Images (JPEG/PNG/HEIC/TIFF/WebP/SVG/PSD/RAW/EXR/HDR) | M,P | — |
| FILE-07 | Import a folder of images as layers | P | — |
| FILE-08 | Save / Save As (.comp), keep editing while saving | M,U | — |
| FILE-09 | Export PNG | M,P | — |
| FILE-10 | Export JPEG (Export As starting on JPEG) | S | — |
| FILE-11 | Export As: PNG/JPEG first, PDF/EXR/TIFF under More, sized, previewed, color RGB/CMYK | S | — |
| FILE-12 | Export PDF (one page, matte) | S,U | — |
| FILE-13 | Close Project | M,R | — |
| FILE-14 | Project tabs: open, switch, reorder by drag, overflow menu, blank start tab, Untitled numbering | R | — |
| FILE-15 | Drop files on canvas / anywhere on tab bar to open in a new project | R,P | GAP-VER-01: Physical desktop drag and drop (between windows and applications) unverified |
| FILE-16 | Drag a layer into another / a new project (canvas sizes to it) | R | GAP-VER-01: Physical desktop drag and drop (between windows and applications) unverified |
| FILE-17 | External change reload (agents writing .comp), Revert/Keep Mine | U,P | — |
| FILE-18 | Package thumbnails / Quick Look preview | P | GAP-VER-02: Desktop integration: .comp thumbnails absent in file managers (Flatpak exports no thumbnailers) |
| FILE-19 | PSD/PSB import: folders, masks, blend modes, shapes, text, adjustments, merged-only | U | — |
| FILE-20 | PSD conversion sheet shown while reading | S | — |
| FILE-21 | Crop oversize PSD layers to the canvas | U | — |
| FILE-22 | RAW import with develop sheet (Noise Reduction, Lens Correction, Highlight Recovery) | P,S | GAP-PLAT-02: RAW Lens Correction only for files with an embedded lens profile (resolved b215842) |
| FILE-23 | RAW import › Camera Raw… opens the Camera Raw Filter | S,R | — |
| FILE-24 | SVG import | P | — |
| FILE-25 | HDR import EXR/Radiance; EXR export | P | — |
| FILE-26 | CMYK Photoshop files open; file's profile remembered | U,P | — |
| FILE-27 | Project format v13 manifest + PNG/EXR assets, validation | U | — |
| EDIT-01 | Undo / Redo with named steps; text-field undo during modal edits | M | — |
| EDIT-02 | Cut / Copy / Paste pixels (desktop clipboard) | M,P | — |
| EDIT-03 | Copy Merged | M | — |
| EDIT-04 | Copy/paste whole layers and folders within and between projects | M,P | — |
| EDIT-05 | Fill with Foreground / Background color | M | — |
| EDIT-06 | Clear Selection Pixels | M | — |
| EDIT-07 | Content-Aware Fill (multi-scale PatchMatch, past layer edges) | M,U | — |
| EDIT-08 | Keyboard Shortcuts editor (search, record, clear, conflicts, Restore Defaults) | S | GAP-UI-04: Badged and unmapped SF Symbols render as empty squares in panels (resolved 6f69273) |
| EDIT-09 | Edit menu without macOS text extras | M | — |
| VIEW-01 | Search Commands / command palette (menus, tools and modes, ranking, toggles shown) | R | GAP-UI-08: Command palette is a Qt re-implementation with small UX differences (resolved c5ed205) |
| VIEW-02 | Fit Canvas / Actual Pixels / Zoom In / Zoom Out / stepped keyboard zoom | M,S | — |
| VIEW-03 | Navigator minimap from 300% | S,R | — |
| VIEW-04 | Pixel grid from 800% | C | — |
| VIEW-05 | Show Transform Controls (Ctrl+H) | M | — |
| VIEW-06 | CMYK Proof Colors / Gamut Warning on canvas | M,P | — |
| VIEW-07 | CMYK proof/gamut pills at canvas foot (profile name, close button) | R | GAP-UI-03: CMYK Proof / Gamut Warning pills are not shown on the canvas (resolved 6f69273) |
| VIEW-08 | CMYK profile choice / Load Profile… | M,P | GAP-PLAT-05: No CMYK profile ships with the Linux build (resolved 43f3112) |
| VIEW-09 | Rulers, guides from rulers, layout grid, Show Grid/Guides | R,C | — |
| VIEW-10 | Grid Settings (color, style, opacity, spacing, subdivisions, Restore Defaults) | S | — |
| VIEW-11 | Snap and Snap To (guides, grid, layers, document bounds); Control bypasses | M,C | — |
| VIEW-12 | Lock Guides / Clear Guides | M | — |
| VIEW-13 | Sharp downsampling when zoomed out; marching ants from screen outline | C,B | — |
| VIEW-14 | Mask-alone view badge | R | — |
| VIEW-15 | Status bar: zoom, size, color, per-tool hints, busy/importing progress | S | — |
| VIEW-16 | Trackpad pinch zoom; middle-drag pan; Ctrl/Cmd+middle-drag zoom | C,P | GAP-VER-03: Physical touch, pen, trackpad and native Wayland input unverified |
| VIEW-17 | GPU-drawn canvas frames (Metal); CPU fallback | B | GAP-PERF-01: Canvas composited on the CPU instead of upstream's GPU canvas (within budget) |
| VIEW-18 | 16-bit layers on canvas at 16 bits, dithered to screen | B | GAP-PERF-01: Canvas composited on the CPU instead of upstream's GPU canvas (within budget) |
| SEL-01 | Select All / Deselect / Inverse | M | — |
| SEL-02 | Layer's Pixels / Mask's Black Areas / Ctrl-click thumbnail loads selection | M,L | — |
| SEL-03 | Select Subject | M,P | GAP-PLAT-01: Object selection / Select Subject / Remove Background use U²-Net instead of Apple Vision |
| SEL-04 | Color Range (eyedroppers add/remove, Fuzziness, Invert, live selection) | S | GAP-UI-04: Badged and unmapped SF Symbols render as empty squares in panels (resolved 6f69273) |
| SEL-05 | Expand / Contract / Feather (menu prompt + options bar) | M,S | — |
| SEL-06 | Selection modes New/Add/Subtract; Shift/Alt live in bar | S,C | — |
| SEL-07 | Move outline / move or duplicate selected pixels (Ctrl-drag, Ctrl-Alt-drag), Shift line, nudge | C | — |
| SEL-08 | Marching ants | C | — |
| IMG-01 | Curves (points, channels, Reset, preview) | S | — |
| IMG-02 | Levels (histogram, eyedroppers, Auto, presets, preview) | S | — |
| IMG-03 | Hue/Saturation (ranges, targeted hand, colorize, colored tracks) | S | GAP-UI-04: Badged and unmapped SF Symbols render as empty squares in panels (resolved 6f69273) |
| IMG-04 | Black & White | S | GAP-UI-02: Filter/adjustment slider titles are clipped at 60 pt (resolved 6f69273) |
| IMG-05 | Color Balance | S | GAP-UI-02: Filter/adjustment slider titles are clipped at 60 pt (resolved 6f69273) |
| IMG-06 | Exposure | S | — |
| IMG-07 | Gradient Map | S | — |
| IMG-08 | Grain | S | GAP-UI-02: Filter/adjustment slider titles are clipped at 60 pt (resolved 6f69273) |
| IMG-09 | Invert / Invert Mask | M | — |
| IMG-10 | Canvas Size (anchor, relative, extension color) | S | — |
| IMG-11 | Image Size (units, resolution, resample, sampling) | S | — |
| IMG-12 | Trim (based on, trim away sides) | S | — |
| IMG-13 | Rotate Canvas 90° CW/CCW, Flip Canvas H/V | M | — |
| IMG-14 | Convert layer 8↔16 bit; HDR → 16-bit | L | — |
| FLT-01 | Gaussian Blur (Preserve Transparency, solid canvas edges) | S,B | — |
| FLT-02 | Motion Blur | S,B | — |
| FLT-03 | Progressive Blur (linear/radial, drag points on canvas) | S,B | — |
| FLT-04 | Add Noise | S,B | — |
| FLT-05 | Vignette (round, empty layer across canvas) | S,B | GAP-UI-02: Filter/adjustment slider titles are clipped at 60 pt (resolved 6f69273) |
| FLT-06 | Bloom / Glow | S,B | — |
| FLT-07 | Dither (styles, pixel shape, ASCII) | S,B | — |
| FLT-08 | Scanlines (CRT: displace, threshold, dots, color split, glow) | S,B | GAP-UI-02: Filter/adjustment slider titles are clipped at 60 pt (resolved 6f69273) |
| FLT-09 | Tonal Contrast | S,B | — |
| FLT-10 | Lens Correction | S,B | GAP-UI-02: Filter/adjustment slider titles are clipped at 60 pt (resolved 6f69273) |
| FLT-11 | Camera Raw Filter (light, color, grading, curves, mixer, detail, optics, geometry, calibration, scopes) | S,B | GAP-UI-06: Camera Raw histogram/vectorscope is drawn tiny with a large empty band above (resolved 6f69273) |
| FLT-12 | Remove Background (basic/advanced, mask) | S,B | GAP-PLAT-01: Object selection / Select Subject / Remove Background use U²-Net instead of Apple Vision |
| FLT-13 | Last Filter (Ctrl+Meta+F) with the same settings | M | — |
| FLT-14 | Live previews limited to the selection; Preview toggle | S,C | — |
| FLT-15 | Floating filter panels; Camera Raw docked beside the window | R | — |
| LAY-01 | Layers panel: header count, appearance (blend, opacity), list, footer | S,L | — |
| LAY-02 | New Blank Layer | M,S | — |
| LAY-03 | Folders: Group Selected (Ctrl+G), Ungroup (Shift+Ctrl+G), Move Out of Folder, folder opacity | M,L | — |
| LAY-04 | Duplicate Layer / Layer via Copy (Ctrl+J), multi-select, folders | M,L | — |
| LAY-05 | Rename inline (double-click), Rename Layer… | M,L | — |
| LAY-06 | Show/Hide layer; eye swipe across rows (one undo) | L | — |
| LAY-07 | Reorder/nest by drag; Option-drag duplicates; middle-drag scrolls the list | L | — |
| LAY-08 | Move Layer Up/Down (Ctrl+] / Ctrl+[) | M | — |
| LAY-09 | Merge Down / Merge Layers / Merge Group (Ctrl+E) | M,L | — |
| LAY-10 | Flip Layer H/V | M | — |
| LAY-11 | Delete Layer(s) / Mask / Effect | M,S | — |
| LAY-12 | Blend modes (all Photoshop modes, grouped), hover preview on canvas, Shift+/- cycling | S | — |
| LAY-13 | Opacity slider/field; 1–0 keys | S,C | — |
| LAY-14 | Layer context menu (duplicate, rename, delete, clipping, group, merge, depth, masks, visibility) | L | — |
| LAY-15 | Thumbnails for pixel layers, masks (white/black background), adjustment/effect rows | L | GAP-UI-05: AppKit symbol images missing in the Layers list (resolved 6f69273) |
| LAY-16 | Reveal selected layers in the list; no gray flash | L | — |
| LAY-17 | Panel width drag (222–352) | R | — |
| LAY-18 | Cursor feedback: duplicate pointer with eye over mask (Option) | L | GAP-UI-05: AppKit symbol images missing in the Layers list (resolved 6f69273) |
| MSK-01 | Add layer mask (reveals selection; Option = black) | S,L | — |
| MSK-02 | Paint/fill/invert/blur mask, paint anywhere on canvas, feather past pixels | C | — |
| MSK-03 | Disable/Delete/Link/Unlink mask; move unlinked mask | L,C | — |
| MSK-04 | Option-drag copies masks between layers | L | — |
| MSK-05 | Clipping masks (Ctrl+Alt+G, Option-click boundary), folder masks | M,L | — |
| ADJ-01 | New Adjustment Layer (12 kinds) via menu and footer | M,S | GAP-UI-05: AppKit symbol images missing in the Layers list (resolved 6f69273) |
| ADJ-02 | Edit Adjustment (re-edit), live preview, cancel restores | M,S | — |
| ADJ-03 | HDR-revealing adjustment layers | U | — |
| FX-01 | Stroke, Drop Shadow, Inner Shadow, Color Overlay, Outer Glow, Inner Glow | S,B | — |
| FX-02 | Effects persist through snapshots, text edits, size changes, undo | U | — |
| FX-03 | Effect rows in list: toggle, select, Option-drag copy, delete | L | — |
| TRF-01 | Move/scale/rotate/flip non-destructively; handles; Show Controls | C,S | — |
| TRF-02 | Typed X/Y/W/H/Scale/angle values preview live, one undo step; arrow steps; label scrub | S | — |
| TRF-03 | Free Transform (Ctrl+T), Cancel/Apply only when pending | M,C | — |
| TRF-04 | Distort with Ctrl-drag handle; Shift locks axis | C | — |
| TRF-05 | Auto Select (Command flips), aspect lock (Shift flips) live in bar | S,C | — |
| TRF-06 | Sampling choice (High quality / nearest) | S | GAP-UI-10: Transform bar Sampling picker text truncated (“High qual”) (resolved 6f69273) |
| TRF-07 | Several layers / folder together; transform selection | C | — |
| TRF-08 | Snap moves/resizes to Snap To targets | C | — |
| TOOL-01 | Tool rail with 15 tools + color palette; key shortcuts; tool-mode icons | S | — |
| TOOL-02 | Marquee rectangle/ellipse (M cycles), Shift square/circle, Option center | C,S | — |
| TOOL-03 | Lasso freehand/polygonal (L cycles), anti-alias | C,S | — |
| TOOL-04 | Magic tool: Wand (tolerance, sample size, layers, contiguous) | C,S | — |
| TOOL-05 | Magic tool: Object mode (click traces object, edge offset); Tab switches | C,S,P | GAP-PLAT-01: Object selection / Select Subject / Remove Background use U²-Net instead of Apple Vision |
| TOOL-06 | Crop with ratios (3:4, 9:16…), snapping, Option symmetric, start from selection | C,S | — |
| TOOL-07 | Brush paint/erase (B/E), size/hardness/opacity/smoothing, Shift lines, right-drag size | C,S,B | — |
| TOOL-08 | Spot Healing (content-aware, create texture, proximity) | C,S | — |
| TOOL-09 | Clone Stamp (aligned, this/all layers, Option-click source) | C,S | — |
| TOOL-10 | Smear: Liquify / Blur / Smudge (strength, radius) | C,S,B | — |
| TOOL-11 | Gradient linear/radial, styles, reverse, opacity, editable ends, 16-bit | C,S | — |
| TOOL-12 | Shape rectangle/ellipse/line, live shape layers, radius, smooth corners | C,S | — |
| TOOL-13 | Type: boxes, multiline, per-letter color/font, tracking, leading, alignment, font previews | C,S,P | — |
| TOOL-14 | Eyedropper with sample ring; Option temporary eyedropper in paint tools | C,S | — |
| TOOL-15 | Hand (closed hand for whole pan), Space temporary hand | C | — |
| TOOL-16 | Zoom tool: click/Option-click, drag to zoom, typed percent, cursors flip immediately | C,S | — |
| TOOL-17 | No tool (A) | S | — |
| TOOL-18 | Color palette: foreground/background, swap (X), reset (D), full color picker | S | — |
| TOOL-19 | Tool cursors (pictured cursors per tool/mode) | C,P | — |
| TOOL-20 | Brush can't paint → reason shown | S | — |
| RND-01 | Layer compositing, all blend modes (sRGB dodge/burn, Core Image soft light) | B,U | — |
| RND-02 | Tiled layer rendering, raster snapshots | U | — |
| RND-03 | Layer effects GPU kernels | B | — |
| RND-04 | Brush coverage GPU | B | — |
| RND-05 | Warp (Liquify/Smudge) GPU | B | — |
| RND-06 | Camera Raw lookup GPU (verified Metal lookup) | B | — |
| RND-07 | GPU noise/grain | B | — |
| RND-08 | 16-bit and HDR pipelines (deep pixels, dithering to 8 bit) | U,P | — |
| RND-09 | Color management: import profile conversion, export tags, CMYK via ICC | P | GAP-VER-04: No macOS comparison: color fidelity, visual parity and .comp round trip Mac↔Linux unverified |
| RND-10 | Text shaping/drawing (Core Text) | P | — |
| KEY-01 | Photoshop-style shortcuts, remappable, Linux key names | M,S | — |
| KEY-02 | Numeric label scrubbing (drag a label) | S | — |
| KEY-03 | Slider click animation / snap | S | — |
| KEY-04 | Touch / pen input | R | GAP-VER-03: Physical touch, pen, trackpad and native Wayland input unverified |
| KEY-05 | Tool options bars never show a scroll bar; headers scroll when narrow | S | — |

## Stubs and no-ops found

See GAP-ARCH-01 (report 09). Compat SwiftUI modifiers that return `self`: `gesture<G>` (non-drag), `animation`, `aspectRatio`, `zIndex`, `onMove`, `onDelete`, `toolbar`, `preferredColorScheme`, `scrollBounceBehavior`, `sharedBackgroundVisibility`, `navigationTitle`. AppKit view animation lands immediately (`Sources/Compat/AppKit/Drawing.swift:172`). No `fatalError("unimplemented")` paths were found in `Sources/` or `host/`.

