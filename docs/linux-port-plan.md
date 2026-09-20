# Compositor Linux Port Plan

**Status:** APPROVED & CONVERGED (CEO, Design, Engineering, and DX Reviews Completed)  
**Historical Oracle:** macOS Compositor 1.0.4 (`a19db9011282399785dc18efcfded904627bdcc2`)  
**Implementation Branch:** `eng-1-c-abi-seam`  
**Platform Target:** Flatpak on Freedesktop SDK 26.08, Swift 6 (`org.freedesktop.Sdk.Extension.swift6`), Qt 6.11.2 (Widgets), Skia (Vulkan GPU + Raster CPU fallback), OpenCV 4.14.0 (selected operations)

---

## 1. Architectural Summary & Strategy

The shortest, lowest-risk path to GNU/Linux retains the entire Swift domain core and existing C image-processing kernels while isolating Linux platform components behind a thin C ABI.

```text
                  existing Compositor
               Swift core + existing C
                         │
            ┌────────────┴────────────┐
            │ minimal compatibility  │
            │ + platform boundaries  │
            └────────────┬────────────┘
                         │
        ┌────────────────┼────────────────┐
        │                │                │
        ↓                ↓                ↓
   Qt Widgets      CoreGraphicsCompat   XDG/Qt
   UI + input            │             platform I/O
                         ↓
                   thin C ABI
                         ↓
                       Skia
                    ┌────┴────┐
                    ↓         ↓
                 Vulkan     Raster
                   GPU        CPU

       existing C ────────────────┐
                                  ↓
                       image processing
                           + OpenCV
                         only if useful
```

### Core Decisions
1. **No Swift-to-C++ Rewrite:** C++ exists only on the platform side of the thin C ABI to interface with Qt, Skia, and Vulkan.
2. **CoreGraphicsCompat Shim:** Rather than renaming hundreds of `CGPoint`, `CGRect`, `CGImage`, `CGContext`, and `CGAffineTransform` call sites across the codebase, a narrow compatibility layer (`CoreGraphicsCompat`) wraps Skia surfaces and CPU buffers.
3. **Mandatory CPU Failsafe:** Authoritative document state resides entirely in CPU memory (`PixelBuffer`, `PortableImage`). The GPU is an ephemeral rendering accelerator. If Vulkan initialization fails or a device loss occurs at runtime, the renderer instantly falls back to `SkiaRasterDevice` with zero document corruption.
4. **Qt 6 Widgets Desktop Shell:** Native Linux menus, dock widgets, file dialogs, and a `QTreeView` layer adapter viewing into the Swift `EditorSession`.
5. **Format & Package Integrity:** The `.comp` directory package (with `manifest.json`, `images/`, and `masks/`) is preserved with atomic directory replacement to ensure seamless cross-platform file interchange with macOS 1.0.4.

---

## 2. Source Code Disposition Map

| Component / File Area | Existing Function | Linux Disposition | Strategy |
|---|---|---|---|
| **C Kernels** (`Compositor/Rendering/*.c`) | Adjust, Brush, Heal, Levels, Wand, Noise, Lens, ContentFill | **KEEP (1:1)** | 100% shared C99/C11 code, identical between CMake and SPM |
| **Document Domain** (`Sources/CompositorCore/Document/`) | History, layers, groups, transforms, selections, tools | **KEEP (~85%)** | Preserved behind `CoreGraphicsCompat` geometry and raster buffers |
| **CoreGraphics** (`CGContext`, `CGImage`, `CGPoint`, etc.) | Canvas rendering, raster transformations, clipping | **SHIM** | `CoreGraphicsCompat` wraps Skia Raster & Vulkan surfaces |
| **CoreImage** (`CIFilter` graph) | Color adjustments, blurs, distortion | **ADAPTER** | Dedicated Skia ops + OpenCV where beneficial |
| **ImageIO** (`CGImageSource`, `CGImageDestination`) | PNG/JPEG encoding & decoding | **ADAPTER** | `PlatformImageCodec` using Skia and Qt codecs |
| **Project Packaging** (`NSFileCoordinator`, `FileWrapper`) | Atomic `.comp` file reading & writing | **ADAPTER** | `ProjectPackageIO` with atomic POSIX directory replacement |
| **AppKit / SwiftUI UI** (`UI/*.swift`, `ContentView.swift`) | Desktop windows, sheets, canvas views, layer table | **REWRITE (UI)** | Qt 6 Widgets (`MainWindow`, `CanvasWidget`, `QTreeView`) |
| **Metal Brush** (`MetalBrushCoverage.swift`) | Brush stroke alpha coverage acceleration | **ADAPTER** | CPU path first; optional Vulkan compute shader backend |
| **Sparkle** | macOS update feeds | **REMOVED** | Flatpak updates managed by package manager / AppCenter |

