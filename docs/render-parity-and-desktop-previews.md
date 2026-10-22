# Render parity and optional desktop previews

The shared corpus and desktop providers implement the October 20 follow-up to the
upstream/Linux audit. The protected upstream source, tests and Xcode project are
unchanged. Test infrastructure is separate from application code.

## Independent macOS references

`.github/workflows/render-parity.yml` generates one input artifact, renders it on
macOS and Linux, and compares CPU and Vulkan outputs separately. macOS builds the
matching upstream revision in a disposable checkout with the shared test harness
injected only into that copy. It uses the runner's Xcode on Apple-silicon macOS 26.
The older manual guide's Intel/macOS 15 requirement is incorrect for this upstream
version; the project targets arm64 and macOS 26.

The corpus contains 162 images: every blend mode at two opacities, every adjustment
at three settings (Invert has no settings), nonautomatic filters at two settings, six effects, transforms,
nine text face/size combinations, shapes, color imports, five synthetic Bayer DNGs
and PNG export. The 16-bit and HDR imports also emit full-precision channel samples.
Synthetic RAW fixtures exercise reproducible decoding; they do not establish the
look of every supported camera. Content-aware filling and subject segmentation
retain their separate existing acceptance procedures.

The 1.5.5 macOS run completed all 162 exports, including native development of all
five synthetic RAW inputs. Export success is separate from comparison success:
the first complete comparison exposed Bloom compositing and unflipped text drawing
differences, along with remaining RAW, dither, blur and font rasterization differences.
The category thresholds remain unchanged; consult the comparison artifacts rather
than interpreting a successful exporter as a passing cross-platform parity gate.

Both platforms use the same bundled Inter font files and SWOP ICC profile. Missing
font faces, missing renders, changed inputs, different upstream revisions, wrong
platform labels and image checksum mismatches fail the gate. References are never
created from Linux output. A failed render cannot leave a successful manifest.

The comparator uses report 07's category-specific channel, Delta E 2000, SSIM,
PSNR and glyph-coverage thresholds. Color is compared over black and white mattes;
hidden RGB does not affect a transparent pixel. Deep samples permit 4/65535 absolute
error, plus 1/1024 relative error for half-float HDR. Thresholds are checked into the
comparator, not supplied by a candidate artifact. Difference images amplify errors
8 times; JSON and Markdown reports contain the measured values and failures.

Generate inputs outside a Flatpak, then render inside the normal build environment:

```sh
python3 -m pip install -r scripts/parity-requirements.txt
python3 scripts/parity-inputs.py .build/parity-inputs
# Inside the configured SDK, with the real Skia/ImageIO backends and Qt offscreen:
python3 scripts/render-parity.py --inputs .build/parity-inputs --output .build/parity-linux
# On macOS, use the same input artifact and command with a fresh output directory.
python3 scripts/compare-render-parity.py .build/parity-mac .build/parity-linux --output .build/parity-diff
```

Output directories must be new. The input tree and every render are hashed; each
manifest records its toolchain, OS, backend and upstream revision. Retain the
workflow artifacts together. A local CPU/Vulkan comparison is a Linux regression
check and must never be reported as a Mac comparison.

## Optional host integration

Flatpak does not export its thumbnailer registration to host file managers.
Compositor projects are directories, so exporting a generic `.thumbnailer` file
alone is insufficient. These optional providers read the saved JPEG/PNG under
`QuickLook` directly on the host; they do not start Compositor or change a package.

Nautilus 4 needs PyGObject, GdkPixbuf and the distribution's Nautilus Python loader
(`nautilus-python` or `python3-nautilus`). The provider maintains cached custom icons
through GIO metadata. Existing user icons take priority. Preview content changes
are watched; use the file manager's Refresh command (Ctrl+R) to reload its cached
icon metadata after the first preview or a saved-preview change.

Dolphin needs KDE Frameworks 6 and a plugin built against the host Qt/KIO versions:

