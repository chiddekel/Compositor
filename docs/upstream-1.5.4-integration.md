# Upstream 1.5.4 integration on GNU/Linux

Target: `upstream/main` at `2f4cb15`, following `365b574` (1.5.3). Linux release: `1.5.4-linux-alpha.1` on `GNU_Linux`.
Protected app sources, tests and the Xcode project remain identical to
the upstream target; Linux changes belong to the framework compatibility modules, generated overrides and host adapters.

## Updates after the published 1.5.4 baseline

The foundation through `8e4b63b` is committed locally at `9fbb840`. The current merge
advances protected sources to `9fe0c72`, which adds Channel Pack export. Its domain code,
Export As controls and three original tests compile unchanged. Collection-element bindings,
vImage image-buffer conversion and straight-RGBA ImageIO support live in the compatibility modules.
Source images retain their original samples separately from their premultiplied drawing pixels,
so RGB beneath zero alpha survives PNG export and source-sample extraction. A bounded per-thread
constructor handoff keeps inline borrowed color-space arguments alive until vImage takes ownership.

The normal SDK contract run has passed **1,029 Swift Testing checks** (981 main and 48 shared-state)
and **159 XCTest checks**, plus native backend checks and source coverage. Its **39 native journeys
are still running**: this is not yet a successful full-run result. Evidence:
`/tmp/compositor-upstream9fe0c72-contract.log`.

Focused native checks pass for Channel Pack's hidden named layers, four source bindings,
transparent RGB file samples, remembered choices and source/history isolation
(`/tmp/compositor-channel-pack-native4.log`). An independent PNG chunk/filter decoder also verifies
zero/partial-alpha samples, DPI metadata and unchanged legacy premultiplied decoding; repeat with
`python3 tests/test_straight_png.py /path/to/libCompositorQtImageIO.so` inside the SDK.

Alpha.3 Linux CI run `39662326130` failed its font-picker Undo check; its release build
`39662325005` succeeded. The bridge now reports transient text-style preview state, so native history
records a font choice on commit. The native regression passes multiple highlights, Cancel, exact
mixed-font restoration with one Undo and exact Redo (`/tmp/compositor-ci-font-history-positive2.log`).

Opening at 100% also exposed the older Linux 16-point resize hit area covering a 32-pixel object's
whole height. The generated override now limits hit reach to one third of the shortest edge,
preserving a draggable interior and wider mouse/touch targets on larger objects. The mouse/touch
geometry regression and exact live mask-coverage probe pass (`TouchTargetsTests` and
`/tmp/compositor-mask-drag-focused-positive.log`). Pixel-oracle fixtures explicitly disable Snap;
crop and dedicated snapping checks retain it. The previous full 8e4b63b run's seven native failures
are recorded in `/tmp/compositor-upstream8e4b63-contract-final.log`; that run was nonzero.

The next integration target is the newly observed upstream head `fc02107`: RGB Split, additional
filter adjustment layers and Photoshop artboards. Those four follow-up commits are not merged yet.

The upstream viewport now caps opening/import fitting at 100%, allows explicit Fit to enlarge,
and preserves zoom while recentering after Image Size. Those algorithms compile unchanged;
the existing EditorSession generator carries its updated explicit Fit call.

Save/Open presentation marks the active AppKit file panel, restoring the previous panel after
nested presentation. Generated application commands consult that marker; native Qt text controls
keep their own clipboard and undo history. No document-history algorithm is duplicated.

The generated LatinKeys override retains upstream's event translation and guards, replacing only
Carbon layout lookup with `NSKeyboardLayout`. The Qt host supplies the person's Latin character
from XKB: the current X11 device map or a compositor-provided Wayland `wl_keyboard` map. Shift is
evaluated in that layout, including punctuation; a non-ASCII Latin-layout result is left unchanged.
With only non-Latin layouts configured, the adapter uses a US fallback, as Qt's shortcuts do.
Native text input remains unchanged. The SDK/runtime provide xkbcommon, xkbcommon-x11 and
wayland-client; no additional source downloads are introduced.

