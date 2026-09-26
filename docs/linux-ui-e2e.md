# Linux desktop UI tests

These tests compile the Linux host against the existing Compositor Swift sources.
They do not modify `Compositor/`, `CompositorTests/` or the Xcode project.

## Run

Install the KDE SDK and Swift extension declared by `com.compositor.Client.yaml`,
plus host `flatpak`, `Xvfb`, `libX11`, `libXtst`, `dbus-run-session`, Python 3.11+ and Pillow.
The normal development build's Skia and Qt image bridges must exist in `build/lib/`.
For a clean machine, build those dependencies with:

```sh
bash scripts/build-ui-e2e-deps.sh
```

Run the release build and all desktop tests:

```sh
bash scripts/run-ui-e2e.sh
```

The runner fails on a build error or a missing dependency. It never substitutes a
no-Skia renderer, retries failing cases, or silently skips an unavailable desktop.
It prints an artifact directory under `/tmp`; override it with `UI_E2E_ARTIFACTS`.
Use a fresh directory for each run so stale observations cannot produce a pass.

For focused development with an already built binary:

```sh
UI_E2E_ARTIFACTS=/tmp/compositor-ui-color-1 \
  bash scripts/run-ui-e2e.sh --no-build --case color_accept
```

## What is tested

Each case opens a fresh application with isolated preferences, a private Xvfb display
and a private D-Bus session. XTest supplies native mouse and keyboard input. Document
creation, tool selection, field editing, dialog confirmation, painting and shortcuts
go through the visible UI. Coordinates are resolved from visible widgets; selectors
fail when ambiguous. Document coordinates are converted through the current canvas
mapping. The driver assigns X11 window focus because Xvfb has no window manager.

| Journey | Assertions |
| --- | --- |
| Fast circular brush stroke with a busy UI | At least 175/180 expected path points painted; center untouched |
| Continuous circular stroke | Path coverage and maximum radial deviation at 100% zoom |
| Layer rename | Focus and selected text, Return, Escape, blur, undo/redo, add another layer |
| Options-bar color picker | OK, Return then OK, Cancel; actual brush pixel color and alpha |
| Brush size and opacity | Painted width and alpha, empty canvas after undo, identical pixels after redo |
| Erase | Removes the crossing while preserving pixels outside the eraser |
| Brush hardness | Soft edge alpha falls away from the center for 64 px and 256 px brushes |
| Smoothing | The UI parameter reduces a recorded zigzag's vertical deviation |
| Save, close and reopen | Qt file dialogs; saved layer name, dimensions and byte-identical painted pixels |
| Tool inventory and tooltips | All 15 rail tools select correctly; each tooltip has themed background and visible text in a desktop screenshot |
| Move / Transform | Layer offset matches drag, actual pixels move, exposed area is transparent; undo restores pixels |
| Marquee, Lasso, Magic | Rectangle/Ellipse, Freehand/Polygonal, Wand/Object; painting clips to selection, deselect and undo work |
| Crop | Cancel preserves pixels; Apply changes dimensions and preserves exact selected pixels; undo |
| Clone Stamp | Alt-click source, copied pixels match source, source preserved; undo |
| Spot Healing | Content-Aware, Create Texture, Proximity Match remove a dark spot and preserve distant pixels; undo |
| Smear | Liquify/Smudge move color, Blur softens an edge; distant pixels preserved; undo |
| Smear live feedback | All three modes at 256 px on a 1920 × 1080 image; working pixels and desktop preview change before release; five fresh edge crossings each appear within 100 ms |
| Gaussian / Motion Blur | Full-HD adjustment layers; editor opens within 1500 ms, blur direction, visible slider feedback before release, final value, Preview off/on, Apply, and Undo (`effect_gaussian_blur`, `effect_motion_blur`) |
| Gradient | Linear/Radial preview, Cancel, Apply, alpha falloff and symmetry; undo |
| Shape | Rectangle/Ellipse/Line geometry, filled and empty regions; undo |
| Type | Native text input and commit produce rendered glyphs; undo |
| Eyedropper | Sample fixture color, then paint with that exact color |
| Hand and Zoom | Pan offset, zoom in/out, document pixels unchanged |
| Idle shortcut | Dragging changes neither pixels nor history |
| Repeated brush performance | Three sizes × two smoothing values, plus two soft brushes; one warm-up and five measured strokes each; consistent pixels, trajectory checks, undo |
| Downloaded complex PSDs | Layer order, hierarchy, names, visibility, opacity, masks, clipping links, Curves adjustment, conversion warnings, pixel-preserving save/reopen, painting and undo |
| PSD cancellation and unsupported depth | Cancel applies no layers; 16/32-bit errors are visible; creating and painting still work afterward |

The PSD corpus contains real downloaded files with pinned source URLs and SHA-256
checksums. Its expected structure was inspected with an independent reader. See
[PSD fixture provenance](../tests/ui_e2e/fixtures/psd-tools/README.md) for licensing,
coverage and the explicit **1.27 GiB PSB stress test**. The large binary is kept outside
Git and the default CI suite. Requesting that test without its file fails; it is never
silently skipped. The current document budget rejects it, and the stress test reports
that as a failed import while also checking UI recovery.

The runner also executes a **negative control**: it deliberately restores Qt input
compression and repeats the queued circle. Only the specific missing-trajectory
assertion counts as detection. A startup failure, timeout or unrelated assertion
fails the control. This proves the test can expose the event-loss regression that
direct Qt event injection misses.

