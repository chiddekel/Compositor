# Upstream release feature inventory → Linux status (tip `v1.4.5` / `11d8d7a`)

Source: [robbietilton/Compositor releases](https://github.com/robbietilton/Compositor/releases) plus the Features section of upstream `README.md`. Treat each release note as the catch-up **prompt**: inherit tip trees, then Port / Adapter only what Linux still lacks.

Legend: **✅** Linux matches tip · **🟡** works with known UX gap · **❌** missing · **n/a** macOS-only · **e2e** covered by `tests/ui_e2e`.

## Product features (README tip)

| Area | Feature | Linux | e2e |
| --- | --- | --- | --- |
| Layers | Folders, opacity, blend modes | ✅ | PSD + layer rename |
| Layers | Masks paint/fill/invert/blur; link/unlink | ✅ | tip_mask_* |
| Layers | Clipping / folder masks | ✅ | — |
| Layers | Adjustment layers (12) | ✅ | effect_* |
| Layers | Layer effects (6) | ✅ | — |
| Layers | Merge / duplicate / rename / reorder | ✅ | layer_rename |
| Layers | Ungroup (⇧⌘G) + folder context menu | ✅ | tip_ungroup |
| Layers | Mask alone (Option-click) + reveal/hide selection mask | ✅ | tip_mask_alone, tip_mask_reveal_selection |
| Layers | Option-over-mask eye cursor | ✅ | — |
| Transform | Move/scale/rotate/flip, free distort, multi-layer | ✅ | tool_move |
| Transform | Live Auto Select / aspect lock via HeldModifiers | ✅ | — |
| Transform | Field apply without Apply; Cancel/Apply only when waiting | ✅ | — |
| Transform | Resize handle snap | ✅ | — |
| Selections | Marquee / Lasso / Wand+Object | ✅ | tool_marquee_*, tool_lasso_*, tool_wand_* |
| Selections | Subject, Expand/Contract/Feather | ✅ | — |
| Selections | Color Range | ✅ | tip_color_range (opt-in `--case`) |
| Selections | Select All → Inverse deselects full canvas | ✅ | tip_select_all_inverse |
| Painting | Brush / Erase / Clone / Heal / Smear | ✅ | brush_*, tool_*, smear_feedback_* |
| Painting | paintRefusal explanations | ✅ | tip_paint_refusal_folder |
| Painting | Clone/Blur at layer resolution | ✅ | — |
| Painting | Blur Radius; Liquify sharp / Smudge no ghosts (1.4.2) | ✅ | — |
| Painting | Large-canvas Blur/Smudge/Liquify (1.4.3) | ✅ | LargeCanvasBrushTests |
| Filters | Camera Raw, Levels, Curves, blurs, Dither, … | ✅ | effect_* |
| Filters | Dither Scanlines CRT + Glow/Dots/Wobble (1.4.4) | ✅ | DitherTests |
| Filters | Camera Raw curves = Photoshop parametric + RGB tone (1.4.5) | ✅ | CameraRawTests parametric* |
| Canvas | Tabs; drag reorder + overflow “N more” menu | ✅ | tip_tab_reorder |
| Canvas | Rulers, guides, grid, Snap To, Grid Settings | ✅ | — |
| Canvas | Crop, Canvas/Image Size, Trim | ✅ | tool_crop |
| Files | .comp save/open, PSD/PSB, SVG, RAW, JPEG preview export | ✅ | save_reopen, psd_* |
| App | Remappable shortcuts, label scrubbing | ✅ | — |
| App | Quit/close while busy (gradient/dialog) settle (1.4.4) | ✅ | — |
| App | Sparkle auto-update | n/a | Flatpak updates |
| App | Finder Quick Look / thumbnails | n/a | Adapter writes preview where useful |
| App | macOS 26 / Apple silicon packaging | n/a | — |

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
| `GPUCanvasRenderer` / canvas present | CI present → CG/Qt ([`GPUCanvas`](../Sources/Overrides/GPUCanvas.swift)); Skia Vulkan blit ([`SkiaBridge`](../linux/graphics/SkiaBridge.cpp)) | **Default:** Core Graphics (Mac look). `drawOnGPU` opt-in via `COMPOSITOR_FORCE_GPU_CANVAS` until GPU↔CPU pixel parity |
| `MetalWarp` / `GPUNoise` | Same-API overrides; dab/noise math mirrors Metal kernels | CPU dabs / NoisePixels |

### v1.3 → v1.3.4–1.3.7
Color Range · Type per-letter font/color · Dither · Grid Settings · Snap To · JPEG zoomable preview · font previews · New Canvas presets · ⌘Z while typing — **✅**.

### v1.2 → v1.3
External reload · save-while-edit · SVG · mask paint anywhere · numeric scrub · PSB — **✅**.

## How to use a release as a prompt

1. Read the GitHub release body (and commits between tags).
2. Classify each bullet: **Inherit** (protected trees) · **Port** (Compat / Overrides / host) · **Adapter** · **n/a**.
3. Merge `upstream/main`, keep `scripts/check-upstream-clean.sh` green (no hand-edits under `Compositor/` / `CompositorTests/`).
4. Port only Linux-side gaps; regenerate generators (`gen-smudge-liquify-override.py`, …).
5. Prove with the matching Swift tests / `scripts/run-ui-e2e.sh` cases.

## How to verify

```sh
# Tip feature journeys only
UI_E2E_ARTIFACTS=/tmp/compositor-tip-e2e \
  bash scripts/run-ui-e2e.sh --case tip_select_all_inverse --case tip_paint_refusal_folder \
  --case tip_ungroup --case tip_mask_alone --case tip_mask_reveal_selection \
  --case tip_color_range --case tip_tab_reorder

# Full desktop suite (see docs/linux-ui-e2e.md)
bash scripts/run-ui-e2e.sh
```

Unit gates: `bash scripts/check-upstream-clean.sh` and SwiftPM / LinuxOverrideTests as usual.
`swift test --filter 'DitherTests.glowLightsBetweenTheLines|CameraRawTests.parametricCurve|CameraRawTests.curveDeepens'`.
