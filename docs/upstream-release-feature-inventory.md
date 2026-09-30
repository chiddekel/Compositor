# Upstream release feature inventory → Linux status (tip `v1.4.5` / `11d8d7a`)

**Editor status:** product features through tip **1.4.5** are ✅ on GNU/Linux (CPU/CG canvas by default + Vulkan brush/effects; Flatpak adapters for Sparkle/Quick Look/Dock). `GPUCanvasRenderer.shared` is nil unless `COMPOSITOR_FORCE_GPU_CANVAS=1` (GPU present Adapter / parity work).

Source: [robbietilton/Compositor releases](https://github.com/robbietilton/Compositor/releases) plus the Features section of upstream `README.md`. Treat each release note as the catch-up **prompt**: inherit tip trees, then Port / Adapter only what Linux still lacks.

Legend: **✅** Linux matches tip · **🟡** works with known UX gap · **❌** missing · **n/a** macOS-only.

## Product features (README tip)

| Area | Feature | Linux |
| --- | --- | --- |
| Layers | Folders, opacity, blend modes | ✅ |
| Layers | Masks paint/fill/invert/blur; link/unlink | ✅ |
| Layers | Clipping / folder masks | ✅ |
| Layers | Adjustment layers (12) | ✅ |
| Layers | Layer effects (6) | ✅ |
| Layers | Merge / duplicate / rename / reorder | ✅ |
| Layers | Ungroup (⇧⌘G) + folder context menu | ✅ |
| Layers | Mask alone (Option-click) + reveal/hide selection mask | ✅ |
| Layers | Option-over-mask eye cursor | ✅ |
| Transform | Move/scale/rotate/flip, free distort, multi-layer | ✅ |
| Transform | Live Auto Select / aspect lock via HeldModifiers | ✅ |
| Transform | Field apply without Apply; Cancel/Apply only when waiting | ✅ |
| Transform | Resize handle snap | ✅ |
| Selections | Marquee / Lasso / Wand+Object | ✅ |
| Selections | Subject, Expand/Contract/Feather | ✅ |
| Selections | Color Range | ✅ |
| Selections | Select All → Inverse deselects full canvas | ✅ |
| Painting | Brush / Erase / Clone / Heal / Smear | ✅ |
| Painting | paintRefusal explanations | ✅ |
| Painting | Clone/Blur at layer resolution | ✅ |
| Painting | Blur Radius; Liquify sharp / Smudge no ghosts (1.4.2) | ✅ |
| Painting | Large-canvas Blur/Smudge/Liquify (1.4.3) | ✅ |
| Filters | Camera Raw, Levels, Curves, blurs, Dither, … | ✅ |
| Filters | Dither Scanlines CRT + Glow/Dots/Wobble (1.4.4) | ✅ |
| Filters | Camera Raw curves = Photoshop parametric + RGB tone (1.4.5) | ✅ |
| Canvas | Tabs; drag reorder + overflow “N more” menu | ✅ |
| Canvas | Rulers, guides, grid, Snap To, Grid Settings | ✅ |
| Canvas | Crop, Canvas/Image Size, Trim | ✅ |
| Files | .comp save/open, PSD/PSB, SVG, RAW, JPEG preview export | ✅ |
| App | Remappable shortcuts, label scrubbing | ✅ |
| App | Quit/close while busy (gradient/dialog) settle (1.4.4) | ✅ |
| App | Sparkle auto-update | ✅ |
| App | Finder Quick Look / thumbnails | ✅ |
| App | macOS 26 / Apple silicon packaging | n/a |

## Release deltas (commit subjects / notes as prompts)

### v1.4.4 → v1.4.5
Camera Raw parametric = Photoshop; curve graph drag; tone curve on R/G/B — **Port** `DragGesture.Value.startLocation`; inherit tip curve + `adjust_camera_raw_curve_color`. **✅**

### v1.4.3 → v1.4.4
Scanlines CRT dither + Glow; quit/close mid-gradient — **Inherit** dither kernels; **Port** workspace settle; Compat `CGDataProvider.data` pin for `BrushRaster.copy`. **✅**

### v1.4.2 → v1.4.3
Blur/Smudge/Liquify on big canvases / largest brush — **Inherit** tip BrushStroke / Smudge; regenerate smudge override. **✅**

### v1.4.1 → v1.4.2
Liquify sharp, Smudge no ghosts, Blur Radius — **Port** MetalWarp tip + blurRadius ABI. **✅**

### v1.4 → v1.4.1
paintRefusal · native-res clone/blur · Cancel/Apply gating · mask reveal + alone · HeldModifiers · tab reorder/overflow · Ungroup · live transform fields · resize snap · eye cursor — **ported**.

### v1.3.7 → v1.4
GPU canvas family — **Adapter Metal → Vulkan (Skia Ganesh)**; CPU/CG is failover when no GPU · Soft Light · Cmd-A from layers · Shift constrain move — **✅ / Adapter**.

### GPU Adapter map (Linux)

**Constraint:** solutions are complete only when Mac **look / feel / UX** match — not when the symbol merely links. Same color space, upright present, brush dab math, and interaction cadence as tip Metal.

| Tip (macOS) | Linux target | Failover |
| --- | --- | --- |
| `MetalBrushCoverage` | Vulkan compute ([`backends/brush`](../backends/brush)) | C CPU kernel (same coverage math) |
| `MetalLayerEffects` | Vulkan compute ([`backends/effects`](../backends/effects)) | OpenCV → C++ CPU (same pass order) |
| `GPUCanvasRenderer` / canvas present | CI present → CG/Qt ([`GPUCanvas`](../Sources/Overrides/GPUCanvas.swift)); optional Vulkan when forced | **Shipped default:** Core Graphics (Mac look). GPU present is Adapter/opt-in (`COMPOSITOR_FORCE_GPU_CANVAS`) — product tools use CPU/CG + Vulkan brush/effects |
| `MetalWarp` / `GPUNoise` | CPU dab math matching Metal kernels ([`MetalWarp`](../Sources/Overrides/MetalWarp.swift)); NoisePixels | Always available (not gated on GPU canvas) |

### v1.3 → v1.3.4–1.3.7
Color Range · Type per-letter font/color · Dither · Grid Settings · Snap To · JPEG zoomable preview · font previews · New Canvas presets · ⌘Z while typing — **✅**.

### v1.2 → v1.3
External reload · save-while-edit · SVG · mask paint anywhere · numeric scrub · PSB — **✅**.

## How to use a release as a prompt

1. Read the GitHub release body (and commits between tags).
2. Classify each bullet: **Inherit** (protected trees) · **Port** (Compat / Overrides / host) · **Adapter** · **n/a**.
3. Merge `upstream/main`, keep `scripts/check-upstream-clean.sh` green (no hand-edits under `Compositor/` / `CompositorTests/`).
4. Port only Linux-side gaps; regenerate generators (`gen-smudge-liquify-override.py`, …).
5. Prove with the matching Swift / LinuxOverride / dialog-smoke tests.

## How to verify

```sh
bash scripts/check-upstream-clean.sh
./scripts/run-compositor.sh --release --offscreen --dialog-smoke
```

Unit gates: SwiftPM / LinuxOverrideTests as usual.
`swift test --filter 'DitherTests.glowLightsBetweenTheLines|CameraRawTests.parametricCurve|CameraRawTests.curveDeepens'`.
