# Compat gap inventory: upstream tip vs GNU_Linux

**Date**: 2026-11-02 (updated after CoreML + CI wiring)  
**Ledger base → tip**: `a1bd74c`…`a62490d` (parity `ledger_base`/`ledger_to` was through `4f9ed78`; tip +1 UI commit)  
**Merged upstream tip**: `4f9ed78` (1.5.12 / format 20)  
**Unmerged tip**: `a62490d` (shared panel position — not Compat)  
**Compat work**: Core Image Volumetric filters, Vision crop option, CoreML + depth ONNX backend, DepthModel override.

This inventory is evidence for what still belongs in `Sources/Compat` (and related Overrides) so tip features evaluate under GNU/Linux. It is not a merge plan for protected trees.

## Verification method

1. `git log 4f9ed78..upstream/main` for unmerged tip commits.
2. Category pass over `2d75d91..upstream/main` (see `/tmp/upstream-compat-gap.json` categories).
3. Collect every `applyingFilter("…")` / `CIFilter(name:)` in `Compositor/Document/{VolumetricLight,RimLight,LensEffects}.swift` and require a Compat `case` arm in `Sources/Compat/CoreImage/CoreImage.swift`.
4. Cross-check tip `Compositor/IO/DepthModel.swift` symbols against `Sources/Compat` and `Sources/Overrides/DepthModel.swift`.
5. Cross-check Vision request types used by Volumetric Light against `Sources/Compat/Vision/Vision.swift`.

## Unmerged tip (not Compat)

| SHA | Subject | Compat impact |
|---|---|---|
| `a62490d` | Shared edit-panel position (`FloatingPanel` / `ContentView`) | None. Needs merge + any Linux override regen for those UI files. |

## Commit categories → Compat status

| Category | Upstream SHAs (representative) | Compat status |
|---|---|---|
| Color picker, cursors, selection/view extras, multi-layer menus, Services removal, document history, Image Size scrubbing, per-layer PNG, deep/HDR menu edits | `096dbe2`…`4f9ed78` (non-Rim/Volumetric) | No new Compat frameworks. App/UI; covered by existing AppKit/SwiftUI/host adapters once trees are merged. |
| Prism Fringe / format 20 | `6d49a23` | Covered (project format + LensEffects; CI already present). |
| Rim Light | `b9a0ed8`, `97c3b3f` | **Partial.** CPU Metal ports in `MetalCompute` / `RimLightCompute`; `CIAdditionCompositing` present. Subject mask quality still depends on Vision foreground backend. |
| Volumetric Light / DepthMini | `1405545`…`95d3d63` | **Partial.** CPU volumetric kernels present. Core Image filters required by the Swift path are wired (see below). Real DepthMini and person/pose refinement still open. |
| Docs / appcast / credits | `d98cd19`, `26922f8`, `7e98437` | n/a for Compat. |
| Shared panel position | `a62490d` | Merge only (above). |

## Core Image — Volumetric / Rim / Lens filter audit

Filters referenced by those three tip files: **23**. Missing Compat case arms before this pass: **4**. After wiring in `CoreImage.swift` + `LensRaster.discMinimum`: **0 missing**.

| Filter | Role | Compat |
|---|---|---|
| `CIAreaAverage` | Volumetric glow / gap metrics | **Added** (`Node.areaAverage`, supportedNames, eval) |
| `CIMaximumCompositing` | Keep union of gap fills | **Added** (separable min/max path) |
| `CIMinimumCompositing` | Cut / intersect masks | **Added** |
| `CIMorphologyMinimum` | Narrow cut before expand | **Added** (`LensRaster.discMinimum`) |
| `CIAdditionCompositing`, `CIAreaMaximum`, `CIMorphologyMaximum`, blends, matrices, etc. | Already used by Rim/Lens/Volumetric | Already present |

Evidence command (must print `missing arms []`):

```bash
python3 - <<'PY'
import re
from pathlib import Path
ci = Path('Sources/Compat/CoreImage/CoreImage.swift').read_text()
arms=set()
for m in re.finditer(r'case ((?:"[^"]+"\s*,\s*)*"[^"]+"):', ci):
    arms |= set(re.findall(r'"([^"]+)"', m.group(1)))
needed=set()
for p in ['Compositor/Document/VolumetricLight.swift','Compositor/Document/RimLight.swift','Compositor/Document/LensEffects.swift']:
    needed |= set(re.findall(r'applyingFilter\(\s*"([^"]+)"', Path(p).read_text()))
print(sorted(needed - arms))
PY
```

## Remaining Compat / override gaps (actionable)

### 1. `Sources/Compat/CoreML` — **added**

Tip symbols (`MLModel`, `MLModelConfiguration`, `MLFeatureValue`, `MLDictionaryFeatureProvider`, `MLShapedArray`,
`compileModel`) are in `Sources/Compat/CoreML`, backed by `backends/depth` (Depth Anything V2 Small ONNX via OpenCV
DNN). `Sources/Overrides/DepthModel.swift` downloads that ONNX (Apple’s DepthMini mlpackage is not public/runnable
here) and uses the same GuidedMatte refine path as tip. Requires OpenCV DNN at build time; without it `prepare`
fails and Volumetric keeps tip’s geometric haze.

### 2. Vision — API stub vs quality backends

| Item | Status |
|---|---|
| `VNGenerateForegroundInstanceMaskRequest` | Present; classical / optional C backend |
| `VNGeneratePersonSegmentationRequest` | Present; **results stay empty** (tip falls back to general mask) |
| `VNDetectHumanBodyPoseRequest` | Present; **results stay empty** (hand/arm gap cleanup no-ops) |
| `VNImageCropAndScaleOption` | **Added** |

### 3. Metal compute

| Kernel family | Status |
|---|---|
| `rimLight` / `rimCombine` | CPU port via `RimLightCompute` |
| `volumetricBeams` / `volumetricCombine` | CPU port via `VolumetricLightCompute` |
| Other tip Metal | No additional missing names found for these features |

### 4. Not Compat work

- Merge `a62490d` into GNU_Linux and refresh Linux overrides for `FloatingPanel` / `ContentView` if the generator owns them.
- Runtime qualification: OpenCV must load the ViT ONNX; if DNN rejects the graph, depth stays unavailable until ORT or a CNN export is wired.
- Optional quality: person-segmentation and body-pose backends in Vision.

## Priority for Compat work

1. ~~Wire the four Volumetric Core Image filters~~ **done** (`CoreImage.swift`, `LensRaster.swift`).
2. ~~`Sources/Compat/CoreML` + depth backend~~ **done** (ONNX Depth Anything; tip mlpackage still excluded).
3. ~~`VNImageCropAndScaleOption`~~ **done**.
4. Optional: person/pose Vision backends; ORT if OpenCV DNN cannot run the ViT ONNX.

## Related docs

- Catch-up ledger through merged tip: [upstream-after-1.4.10-ledger.md](upstream-after-1.4.10-ledger.md)
- Machine-readable snapshot of this pass: `/tmp/upstream-compat-gap.json` (refresh after commits)
