# Upstream 1.5.2 features → GNU/Linux status (2026-10-14)

Every feature in upstream's own `README.md` (Features section, protected tree at `43d691b`, merged as `aca44c2`),
plus the 1.5–1.5.2 release features the README does not list, against the GNU/Linux build. **Implemented**: the
unchanged upstream code runs on Linux. **Adapted**: the same behavior through a Linux substitute (Qt, Vulkan, LittleCMS,
LibRaw, Flatpak, XDG). Evidence names the upstream suites (run unchanged), Linux suites and native Qt journeys that
pass in the full contract runner. Earlier detail: [70-feature crosswalk](upstream-70-feature-crosswalk.md),
[current inventory](current-linux-compatibility-inventory.md). No Mac is available: Mac appearance comparison and
physical-device input remain outside these scopes.

This audit found and fixed four silent gaps, each now covered by a check that fails without the fix:

| Gap found | Cause | Fix | Check |
|---|---|---|---|
| Typed Transform values did nothing until focus left | Qt kept the focused field's panel unresolved, so upstream's `onChange(of: text)` never ran | Main-thread `text` dispatch settles the panel (`SwiftUIBridge.swift`) | `--transform-fields-probe` (8 cases) |
| Dragging a number's label (scrubbing) did nothing, in ~20 panels | Compat `simultaneousGesture(DragGesture)` fell to the generic no-op | Routed to the drag gesture (`Modifiers.swift`) | `--scrub-probe` |
| View › CMYK Proof Colors / Gamut Warning left the canvas unchanged | Only upstream's Metal `gpuFrame` applies the proof, and compat lacked `CIColorCubeWithColorSpace` | Compat filter + display-only proof for full, scaled and stroke-patch canvas images (`compositor_session_proof_display`) | `CMYKProofDisplayTests` (5), `--cmyk-proof-probe` |
| SVG import had no Linux check | Qt's SVG renderer needs a `QGuiApplication` (absent in unit tests) | Native journey through the real import path | `--svg-import-probe` |

## Layers

| Upstream feature | GNU/Linux | Evidence |
|---|---|---|
| Layers and folders, opacity, all blend modes in Photoshop order; folder opacity | Adapted | `LayerTests`, `GroupTests`, `LayerAppearanceTests`, `LivePreviewTests` (24 modes), native blend menu |
| Layer masks: paint, fill, invert, blur, feather past the layer's pixels; link/unlink | Adapted | `LayerMaskTests`, `MaskTransformTests`, `SelectionFeatherTests`, native mask journeys |
| Clipping masks and folder masks | Adapted | `LiveMaskTests`, `AdjustmentLayerTests`, native clipping menu |
| Adjustment layers (Hue/Sat, Levels, Curves, Exposure, Gradient Map, Grain, B&W, Color Balance, Invert, blurs, Noise) | Adapted | `AdjustmentLayerTests`, `AdjustmentEditorTests`, `ImageAdjustmentTests`, native re-edit journeys |
| Layer effects: Stroke, Drop/Inner Shadow, Color Overlay, Outer/Inner Glow on the GPU | Adapted (Vulkan) | `LayerEffectsBackendTests`, `OuterGlowTests`, `InnerGlowTests`, `ColorOverlayTests`, `VulkanEffectsTests`, `SkiaEffectsTests` |
| Merge Down / Layers / Group | Adapted | `GroupTests`, native merge journey |
| Duplicate, rename inline, reorder/nest by drag, Option-drag duplicate, right-click menu | Adapted | `LayerRenameProbeTests`, `NativeTableKeyboardTests`, native folder duplicate/drag journeys |
| Copy/paste whole layers and folders, within or between projects; drag between projects | Adapted | `SelectionClipboardTests`, `ProjectWorkspaceTests`, native tab journeys |

## Transform

| Upstream feature | GNU/Linux | Evidence |
|---|---|---|
| Non-destructive move, scale, rotate, flip at full resolution | Implemented | `TransformTests`, `TiledLayerTests`, native transform journey |
| Free distort (⌘-drag a handle), Shift to lock an axis | Adapted | `DistortTests`, `TransformPressTests` |
| Several layers or a folder together | Implemented | `TransformTests`, `GroupTests` |
| Snapping to canvas/layer edges and centers, guides | Implemented | `ResizeSnapTests`, `GuideTests` |
| Exact position/size/scale/angle, arrow-key steps | Adapted | `TransformInspectorProbeTests`, `--transform-fields-probe` (fixed this audit) |
| Flip Layer / Flip Canvas | Adapted | `TransformTests`, `CanvasRotationTests`, native flip journey |

