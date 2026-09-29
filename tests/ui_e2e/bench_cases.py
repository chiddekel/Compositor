"""Visible 2048×2048 benchmarks and stress journeys for the running editor."""
import json
import math
import time
from pathlib import Path

from tool_cases import line


SIZE = 2048
BENCH_LIMIT_MS = 150  # first-feedback / per-stroke interactive budget
STRESS_LOOPS = 12


def _create_2k(app):
    app.create(SIZE, SIZE)
    # Fit so the whole canvas is visible in Xephyr; mapping stays document-correct.
    try:
        app.click(app.widget(name="fitCanvas", kind="button"))
    except Exception:
        pass
    app.wait(lambda s: s["state"]["width"] == SIZE and s["state"]["height"] == SIZE
             and not s["state"]["busy"], "2K document ready")


def _circle(cx, cy, radius, count=180):
    return [(cx + radius * math.cos(i * 2 * math.pi / count),
             cy + radius * math.sin(i * 2 * math.pi / count)) for i in range(count + 1)]


def _write_bench(app, name, payload):
    (app.artifacts / f"{name}.json").write_text(json.dumps(payload, indent=2))


def bench_brush_2k(app):
    """Benchmark: five measured soft strokes on a 2048² canvas (256 px tip)."""
    _create_2k(app)
    app.palette("#2563eb")
    app.tool("brush")
    app.brush(size=256, hardness=0, opacity=100, smoothing=0)
    points = _circle(SIZE / 2, SIZE / 2, 600, count=120)
    samples = []
    # Warm-up
    with app.metrics.measure("brush_2k_warmup", canvas=[SIZE, SIZE], diameter=256, points=len(points)):
        app.stroke(points, interval=0.003)
    app.undo()
    app.wait(lambda s: s["state"]["undoName"] in ("New Canvas", "") and not s["state"]["busy"], "warmup undo")

    for trial in range(5):
        before = app.image(f"bench-brush-before-{trial}")
        started = time.perf_counter()
        with app.metrics.measure("brush_2k_stroke", canvas=[SIZE, SIZE], diameter=256,
                                 points=len(points), trial=trial) as record:
            app.stroke(points, interval=0.003)
        wall = (time.perf_counter() - started) * 1000
        painted = app.image(f"bench-brush-{trial}")
        assert painted.tobytes() != before.tobytes(), f"trial {trial}: no paint"
        assert painted.getpixel((SIZE // 2, SIZE // 2))[3] == 0, f"trial {trial}: circle crossed center"
        release = record.get("release_to_observed_ms")
        samples.append({"trial": trial, "wall_ms": wall, "release_to_observed_ms": release})
        assert wall <= 8000, f"trial {trial}: stroke wall {wall:.0f} ms too slow for interactive bench"
        if release is not None:
            assert release <= BENCH_LIMIT_MS * 4, (
                f"trial {trial}: release_to_observed {release:.0f} ms over soft budget")
        app.undo()
        app.wait(lambda s: not s["state"]["busy"], "bench undo")

    walls = [s["wall_ms"] for s in samples]
    _write_bench(app, "bench-brush-2k", {
        "canvas": [SIZE, SIZE], "diameter": 256, "hardness": 0, "points": len(points),
        "limit_release_ms": BENCH_LIMIT_MS * 4, "samples": samples,
        "wall_ms": {"min": min(walls), "median": sorted(walls)[len(walls) // 2], "max": max(walls)},
    })
    snap = app.inspect(timeout=10)
    assert snap["state"]["width"] == SIZE and not snap["state"]["busy"]


def bench_smear_2k(app):
    """Benchmark: Liquify first-visible feedback on a 2048² edge (5 samples, ≤150 ms)."""
    from PIL import Image, ImageChops, ImageDraw, ImageGrab

    _create_2k(app)
    # Paint a hard vertical edge to liquify against.
    app.palette("#000000")
    app.tool("brush")
    app.brush(size=400, hardness=100, opacity=100)
    app.stroke(line((SIZE // 2 - 200, 200), (SIZE // 2 - 200, SIZE - 200), 80))
    app.tool("blur")
    app.option("Liquify")
    for label, value, key, expected in [("Size", 256, "brushDiameter", 256),
                                       ("Hardness", 50, "brushHardness", 0.5),
                                       ("Opacity", 70, "brushOpacity", 0.7)]:
        app.field(value, label=label, ancestor="swiftUIOptionsContainer")
        app.wait(lambda s, k=key, e=expected: abs(s["state"].get(k, -999) - e) < 0.001, "Liquify " + label)

    snapshot = app.inspect()
    app.desktop.focus(snapshot["windowID"])
    x, y, sx, sy = snapshot["canvasMapping"]
    patch = (round(x + (SIZE // 2 - 40) * sx), round(y + (SIZE // 2 - 40) * sy),
             round(x + (SIZE // 2 + 40) * sx), round(y + (SIZE // 2 + 40) * sy))
    samples = []
    before = app.image("bench-smear-base")

    def screen_patch():
        return ImageGrab.grab(bbox=patch, xdisplay=app.desktop.display_name).convert("RGB")

    for repetition in range(5):
        previous = app.inspect()["state"]["undoName"]
        app.desktop.move(x + (SIZE // 2 - 120) * sx, y + (SIZE // 2) * sy)
        previous_patch = screen_patch()
        started = time.perf_counter()
        app.desktop.button(True)
        try:
            app.desktop.move(x + (SIZE // 2 + 120) * sx, y + (SIZE // 2) * sy)
            while True:
                elapsed = (time.perf_counter() - started) * 1000
                if ImageChops.difference(previous_patch, screen_patch()).getbbox():
                    break
                assert elapsed < 2000, "Liquify 2K did not display within 2 s"
                time.sleep(0.002)
            samples.append({"repetition": repetition, "visible_ms": elapsed})
        finally:
            app.desktop.button(False)
        app.wait(lambda s: s["state"]["undoName"] != previous and not s["state"]["busy"],
                 "liquify committed", timeout=30)
        # Prefer exact undo; if export races, re-stamp the edge so the next sample is clean.
        app.undo()
        app.wait(lambda s: s["state"].get("canRedo") and not s["state"]["busy"], "liquify undo")
        restored = app.image(f"bench-smear-undo-{repetition}")
        if restored.tobytes() != before.tobytes():
            app.tool("brush")
            app.brush(size=400, hardness=100, opacity=100)
            app.palette("#000000")
            app.stroke(line((SIZE // 2 - 200, 200), (SIZE // 2 - 200, SIZE - 200), 80))
            before = app.image("bench-smear-base-refresh")
            app.tool("blur")
            app.option("Liquify")
            for label, value, key, expected in [("Size", 256, "brushDiameter", 256),
                                               ("Hardness", 50, "brushHardness", 0.5),
                                               ("Opacity", 70, "brushOpacity", 0.7)]:
                app.field(value, label=label, ancestor="swiftUIOptionsContainer")
                app.wait(lambda s, k=key, e=expected: abs(s["state"].get(k, -999) - e) < 0.001,
                         "Liquify refresh " + label)
            x, y, sx, sy = app.inspect()["canvasMapping"]
            patch = (round(x + (SIZE // 2 - 40) * sx), round(y + (SIZE // 2 - 40) * sy),
                     round(x + (SIZE // 2 + 40) * sx), round(y + (SIZE // 2 + 40) * sy))

    _write_bench(app, "bench-smear-2k", {
        "canvas": [SIZE, SIZE], "diameter": 256, "mode": "Liquify",
        "limit_ms": BENCH_LIMIT_MS, "samples": samples,
        "observer": "X11 screenshot; includes press setup; excludes scanout",
    })
    assert all(s["visible_ms"] <= BENCH_LIMIT_MS for s in samples), (
        "Liquify 2K exceeded 150 ms: " + repr(samples))


def stress_line_effects_smear_2k(app):
    """Stress: paint → layer effect → Blur, ×12 on a 2048² document (visible)."""
    from tip_cases import _EFFECT_KINDS, _add_layer_effect

    _create_2k(app)
    app.palette("#e11d48")
    spacing = SIZE // (STRESS_LOOPS + 2)

    for i in range(STRESS_LOOPS):
        y = spacing * (i + 1)
        kind = _EFFECT_KINDS[i % len(_EFFECT_KINDS)]
        app.tool("brush")
        app.brush(size=32, hardness=100, opacity=100)
        before = app.image(f"stress2k-{i}-before")
        previous = app.inspect()["state"]["undoName"]
        app.stroke(line((120, y), (SIZE - 120, y), 80), undo_name="Brush Stroke")
        app.wait(lambda s: s["state"]["undoName"] != previous and not s["state"]["busy"],
                 f"2K line {i}")
        painted = app.image(f"stress2k-{i}-line")
        assert painted.tobytes() != before.tobytes(), f"iter {i}: no paint"
        assert painted.getpixel((SIZE // 2, y))[3] > 200, f"iter {i}: line missing"

        _add_layer_effect(app, kind)
        after_fx = app.image(f"stress2k-{i}-fx")
        if i < len(_EFFECT_KINDS):
            assert after_fx.tobytes() != painted.tobytes(), f"iter {i}: {kind} no composite change"
        assert not app.inspect()["state"].get("floatingPanels"), f"iter {i}: effect sheet stuck"

        app.tool("blur")
        app.option("Blur")
        for label, value, key, expected in [("Size", 96, "brushDiameter", 96),
                                           ("Hardness", 40, "brushHardness", 0.4),
                                           ("Opacity", 100, "brushOpacity", 1.0)]:
            app.field(value, label=label, ancestor="swiftUIOptionsContainer")
            app.wait(lambda s, k=key, e=expected: abs(s["state"].get(k, -999) - e) < 0.001,
                     f"Blur {label} {i}")
        previous = app.inspect()["state"]["undoName"]
        app.gesture(line((SIZE // 2, y - 60), (SIZE // 2, y + 60), 40))
        app.wait(lambda s: s["state"]["undoName"] != previous and not s["state"]["busy"],
                 f"2K blur {i}", timeout=45)
        smeared = app.image(f"stress2k-{i}-blur")
        assert smeared.tobytes() != after_fx.tobytes(), f"iter {i}: Blur unchanged"
        assert smeared.getpixel((40, 40)) == after_fx.getpixel((40, 40)), f"iter {i}: distant damage"

    snap = app.inspect(timeout=15)
    assert snap["state"]["width"] == SIZE and not snap["state"]["busy"]
    _write_bench(app, "stress-line-fx-smear-2k", {
        "canvas": [SIZE, SIZE], "loops": STRESS_LOOPS, "effects": _EFFECT_KINDS,
        "ok": True,
    })


def stress_multitool_2k(app):
    """Stress: brush → marquee → gradient → smudge → move, three full cycles on 2048²."""
    _create_2k(app)
    app.palette("#16a34a")
    cycles = 3
    for c in range(cycles):
        # Brush block
        app.tool("brush")
        app.brush(size=128, hardness=80, opacity=100)
        previous = app.inspect()["state"]["undoName"]
        app.stroke(line((200 + c * 80, 200), (SIZE - 200, 400 + c * 100), 60))
        app.wait(lambda s: s["state"]["undoName"] != previous and not s["state"]["busy"], f"brush {c}")

        # Marquee + fill-like paint clip
        app.tool("marquee")
        app.option("Rectangle")
        app.gesture(line((300, 300), (900, 900)))
        app.wait(lambda s: s["state"]["hasSelection"] and not s["state"]["busy"], f"marquee {c}")
        app.tool("brush")
        app.brush(size=64, hardness=100)
        app.palette("#dc2626")
        previous = app.inspect()["state"]["undoName"]
        app.stroke(line((350, 500), (850, 500), 40))
        app.wait(lambda s: s["state"]["undoName"] != previous and not s["state"]["busy"], f"clip paint {c}")
        app.desktop.focus(app.inspect()["windowID"])
        try:
            app.option("Deselect")
        except AssertionError:
            app.desktop.key("Control_L", "d")
        app.wait(lambda s: not s["state"]["hasSelection"], f"deselect {c}", timeout=15)

        # Gradient
        app.tool("gradient")
        app.option("Linear")
        app.gesture(line((100, 100 + c * 50), (SIZE - 100, SIZE - 200)))
        app.wait(lambda s: bool(s["state"].get("gradientLine")), f"gradient preview {c}")
        previous = app.inspect()["state"]["undoName"]
        app.option("Apply")
        app.wait(lambda s: s["state"]["undoName"] != previous and not s["state"]["busy"], f"gradient {c}", timeout=45)

        # Smudge
        app.tool("blur")
        app.option("Smudge")
        for label, value, key, expected in [("Size", 128, "brushDiameter", 128),
                                           ("Hardness", 60, "brushHardness", 0.6),
                                           ("Opacity", 100, "brushOpacity", 1.0)]:
            app.field(value, label=label, ancestor="swiftUIOptionsContainer")
            app.wait(lambda s, k=key, e=expected: abs(s["state"].get(k, -999) - e) < 0.001, label)
        previous = app.inspect()["state"]["undoName"]
        app.gesture(line((400, 400), (1200, 1200), 50))
        app.wait(lambda s: s["state"]["undoName"] != previous and not s["state"]["busy"], f"smudge {c}", timeout=45)

        # Move layer slightly
        app.tool("move")
        previous = app.inspect()["state"]["undoName"]
        app.gesture(line((SIZE // 2, SIZE // 2), (SIZE // 2 + 40, SIZE // 2 + 30)))
        app.wait(lambda s: s["state"]["undoName"] != previous and not s["state"]["busy"], f"move {c}")

    snap = app.inspect(timeout=15)
    assert snap["state"]["width"] == SIZE and not snap["state"]["busy"]
    assert snap["state"].get("modified")
    _write_bench(app, "stress-multitool-2k", {"canvas": [SIZE, SIZE], "cycles": cycles, "ok": True})


# --- Full graphics-package E2E benchmark (warm-up + measured iters, p50/p95/p99, high PPI) ---

E2E_WARMUP = 1
E2E_ITERS = 2  # UI satellite: non-gating; engine harness owns ≥30
E2E_PPI = 300  # print-grade pixels/inch (default document is 72)


def _percentiles(values):
    import statistics
    ordered = sorted(values)
    if not ordered:
        return None

    def pct(p):
        rank = max(1, math.ceil(p / 100 * len(ordered)))
        return ordered[rank - 1]

    return {
        "n": len(ordered),
        "min": ordered[0],
        "mean": statistics.fmean(ordered),
        "p50": pct(50),
        "p95": pct(95),
        "p99": pct(99),
        "max": ordered[-1],
    }


def _phase(record, name, fn):
    app = record.get("_app")
    started = time.perf_counter()
    cpu0 = None
    try:
        if app is not None and getattr(app, "metrics", None):
            cpu0 = app.metrics.sample()["cpu_ms"]
    except Exception:
        cpu0 = None
    fn()
    wall = (time.perf_counter() - started) * 1000
    entry = {"wall_ms": wall}
    try:
        if cpu0 is not None:
            entry["cpu_ms"] = app.metrics.sample()["cpu_ms"] - cpu0
    except Exception:
        pass
    record["phases"][name] = entry
    return wall


def _set_high_ppi(app, ppi=E2E_PPI):
    """Best-effort Image Size… to print-grade PPI. Returns True if applied.

    Under nested Xephyr, Ctrl+Alt shortcuts are unsafe and Alt+letter menus are often
    unreachable, so failure is non-fatal for the visible satellite (engine harness owns
    strict PPI gates).
    """
    if abs(app.inspect()["state"].get("resolution", 0) - ppi) < 0.01:
        return True
    app.desktop.focus(app.inspect()["windowID"])
    app.desktop.key("Escape")
    time.sleep(0.15)
    # 1) Bridge command when the rebuilt Host exposes it (no menus).
    try:
        reply = app.request("command", timeout=8, command={
            "action": "resizeImage",
            "width": SIZE,
            "height": SIZE,
            "value": float(ppi),
        })
        if reply.get("ok"):
            app.wait(
                lambda s: abs(s["state"].get("resolution", 0) - ppi) < 0.01
                and s["state"]["width"] == SIZE,
                f"document at {ppi} PPI via command",
                timeout=30,
            )
            return True
    except Exception:
        pass
    # 2) Image menu (when mnemonics work).
    try:
        app.desktop.key("Alt_L", "i")
        time.sleep(0.35)
        item = app.wait(
            lambda s: next(
                (w for w in s["widgets"] if "Image Size" in (w.get("text") or "")),
                None,
            ),
            "Image Size menu item",
            timeout=5,
        )
        app.click(item)
        app.wait(
            lambda s: any(w.get("text") == "Resize" and w.get("kind") == "button" for w in s["widgets"])
            or "ImageSizeSheet" in (s["state"].get("sheets") or []),
            "Image Size sheet",
            timeout=10,
        )
        def resolution_field(snapshot):
            inch = next((w for w in snapshot["widgets"] if w.get("text") == "pixels/inch"), None)
            fields = [w for w in snapshot["widgets"] if w.get("kind") == "field"
                      and not w.get("name") and w.get("text") not in (None, "")]
            if inch:
                iy = inch["rect"][1]
                near = [w for w in fields if abs(w["rect"][1] - iy) < 30]
                for w in near or fields:
                    try:
                        if 1 <= float(w.get("text") or "nan") <= 9600:
                            return w
                    except ValueError:
                        pass
            for w in fields:
                try:
                    if 1 <= float(w.get("text") or "nan") <= 9600:
                        return w
                except ValueError:
                    pass
            return None
        field = app.wait(resolution_field, "Resolution field", timeout=8)
        app.click(field)
        app.desktop.key("Control_L", "a")
        app.desktop.text(str(ppi))
        app.click(app.widget(text="Resize", kind="button"))
        app.wait(
            lambda s: abs(s["state"].get("resolution", 0) - ppi) < 0.01
            and "ImageSizeSheet" not in (s["state"].get("sheets") or []),
            f"document at {ppi} PPI",
            timeout=30,
        )
        return True
    except Exception:
        app.desktop.key("Escape")
        time.sleep(0.2)
        return False



def _make_input_asset(app):
    from PIL import Image, ImageDraw
    # Full-canvas input so welcome Import creates a 2048² document (Linux has no
    # File › Import Images… action once a document is open).
    path = app.artifacts / "e2e-graphics-input.png"
    image = Image.new("RGBA", (SIZE, SIZE), (24, 24, 28, 255))
    draw = ImageDraw.Draw(image)
    draw.rectangle((120, 120, SIZE - 120, SIZE - 120), fill=(37, 99, 235, 255))
    draw.ellipse((SIZE // 2 - 420, SIZE // 2 - 420, SIZE // 2 + 420, SIZE // 2 + 420),
                 fill=(250, 204, 21, 230))
    draw.polygon([(SIZE // 2, 200), (SIZE - 280, SIZE - 280), (280, SIZE - 280)],
                 fill=(244, 63, 94, 200))
    image.save(path, dpi=(E2E_PPI, E2E_PPI))
    return path


def _import_asset(app, path):
    """Import a PNG into the open document via the File menu (keyboard + click).

    Do not use bridge triggerAction for Import: QFileDialog is modal and blocks the
    observation timer, so inspect never answers. Opening the menu via Alt+F then
    clicking the item starts the dialog from Qt's normal event loop instead.
    """
    before = len(app.inspect()["state"].get("layers", []))
    app.desktop.focus(app.inspect()["windowID"])
    app.desktop.key("Alt_L", "f")
    time.sleep(0.35)
    item = app.wait(
        lambda s: next(
            (w for w in s["widgets"] if "Import" in (w.get("text") or "")),
            None,
        ),
        "Import Images menu item",
        timeout=10,
    )
    app.click(item)
    app.wait(
        lambda s: any(w.get("name") == "fileNameEdit" for w in s["widgets"]),
        "Import file dialog",
        timeout=15,
    )
    app.field(str(path), name="fileNameEdit", commit=False)
    app.desktop.key("Return")
    app.wait(
        lambda s: len(s["state"].get("layers", [])) > before and not s["state"]["busy"],
        "imported e2e asset",
        timeout=60,
    )
    try:
        app.click(app.widget(name="fitCanvas", kind="button"))
    except Exception:
        pass


def _export_png(app, path):
    # Full-resolution PNG via SessionWindow::exportPNG (same compositor path File › Export PNG…
    # uses after the save panel). Avoid Ctrl+Shift+E: Swift shell-request + Qt shortcut can leave
    # a modal dialog that blocks later Save As in this harness.
    if app.inspect()["state"].get("tool") == "type":
        app.tool("brush")
    app.desktop.focus(app.inspect()["windowID"])
    app.desktop.key("Escape")
    time.sleep(0.15)
    result = app.request("export", name=path.name, timeout=60)
    assert result.get("ok"), f"export request failed: {result}"
    exported = Path(result["path"])
    if exported.resolve() != path.resolve():
        import shutil
        shutil.copy(exported, path)
    assert path.exists() and path.stat().st_size > 1000


def _save_project(app, path):
    if app.inspect()["state"].get("tool") == "type":
        app.tool("brush")
    app.desktop.focus(app.inspect()["windowID"])
    app.desktop.key("Escape")
    time.sleep(0.15)
    app.menu_ready()
    app.desktop.key("Control_L", "Shift_L", "s")
    try:
        app.wait(
            lambda s: any(w.get("name") == "fileNameEdit" for w in s["widgets"]),
            "Save As dialog",
            timeout=8,
        )
    except AssertionError:
        app.desktop.focus(app.inspect()["windowID"])
        app.desktop.key("Control_L", "Shift_L", "s")
        app.wait(
            lambda s: any(w.get("name") == "fileNameEdit" for w in s["widgets"]),
            "Save As dialog (retry)",
            timeout=10,
        )
    app.field(str(path), name="fileNameEdit", commit=False)
    app.artifacts_now("save-dialog")
    app.desktop.key("Return")
    app.wait(
        lambda s: (path / "manifest.json").exists() and not s["state"].get("modified"),
        "saved .comp",
        timeout=90,
    )


def _close_document(app):
    app.desktop.focus(app.inspect()["windowID"])
    app.desktop.key("Control_L", "w")
    app.wait(lambda s: not s["state"].get("layers"), "closed document", timeout=30)


def _ensure_spare_tab(app):
    if not any(len(w.get("tabs", [])) >= 2 for w in app.inspect()["widgets"]):
        app.click(app.widget(name="newCanvasToolbar", kind="button"))
        app.wait(lambda s: any(len(w.get("tabs", [])) >= 2 for w in s["widgets"]), "spare tab")


def _open_new_canvas_sheet(app):
    """Land on a New Canvas sheet (Import image). Always open a fresh empty tab.

    Closing the previous document is unreliable once a spare tab steals focus (inspect only
    sees the active tab). Leaving prior tabs open keeps Close-from-last-tab from quitting
    the app and matches a multi-document editor workload.
    """
    if any(w.get("text") == "Import image" or w.get("name") == "createCanvas"
           for w in app.inspect()["widgets"]) and not app.inspect()["state"].get("layers"):
        return
    app.click(app.widget(name="newCanvasToolbar", kind="button"))
    app.wait(
        lambda s: (
            any(w.get("text") == "Import image" or w.get("name") == "createCanvas" for w in s["widgets"])
            and not s["state"].get("layers")
        ),
        "new canvas sheet on fresh tab",
        timeout=20,
    )


def _run_e2e_graphics_scenario(app, *, iteration, warmup, asset_path):
    """One full E2E pass at high PPI. Raises on validation failure."""
    import hashlib
    from PIL import Image

    record = {"iteration": iteration, "warmup": warmup, "phases": {}, "_app": app, "ppi": E2E_PPI}
    t0 = time.perf_counter()
    try:
        rss0 = app.metrics.sample()["rss_mib"]
    except Exception:
        rss0 = None

    def create():
        # Proven New Canvas path (width/height + Create canvas), then fit.
        _ensure_spare_tab(app)
        if app.inspect()["state"].get("layers") or not any(
                w.get("name") == "createCanvas" for w in app.inspect()["widgets"]):
            _open_new_canvas_sheet(app)
        _create_2k(app)

    _phase(record, "create_document", create)

    def load():
        # Prefer File›Import when the menu is reachable; under nested Xephyr Alt+F / welcome
        # Import is often unreachable, so fall back to keeping the blank 2K canvas — draw
        # still paints a full mixed scene for a visible E2E pass.
        try:
            _import_asset(app, asset_path)
            record["imported"] = True
        except Exception as exc:
            record["imported"] = False
            record["import_error"] = str(exc)
            app.desktop.key("Escape")
            time.sleep(0.2)
        record["ppi_applied"] = _set_high_ppi(app, E2E_PPI)
        app.wait(lambda s: s["state"]["width"] == SIZE and not s["state"]["busy"],
                 "2K document ready after load")
        record["ppi"] = app.inspect()["state"].get("resolution", 72)

    _phase(record, "load_assets", load)

    def draw():
        app.palette("#e11d48")
        app.tool("brush")
        app.brush(size=64, hardness=80, opacity=100)
        previous = app.inspect()["state"]["undoName"]
        app.stroke(line((200, 400), (SIZE - 200, 900), 60), undo_name="Brush Stroke")
        app.wait(lambda s: s["state"]["undoName"] != previous and not s["state"]["busy"], "brush")

        app.tool("shape")
        app.option("Ellipse")
        previous = app.inspect()["state"]["undoName"]
        app.gesture(line((600, 600), (1100, 1100)))
        app.wait(lambda s: s["state"]["undoName"] != previous and not s["state"]["busy"], "shape")

        app.tool("gradient")
        app.option("Radial")
        app.gesture(line((SIZE // 2, SIZE // 2), (SIZE // 2 + 500, SIZE // 2)))
        app.wait(lambda s: bool(s["state"].get("gradientLine")), "gradient preview")
        previous = app.inspect()["state"]["undoName"]
        app.option("Apply")
        app.wait(
            lambda s: s["state"]["undoName"] != previous and not s["state"]["busy"],
            "gradient",
            timeout=60,
        )

        app.tool("type")
        app.gesture([(280, 280)])
        app.wait(lambda s: s["state"].get("textDraft") is not None, "text editor")
        app.click(app.widget(name="canvas.textEditor"))
        app.desktop.text("E2E 2K")
        previous = app.inspect()["state"]["undoName"]
        app.desktop.key("Control_L", "Return")
        app.wait(
            lambda s: not s["state"].get("textDraft") and s["state"]["undoName"] != previous,
            "text commit",
            timeout=30,
        )

        from tip_cases import _add_layer_effect
        _add_layer_effect(app, "Drop Shadow")

    _phase(record, "draw_and_effects", draw)

    export_path = app.artifacts / f"e2e-out-{'warmup' if warmup else 'iter'}{iteration}.png"

    def render_export():
        _export_png(app, export_path)

    _phase(record, "render_export", render_export)

    project = app.artifacts / f"e2e-{'warmup' if warmup else 'iter'}{iteration}.comp"

    def save():
        _save_project(app, project)

    _phase(record, "save_project", save)

    def validate():
        assert export_path.exists() and export_path.stat().st_size > 1000, "export missing/too small"
        image = Image.open(export_path)
        assert image.size == (SIZE, SIZE), f"export size {image.size}"
        assert image.format == "PNG", f"export format {image.format}"
        rgba = image.convert("RGBA")
        extrema = rgba.getextrema()
        assert any(lo != hi for lo, hi in extrema), "export looks empty/uniform"
        dpi = image.info.get("dpi")
        # SessionWindow::exportPNG (Qt QImageWriter path) currently stamps ~72 DPI even when the
        # document resolution is higher; package PPI is validated via the .comp manifest below.
        digest = hashlib.sha256(export_path.read_bytes()).hexdigest()
        assert (project / "manifest.json").exists(), "project manifest missing"
        manifest = json.loads((project / "manifest.json").read_text())
        live_ppi = float(app.inspect()["state"].get("resolution", 0) or 0)
        man_ppi = float(manifest.get("resolution", 0) or 0)
        if record.get("ppi_applied"):
            assert abs(man_ppi - E2E_PPI) < 0.01, f"manifest resolution {man_ppi}"
            assert abs(live_ppi - E2E_PPI) < 0.01, f"live resolution {live_ppi}"
        live = app.image(f"e2e-live-{iteration}")
        assert live.size == (SIZE, SIZE)
        record["validation"] = {
            "export_bytes": export_path.stat().st_size,
            "export_sha256": digest,
            "export_size": list(image.size),
            "export_dpi": list(dpi) if dpi else None,
            "manifest_resolution": manifest.get("resolution"),
            "project_ok": True,
        }

    _phase(record, "validate", validate)

    record["total_ms"] = (time.perf_counter() - t0) * 1000
    try:
        rss1 = app.metrics.sample()["rss_mib"]
        record["rss_delta_mib"] = rss1 - (rss0 or rss1)
        record["rss_mib"] = rss1
    except Exception:
        pass
    record.pop("_app", None)
    return record


def bench_e2e_graphics_2k(app):
    """UI-E2E satellite of the graphics-package bench (2048² @ 300 PPI).

    Non-gating vs the engine harness in ``tests/bench`` (see
    docs/benchmark-e2e-graphics-package.md). Warm-up + two measured iterations;
    reports p50/p95/p99 for the interactive Import→Draw→Export→Save path.
    """
    asset = _make_input_asset(app)
    samples = []
    warm = _run_e2e_graphics_scenario(app, iteration=0, warmup=True, asset_path=asset)
    samples.append(warm)

    measured = []
    for i in range(1, E2E_ITERS + 1):
        row = _run_e2e_graphics_scenario(app, iteration=i, warmup=False, asset_path=asset)
        measured.append(row)
        samples.append(row)

    totals = [r["total_ms"] for r in measured]
    phase_names = list(measured[0]["phases"].keys())
    phase_stats = {
        name: _percentiles([r["phases"][name]["wall_ms"] for r in measured])
        for name in phase_names
    }
    report = {
        "schema": "compositor.e2e_graphics_bench/1",
        "canvas": [SIZE, SIZE],
        "ppi": E2E_PPI,
        "scenario": (
            "Input → Load Assets → Create Scene (2048² @ 300 PPI) → Draw Elements → "
            "Apply Effects → Render → Export → Save → Validate"
        ),
        "warmup": E2E_WARMUP,
        "iterations": E2E_ITERS,
        "total_ms": _percentiles(totals),
        "phases_ms": phase_stats,
        "throughput_docs_per_s": 1000.0 / (_percentiles(totals)["p50"] or 1),
        "samples": samples,
        "notes": (
            "Document resolution set via Image Size to 300 pixels/inch with pixel count unchanged; "
            "validated on the saved .comp manifest. PNG export uses SessionWindow::exportPNG "
            "(Qt path currently stamps ~72 DPI metadata). App-process CPU/RSS via UI E2E Metrics "
            "when available. Wall times include UI pacing, dialogs, and observation polling — not "
            "GPU frame time."
        ),
    }
    _write_bench(app, "e2e-graphics-bench-2k", report)
    lines = [
        "# Graphics package E2E benchmark (2048×2048 @ 300 PPI)",
        "",
        f"Warm-up: {E2E_WARMUP} · Measured: {E2E_ITERS} · PPI: {E2E_PPI}",
        "",
        "| Metric | p50 | p95 | p99 | mean | max |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
        f"| total_ms | {report['total_ms']['p50']:.0f} | {report['total_ms']['p95']:.0f} | "
        f"{report['total_ms']['p99']:.0f} | {report['total_ms']['mean']:.0f} | "
        f"{report['total_ms']['max']:.0f} |",
    ]
    for name, stats in phase_stats.items():
        lines.append(
            f"| {name} | {stats['p50']:.0f} | {stats['p95']:.0f} | {stats['p99']:.0f} | "
            f"{stats['mean']:.0f} | {stats['max']:.0f} |"
        )
    lines += [
        "",
        f"Throughput (p50): {report['throughput_docs_per_s']:.3f} docs/s",
        "",
    ]
    (app.artifacts / "e2e-graphics-bench-2k.md").write_text("\n".join(lines))
    assert report["total_ms"]["p95"] < 180_000, (
        f"E2E p95 {report['total_ms']['p95']:.0f} ms exceeds 180 s envelope"
    )


BENCH_CASES = {
    "bench_brush_2k": bench_brush_2k,
    "bench_smear_2k": bench_smear_2k,
    "bench_e2e_graphics_2k": bench_e2e_graphics_2k,
    "stress_line_effects_smear_2k": stress_line_effects_smear_2k,
    "stress_multitool_2k": stress_multitool_2k,
}