Current targeted verification passes: three upstream viewport tests; 17 keyboard, modal ownership
and file-panel Swift tests; native Qt Open/Save clipboard and Undo/Redo; eight real X11 key-event
cases and four Wayland keymap cases. The latter distinguish US, German and French layouts, shifted
punctuation, and non-ASCII preservation. Current source coverage accounts for 160 upstream files:
132 unchanged, 21 generated, five replacements and two platform substitutions, plus 91 unchanged test
files and two generated test mirrors (`/tmp/compositor-upstream9fe0c72-source-coverage.json`); all 11 coverage
fault tests pass. Full regression verification is still in progress.

Evidence: `/tmp/compositor-upstream8e4b63-viewport.log`, `-targeted.log`, `-file-panels.log`,
`-keyboard.log` and `-contract.log`. To repeat the isolated layout acceptance, build the CMake
`test_keyboard_layout` target and run `python3 tests/test_keyboard_layout.py` on the host.
The default executable is `.build/linux-contract-native/test_keyboard_layout`;
`COMPOSITOR_KEYBOARD_PROBE=/absolute/path/to/test_keyboard_layout` selects another build.
It requires Xvfb, Weston, xkbcli, xkbcomp,
X11/XTest libraries and the KDE 6.11 SDK. Every display and keymap is private to the tests.
Wayland cases check actual compositor-provided keymaps; real injected key events are checked on X11.

## Architecture

- Qt pen events pass through `ITabletHandler` and `compositor_canvas_tablet` to the original `CanvasView`. Pressure
  travels with the event, without rewriting brush settings. `PenInput` and pressure controls are upstream code.
- `BrushCoverageRequest` carries endpoint radius/strength and optional soft-opacity caps. The pressure CPU kernel
  follows upstream's continuous coverage math and preserves provisional tails. Existing uniform CPU/Vulkan coverage
  remains available. Variable pressure currently falls back to CPU through the existing backend contract.
- Core Graphics exposes PDF page geometry and drawing through a dynamically loaded Poppler backend. The backend
  parses and rasterizes; the original `ImageImporter` applies page order, 300-DPI sizing, canvas fitting and budgets.
  Poppler and its character-map data are pinned in the Flatpak manifest and `scripts/build-poppler.sh`.
  The existing lossless reader remains available for exact nearest-neighbor redraws of recognized single-raster
  exports with optional mattes; pages with additional PDF operators use the general engine.
- The original font search panel compiles through the selector generator. AppKit child-window hosting, native
  text-field commands and custom pop-up presentation are generic compatibility facilities, not copies of font-search
  logic. Font-family lookup includes the existing platform aliases, native installed-font catalog and font-file
  metadata, including before GUI startup. The menu uses PostScript face names consistently, avoiding duplicate Qt
  family/style aliases. View layout installs tracking areas and honors autoresizing masks for the original panel.
- Line styles, caps, pixel alignment, scaled-line rasterization and project format 15 use the shared upstream code.
  The Linux text/shape golden was reviewed and refreshed: 56 changed pixels, confined to the line region
  (`x=19...33`, `y=29...46`); text and the other shapes are unchanged.

## Verification

| Check | Current evidence |
|---|---|
| Protected source and generator integrity | `scripts/check-upstream-clean.sh` passes; `/tmp/compositor-upstream154-integrity-final.log` |
| Source/test inclusion | 158 sources: 131 unchanged, 20 generated, 5 replacements, 2 platform substitutions; 90 unchanged test files and 2 mirrors. Eleven coverage fault tests pass. |
| Native pressure kernel | `tests/test_pressure_brush.cpp` passes: variable size/strength, legacy parity, opacity caps, tail replacement and invalid-input preservation |
| Independent PDF renderer | Passes: compressed vectors/text, crop, rotation metadata, transparent paper, exact slice origin, malformed input and password protection |
| Complete Swift suite | 974 tests in the main pass, 45 shared-state tests separately, and 154 XCTest checks pass; `/tmp/compositor-upstream154-final-swift.log` |
| Native UI journeys | All 37 have passing results across the full run and targeted reruns; see the qualification below |
| Native 1.5.4 acceptance | Pen controls/raw pressure/taper/settings isolation/exact Undo/Redo; font search/hover/pointer/arrows/Return/Escape/hide cancellation; independent two-page PDF import at 300 DPI and pixel-identical project save/reopen all pass; `/tmp/compositor-upstream154-final-ui.log` |
| Font layout and rich-text history | 300×440 panel with 300×393 viewport; no shrinking or duplicate Qt aliases. Mixed fonts, Unicode selection, native Undo/Redo and saved font runs pass; `/tmp/compositor-upstream154-final-preview.log` |
| Additional native contracts | RAW lens, text rendering/measurement/named-font aliases, group rotation and persistent grid controls pass; `/tmp/compositor-upstream154-final-extra.log`, `/tmp/compositor-upstream154-final-text.log`, `/tmp/compositor-upstream154-final-group-grid.log` |
| Packaging configuration | Manifest loads with pinned Poppler/data modules and PDF-library installation; AppStream XML loads with `1.5.4-linux-alpha.1`; shell syntax checks pass |