## Selections

| Upstream feature | GNU/Linux | Evidence |
|---|---|---|
| Marquee, lassos, Magic tool (Wand by color, Object traces a click, Tab switches) | Adapted (U²-Net/OpenCV for Object) | `SelectionTests`, `MagicWandTests`, `EllipseSelectionBooleanTests`, `SubjectModelAcceptanceTests`, native Wand/Object journeys |
| Select Subject; Expand, Contract, Feather | Adapted | `SubjectModelAcceptanceTests`, `SelectionEditTests`, `SelectionFeatherTests` |
| Add/subtract, move the outline, move/duplicate selected pixels | Implemented | `SelectionTests`, `SelectionEditTests`, `GroupingSelectionTests` |
| Load a layer's pixels or a mask as a selection | Adapted | Original mask/selection suites, native Ctrl-thumbnail journey |
| Content-Aware Fill, extending past the edges | Implemented | `SmartEditTests`, native extend journey |

## Painting and retouching

| Upstream feature | GNU/Linux | Evidence |
|---|---|---|
| Brush size/hardness/opacity/smoothing, Paint/Erase (B/E), Shift straight lines | Adapted (Vulkan coverage) | `BrushTests`, `LargeCanvasBrushTests`, `BrushCoverageBackendTests`, native Shift-axis/eraser journeys |
| Spot Healing Brush | Implemented | `SpotHealingTests`, native healing journey |
| Clone Stamp, aligned or not, one or all layers | Adapted | `CloneStampTests`, native clone journey |
| Blur tool on pixels or masks | Implemented | `BlurBrushTests` |
| Gradient and Shape tools, kept editable | Adapted | `GradientTests`, `PendingGradientTests`, `ShapeToolTests` |
| Type tool: inline multiline paragraph boxes, header styling, transform, clipping | Adapted (Qt text) | `TypeToolTests`, `NativeTextEditingTests`, `SystemFontTests`, text backend journey |
| Eyedropper and full color picker | Adapted | `ColorPickerTests`, native picker journey |

## Adjustments and filters

| Upstream feature | GNU/Linux | Evidence |
|---|---|---|
| Camera Raw filter (light, color, curves, mixer, grading, detail, optics, geometry), per-section reset | Adapted (LibRaw) | `CameraRawTests`, `CameraRawResetTests`, `CameraRawSliderTests`, `RawDevelopCapabilityTests`, RAW-lens journey |
| Levels (Auto), Curves, Hue/Sat, Exposure, Gradient Map, Grain, B&W, Color Balance, Invert | Adapted | `LevelsTests`, `HueSaturationTests`, `ImageAdjustmentTests`, Levels/Curves/Hue native probes |
| Gaussian and Motion Blur past a layer's edges | Implemented | `FilterTests`, `FinishingFilterTests` |
| Add Noise, Vignette, Bloom, Dither, Scanlines, Tonal Contrast, Lens Correction, Remove Background | Adapted | `FilterTests`, `ScanlinesTests`, `OpenCVEffectsTests`, `RawDitherTests`, `SubjectModelAcceptanceTests` |
| Live previews limited to the selection | Adapted | `LivePreviewTests`, `ScaledAdjustmentPreviewTests`, native selected-preview journey |
| Last Filter (⌃⌘F) | Implemented | `ReadmeFeatureAcceptanceTests.lastFilterRunsTheFilterAgainWithItsSettings` (new; upstream has no test) |

## Canvas and files

