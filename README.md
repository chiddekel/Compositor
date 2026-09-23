# Compositor

Adobe Photoshop costs too much and tools like GIMP don’t feel familiar enough for me to stay in flow. That’s why I built Compositor.

The goal was to create a full-featured image editor that is completely free and open source. I use Photoshop for compositing and post-processing, so Compositor is built around that workflow - with the tools needed to create a pixel-perfect final image.

Because it’s open source, you can download the Xcode project and add, remove, or modify any feature to fit your workflow.

**Jump to:** [Features](#features) · [macOS build](#requirements) · [**Linux port**](#linux-port) · [Releasing](#releasing) · [License](#license)

## Features

### Layers
- Layers and folders, with blend modes and opacity — a folder's opacity dims everything inside it
- Layer masks: paint, fill, invert, blur and feather them; link or unlink them to transform a mask on its own
- Clipping masks and folder masks
- Adjustment layers: Hue/Saturation, Levels, Curves, Exposure, Gradient Map and Grain
- Layer effects: Stroke, Drop Shadow, Color Overlay, Inner Shadow and Outer Glow, rendered on the GPU and editable at any time
- Merge Down, Merge Layers and Merge Group (⌘E)
- Duplicate, rename inline, reorder and nest by drag and drop; Option-drag to duplicate
- Drag layers between open projects

### Transform
- Non-destructive move, scale, rotate and flip — images keep their full resolution however small you make them
- Free distort (⌘-drag a handle), with Shift to lock to an axis
- Transform several layers, or a whole folder, together
- Snapping to canvas and layer edges and centers, with guides
- Exact values for position, size, scale and angle, stepped with the arrow keys
- Flip Layer and Flip Canvas, horizontal and vertical

### Selections
- Rectangle and Ellipse Marquee, Freehand and Polygonal Lasso, and the Magic tool — Wand selects by color, Object traces whatever you click (Tab switches)
- Select Subject, and Expand, Contract and Feather on any selection
- Add to and subtract from selections, move the outline, or move and duplicate the pixels inside
- Load a layer's pixels or a mask as a selection
- Content-Aware Fill, which can also extend an image past its edges

### Painting and retouching
- Brush with size, hardness, opacity and smoothing, in Paint or Erase mode (B and E), and Shift for straight lines
- Spot Healing Brush (content-aware)
- Clone Stamp, aligned or not, sampling one layer or all of them
- Blur tool, on pixels or masks
- Gradient tool and Shape tool (rectangles, rounded rectangles, ellipses and lines), which stay editable rather than being rasterized
- Type tool (T): inline multiline editing in draggable, resizable paragraph boxes; font, size, color, alignment and spacing in the tool header; transform text and use it as a clipping mask
- Eyedropper and a full color picker

### Adjustments and filters
- Levels (with Auto), Curves, Hue/Saturation, Exposure, Gradient Map, Grain and Invert
- Gaussian Blur and Motion Blur that spread past a layer's edges
- Add Noise, Lens Correction and Remove Background
- Live previews, limited to the selection when there is one

### Canvas and files
- Multiple projects in tabs
- Rulers (⌘R), guides dragged from them, a layout grid, and Snap To for guides, grid, layers and document bounds
- Crop with snapping, and Option for symmetric cropping
- Canvas Size and Image Size
- Sharp high-quality downsampling when zoomed out, and a pixel grid when zoomed in
- Import JPEG, PNG, HEIC, TIFF and Photoshop PSD (8-bit RGB only; not PSB or CMYK). PSD folders, masks, a subset of blend modes, and fill rectangles/ellipses stay editable; text and other vectors become pixels. A conversion report is shown before anything is applied.
- Export JPEG with a live preview (⇧⌥⌘S); Copy Merged
- Photoshop-style keyboard shortcuts throughout, remappable in Edit > Keyboard Shortcuts
- Automatic updates, signed and notarized

## Requirements

- macOS 26.5 or later
- Xcode 26 or later (to build from source)

## Building

Open `Compositor.xcodeproj` and run the **Compositor** scheme.

## Linux Port

Runs on GNU/Linux via Flatpak. Upstream Swift/SwiftUI compiles unmodified against a Linux
compat layer (AppKit/CoreGraphics/SwiftUI) — same look and behavior as macOS, custom title
bar included.

### Requirements

```
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub \
    org.kde.Platform//6.11 org.kde.Sdk//6.11 \
    org.freedesktop.Sdk.Extension.swift6//26.08
```

Version must match the manifest's `runtime-version` — mismatched SDK/runtime fails to link.

### Run it

```
flatpak-builder --user --install --force-clean build-dir com.wonderassembly.Compositor.yaml
flatpak run com.wonderassembly.Compositor
```

No native title bar: drag the header to move the window, double-click to maximize.

Headless: `QT_QPA_PLATFORM=offscreen flatpak run com.wonderassembly.Compositor --help`

### Dev loop

[`scripts/run-compositor.sh`](scripts/run-compositor.sh) — builds from the working tree, runs from `.build/`, seconds not minutes:

```
./scripts/run-compositor.sh              # build + run
./scripts/run-compositor.sh --offscreen  # headless
```

Smoke tests (add `--offscreen`):

| Flag | Checks |
|---|---|
| `--session-smoke` | new/paint/render/undo/redo/close |
| `--dialog-smoke` | resize, undo, autosave, save/reopen |
| `--io-smoke` | image codecs |
| `--layers-smoke` | layers dock |
| `--brush-smoke` | brush + blend + paint |

<details>
<summary>Manual build (what the script automates)</summary>

```
flatpak-builder --run build-dir com.wonderassembly.Compositor.yaml bash
# inside the sandbox:
export PATH=/usr/lib/sdk/swift6/bin:$PATH
swift build -c release --static-swift-stdlib
cmake -S . -B build -DCMAKE_PREFIX_PATH=/app \
    -DQt6_DIR=/usr/lib/x86_64-linux-gnu/cmake/Qt6 \
    -DOpenCV_DIR=/app/lib/cmake/opencv4 \
    -DCompositorCore_SWIFT_STATIC_LIB=$PWD/.build/release/libCompositorCore.a
cmake --build build
QT_QPA_PLATFORM=offscreen ctest --test-dir build --output-on-failure
```

Skia/OpenCV source isn't committed; `flatpak-builder` fetches and verifies it (pinned hashes in
the manifest). See [`third_party/skia.pinned`](third_party/skia.pinned) / [`third_party/opencv.pinned`](third_party/opencv.pinned).