`COMPOSITOR_UI_E2E_DIR` enables a small observation bridge in the Linux host. It reports
widgets, session state and received-input counters, captures the private desktop,
and exports actual document pixels. It has no editor-command endpoint. A bounded
300 ms GUI stall simulates work while the independent desktop driver queues input.
Without that environment variable, the bridge installs no timer or input observer.

## Evidence and release use

See [tool E2E and response-time results](tool-e2e-status.md) for the verified tool
inventory, fixes, latest acceptance evidence, and measured performance limits.

Each case retains the application log, Xvfb log, native input JSONL, widget/session JSON,
desktop screenshot and exported PNGs. `junit.xml` records failures with tracebacks.
The shell runner records the source revision, working-tree summary and binary hashes.

## Speed and resource metrics

Every case writes `metrics.json`; the suite writes combined `metrics.json` and a readable
`metrics.md`. These record app-process CPU milliseconds, elapsed milliseconds, initial/final
RSS and peak RSS in MiB. Driver, Xvfb and D-Bus CPU/memory are excluded. CPU percentage is
relative to one core and can exceed 100%; **CPU milliseconds per identical operation** is
the useful efficiency comparison. Lower CPU percentage alone does not prove less work.

Tool selection, pointer gestures and brush strokes also record individual durations and
CPU cost. The brush benchmark uses identical 181-point circles, 3 ms input pacing, sizes
12/64/256 px and smoothing 0/30 with hardness 100, plus 64/256 px at hardness 0 and smoothing
0, all at 100% zoom. One warm-up is reported separately from the
five measured strokes per configuration. Median, p95 and maximum are retained alongside
all samples. With five samples, p95 is the maximum; use repeated runs before drawing
performance conclusions. Export and undo checks happen outside the stroke measurement.

```sh
python3 tests/ui_e2e/run.py --case brush_performance \
  --artifacts /tmp/compositor-brush-benchmark-1
```

Compare the same workload, backend, release build configuration and idle machine. Lower
elapsed time, CPU work and memory are improvements only when the pixel assertions still
pass. The first run establishes a baseline; it does not prove an improvement. Benchmark
runs should be sequential, without concurrent E2E jobs or other heavy workloads.

Compare two reports with:

```sh
python3 tests/ui_e2e/compare_metrics.py /tmp/baseline/metrics.json /tmp/candidate/metrics.json
```

Negative percentages mean less time or memory. The comparison rejects differing machines,
backend requests, case lists, input workloads or failed correctness checks. Add
`--max-regression-percent 20` to fail on a regression exceeding an explicitly chosen
budget; no universal performance budget is enabled by default. Establish normal machine
variance before enforcing a budget. Reports from a modified test workload need a new baseline.

`release_to_observed_ms` measures release submission until the driver observes delivery
(and brush commit history). It includes the 10 ms observation bridge/driver polling and
30 ms retry interval. It is **not input-to-screen latency or GPU frame time**. Total gesture
time includes intentional input pacing and observation requests. RSS is sampled every
50 ms; process-lifetime peak RSS comes from Linux `VmHWM` and includes startup. CPU values
have the kernel clock-tick resolution. The report includes machine, backend request and
binary hash. GPU use, power consumption and hardware display presentation are unmeasured.

The three `smear_feedback_*` cases additionally write `visible-latency.json`. They measure
from native button-down and a 160 px document-space move to a changed X11 screenshot
patch, independently of the application's observation bridge. Each of five samples
starts from the original image, and undo must restore every pixel. This avoids treating
Smudge's intentional dab spacing or Blur's already-saturated coverage as a stalled frame.
The 100 ms limit includes stroke setup and screenshot overhead; it is a regression budget
for this specified workload, not a guarantee for every document or hardware display.

```sh
UI_E2E_ARTIFACTS=/tmp/compositor-smear-feedback \
  bash scripts/run-ui-e2e.sh --no-build \
  --case smear_feedback_liquify --case smear_feedback_blur --case smear_feedback_smudge
```

The `Linux UI E2E` workflow runs on pushes and pull requests targeting `GNU_Linux`
and can be run manually. It builds the production manifest's Skia module and the
release Swift/Qt executable. Make its `desktop-ui` job a required repository status
check before release. Branch protection itself is managed in repository settings.

These tests complement the existing Swift and shell tests. They do not establish
that every feature is bug-free: Wayland, real tablets/pressure, system portals,
global desktop menus, hardware GPU drivers and display-frame latency need additional coverage.
The virtual desktop explicitly uses in-window menus, Qt file dialogs and Qt's local compose input method.
The default brush backend is CPU for repeatable CI; use `--backend auto` to exercise
normal backend selection on a development machine. The dependency build only includes
the Skia/image-codec parts, not RAW or optional OpenCV models. The synthetic Magic/Object
journey checks the available selection path; it does not establish model segmentation quality.

## Extend

Add a case in `tests/ui_e2e/run.py` (`CASES`), `tests/ui_e2e/tool_cases.py` (`TOOL_CASES`),
or `tests/ui_e2e/psd_cases.py` (`PSD_CASES`). Perform mutations through
`Desktop` mouse/keyboard input; use observations and exported pixels for assertions.
Wait for the expected state rather than adding long sleeps. Keep a regression's
original failing input and a meaningful pixel/state assertion; do not loosen an
assertion merely to get a green build. Add a negative control when practical.
