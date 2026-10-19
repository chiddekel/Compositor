# 02 — Upstream feature inventory

Upstream `365b574` (1.5.3). 179 features with stable IDs, derived from the source: the menu commands (`Compositor/CompositorApp.swift:20-395`), the tool enum (`NavigationTool`, `Compositor/Document/EditorSession.swift`), every SwiftUI view under `Compositor/UI` and `ContentView.swift`, the layer list (`UI/NativeLayerList.swift`), the importer/exporter/store under `Compositor/IO`, the filter and adjustment kinds (`Document/Filters.swift:7-26`, `Document/LayerAdjustment.swift:5-25`), the shortcut catalog (`UI/KeyboardShortcuts.swift`) and the rendering backends under `Compositor/Rendering`. Symbol locations are looked up mechanically (`gen_reports.py: locate`).

Granularity: one row per user-visible capability or per subsystem that has its own backend; sub-controls are listed in the row (e.g. every Scanlines parameter is FLT-08). The upstream source has 444 distinct `EditorSession` functions over 41 extension files; every menu command and tool maps to a row here.

Status in upstream: all rows are **complete** (shipped in a tagged release and covered by menus/tools). No upstream row is experimental or unreachable; removed functionality is listed at the end.

| ID | Category | Feature | Entry point | Upstream source | Commits | Upstream tests |
|---|---|---|---|---|---|---|
| APP-01 | App | Launch into documentless window with New canvas welcome | launch | `Compositor/ContentView.swift`; `Compositor/UI/NewCanvasSheet.swift` | 29d8cf5(L) | CanvasEntryTests,--ui-audit-probe |
| APP-02 | App | First launch fills screen, later launches restore placement | launch | `Compositor/CompositorApp.swift` | caff3b3(L) | — |
| APP-03 | App | Always-dark appearance incl. alerts and panels | global | `Compositor/ContentView.swift` | d62a132 | — |
| APP-04 | App | About panel with version | Compositor › About | `Compositor/CompositorApp.swift` | 636b34f(L) | — |
| APP-05 | App | Check for Updates / automatic update check | Compositor › Check for Updates… | `Compositor/IO/UpdateDriver.swift` | b36b305,0ecbacf,759bcbe,5e9033f | — |
| APP-06 | App | Hide Compositor | Compositor › Hide | `Compositor/CompositorApp.swift` | - | — |
| APP-07 | App | Hide Others / Show All | Compositor › Hide Others | `Compositor/CompositorApp.swift` | - | — |
| APP-08 | App | Quit, incl. mid-gradient or with a dialog open | Compositor › Quit (Ctrl+Q) | `Compositor/CompositorApp.swift` | 1aad384 | — |
| APP-09 | App | Unsaved-changes prompt (Don't Save matches Cancel) | close/quit | `Compositor/IO/ProjectController.swift` | 283d360,4e035bf | ProjectTests |
| APP-10 | App | Window menu (Minimize, Zoom) | Window | (AppKit default) | - | — |
| APP-11 | App | Help menu | Help | (AppKit default) | - | — |
| APP-12 | App | Open a project while the app is quit shows its window | file manager open | `Compositor/IO/CompositorApplicationDelegate.swift` | e70da06 | — |
| APP-13 | App | Title-bar free space drags the window | header | `Compositor/UI/ProjectTabs.swift` | e8ed83b | TitleBarDragTests |
| APP-14 | App | Canvas Only / Toggle Fullscreen (F, Esc) | View › Toggle Fullscreen | `Compositor/IO/CompositorApplicationDelegate.swift:102` (toggleCanvasOnly) | ad4bddf,088a5c1,720c121 | CompositorTests |
| APP-15 | App | Enter Full Screen (window) | View › Enter Full Screen | (AppKit default) | - | — |
| APP-16 | App | Memory budgets for large documents (per-surface 200 MP, document total) | import/new | `Compositor/Document/DocumentLimits.swift` | 7dadc88,bc865fb | ProjectTests |
| FILE-01 | Files | New Canvas (size, units in/cm/mm, 72/300 DPI, transparent/white/black) | File › New Canvas…, welcome | `Compositor/Document/EditorSession+Projects.swift:69` (createNewProject) | b0b4f01,ab9779a,a00d8b6 | NewCanvasUnitTests,CanvasEntryTests |
| FILE-02 | Files | New Canvas preset sizes (More ⋯ menu) | welcome ⋯ | `Compositor/UI/NewCanvasSheet.swift` | aaf3dc0 | --ui-audit-probe |
| FILE-03 | Files | Paste an image on the New canvas screen to make the canvas | welcome + Ctrl+V | `Compositor/Document/SelectionClipboard.swift:179` (pasteImageAsNewCanvas) | 2522e3b | SelectionClipboardTests |
| FILE-04 | Files | Open Project (.comp package) | File › Open Project… | `Compositor/IO/ProjectController.swift` | - | ProjectTests |
| FILE-05 | Files | Open Recent / Clear Menu | File › Open Recent | `Compositor/IO/RecentProjects.swift` | 73dc0f4 | — |
| FILE-06 | Files | Import Images (JPEG/PNG/HEIC/TIFF/WebP/SVG/PSD/RAW/EXR/HDR) | File › Import Images… | `Compositor/Document/EditorSession.swift:818` (importImages) | f137814,5724099,70b3e14,7f239dc | ImageImportTests |
| FILE-07 | Files | Import a folder of images as layers | Import / drop | `Compositor/IO/ImageImporter.swift` | b2a0c45 | ImageImportTests |
| FILE-08 | Files | Save / Save As (.comp), keep editing while saving | File › Save, Save As… | `Compositor/IO/ProjectStore.swift` | 940e188,cd4061a,cba6efc | ProjectTests |
| FILE-09 | Files | Export PNG | File › Export PNG… | `Compositor/IO/ImageExporter.swift` | - | ExportTests |
| FILE-10 | Files | Export JPEG (Export As starting on JPEG) | File › Export JPEG… | `Compositor/UI/ExportAsSheet.swift` | ac6f309,450af5f | JPEGExportTests |
| FILE-11 | Files | Export As: PNG/JPEG first, PDF/EXR/TIFF under More, sized, previewed, color RGB/CMYK | File › Export As… | `Compositor/UI/ExportAsSheet.swift` | 450af5f,b1db93d,f5ae5ba,dac3bc6 | ExportTests,CMYKTests |
| FILE-12 | Files | Export PDF (one page, matte) | Export As › More | `Compositor/IO/ImageExporter.swift` | 9287cf1 | ExportTests |
| FILE-13 | Files | Close Project | File › Close Project | `Compositor/IO/ProjectController.swift` | - | ProjectWorkspaceTests |
| FILE-14 | Files | Project tabs: open, switch, reorder by drag, overflow menu, blank start tab, Untitled numbering | tab strip | `Compositor/UI/ProjectTabs.swift`; `Compositor/UI/ProjectTabLayout.swift` | 1faf7a0,d0ec2f3 | ProjectWorkspaceTests,ProjectTabLayoutTests |
| FILE-15 | Files | Drop files on canvas / anywhere on tab bar to open in a new project | drag and drop | `Compositor/IO/ImageFileDrop.swift` | d3d0ce7,54dc7ba | ProjectWorkspaceTests |
| FILE-16 | Files | Drag a layer into another / a new project (canvas sizes to it) | drag layer to tab | `Compositor/Document/ProjectWorkspace.swift:20` (ProjectWorkspace) | e580107 | ProjectWorkspaceTests |
| FILE-17 | Files | External change reload (agents writing .comp), Revert/Keep Mine | automatic | `Compositor/IO/ProjectController+ExternalChanges.swift`; `Compositor/IO/ProjectWatcher.swift` | ed5ddea,29f0bea | ExternalChangeTests |
| FILE-18 | Files | Package thumbnails / Quick Look preview | Finder | `Compositor/IO/ImageExporter.swift` | 14aad18,4868465 | — |
| FILE-19 | Files | PSD/PSB import: folders, masks, blend modes, shapes, text, adjustments, merged-only | Import | `Compositor/IO/PSD/PSDReader.swift` | ac5aa88,b8e3cd1,b8cce6e,e6bcfa1 | PSDRoundTripTests,PSBImportTests,PSDAdjustmentTests |
| FILE-20 | Files | PSD conversion sheet shown while reading | Import PSD | `Compositor/UI/PSDConversionSheet.swift` | cf1ae1d | PSDRoundTripTests |
| FILE-21 | Files | Crop oversize PSD layers to the canvas | Import PSD | `Compositor/IO/PSD/PSDDocumentBuilder.swift` | 1fcf854 | CropToCanvasImportTests |
| FILE-22 | Files | RAW import with develop sheet (Noise Reduction, Lens Correction, Highlight Recovery) | Import RAW | `Compositor/IO/RawImporter.swift`; `Compositor/UI/RawDevelopSheet.swift` | 0555d62,248d4d4,6345432,196342c | CameraRawTests,RawDitherTests |
| FILE-23 | Files | RAW import › Camera Raw… opens the Camera Raw Filter | RAW develop sheet | `Compositor/UI/RawDevelopSheet.swift` | a3a0e29 | CameraRawTests |
| FILE-24 | Files | SVG import | Import | `Compositor/IO/ImageImporter.swift` | 0534e00 | — |
| FILE-25 | Files | HDR import EXR/Radiance; EXR export | Import / Export As | `Compositor/IO/ImageImporter.swift` | 7f239dc,b9186f7 | DeepLayerTests |
| FILE-26 | Files | CMYK Photoshop files open; file's profile remembered | Import PSD | `Compositor/IO/CMYK.swift` | 896d5c8 | CMYKTests |
| FILE-27 | Files | Project format v13 manifest + PNG/EXR assets, validation | save/load | `Compositor/IO/ProjectStore.swift` | 4cc9951,156c38c | ProjectTests |
| EDIT-01 | Edit | Undo / Redo with named steps; text-field undo during modal edits | Edit › Undo/Redo | `Compositor/Document/DocumentHistory.swift:76` (undo); `Compositor/Document/DocumentHistory.swift:84` (redo) | ee68ba9 | HistoryTests |
| EDIT-02 | Edit | Cut / Copy / Paste pixels (desktop clipboard) | Edit | `Compositor/Document/SelectionClipboard.swift:142` (cutSelection); `Compositor/Document/SelectionClipboard.swift:113` (copySelection); `Compositor/Document/SelectionClipboard.swift:156` (paste) | - | SelectionClipboardTests |
| EDIT-03 | Edit | Copy Merged | Edit › Copy Merged | `Compositor/Document/SelectionClipboard.swift:99` (copyMergedSelection) | - | SelectionClipboardTests |
| EDIT-04 | Edit | Copy/paste whole layers and folders within and between projects | Edit › Copy/Paste | `Compositor/Document/SelectionClipboard.swift:113` (copySelection); `Compositor/Document/SelectionClipboard.swift:156` (paste) | 5ef5b0a,c873453 | SelectionClipboardTests |
| EDIT-05 | Edit | Fill with Foreground / Background color | Edit | `Compositor/Document/SelectionEdits.swift:53` (fillSelection) | - | SelectionEditTests |
| EDIT-06 | Edit | Clear Selection Pixels | Edit / Delete | `Compositor/Document/SelectionEdits.swift:67` (clearSelectedPixels) | - | SelectionEditTests |
| EDIT-07 | Edit | Content-Aware Fill (multi-scale PatchMatch, past layer edges) | Edit › Content-Aware Fill… | `Compositor/Document/ContentFill.swift` | 23913d3,39d1257 | SmartEditTests |
| EDIT-08 | Edit | Keyboard Shortcuts editor (search, record, clear, conflicts, Restore Defaults) | Edit › Keyboard Shortcuts… | `Compositor/UI/KeyboardShortcuts.swift` | 391042d,87e2283 | KeyboardShortcutTests,--ui-audit-probe |
| EDIT-09 | Edit | Edit menu without macOS text extras | Edit | `Compositor/CompositorApp.swift` | 710dd66 | — |
| VIEW-01 | View | Search Commands / command palette (menus, tools and modes, ranking, toggles shown) | View › Search Commands… (Ctrl+F) | `Compositor/UI/CommandPalette.swift`; `Compositor/UI/CommandPaletteView.swift` | cb139a1,07b8b1e,94b57f7,bba92dc | CommandPaletteTests |
| VIEW-02 | View | Fit Canvas / Actual Pixels / Zoom In / Zoom Out / stepped keyboard zoom | View; toolbar | `Compositor/Document/BlurTool.swift:27` (fit); `Compositor/Document/EditorSession.swift:1074` (zoom); `Compositor/Document/EditorSession.swift:1082` (zoomKeyboard) | 383548c | CompositorTests |
| VIEW-03 | View | Navigator minimap from 300% | View › Navigator | `Compositor/UI/NavigatorMinimap.swift` | 6490bb3,3e09948 | NavigatorTests |
| VIEW-04 | View | Pixel grid from 800% | View › Pixel Grid | `Compositor/Rendering/EditorCanvas.swift` | 8e55e0c(L) | DownsampleTests |
| VIEW-05 | View | Show Transform Controls (Ctrl+H) | View | `Compositor/CompositorApp.swift` | - | TransformTests |
| VIEW-06 | View | CMYK Proof Colors / Gamut Warning on canvas | View › CMYK | `Compositor/IO/CMYK.swift`; `Compositor/IO/CMYK.swift` | 59025aa,87e2283 | CMYKTests |
| VIEW-07 | View | CMYK proof/gamut pills at canvas foot (profile name, close button) | canvas overlay | `Compositor/UI/LayerMaskMenu.swift` (ProofBadge) | 59025aa | --ui-audit-probe |
| VIEW-08 | View | CMYK profile choice / Load Profile… | View › CMYK › Profile | `Compositor/CompositorApp.swift:399` (loadCMYKProfile) | 59025aa | CMYKTests |
| VIEW-09 | View | Rulers, guides from rulers, layout grid, Show Grid/Guides | View | `Compositor/UI/CanvasRulers.swift`; `Compositor/Document/Guides.swift` | e3a474a,3e4fd6a | GuideTests |
| VIEW-10 | View | Grid Settings (color, style, opacity, spacing, subdivisions, Restore Defaults) | View › Grid Settings… | `Compositor/UI/GridSettingsSheet.swift` | 1c819d0,db5eafa | --ui-audit-probe |
| VIEW-11 | View | Snap and Snap To (guides, grid, layers, document bounds); Control bypasses | View › Snap | `Compositor/Document/Crop.swift:186` (snappedPoint) | bba92dc,d6e3e93,8b1369a,c459f88 | ResizeSnapTests,GuideTests |
| VIEW-12 | View | Lock Guides / Clear Guides | View | `Compositor/Document/Guides.swift:230` (clearGuides) | - | GuideTests |
| VIEW-13 | View | Sharp downsampling when zoomed out; marching ants from screen outline | canvas | `Compositor/Rendering/DownsampleCache.swift` | 8eba077 | DownsampleTests,RegionRenderTests |
| VIEW-14 | View | Mask-alone view badge | Alt-click mask thumbnail | `Compositor/Document/LayerMask.swift:231` (toggleMaskAlone) | b3419ab | MaskAloneTests |
| VIEW-15 | View | Status bar: zoom, size, color, per-tool hints, busy/importing progress | status bar | `Compositor/ContentView.swift` (statusBar) | - | — |
| VIEW-16 | View | Trackpad pinch zoom; middle-drag pan; Ctrl/Cmd+middle-drag zoom | canvas | `Compositor/Rendering/EditorCanvas.swift` | 30a8694,e03923f | MiddleButtonTests |
| VIEW-17 | View | GPU-drawn canvas frames (Metal); CPU fallback | canvas | `Compositor/Rendering/GPUCanvas.swift` | cdf8674,f773f7b,d04f159,4c5e1a6 | GPUCanvasTests |
| VIEW-18 | View | 16-bit layers on canvas at 16 bits, dithered to screen | canvas | `Compositor/Rendering/GPUCanvas.swift` | 905efc5 | DeepLayerTests,GPUCanvasTests |
| SEL-01 | Select | Select All / Deselect / Inverse | Select | `Compositor/Document/Selection.swift:344` (selectAll); `Compositor/Document/Selection.swift:349` (deselect); `Compositor/Document/Selection.swift:354` (invertSelection) | 133c34a,451281e | SelectionTests |
| SEL-02 | Select | Layer's Pixels / Mask's Black Areas / Ctrl-click thumbnail loads selection | Select; layer thumbnail | `Compositor/Document/MaskTracing.swift:87` (loadLayerSelection); `Compositor/Document/MaskTracing.swift:76` (loadMaskSelection) | - | SelectionEditTests,LayerMaskTests |
| SEL-03 | Select | Select Subject | Select › Subject | `Compositor/Document/SubjectRemoval.swift:119` (selectSubject) | - | SelectionTests |
| SEL-04 | Select | Color Range (eyedroppers add/remove, Fuzziness, Invert, live selection) | Select › Color Range… | `Compositor/Document/ColorRangeSelection.swift:46` (beginColorRange); `Compositor/Document/ColorRangeSelection.swift` | c3e360a | ColorRangeTests,--ui-audit-probe |
| SEL-05 | Select | Expand / Contract / Feather (menu prompt + options bar) | Select; options bar | `Compositor/Document/Selection.swift:317` (expandSelection); `Compositor/Document/Selection.swift:321` (contractSelection); `Compositor/Document/Selection.swift:325` (featherSelection) | 2e8ebd7 | SelectionEditTests,SelectionFeatherTests |
| SEL-06 | Select | Selection modes New/Add/Subtract; Shift/Alt live in bar | options bar | `Compositor/Document/Selection.swift:123` (selectionMode) | 89dfb56 | SelectionTests |
| SEL-07 | Select | Move outline / move or duplicate selected pixels (Ctrl-drag, Ctrl-Alt-drag), Shift line, nudge | canvas | `Compositor/Document/Selection.swift:272` (moveSelection); `Compositor/Document/SelectionEdits.swift:182` (movePixels); `Compositor/Document/SelectionEdits.swift:221` (nudgePixels) | 8863eda,4b04323,60bde4f | SelectionTests,GroupingSelectionTests |
| SEL-08 | Select | Marching ants | canvas | `Compositor/Rendering/EditorCanvas.swift` | 8eba077 | SelectionTests |
| IMG-01 | Image | Curves (points, channels, Reset, preview) | Image › Curves… (Ctrl+M) | `Compositor/Document/Curves.swift`; `Compositor/UI/CurvesControls.swift` | - | ImageAdjustmentTests,FilterTests |
| IMG-02 | Image | Levels (histogram, eyedroppers, Auto, presets, preview) | Image › Levels… (Ctrl+L) | `Compositor/Document/Levels.swift:149` (beginLevels); `Compositor/UI/LevelsSheet.swift` | - | LevelsTests |
| IMG-03 | Image | Hue/Saturation (ranges, targeted hand, colorize, colored tracks) | Image › Hue/Saturation… (Ctrl+U) | `Compositor/Document/HueSaturation.swift:464` (beginHueSaturation); `Compositor/UI/HueSaturationSheet.swift` | c8ed9ba,fe7a83d | HueSaturationTests |
| IMG-04 | Image | Black & White | Image › Black & White… | `Compositor/Document/Filters.swift:25` (FilterKind.blackWhite) | 0d31ccb,6b709b4 | ImageAdjustmentTests,--ui-audit-probe |
| IMG-05 | Image | Color Balance | Image › Color Balance… | `Compositor/Document/Filters.swift:26` (FilterKind.colorBalance) | 0d31ccb,6b709b4 | ImageAdjustmentTests,--ui-audit-probe |
| IMG-06 | Image | Exposure | Image › Exposure… | `Compositor/Document/CameraRaw.swift:58` (FilterKind.exposure) | - | ImageAdjustmentTests |
| IMG-07 | Image | Gradient Map | Image › Gradient Map… | `Compositor/Document/Filters.swift:23` (FilterKind.gradientMap) | - | ImageAdjustmentTests |
| IMG-08 | Image | Grain | Image › Grain… | `Compositor/Document/Filters.swift:24` (FilterKind.grain) | 59b5040 | ImageAdjustmentTests,--ui-audit-probe |
| IMG-09 | Image | Invert / Invert Mask | Image › Invert (Ctrl+I) | `Compositor/Document/SelectionEdits.swift:103` (invertPixels) | 0d31ccb | ImageAdjustmentTests |
| IMG-10 | Image | Canvas Size (anchor, relative, extension color) | Image › Canvas Size… | `Compositor/IO/CanvasResizer.swift`; `Compositor/UI/CanvasSizeSheet.swift` | c580a38 | CanvasSizeTests |
| IMG-11 | Image | Image Size (units, resolution, resample, sampling) | Image › Image Size… | `Compositor/IO/ImageResizer.swift`; `Compositor/UI/ImageSizeSheet.swift` | 555417e | ImageSizeTests |
| IMG-12 | Image | Trim (based on, trim away sides) | Image › Trim… | `Compositor/Document/DocumentHistory.swift:120` (trim); `Compositor/UI/TrimSheet.swift` | feb39f3 | ImageTrimTests |
| IMG-13 | Image | Rotate Canvas 90° CW/CCW, Flip Canvas H/V | Image | `Compositor/Document/CanvasRotation.swift:34` (rotateCanvas); `Compositor/Document/LayerFlip.swift:55` (flipCanvas) | 754f188 | CanvasRotationTests |
| IMG-14 | Image | Convert layer 8↔16 bit; HDR → 16-bit | layer context menu | `Compositor/Document/DeepLayers.swift:298` (convertLayerDepth); `Compositor/Document/DeepLayers.swift:282` (convertHDRToSixteenBit) | 2fe3524,5a2e57f | DeepLayerTests |
| FLT-01 | Filter | Gaussian Blur (Preserve Transparency, solid canvas edges) | Filter › Gaussian Blur… | `Compositor/Document/Filters.swift:8` (FilterKind.gaussianBlur); `Compositor/UI/FilterSheet.swift` | 9a0ad3e | FilterTests |
| FLT-02 | Filter | Motion Blur | Filter › Motion Blur… | `Compositor/Document/Filters.swift:9` (FilterKind.motionBlur); `Compositor/UI/FilterSheet.swift` | - | FilterTests |
| FLT-03 | Filter | Progressive Blur (linear/radial, drag points on canvas) | Filter › Progressive Blur… | `Compositor/Document/Filters.swift:10` (FilterKind.progressiveBlur); `Compositor/UI/FilterSheet.swift` | 3ae11cd | ProgressiveBlurTests |
| FLT-04 | Filter | Add Noise | Filter › Add Noise… | `Compositor/Document/Filters.swift:11` (FilterKind.addNoise); `Compositor/UI/FilterSheet.swift` | - | FilterTests |
| FLT-05 | Filter | Vignette (round, empty layer across canvas) | Filter › Vignette… | `Compositor/Document/Filters.swift:12` (FilterKind.vignette); `Compositor/UI/FilterSheet.swift` | 0488cab | FinishingFilterTests,--ui-audit-probe |
| FLT-06 | Filter | Bloom / Glow | Filter › Bloom / Glow… | `Compositor/Document/Filters.swift:13` (FilterKind.bloomGlow); `Compositor/UI/FilterSheet.swift` | e08dd8c | FinishingFilterTests |
| FLT-07 | Filter | Dither (styles, pixel shape, ASCII) | Filter › Dither… | `Compositor/Document/Filters.swift:14` (FilterKind.dither); `Compositor/UI/FilterSheet.swift` | f3cd4e9,09ab78a,2309a85 | FilterTests |
| FLT-08 | Filter | Scanlines (CRT: displace, threshold, dots, color split, glow) | Filter › Scanlines… | `Compositor/Document/Filters.swift:15` (FilterKind.scanlines); `Compositor/UI/FilterSheet.swift` | 9c99853,06c3a22,1187736,cdde327 | ScanlinesTests,--ui-audit-probe |
| FLT-09 | Filter | Tonal Contrast | Filter › Tonal Contrast… | `Compositor/Document/Filters.swift:16` (FilterKind.tonalContrast); `Compositor/UI/FilterSheet.swift` | e08dd8c | FinishingFilterTests |
| FLT-10 | Filter | Lens Correction | Filter › Lens Correction… | `Compositor/Document/Filters.swift:17` (FilterKind.lensCorrection); `Compositor/UI/FilterSheet.swift` | e08dd8c | FinishingFilterTests,--ui-audit-probe |
| FLT-11 | Filter | Camera Raw Filter (light, color, grading, curves, mixer, detail, optics, geometry, calibration, scopes) | Filter › Camera Raw Filter… | `Compositor/Document/Filters.swift:18` (FilterKind.cameraRaw); `Compositor/UI/FilterSheet.swift` | 9982fad,57ab3bb,75147a2,bdfb9c2,f745d65,f4b7009,9329ab8 | CameraRawTests,CameraRawResetTests,CameraRawSliderTests,CameraRawGPUTests,--ui-audit-probe |
| FLT-12 | Filter | Remove Background (basic/advanced, mask) | Filter › Remove Background… | `Compositor/Document/Filters.swift:19` (FilterKind.removeBackground); `Compositor/UI/FilterSheet.swift` | e08dd8c | FilterTests |
| FLT-13 | Filter | Last Filter (Ctrl+Meta+F) with the same settings | Filter › Last Filter | `Compositor/Document/Filters.swift:751` (repeatLastFilter) | 0415aa4,6b81d4a | — |
| FLT-14 | Filter | Live previews limited to the selection; Preview toggle | filter panels | `Compositor/Document/Filters.swift:770` (updateFilter) | - | LivePreviewTests |
| FLT-15 | Filter | Floating filter panels; Camera Raw docked beside the window | panels | `Compositor/UI/FloatingPanel.swift` | f24dd37,5ddb41e,a5cd7a6 | FloatingPanelTests |
| LAY-01 | Layers | Layers panel: header count, appearance (blend, opacity), list, footer | right panel | `Compositor/UI/LayersPanel.swift` | - | LayerTests |
| LAY-02 | Layers | New Blank Layer | Layer › New Blank Layer; footer + | `Compositor/Document/EditorSession.swift:703` (addBlankLayer) | - | LayerTests |
| LAY-03 | Layers | Folders: Group Selected (Ctrl+G), Ungroup (Shift+Ctrl+G), Move Out of Folder, folder opacity | Layer; footer | `Compositor/Document/LayerGroups.swift:180` (groupSelectedLayers); `Compositor/Document/LayerGroups.swift:233` (ungroupLayers); `Compositor/Document/LayerGroups.swift:319` (moveActiveLayerOutOfGroup) | 391042d,1318f1e,6c3b9a5 | GroupTests |
| LAY-04 | Layers | Duplicate Layer / Layer via Copy (Ctrl+J), multi-select, folders | Layer; context menu | `Compositor/Document/SelectionClipboard.swift:206` (layerViaCopy); `Compositor/Document/SelectionClipboard.swift:232` (duplicateLayers) | 245db93,2f1537f,9f49d67 | GroupTests,LayerTests |
| LAY-05 | Layers | Rename inline (double-click), Rename Layer… | Layer; list | `Compositor/Document/EditorSession.swift:754` (renameLayer) | 8f7d344 | LayerTests |
| LAY-06 | Layers | Show/Hide layer; eye swipe across rows (one undo) | list eye | `Compositor/Document/EditorSession.swift:762` (toggleLayerVisibility); `Compositor/Document/EditorSession.swift:771` (beginVisibilitySwipe) | 8fed2e7 | LayerTests |
| LAY-07 | Layers | Reorder/nest by drag; Option-drag duplicates; middle-drag scrolls the list | list | `Compositor/Document/EditorSession.swift:785` (reorderLayers) | 77a3018,92eba05 | LayerTests |
| LAY-08 | Layers | Move Layer Up/Down (Ctrl+] / Ctrl+[) | Layer | `Compositor/Document/EditorSession.swift:801` (moveActiveLayer) | - | LayerTests |
| LAY-09 | Layers | Merge Down / Merge Layers / Merge Group (Ctrl+E) | Layer; context | `Compositor/Document/LayerMerge.swift:34` (mergeLayers) | - | GroupTests |
| LAY-10 | Layers | Flip Layer H/V | Layer | `Compositor/Document/LayerFlip.swift:24` (flipLayers) | - | TransformTests |
| LAY-11 | Layers | Delete Layer(s) / Mask / Effect | Layer; footer trash | `Compositor/Document/SelectionEdits.swift:84` (deleteLayerOrMask) | - | LayerTests |
| LAY-12 | Layers | Blend modes (all Photoshop modes, grouped), hover preview on canvas, Shift+/- cycling | appearance picker | `Compositor/Document/LayerAppearance.swift:130` (setLayerBlendMode); `Compositor/Document/LayerAppearance.swift:80` (previewBlendMode); `Compositor/Document/LayerAppearance.swift:124` (cycleBlendMode) | 09a65db,e521ca0,121a15f | BlendShortcutTests,LayerAppearanceTests |
| LAY-13 | Layers | Opacity slider/field; 1–0 keys | appearance; keys | `Compositor/Document/LayerAppearance.swift:99` (setLayerOpacity) | - | LayerAppearanceTests |
| LAY-14 | Layers | Layer context menu (duplicate, rename, delete, clipping, group, merge, depth, masks, visibility) | right-click row | `Compositor/UI/NativeLayerList.swift` | 6fa115e,2f1e796,5c5f05b | LayerTests |
| LAY-15 | Layers | Thumbnails for pixel layers, masks (white/black background), adjustment/effect rows | list | `Compositor/UI/NativeLayerList.swift` | a247676 | LayerTests,--ui-audit-probe |
| LAY-16 | Layers | Reveal selected layers in the list; no gray flash | list | `Compositor/Document/LayerGroups.swift:156` (revealActiveLayer) | d2b8aaf,06313a9 | LayerTests |
| LAY-17 | Layers | Panel width drag (222–352) | panel edge | `Compositor/ContentView.swift:4` (ContentView) (PanelResizeEdge) | 0a5c8d9 | — |
| LAY-18 | Layers | Cursor feedback: duplicate pointer with eye over mask (Option) | list hover | `Compositor/UI/NativeLayerList.swift` | 6955a6f | CursorTests |
| MSK-01 | Masks | Add layer mask (reveals selection; Option = black) | footer mask button; context | `Compositor/Document/LayerMask.swift:270` (addLayerMask) | b3419ab | LayerMaskTests |
| MSK-02 | Masks | Paint/fill/invert/blur mask, paint anywhere on canvas, feather past pixels | brush on mask | `Compositor/Document/LayerMask.swift` | e753f26,2ffb092 | LayerMaskTests,SelectionFeatherTests |
| MSK-03 | Masks | Disable/Delete/Link/Unlink mask; move unlinked mask | context; link click | `Compositor/Document/LayerMask.swift:279` (toggleLayerMask); `Compositor/Document/LayerMask.swift:319` (toggleMaskLink) | 8d2eade | MaskTransformTests,LayerMaskTests |
| MSK-04 | Masks | Option-drag copies masks between layers | list drag | `Compositor/Document/LayerMask.swift:305` (copyMask) | 77a3018 | LayerMaskTests |
| MSK-05 | Masks | Clipping masks (Ctrl+Alt+G, Option-click boundary), folder masks | Layer | `Compositor/Document/LiveLayerMask.swift:221` (toggleClippingMask) | 77a3018 | LiveMaskTests |
| ADJ-01 | Adjustment layers | New Adjustment Layer (12 kinds) via menu and footer | Layer › New Adjustment Layer; footer | `Compositor/Document/LayerAdjustment.swift:208` (addAdjustment) | 98ad817,24052b5,067fca4 | AdjustmentLayerTests,--ui-audit-probe |
| ADJ-02 | Adjustment layers | Edit Adjustment (re-edit), live preview, cancel restores | Layer › Edit Adjustment…; double-click | `Compositor/Document/AdjustmentEditing.swift:6` (beginAdjustmentEditing) | - | AdjustmentLayerTests |
| ADJ-03 | Adjustment layers | HDR-revealing adjustment layers | - | `Compositor/Document/AdjustmentEditing.swift` | b9186f7 | DeepLayerTests |
| FX-01 | Layer effects | Stroke, Drop Shadow, Inner Shadow, Color Overlay, Outer Glow, Inner Glow | footer ✦ menu | `Compositor/Document/LayerEffects.swift:247` (addEffect); `Compositor/UI/EffectsSheet.swift` | cdd8eb6,f11017a,cd0ca3c,e7e295e,9cb57db | OuterGlowTests,InnerGlowTests,ColorOverlayTests |
| FX-02 | Layer effects | Effects persist through snapshots, text edits, size changes, undo | - | `Compositor/Document/LayerEffects.swift:327` (changeEffects) | 6230e41,94e90bd,b683acb | LayerEffectsSurviveTests |
| FX-03 | Layer effects | Effect rows in list: toggle, select, Option-drag copy, delete | list | `Compositor/Document/LayerEffects.swift:364` (toggleEffect); `Compositor/Document/LayerEffects.swift:344` (copyEffect) | - | LayerTests |
| TRF-01 | Transform | Move/scale/rotate/flip non-destructively; handles; Show Controls | Move tool (V) | `Compositor/Document/EditorSession.swift:445` (beginTransform); `Compositor/Document/EditorSession.swift:484` (commitTransform) | - | TransformTests,TiledLayerTests |
| TRF-02 | Transform | Typed X/Y/W/H/Scale/angle values preview live, one undo step; arrow steps; label scrub | Transform bar | `Compositor/UI/TransformInspector.swift` | 686d8c7,2d36d6e | TransformTests |
| TRF-03 | Transform | Free Transform (Ctrl+T), Cancel/Apply only when pending | Layer › Transform Layer | `Compositor/Document/FloatingSelection.swift:22` (transformCommand) | 67cc31e | TransformPressTests |
| TRF-04 | Transform | Distort with Ctrl-drag handle; Shift locks axis | canvas | `Compositor/Document/Distort.swift:264` (beginDistort) | 7111885 | DistortTests |
| TRF-05 | Transform | Auto Select (Command flips), aspect lock (Shift flips) live in bar | Transform bar | `Compositor/UI/HeldModifiers.swift` | bca8f13,691bfd4,26acd89 | TransformPressTests |
| TRF-06 | Transform | Sampling choice (High quality / nearest) | Transform bar | `Compositor/Document/LayerTransform.swift:4` (LayerSampling) | - | TransformTests,--ui-audit-probe |
| TRF-07 | Transform | Several layers / folder together; transform selection | canvas | `Compositor/Document/FloatingSelection.swift:27` (beginSelectionTransform) | - | TransformTests,GroupTests |
| TRF-08 | Transform | Snap moves/resizes to Snap To targets | canvas | `Compositor/Document/Crop.swift:122` (snappedMove); `Compositor/Document/Crop.swift:143` (snappedResizePoint) | c459f88 | ResizeSnapTests |
| TOOL-01 | Tools | Tool rail with 15 tools + color palette; key shortcuts; tool-mode icons | left rail | `Compositor/ContentView.swift:310` (ContentView.toolRail); `Compositor/Document/EditorSession.swift:90` (NavigationTool) | - | CompositorTests,--ui-audit-probe |
| TOOL-02 | Tools | Marquee rectangle/ellipse (M cycles), Shift square/circle, Option center | M | `Compositor/Document/Selection.swift:184` (pressMarqueeKey); `Compositor/Document/Selection.swift:155` (dragMarquee) | 8863eda | SelectionTests,EllipseSelectionBooleanTests |
| TOOL-03 | Tools | Lasso freehand/polygonal (L cycles), anti-alias | L | `Compositor/Document/Selection.swift:141` (beginLasso); `Compositor/Document/Selection.swift:204` (toggleLassoKind) | - | SelectionTests |
| TOOL-04 | Tools | Magic tool: Wand (tolerance, sample size, layers, contiguous) | W | `Compositor/Document/MagicWand.swift:98` (magicWand) | - | MagicWandTests |
| TOOL-05 | Tools | Magic tool: Object mode (click traces object, edge offset); Tab switches | W, Tab | `Compositor/Document/ObjectSelection.swift:273` (selectObject) | 8ccfcf0,886d178,8c5fade | SelectionTests |
| TOOL-06 | Tools | Crop with ratios (3:4, 9:16…), snapping, Option symmetric, start from selection | C | `Compositor/Document/Crop.swift:236` (commitCrop); `Compositor/Document/Crop.swift:230` (changeCropRatio) | 5ece82b,8b5a6af | CropTests |
| TOOL-07 | Tools | Brush paint/erase (B/E), size/hardness/opacity/smoothing, Shift lines, right-drag size | B/E | `Compositor/Document/EditorSession+Brush.swift:50` (beginBrush); `Compositor/Document/BrushStroke.swift` | 8b0215e,89dfb56 | BrushTests,LargeCanvasBrushTests,BrushIntersectionTests |
| TOOL-08 | Tools | Spot Healing (content-aware, create texture, proximity) | J | `Compositor/Document/ContentFill.swift` | 23913d3 | SpotHealingTests |
| TOOL-09 | Tools | Clone Stamp (aligned, this/all layers, Option-click source) | S | `Compositor/Document/CloneStamp.swift:14` (setCloneSource) | d3170ab | CloneStampTests |
| TOOL-10 | Tools | Smear: Liquify / Blur / Smudge (strength, radius) | R | `Compositor/Document/SmudgeLiquify.swift:215` (beginWarp); `Compositor/Document/SmudgeLiquify.swift` | 89dfb56,7164dd4,ad9ad7c,504129d | BlurBrushTests,MetalWarpTests |
| TOOL-11 | Tools | Gradient linear/radial, styles, reverse, opacity, editable ends, 16-bit | G | `Compositor/Document/Gradient.swift:54` (beginGradient); `Compositor/Document/Gradient.swift:111` (commitGradient) | - | GradientTests |
| TOOL-12 | Tools | Shape rectangle/ellipse/line, live shape layers, radius, smooth corners | U | `Compositor/Document/ShapeTool.swift:111` (beginShape); `Compositor/Document/ShapeTool.swift` | 1c26aff,9f1d158,9b3f48e | ShapeToolTests |
| TOOL-13 | Tools | Type: boxes, multiline, per-letter color/font, tracking, leading, alignment, font previews | T | `Compositor/Document/TypeTool.swift:235` (beginText); `Compositor/UI/TypeControls.swift` | cdd8eb6,2bfc4ea,0eaeb98,1bd1df4,916d1ab | TypeToolTests |
| TOOL-14 | Tools | Eyedropper with sample ring; Option temporary eyedropper in paint tools | I | `Compositor/Document/ColorPalette.swift:239` (sampleCompositeColor) | - | ColorPickerTests |
| TOOL-15 | Tools | Hand (closed hand for whole pan), Space temporary hand | H / Space | `Compositor/Rendering/EditorCanvas.swift` | c0a1cd0 | CompositorTests |
| TOOL-16 | Tools | Zoom tool: click/Option-click, drag to zoom, typed percent, cursors flip immediately | Z | `Compositor/Document/EditorSession.swift:1074` (zoom) | 8fed2e7,fc4c273 | CursorTests |
| TOOL-17 | Tools | No tool (A) | A | `Compositor/Document/EditorSession.swift:93` (NavigationTool.idle) | - | — |
| TOOL-18 | Tools | Color palette: foreground/background, swap (X), reset (D), full color picker | rail swatches | `Compositor/UI/ColorPaletteControls.swift`; `Compositor/UI/ColorPickerSheet.swift` | e6060e8(L) | ColorPickerTests |
| TOOL-19 | Tools | Tool cursors (pictured cursors per tool/mode) | canvas hover | `Compositor/Rendering/EditorCanvas.swift` | dd40969(L) | CursorTests |
| TOOL-20 | Tools | Brush can't paint → reason shown | canvas | `Compositor/Document/EditorSession.swift:348` (brushError) | 133c34a | BrushTests |
| RND-01 | Rendering | Layer compositing, all blend modes (sRGB dodge/burn, Core Image soft light) | - | `Compositor/Rendering/LayerRenderer.swift` | 121a15f,5a8f6ce | LayerAppearanceTests,LivePreviewTests |
| RND-02 | Rendering | Tiled layer rendering, raster snapshots | - | `Compositor/Rendering/TiledLayerRenderer.swift`; `Compositor/Rendering/RasterSnapshot.swift` | - | TiledLayerTests,RasterSnapshotTests |
| RND-03 | Rendering | Layer effects GPU kernels | - | `Compositor/Rendering/MetalLayerEffects.swift` | f11017a | OuterGlowTests,InnerGlowTests |
| RND-04 | Rendering | Brush coverage GPU | - | `Compositor/Rendering/MetalBrushCoverage.swift` | - | BrushTests |
| RND-05 | Rendering | Warp (Liquify/Smudge) GPU | - | `Compositor/Rendering/MetalWarp.swift` | 91cb0b1 | MetalWarpTests |
| RND-06 | Rendering | Camera Raw lookup GPU (verified Metal lookup) | - | `Compositor/Rendering/MetalCameraRawLookup.swift` | 9329ab8 | CameraRawGPUTests |
| RND-07 | Rendering | GPU noise/grain | - | `Compositor/Rendering/GPUNoise.swift` | - | GPUCanvasTests |
| RND-08 | Rendering | 16-bit and HDR pipelines (deep pixels, dithering to 8 bit) | - | `Compositor/Rendering/DeepPixels.c` | d9cdb81,6aea90a,bdcedf2 | DeepLayerTests |
| RND-09 | Rendering | Color management: import profile conversion, export tags, CMYK via ICC | - | `Compositor/IO/ImageImporter.swift`; `Compositor/IO/CMYK.swift` | 59025aa | CMYKTests,ImageImportTests |
| RND-10 | Rendering | Text shaping/drawing (Core Text) | - | `Compositor/Document/TypeTool.swift`; `Compositor/Rendering/InlineTextEditor.swift` | - | TypeToolTests |
| KEY-01 | Input | Photoshop-style shortcuts, remappable, Linux key names | global | `Compositor/UI/KeyboardShortcuts.swift` | 391042d,87e2283 | KeyboardShortcutTests |
| KEY-02 | Input | Numeric label scrubbing (drag a label) | panels | `Compositor/UI/NumericScrub.swift` | 2d36d6e,680a522 | SliderSnapTests |
| KEY-03 | Input | Slider click animation / snap | panels | `Compositor/UI/SliderSnap.swift` | 95c1ddc | SliderSnapTests,CameraRawSliderTests |
| KEY-04 | Input | Touch / pen input | canvas | `Compositor/Rendering/EditorCanvas.swift` | - | — |
| KEY-05 | Input | Tool options bars never show a scroll bar; headers scroll when narrow | headers | `Compositor/ContentView.swift` | 7311d69,68396ff | — |

## Removed or superseded upstream behavior (not active requirements)

| Commit | What changed |
|---|---|
| `8837709` | Camera Raw upright modes that ignore the picture |
| `5d7adba` | Layer Effects entry in the layer context menu |
| `d0aae29` | Dither styles reduced |
| `67301d2` | Text box undo PR #93 reverted |
| `d076c28` | Verify-tests-on-push workflow reverted (later restored by f0ccb6e) |
| `a00d8b6` | New Canvas remembering print units (always starts in pixels, transparent, 72 DPI) |
| `6b81d4a / 720c121` | Command palette moved off F; Last Filter moved from ⌘F to ⌃⌘F |
| `3e09948` | Navigator above the Layers panel (6490bb3) replaced by an in-canvas minimap |
| `3e97eb3 → a5cd7a6` | Camera Raw beside the window instead of docked, then docked again |

## Upstream tests

89 files in `CompositorTests/` (652 `@Test` functions + 10 XCTest methods; parameterized cases expand at run time) and 1 XCUITest file (`CompositorUITests/ScreenshotTests.swift`).

