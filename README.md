# Compositor

Adobe Photoshop costs too much and tools like GIMP don’t feel familiar enough for me to stay in flow. That’s why I built Compositor.

The goal was to create a full-featured image editor that is completely free and open source. I use Photoshop for compositing and post-processing, so Compositor is built around that workflow - with the tools needed to create a pixel-perfect final image.

Because it’s open source, you can download the Xcode project and add, remove, or modify any feature to fit your workflow.

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

### Linux (Flatpak)

The Linux port builds entirely inside the Flatpak SDK sandbox — it never links
the build host's installed system libraries. Qt6 comes from the KDE SDK, pinned to the exact
`runtime-version` in the manifest (currently 6.11) — a binary built against one SDK version
and run against another fails to link (`Qt_6.11 not found`), so always match the manifest,
never hardcode a version in a script. Swift comes from the `swift6` SDK extension (Freedesktop
26.08 branch, Swift 6.3.3), and Skia + OpenCV are vendored as pinned Flatpak modules compiled
into `/app`.

Install the runtime, SDK, and Swift extension (one-time):

```
flatpak install --user flathub \
    org.kde.Platform//6.11 org.kde.Sdk//6.11 \
    org.freedesktop.Sdk.Extension.swift6//26.08
```

Build and install the app:

```
flatpak-builder --user --install --force-clean build-dir \
    com.wonderassembly.Compositor.yaml
```

Run:

```
flatpak run com.wonderassembly.Compositor
```

The window has no native title bar, matching the macOS build's look: it draws its own
close/minimize/maximize dots in the header. Drag that header's empty background to move the
window, and double-click it to maximize/restore.

Headless smoke test (no display):

```
QT_QPA_PLATFORM=offscreen flatpak run com.wonderassembly.Compositor --help
```

Local development (build from the working tree inside the sandbox):

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

The Skia and OpenCV source archives are not committed to the repo; `flatpak-builder`
fetches and verifies them (pinned `sha256` in the manifest) at build time.
Provenance records live in `third_party/skia.pinned` and `third_party/opencv.pinned`.

#### Fast dev loop: `scripts/run-compositor.sh`

For day-to-day work you don't need the full `flatpak-builder --install` cycle above — it
recompiles from `com.wonderassembly.Compositor.minimal.yaml` (debug, no Skia/OpenCV source
build) and runs the binary straight out of `.build/`, so edit-build-run is seconds, not minutes:

```
./scripts/run-compositor.sh                 # builds (if needed) and runs against your display
./scripts/run-compositor.sh --offscreen      # headless (QT_QPA_PLATFORM=offscreen)
```

The script reads the required KDE SDK version from the manifest itself rather than assuming
one — do the same in any script you add here, so it can't drift out of sync the way a hardcoded
version eventually will.

It also drives the Qt smoke-test suite (`host/DialogJourney.cpp`), each a real `SessionWindow`
exercised end-to-end against fake platform services — the fastest way to check nothing broke:

```
./scripts/run-compositor.sh --offscreen --session-smoke   # new/paint/render/undo/redo/close via the Swift ABI
./scripts/run-compositor.sh --offscreen --dialog-smoke    # resize, resolution, undo, autosave, save/reopen
./scripts/run-compositor.sh --offscreen --io-smoke        # Qt image codec plugins
./scripts/run-compositor.sh --offscreen --layers-smoke    # layers dock: add/duplicate/select/delete/group/mask
./scripts/run-compositor.sh --offscreen --brush-smoke     # brush palette + blend + paint
```

## Releasing

`scripts/release.sh` builds a Release version, signs it with Developer ID, notarizes and staples it, and packages it into `dist/Compositor-<version>.dmg`.

It needs, all kept outside this repository:

- a **Developer ID Application** certificate in the login keychain
- notarization credentials saved with `xcrun notarytool store-credentials "compositor-notary" …`
- [`create-dmg`](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`)

## License

MIT — see [LICENSE](LICENSE).