</details>

### Docs

| | |
|---|---|
| [`docs/platform-abstraction.md`](docs/platform-abstraction.md) | macOS API → Linux/Qt mapping |
| [`docs/linux-port-file-map.md`](docs/linux-port-file-map.md) | which files are reused vs. replaced |
| [`docs/project-format.md`](docs/project-format.md) | the `.comp` file format |
| [`linux/upstream-parity.json`](linux/upstream-parity.json) | every UI override, and why |
| [`linux/UPSTREAM_TEST_EXCLUSIONS.md`](linux/UPSTREAM_TEST_EXCLUSIONS.md) | skipped upstream tests, and why |

**Contributing:** extend `Sources/Compat/` before adding to `Sources/Overrides/`. Overrides are
a last resort for the handful of cases that need the Objective-C runtime or missing AppKit —
same public API either way.

### Known issues

- Camera Raw / Image Trim render blank on Linux — pixel-kernel portability gap, not wiring.

## Releasing

`scripts/release.sh` builds a Release version, signs it with Developer ID, notarizes and staples it, and packages it into `dist/Compositor-<version>.dmg`.

It needs, all kept outside this repository:

- a **Developer ID Application** certificate in the login keychain
- notarization credentials saved with `xcrun notarytool store-credentials "compositor-notary" …`
- [`create-dmg`](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`)

## License

MIT — see [LICENSE](LICENSE).