| Upstream feature | GNU/Linux | Evidence |
|---|---|---|
| Multiple projects in tabs | Adapted (Qt tab bar) | `ProjectWorkspaceTests`, `ProjectTabLayoutTests`, `--tab-smoke` |
| Search Commands (⌘F) | Adapted | `CommandPaletteTests`, native palette journey |
| Toggle Fullscreen (F) | Adapted | `CompositorTests` canvas-only test, native shell |
| Rulers, guides, layout grid, Snap To | Adapted | `GuideTests`, `ResizeSnapTests`, native ruler/grid journeys |
| Crop with snapping, ratios, Option symmetric, start from a selection | Adapted | `CropTests`, `CropToCanvasImportTests`, native crop journey |
| Canvas Size, Image Size, Trim | Implemented | `CanvasSizeTests`, `ImageSizeTests`, `ImageTrimTests` |
| Navigator minimap from 300% | Adapted | `NavigatorTests` |
| Sharp downsampling zoomed out, pixel grid zoomed in | Adapted | `DownsampleTests`, `RegionRenderTests`, native pixel-grid journey |
| Import JPEG/PNG/HEIC/TIFF/WebP | Adapted (Qt/libheif/libtiff codecs) | `ImageImportTests`, `test_imageio_color --require-heif` |
| Import SVG | Adapted (Qt SVG) | `--svg-import-probe` (new) |
| Import camera RAW with a develop step | Adapted (LibRaw) | `CameraRawTests`, RAW journeys |
| Import Photoshop PSD/PSB (folders, masks, blend modes, shapes, text, adjustments) | Implemented | `PSDRoundTripTests`, `PSBImportTests`, `PSDAdjustmentTests` |
| Large documents: memory budget, oversize PSD layers cropped to the canvas | Adapted | `ProjectResourceLimitsTests`, `CropToCanvasImportTests`, `LargeCanvasBrushTests` |
| Export PNG / JPEG / Export As (PNG, JPEG, one-page PDF) with live preview; Copy Merged | Adapted | `ExportTests`, `JPEGExportTests`, `PDFMatteTests`, `SelectionClipboardTests`, `--save-smoke` |
| Keep working while a project saves | Adapted | `ProjectSaveSnapshotTests`, `StagedAssetRecoveryTests` |
| Photoshop-style shortcuts, remappable | Adapted | `KeyboardShortcutTests`, `KeyboardShortcutsLinuxTests`, shortcut-binding probe |
| Drag a number's label to scrub its value | Adapted | `--scrub-probe` (fixed this audit) |
| Automatic updates | Adapted (Flatpak, not Sparkle) | Flatpak update service; installed-release update unverified |

## Works with AI agents

| Upstream feature | GNU/Linux | Evidence |
|---|---|---|
| `.comp` folder of PNG layers + manifest; an open project updates live as it is written | Adapted | `ProjectTests`, `ProjectManifestValidationTests`, `ExternalChangeTests`, native external-change journeys |

## 1.5–1.5.2 release features not in the README

| Upstream commit | Feature | GNU/Linux | Evidence |
|---|---|---|---|
| `59025aa` | CMYK proof on the canvas; CMYK export | Adapted (LittleCMS) | `CMYKTests`, `CMYKProofDisplayTests`, `--cmyk-proof-probe` (canvas proof fixed this audit) |
| `896d5c8` | Open CMYK Photoshop files, remember a file's profile | Implemented | `CMYKTests.layeredCMYKPhotoshopFilesOpen`, `openingACMYKFileChoosesItsProfile` |
| `dac3bc6` | Export As color choice, starting on RGB | Implemented | `CMYKTests` |
| `905efc5` | 16-bit layers on the canvas at 16 bits, dithered | Adapted (Vulkan) | `DeepLayerTests`, `GPUCanvasUploadTests` |
| `3ae11cd` | Filter › Progressive Blur | Adapted | `ProgressiveBlurTests` (compat `CIMaskedVariableBlur`) |
| `735c2cc` | Camera Raw Shadows adapts to the picture | Implemented | `CameraRawTests` |
| `a3a0e29` | RAW import opens the Camera Raw Filter | Adapted | Native single/mixed import journeys |
| `87e2283` | Clear a shortcut; CMYK proofing keys | Adapted | `KeyboardShortcutTests` |
| `5e9033f` | Update alert in the wide layout | Adapted (Flatpak updater; Sparkle excluded) | Ledger row 25 |

Linux has no bundled Generic CMYK profile (Apple's is macOS-only): users load a print ICC profile under
View › CMYK › Profile, which upstream's own Load Profile folder holds.
