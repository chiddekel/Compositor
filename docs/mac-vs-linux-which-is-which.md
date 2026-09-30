# Mac vs GNU/Linux Flatpak — which is which

Canonical platform map for branch `GNU_Linux` / tip **Compositor 1.4.5**.  
Product editor logic is shared (UpstreamCore); this page is only **platform substitution**.

## Side-by-side

```
macOS                              GNU/Linux Flatpak
──────────────────────────────     ──────────────────────────────
Xcode / Apple SDK              →   KDE/Freedesktop SDK
Swift compiler                 →   Freedesktop Swift 6 extension
AppKit                         →   Qt 6 + AppKit compat
SwiftUI                        →   SwiftUI compat + Qt host
CoreGraphics                   →   Skia
Metal                          →   Vulkan
Vision                         →   OpenCV DNN
ImageIO                        →   Qt codecs / Linux codec layer
Finder integration             →   XDG/Freedesktop integration
NSOpenPanel                    →   XDG FileChooser portal
App sandbox                    →   Flatpak sandbox
Sparkle                        →   FlatpakUpdateService / portals
Finder Quick Look              →   QuickLook/Preview.jpg + thumbnailer
Dock / Services                →   .desktop Actions + MIME + recently-used
```

## Equivalence table

| macOS-only piece | Linux / Flatpak equivalent | What this branch uses |
|---|---|---|
| **Sparkle updater** | Flatpak update mechanism / AppStream + repository updates | `FlatpakUpdateService` (`org.freedesktop.portal.Flatpak`) + Help → Check for Updates. |
| **Finder Quick Look** | File-manager previewers / thumbnailers (Nautilus, Dolphin, …) | Save writes `QuickLook/Preview.jpg` (same as macOS). `compositor-thumbnailer` + MIME `application/x-compositor-project`. |
| **Finder Services** | `.desktop` actions, MIME handlers, portals, DBus services | `.desktop` Actions (New Canvas…), MIME open (`%F`), XDG portals. |
| **Dock integration** | Freedesktop `.desktop`, StartupWMClass/app-id, task manager | `com.compositor.Client.desktop` + `StartupWMClass`; recently-used.xbel for recents. |
| **AppKit widgets** | Qt 6 Widgets, GTK4/libadwaita, or compat shim | **Qt 6.11** (KDE Platform) + AppKit/SwiftUI compatibility layer. |
| `NSOpenPanel` / `NSSavePanel` | `QFileDialog` → **XDG FileChooser portal** | Implemented this way (no `--filesystem=home`/`host`). |
| `NSPasteboard` | `QClipboard` / XDG clipboard | `IClipboardService` → Qt clipboard. |
| `NSColorPanel` | `QColorDialog` / custom Qt picker | Custom `ColorPickerDialog`. |
| `NSAlert` | `QMessageBox` | Mapped. |
| App Support directory | `XDG_DATA_HOME`, `QStandardPaths::AppDataLocation` | `IStorageLocator`. |
| macOS menu bar | Qt menu + global-menu DBus where available | Manifest allows `com.canonical.AppMenu.Registrar`. |
| Apple `CoreGraphics` | Skia / Cairo / Qt painting | **Skia**, behind a CoreGraphics-compatible Swift module. |
| Apple `ImageIO` | Qt image plugins, libpng/jpeg/webp, … | Qt image backend / compat module (+ libheif, LibRaw where needed). |
| Apple `Vision` | OpenCV / ONNX / other ML | **OpenCV DNN**, including U²-Net-small subject segmentation. |
| Accelerate / vImage | OpenCV / Eigen / SIMD / BLAS | Compat layer + portable kernels / OpenCV. |
| `NSEvent` tablet APIs | `QTabletEvent` | Mapped (`SessionWindow` / `TabletHandler`). |
| **Metal device / queue** | **Vulkan** | Primary GPU path. |
| Metal compute shaders | Vulkan compute + SPIR-V | Brushes / layer effects backends. |
| Metal fallback | CPU / OpenCV / Skia raster | CPU / OpenCV fallback chains. |
| `MTLTexture` API surface | Vulkan images/buffers or CPU-backed compat | Linux **Metal** compatibility surface in `Package.swift` so tip Swift compiles. |
| GPU canvas | Vulkan-backed canvas once parity is validated | **Shipped:** Core Graphics canvas (Mac look). Opt-in GPU present via `COMPOSITOR_FORCE_GPU_CANVAS`. Brush/effects already use Vulkan when available. |
| Xcode | SwiftPM + CMake/Ninja | **SwiftPM + CMake**. |
| Apple Swift SDK | Freedesktop Swift SDK extension | `org.freedesktop.Sdk.Extension.swift6//26.08`. |
| macOS app bundle | Flatpak application | `com.compositor.Client`. |
| macOS sandbox / bookmarks | Flatpak sandbox + Documents/FileChooser portals | No broad `--filesystem=home`/`host`. |
| `.app` resources | `/app/share`, `.desktop`, AppStream, icons | Standard Flatpak/Freedesktop packaging. |

## Shared product (not in the table)

Same tip editor on both platforms: layers, tools, filters, Camera Raw, Dither, selections, `.comp`/PSD/…  
Linux runs that Swift via `Sources/UpstreamCore` + overrides listed in [`linux/upstream-parity.json`](../linux/upstream-parity.json).

## Related

- Feature checklist: [`upstream-release-feature-inventory.md`](upstream-release-feature-inventory.md)
- Manifest: [`com.compositor.Client.yaml`](../com.compositor.Client.yaml)
- Canvas: **mac-vs-linux**