```sh
cmake -S desktop/kde -B .build/desktop-preview -DCMAKE_BUILD_TYPE=Release
cmake --build .build/desktop-preview --parallel 2
/usr/bin/python3 scripts/desktop-integration.py install --desktop both \
  --kde-plugin .build/desktop-preview/plugins/kf6/thumbcreator/acompositorpreview.so
/usr/bin/python3 scripts/desktop-integration.py status
/usr/bin/python3 scripts/desktop-integration.py uninstall
```

Use `--desktop gnome` or `--desktop kde` for one desktop. Installation is explicit
and user-scoped. It backs up replaced files, enables the KDE provider, and gives the
user's Dolphin launcher its plugin path without changing other Qt applications.
Restart running file managers after install/uninstall; enable previews in Dolphin.
The provider delegates ordinary directories to KDE's standard directory thumbnailer.
KIO chooses a single enabled provider per MIME type, so its original directory
provider is replaced in the enabled list and called by the Compositor wrapper.

Uninstall disables the running Nautilus provider before restoring owned icons.
It restores backed-up files and KDE settings, retaining later user edits. Metadata
restoration failures retain the ownership record for retry. Cached preview files
are ordinary user cache data. No privileges or additional Flatpak permissions are
required.

## Acceptance evidence and current status

Local checks on the October 20 worktree:

- Both real Linux rendering paths produced all 151 images and two deep sample files.
  CPU/Vulkan image differences are within the cross-platform comparison thresholds.
- Comparator fault tests cover incorrect colors/alpha, missing images/references,
  corrupted checksums and missing cases; CIEDE2000 matches published numeric pairs.
- Real isolated Nautilus displayed the preview, refreshed it after a save and Ctrl+R,
  and removed a corrupt preview. Its screenshot is in
  `.build/evidence/desktop-previews/nautilus-preview.png`.
- Native KDE creator and out-of-process KIO MIME dispatch both passed. The separate
  real Dolphin screenshot test is included in the desktop CI workflow; Dolphin is
  not installed on this development machine, so that GUI check remains unexecuted.
- `APP-12` passed an independent real GIO `%F` desktop-entry launch of the editor,
  with the saved project's dimensions/layers, clean history and window screenshot
  captured under `.build/evidence/parity-launch/`. Installed Flatpak delivery is
  still part of the broader physical-desktop acceptance matrix.
- The broader Linux contract's Swift suites passed, but its six-journey parallel
  native batch failed Canvas Size focus validation and stalled in Image Size.
  The stalled process was terminated after more than 15 minutes. Both journeys
  passed when rerun alone with the same binary; the parallel failure's cause is
  unresolved. The full contract is therefore not a passing acceptance result.
  Logs are under `.build/evidence/parity-full-contract.log` and
  `.build/evidence/parity-{canvas,image-size}-repro.log`.

`APP-12` is verified within this Linux scope. `FILE-18` is implemented, with
Nautilus and KIO evidence, pending real Dolphin GUI acceptance. Visual/color parity
with macOS remains unverified until the independent Mac job and both comparison
jobs actually pass. Cross-platform `.comp` round trips remain separate acceptance
work; a rendering comparison does not close all of `GAP-VER-04`.

Useful commands:

```sh
/usr/bin/python3 tests/test_render_parity.py
/usr/bin/python3 tests/test_desktop_integration.py
QT_QPA_PLATFORM=offscreen ctest --test-dir .build/desktop-preview --output-on-failure
/usr/bin/python3 tests/test_nautilus_provider.py --evidence .build/desktop-evidence
/usr/bin/python3 tests/test_dolphin_provider.py \
  --plugin .build/desktop-preview/plugins/kf6/thumbcreator/acompositorpreview.so \
  --evidence .build/desktop-evidence
# Inside the configured SDK:
python3 tests/test_project_launch.py .build/release/CompositorHostBootstrap \
  --evidence .build/project-launch-evidence
```

The GUI tests use private Xvfb/D-Bus sessions and temporary XDG settings. Their
failure is an acceptance failure, not a skip. The KDE dispatch follows
[KIO's provider selection](https://github.com/KDE/kio/blob/master/src/gui/previewjob.cpp);
Nautilus uses its [custom-icon metadata](https://github.com/GNOME/nautilus/blob/main/src/nautilus-file.c).