---

## 3. Delivery Stages & Milestones

- **Stage 0 — Flatpak & Toolchain Foundation:** Freedesktop SDK 26.08, `org.freedesktop.Sdk.Extension.swift6` (Swift 6.3.3), Qt 6.11.2, pinned Skia (`canvaskit/0.42.0` with Vulkan+Ganesh), OpenCV 4.14.0.
- **Stage 1 — C ABI Seam:** Bidirectional C ABI (`include/CompositorCore.h`, `EditorBridge.swift`) establishing thread-safe, opaque handle lifecycle.
- **Stage 2 — Portable C Pixel Kernels:** All 8 modules compiled and tested in both CMake and SwiftPM.
- **Stage 3 — Portable Swift Core:** `Document`, `History`, `Transforms`, `Selections`, `Masks` compiled on Linux; passing 412 unit tests.
- **Stage 4 — CoreGraphicsCompat Shim:** Geometry, context, and image compatibility layer (`Context.swift`, `RenderDeviceBinding.swift`).
- **Stage 5 — Skia Raster CPU Backend:** `SkiaRasterDevice` composite pipeline matching macOS golden image references.
- **Stage 6 — Minimal Qt Widgets Shell:** `MainWindow` and `CanvasWidget` running under native Wayland and XWayland with pan/zoom.
- **Stage 7 — Layer Tree & Persistence:** `QTreeView` layer hierarchy, `.comp` package read/write, atomic staging transactions.
- **Stage 8 — Skia Vulkan GPU & Failsafe:** `SkiaVulkanDevice` hardware presentation with automatic dynamic fallback to Raster.
- **Stage 9 — Editing Tools Parity:** Move, Crop, Transform, Brush (CPU), Marquee, Lasso, Magic Wand, Clone Stamp, Healing.
- **Stage 10 — Selected OpenCV Operations:** Content-aware fill, guided matte refinement, specialized filters.
- **Stage 11 — XDG & Desktop Portals:** FileChooser portal, Documents portal persistence, clipboard, drag-and-drop, AppStream metadata.
- **Stage 12 — Full Parity:** HEIC/TIFF codecs, ML background removal, tablet pressure/tilt support.

---

## 4. Verification & Testing Runbook

### Run Swift Core Test Suite (412 tests)
```bash
flatpak run --user --devel --env=FLATPAK_ENABLE_SDK_EXT=swift6 \
  --filesystem="$PWD" --command=sh org.kde.Sdk//6.11 \
  -c 'cd "$PWD" && export PATH=/usr/lib/sdk/swift6/bin:$PATH && swift test'
```

### Build and Run C++ Host Tests & C Kernels
```bash
cmake -S . -B build -DCOMPOSITOR_BUILD_HOST=ON
cmake --build build
ctest --test-dir build --output-on-failure
```

### Build Sandboxed Flatpak Bundle
```bash
flatpak-builder --disable-rofiles-fuse --user --install --force-clean \
  build-flatpak com.wonderassembly.Compositor.yaml
flatpak run com.wonderassembly.Compositor
```
