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

Compositor also runs on GNU/Linux, packaged as a Flatpak. The port compiles upstream's own
Swift/SwiftUI source **unmodified** wherever possible — Linux-specific code is a generic
AppKit/CoreGraphics/SwiftUI compatibility layer underneath it, not a per-screen rewrite —
which is why the app looks and behaves like the macOS original, including its own drawn
title bar (see [Quick start](#quick-start) below).

> **This README is the starting point for Linux development.** Everything below links out to
> the deeper reference docs as it goes; you shouldn't need to go spelunking through `docs/` to
> get oriented.

### Requirements

- A Flatpak-capable Linux system ([flatpak.org/setup](https://flatpak.org/setup/))
- `flathub` remote added, and these one-time installs:

  ```
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  flatpak install --user flathub \
      org.kde.Platform//6.11 org.kde.Sdk//6.11 \
      org.freedesktop.Sdk.Extension.swift6//26.08
  ```

  The SDK/runtime version must always match the manifest's `runtime-version` — the KDE SDK
  supplies Qt6, and a binary built against one SDK version fails to link against another
  (`Qt_6.11 not found`). `6.11` is current as of this writing; treat the manifest, not this
  README, as the source of truth if they ever disagree.

Everything else — Swift 6.3.3, and Skia + OpenCV vendored as pinned Flatpak modules — is
pulled in by the sandbox itself. The build **never** links the host system's own libraries.

### Quick start

Build, install, and run the packaged app:

```
flatpak-builder --user --install --force-clean build-dir com.wonderassembly.Compositor.yaml
flatpak run com.wonderassembly.Compositor
```

The window has no native title bar — it draws its own close/minimize/maximize dots in the
header, matching the macOS look. **Drag the header's empty background to move the window**,
and double-click it to maximize/restore.

Headless smoke test (no display needed):

```
QT_QPA_PLATFORM=offscreen flatpak run com.wonderassembly.Compositor --help
```

### Fast dev loop

For day-to-day work you don't need the full install cycle above. [`scripts/run-compositor.sh`](scripts/run-compositor.sh)
rebuilds from the working tree in debug mode and runs the binary straight out of `.build/` —
edit/build/run is seconds, not minutes:

```
./scripts/run-compositor.sh                 # builds (if needed) and runs against your display
./scripts/run-compositor.sh --offscreen      # headless (QT_QPA_PLATFORM=offscreen)
```

The script reads the required KDE SDK version from the manifest itself instead of hardcoding
one, so it can never drift out of sync the way a hand-pinned version eventually will — do the
same in any tooling you add here.

It also drives the Qt smoke-test suite ([`host/DialogJourney.cpp`](host/DialogJourney.cpp)),
each a real `SessionWindow` exercised end-to-end against fake platform services — the fastest
way to check nothing broke:

| Flag | Exercises |
|---|---|
| `--session-smoke` | new / paint / render / undo / redo / close, via the Swift ABI |
| `--dialog-smoke` | resize, resolution, undo, autosave, save/reopen |
| `--io-smoke` | Qt image codec plugins |
| `--layers-smoke` | layers dock: add / duplicate / select / delete / group / mask |
| `--brush-smoke` | brush palette + blend + paint |

```
./scripts/run-compositor.sh --offscreen --session-smoke
```

<details>
<summary><strong>Full local build from the working tree (what the fast dev loop automates)</strong></summary>

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

The Skia and OpenCV source archives are not committed to the repo; `flatpak-builder` fetches
and verifies them (pinned `sha256` in the manifest) at build time. Provenance records live in
[`third_party/skia.pinned`](third_party/skia.pinned) and [`third_party/opencv.pinned`](third_party/opencv.pinned).

</details>

### Architecture & further reading

| Doc | What's in it |
|---|---|
| [`docs/platform-abstraction.md`](docs/platform-abstraction.md) | How every macOS API (CoreGraphics, Metal, Vision, AppKit dialogs, …) maps to its Linux/Qt equivalent behind a shared interface, SOLID-style |
| [`docs/linux-port-file-map.md`](docs/linux-port-file-map.md) | File-by-file disposition of the upstream source tree — what's reused as-is, what's replaced, and why |
| [`docs/project-format.md`](docs/project-format.md) | The `.comp` project package format, shared byte-for-byte between the macOS and Linux builds |
| [`linux/upstream-parity.json`](linux/upstream-parity.json) | Live, per-file record of every `Compositor/UI/*.swift` override still needed on Linux and the reason for each one |
| [`linux/UPSTREAM_TEST_EXCLUSIONS.md`](linux/UPSTREAM_TEST_EXCLUSIONS.md) | Every upstream test excluded on Linux, with the specific reason (never edited, only excluded with cause) |

**The guiding rule for contributing to the Linux port**: prefer extending the generic
compatibility layer (`Sources/Compat/`) over writing Linux-specific code for one panel. An
override under `Sources/Overrides/` is a last resort, reserved for the handful of places that
generically need the Objective-C runtime (`#selector`/`@objc` target-action) or an AppKit
class the compat layer doesn't implement — and even then, it keeps the exact same public API
so nothing upstream has to change to use it. `linux/upstream-parity.json` names every one of
those and explains why.

### Known limitations

- The newest upstream Camera Raw / Image Trim pixel kernels render blank on Linux — a
  portability gap in that native pixel code or the Accelerate/vImage compatibility shim, not
  a build or wiring issue. Tracked, not yet fixed.

## Releasing

`scripts/release.sh` builds a Release version, signs it with Developer ID, notarizes and staples it, and packages it into `dist/Compositor-<version>.dmg`.

It needs, all kept outside this repository:

- a **Developer ID Application** certificate in the login keychain
- notarization credentials saved with `xcrun notarytool store-credentials "compositor-notary" …`
- [`create-dmg`](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`)

## License

MIT — see [LICENSE](LICENSE).