The complete contract run (`/tmp/compositor-upstream154-contract2.log`) passed the Swift suites and 35 of 37 native
journeys. Two old native assertions needed adaptation to upstream 1.5.4: square diagonal caps extend beyond the old
round-cap bounds, and fonts are chosen through the searchable panel rather than by changing the closed combo's index.
The corrected journeys pass in `/tmp/compositor-upstream154-final-combo.log` and
`/tmp/compositor-upstream154-final-preview.log`. The original full-run exit status remains nonzero; these are recorded
as targeted reruns, not a claimed single all-in-one green run. A final five-test adapter rerun also passes after
updating the text-rendering smoke fixture to use PostScript names (`/tmp/compositor-upstream154-final-smoke-build.log`).
The old alias-based text check's failure remains in `final-extra.log`; the passing `final-text.log` supersedes it.

Native kernel/PDF checks run in the KDE 6.11 SDK. The first PDF check exposed opaque paper; enabling
`IgnorePaperColor` fixes it and the independent test now passes. Locked documents reject page queries before entering
the parser's page API; both native and Swift import regressions pass. `tests/fixtures/password-protected.pdf` is a generated
test document, password `compositor-test`, used only to verify locked-document handling.
The independent PDF fixture also verifies the first pixel: rendering a slice from `(0, 0)` avoids an unintended
one-pixel transparent border. Poppler's image interpolation differs from the exporter's exact raster roundtrip;
the recognized-raster path preserves the existing nearest-neighbor behavior.

## Dependency notices

Poppler is distributed under its bundled GPL terms (`third_party/licenses/Poppler-COPYING`). The Flatpak installs
that license and the Poppler-data license notices with the application. The upstream Compositor source retains its
MIT license; distributing the combined Linux binary must also satisfy the bundled dependencies' terms.

## Change inventory

- Framework compatibility: `Sources/Compat/AppKit`, `CoreGraphics`, `PDFKit` and `SwiftUI`.
- Domain adapters and generated source: `Sources/LinuxBridge`, `Sources/Overrides`, `Sources/UpstreamCore`, selector
  generators, source-coverage/parity metadata and the upstream commit ledger.
- Native backends and host: pressure coverage in `backends/brush`, the new `backends/pdf` engine, tablet forwarding,
  generic child-window hosting, font metadata, file import and native acceptance journeys in `host`.
- Build and packaging: `Package.swift`, `CMakeLists.txt`, the Flatpak manifest/desktop/AppStream files, pinned Poppler
  build script, launcher, contract runner, generated version/icons and dependency license notices.
- Verification: `Upstream154Tests.swift`, independent pressure/PDF tests, the password-protected PDF fixture, native
  journey updates and the reviewed Linux line-shape golden.

Inside the KDE 6.11 SDK with the Swift extension and existing renderer dependencies available, reproduce with
`scripts/build-poppler.sh` followed by `scripts/linux-contract-tests.sh --jobs 6`.
Review the integration with `git diff linux-v1.5.3-linux-alpha.5..linux-v1.5.4-linux-alpha.1`.

## Validation limits

- UI journeys use offscreen Qt and synthetic pointer/tablet events. Physical tablet/Wayland input, interactive
  outside-click behavior and comparison against a running Mac have not been tested here.
- macOS/Xcode builds are unavailable on this Linux host; the protected-source gate verifies exact upstream content.
- Poppler and the native libraries were built and tested in the SDK; a complete distributable Flatpak image was not built.
- Variable-pressure strokes use the CPU fallback; uniform strokes retain the existing CPU/Vulkan selection.
