"""Visible first-feedback latency for every tool family. Budget: 150 ms."""
import json
import time

from PIL import ImageChops, ImageGrab

from tool_cases import TOOLS, import_fixture, line, undo_pixels


LIMIT_MS = 150
SAMPLES = 5
WARMUP = 1  # Discarded from the budget; recorded in visible-latency.json
OBSERVER_SCREEN = ("X11 screenshot pixels; includes press setup and capture overhead; "
                   "excludes hardware display scanout")
OBSERVER_STATE = ("session state after XTest input; includes inspect round-trip overhead; "
                  "used when the tool's first feedback is an overlay/mapping change")


def _mapping(app):
    return app.inspect()["canvasMapping"]


def _screen_rect(mapping, doc):
    x, y, sx, sy = mapping
    x0, y0, x1, y1 = doc
    return (round(x + x0 * sx), round(y + y0 * sy), round(x + x1 * sx), round(y + y1 * sy))


def _patch(app, rect):
    return ImageGrab.grab(bbox=rect, xdisplay=app.desktop.display_name).convert("RGB")


def _write_latency(app, *, name, limit_ms, samples_out, warmup, observer, **extra):
    (app.artifacts / "visible-latency.json").write_text(json.dumps({
        "tool": name, "limit_ms": limit_ms, "warmup": warmup,
        "budgeted_samples": [s for s in samples_out if not s.get("warmup")],
        "samples": samples_out, "observer": observer, **extra}, indent=2))


def _assert_budget(name, samples_out, limit_ms):
    budgeted = [s for s in samples_out if not s.get("warmup")]
    assert budgeted and all(s["visible_ms"] <= limit_ms for s in budgeted), (
        f"{name} exceeded {limit_ms} ms: " + repr(budgeted))


def measure_drag(app, *, name, start_doc, end_doc, samples=SAMPLES, warmup=WARMUP,
                 limit_ms=LIMIT_MS, patch_doc=None, ready=None, restore=None, modifier=None,
                 commit=False):
    """Press at start, move to end; wait for screenshot change and/or session ready().

    commit=True releases the button before waiting — for tools whose session state
    updates only on mouse-up (marquee selection commit).
    """
    assert patch_doc is not None or ready is not None
    snapshot = app.inspect()
    app.desktop.focus(snapshot["windowID"])
    mapping = snapshot["canvasMapping"]
    patch = _screen_rect(mapping, patch_doc) if patch_doc else None
    start = (mapping[0] + start_doc[0] * mapping[2], mapping[1] + start_doc[1] * mapping[3])
    end = (mapping[0] + end_doc[0] * mapping[2], mapping[1] + end_doc[1] * mapping[3])
    total = samples + warmup
    samples_out = []
    observer = OBSERVER_SCREEN if patch_doc and not ready else (
        OBSERVER_STATE if ready and not patch_doc else OBSERVER_SCREEN + "; " + OBSERVER_STATE)
    try:
        for repetition in range(total):
            app.desktop.move(*end)
            previous = _patch(app, patch) if patch else None
            if modifier:
                app.desktop.hold(modifier, True)
            try:
                app.desktop.move(*start)
                started = time.perf_counter()
                app.desktop.button(True)
                app.desktop.move(*end)
                if commit:
                    app.desktop.button(False)
                try:
                    while True:
                        elapsed = (time.perf_counter() - started) * 1000
                        changed = False
                        if previous is not None and ImageChops.difference(previous, _patch(app, patch)).getbbox():
                            changed = True
                        if ready and ready(app.inspect()):
                            changed = True
                        if changed:
                            break
                        assert elapsed < 1000, f"{name} did not respond within one second"
                        time.sleep(0.002)
                    samples_out.append({"repetition": repetition, "visible_ms": elapsed,
                                        "warmup": repetition < warmup})
                finally:
                    if not commit:
                        app.desktop.button(False)
            finally:
                if modifier:
                    app.desktop.hold(modifier, False)
            if restore:
                restore(app, snapshot)
            else:
                app.wait(lambda s: not s["state"]["busy"], name + " idle")
    finally:
        _write_latency(app, name=name, limit_ms=limit_ms, samples_out=samples_out, warmup=warmup,
                       observer=observer, path=[list(start_doc), list(end_doc)],
                       patch_doc=list(patch_doc) if patch_doc else None, commit=commit)
    _assert_budget(name, samples_out, limit_ms)
    return samples_out


def measure_click(app, *, name, click_doc, samples=SAMPLES, warmup=WARMUP, limit_ms=LIMIT_MS,
                  patch_doc=None, ready=None, restore=None, modifier=None, hold=False):
    """Click (or press-and-hold) and wait for screenshot/session feedback."""
    assert patch_doc is not None or ready is not None
    snapshot = app.inspect()
    app.desktop.focus(snapshot["windowID"])
    mapping = snapshot["canvasMapping"]
    patch = _screen_rect(mapping, patch_doc) if patch_doc else None
    point = (mapping[0] + click_doc[0] * mapping[2], mapping[1] + click_doc[1] * mapping[3])
    total = samples + warmup
    samples_out = []
    observer = OBSERVER_SCREEN if patch_doc and not ready else (
        OBSERVER_STATE if ready and not patch_doc else OBSERVER_SCREEN + "; " + OBSERVER_STATE)
    try:
        for repetition in range(total):
            app.desktop.move(point[0] + 80, point[1])
            previous = _patch(app, patch) if patch else None
            if modifier:
                app.desktop.hold(modifier, True)
            try:
                app.desktop.move(*point)
                started = time.perf_counter()
                app.desktop.button(True)
                if not hold:
                    app.desktop.button(False)
                try:
                    while True:
                        elapsed = (time.perf_counter() - started) * 1000
                        changed = False
                        if previous is not None and ImageChops.difference(previous, _patch(app, patch)).getbbox():
                            changed = True
                        if ready and ready(app.inspect()):
                            changed = True
                        if changed:
                            break
                        assert elapsed < 1000, f"{name} did not respond within one second"
                        time.sleep(0.002)
                    samples_out.append({"repetition": repetition, "visible_ms": elapsed,
                                        "warmup": repetition < warmup})
                finally:
                    if hold:
                        app.desktop.button(False)
            finally:
                if modifier:
                    app.desktop.hold(modifier, False)
            if restore:
                restore(app, snapshot)
            else:
                app.wait(lambda s: not s["state"]["busy"], name + " idle")
    finally:
        _write_latency(app, name=name, limit_ms=limit_ms, samples_out=samples_out, warmup=warmup,
                       observer=observer, path=[list(click_doc)],
                       patch_doc=list(patch_doc) if patch_doc else None)
    _assert_budget(name, samples_out, limit_ms)
    return samples_out


def _deselect(app, _snapshot=None):
    for _ in range(4):
        if not app.inspect()["state"].get("hasSelection"):
            return
        app.desktop.focus(app.inspect()["windowID"])
        try:
            app.option("Deselect")
        except AssertionError:
            app.desktop.key("Control_L", "d")
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if not app.inspect()["state"].get("hasSelection"):
                return
            time.sleep(0.03)
    raise AssertionError("could not clear selection between latency samples")


def _undo_restore(app, snapshot):
    before_name = snapshot["state"]["undoName"]
    state = app.inspect()["state"]
    if state.get("gradientLine"):
        app.option("Cancel")
        app.wait(lambda s: not s["state"].get("gradientLine"), "cancel gradient")
        return
    if state.get("cropRect"):
        app.option("Cancel")
        app.wait(lambda s: not s["state"].get("cropRect"), "cancel crop")
        return
    if state.get("shapeRect"):
        app.desktop.key("Escape")
        app.wait(lambda s: not s["state"].get("shapeRect"), "cancel shape", timeout=5)
        return
    if state.get("hasSelection"):
        _deselect(app)
        return
    if state["undoName"] != before_name:
        app.undo()
        app.wait(lambda s: s["state"]["canRedo"] and not s["state"]["busy"], "latency undo")


def _pixel_restore(before, label):
    def restore(app, _snapshot):
        undo_pixels(app, before, label)
    return restore


def _prepare_fixture(app):
    return import_fixture(app)


def latency_brush(app):
    before = _prepare_fixture(app)
    app.tool("brush")
    app.brush(size=48, hardness=100, opacity=100)
    app.palette("#00cc44")
    measure_drag(app, name="brush", start_doc=(140, 220), end_doc=(220, 220),
                 patch_doc=(150, 200, 210, 240), restore=_pixel_restore(before, "undo-latency-brush"))


def latency_eraser(app):
    before = _prepare_fixture(app)
    app.tool("brush")
    app.brush(size=40, hardness=100, opacity=100)
    app.click(app.widget(text="Erase", kind="button", ancestor="swiftUIOptionsContainer"))
    measure_drag(app, name="eraser", start_doc=(200, 220), end_doc=(280, 220),
                 patch_doc=(210, 200, 270, 240), restore=_pixel_restore(before, "undo-latency-eraser"))


def latency_move(app):
    before = _prepare_fixture(app)
    app.tool("move")
    measure_drag(app, name="move", start_doc=(240, 220), end_doc=(300, 220),
                 patch_doc=(300, 200, 340, 240), restore=_pixel_restore(before, "undo-latency-move"))


def latency_marquee(app):
    _prepare_fixture(app)
    app.tool("marquee")
    app.option("Rectangle")
    # Marquee commits the selection on mouse-up (lassoDraft is not in session JSON).
    measure_drag(app, name="marquee", start_doc=(80, 80), end_doc=(280, 240),
                 ready=lambda s: s["state"].get("hasSelection"), restore=_deselect, commit=True)


def latency_lasso(app):
    _prepare_fixture(app)
    app.tool("lasso")
    app.option("Freehand")
    # Freehand only keeps a selection when the path encloses area; a short open
    # segment does not. Trace a closed rectangle like the functional journey.
    snapshot = app.inspect()
    app.desktop.focus(snapshot["windowID"])
    mapping = snapshot["canvasMapping"]
    corners = [(160, 140), (320, 140), (320, 300), (160, 300), (160, 140)]
    screen = [(mapping[0] + x * mapping[2], mapping[1] + y * mapping[3]) for x, y in corners]
    samples_out = []
    total = SAMPLES + WARMUP
    try:
        for repetition in range(total):
            app.desktop.move(*screen[-1])
            started = time.perf_counter()
            app.desktop.button(True)
            try:
                for point in screen[1:]:
                    app.desktop.move(*point)
                    time.sleep(0.003)
            finally:
                app.desktop.button(False)
            while True:
                elapsed = (time.perf_counter() - started) * 1000
                if app.inspect()["state"].get("hasSelection"):
                    break
                assert elapsed < 1000, "lasso did not respond within one second"
                time.sleep(0.002)
            samples_out.append({"repetition": repetition, "visible_ms": elapsed,
                                "warmup": repetition < WARMUP})
            _deselect(app)
    finally:
        _write_latency(app, name="lasso", limit_ms=LIMIT_MS, samples_out=samples_out,
                       warmup=WARMUP, observer=OBSERVER_STATE,
                       path=[list(p) for p in corners], commit=True)
    _assert_budget("lasso", samples_out, LIMIT_MS)


def latency_wand(app):
    _prepare_fixture(app)
    app.tool("wand")
    app.option("Wand")
    snapshot = app.inspect()
    app.desktop.focus(snapshot["windowID"])
    mapping = snapshot["canvasMapping"]
    point = (mapping[0] + 240 * mapping[2], mapping[1] + 220 * mapping[3])
    samples_out = []
    total = SAMPLES + WARMUP
    try:
        for repetition in range(total):
            _deselect(app)
            assert not app.inspect()["state"].get("hasSelection"), "selection survived deselect"
            app.desktop.move(*point)
            started = time.perf_counter()
            app.desktop.button(True)
            app.desktop.button(False)
            while True:
                elapsed = (time.perf_counter() - started) * 1000
                if app.inspect()["state"].get("hasSelection"):
                    break
                assert elapsed < 1000, "wand did not respond within one second"
                time.sleep(0.002)
            samples_out.append({"repetition": repetition, "visible_ms": elapsed,
                                "warmup": repetition < WARMUP})
            _deselect(app)
    finally:
        _write_latency(app, name="wand", limit_ms=LIMIT_MS, samples_out=samples_out,
                       warmup=WARMUP, observer=OBSERVER_STATE)
    _assert_budget("wand", samples_out, LIMIT_MS)


def latency_crop(app):
    _prepare_fixture(app)
    app.tool("crop")
    measure_drag(app, name="crop", start_doc=(80, 60), end_doc=(400, 300),
                 patch_doc=(100, 80, 200, 160),
                 ready=lambda s: bool(s["state"].get("cropRect")), restore=_undo_restore)


def latency_clone(app):
    before = _prepare_fixture(app)
    app.tool("brush")
    app.brush(size=36, hardness=100)
    app.tool("cloneStamp")
    app.gesture([(460, 180)], modifier="Alt_L")
    measure_drag(app, name="cloneStamp", start_doc=(240, 380), end_doc=(300, 380),
                 patch_doc=(245, 365, 290, 395), restore=_pixel_restore(before, "undo-latency-clone"))


def latency_heal(app, mode="Content-Aware"):
    before = import_fixture(app, healing=True)
    app.tool("brush")
    app.brush(size=64, hardness=100)
    app.tool("spotHealing")
    app.option(mode)
    measure_drag(app, name="spotHealing_" + mode.lower().replace(" ", "_").replace("-", "_"),
                 start_doc=(300, 240), end_doc=(340, 240),
                 patch_doc=(305, 225, 335, 255), restore=_pixel_restore(before, "undo-latency-heal"))


def latency_smear(app, mode):
    before = _prepare_fixture(app)
    app.tool("brush")
    app.brush(size=64, hardness=100, opacity=100)
    app.tool("blur")
    app.option(mode)
    for label, value, key, expected in [("Size", 64, "brushDiameter", 64),
                                       ("Hardness", 100, "brushHardness", 1.0),
                                       ("Opacity", 100, "brushOpacity", 1.0)]:
        app.field(value, label=label, ancestor="swiftUIOptionsContainer")
        app.wait(lambda s: abs(s["state"].get(key, -999) - expected) < 0.001, "Smear " + label)
    measure_drag(app, name="smear_" + mode.lower(),
                 start_doc=(280, 220), end_doc=(360, 220),
                 patch_doc=(300, 200, 340, 240), restore=_pixel_restore(before, "undo-latency-smear"))


def latency_gradient(app):
    app.create()
    app.click(app.widget(name="actualPixels", kind="button"))
    app.tool("gradient")
    app.option("Linear")
    measure_drag(app, name="gradient", start_doc=(160, 220), end_doc=(400, 220),
                 patch_doc=(180, 200, 300, 240),
                 ready=lambda s: bool(s["state"].get("gradientLine")), restore=_undo_restore)


def latency_shape(app):
    app.create()
    app.click(app.widget(name="actualPixels", kind="button"))
    app.tool("shape")
    app.option("Rectangle")
    measure_drag(app, name="shape", start_doc=(160, 140), end_doc=(320, 300),
                 patch_doc=(180, 160, 280, 260),
                 ready=lambda s: bool(s["state"].get("shapeRect")), restore=_undo_restore)


def latency_type(app):
    app.create()
    app.click(app.widget(name="actualPixels", kind="button"))
    app.tool("type")
    app.gesture([(180, 220)])
    app.wait(lambda s: s["state"].get("textDraft") is not None, "text editor")
    app.click(app.widget(name="canvas.textEditor"))
    samples_out = []
    total = SAMPLES + WARMUP
    try:
        for repetition in range(total):
            app.desktop.key("Control_L", "a")
            app.desktop.key("BackSpace")
            app.wait(lambda s: not ((s["state"].get("textDraft") or {}).get("content") or "").strip(),
                     "cleared text")
            started = time.perf_counter()
            app.desktop.text("W")
            while True:
                elapsed = (time.perf_counter() - started) * 1000
                content = (app.inspect()["state"].get("textDraft") or {}).get("content") or ""
                if "W" in content:
                    break
                assert elapsed < 1000, "type did not respond within one second"
                time.sleep(0.002)
            samples_out.append({"repetition": repetition, "visible_ms": elapsed,
                                "warmup": repetition < WARMUP})
    finally:
        _write_latency(app, name="type", limit_ms=LIMIT_MS, samples_out=samples_out,
                       warmup=WARMUP, observer="session textDraft.content after typed glyph")
        app.desktop.key("Escape")
    _assert_budget("type", samples_out, LIMIT_MS)


def latency_eyedropper(app):
    _prepare_fixture(app)
    app.tool("eyedropper")
    samples_out = []
    targets = [(460, 180, [230 / 255, 40 / 255, 60 / 255]),
               (460, 360, [30 / 255, 80 / 255, 220 / 255])]
    total = SAMPLES + WARMUP
    try:
        for repetition in range(total):
            x, y, expected = targets[repetition % 2]
            mapping = _mapping(app)
            point = (mapping[0] + x * mapping[2], mapping[1] + y * mapping[3])
            app.desktop.move(point[0] - 40, point[1])
            started = time.perf_counter()
            app.desktop.click(*point)
            while True:
                color = app.inspect()["state"]["foregroundColor"]
                elapsed = (time.perf_counter() - started) * 1000
                if all(abs(a - b) < 0.01 for a, b in zip(color, expected)):
                    break
                assert elapsed < 1000, "eyedropper did not sample within one second"
                time.sleep(0.002)
            samples_out.append({"repetition": repetition, "visible_ms": elapsed,
                                "warmup": repetition < WARMUP})
    finally:
        _write_latency(app, name="eyedropper", limit_ms=LIMIT_MS, samples_out=samples_out,
                       warmup=WARMUP, observer="session foregroundColor after XTest click")
    _assert_budget("eyedropper", samples_out, LIMIT_MS)


def latency_hand(app):
    _prepare_fixture(app)
    app.tool("hand")
    origin = _mapping(app)

    def restore(app, _snapshot):
        current = _mapping(app)
        dx = origin[0] - current[0]
        dy = origin[1] - current[1]
        if abs(dx) > 0.5 or abs(dy) > 0.5:
            # Nudge the view back by dragging the opposite offset in document space.
            app.gesture(line((320, 240), (320 - dx / current[2], 240 - dy / current[3])))

    measure_drag(app, name="hand", start_doc=(320, 240), end_doc=(240, 180),
                 ready=lambda s: abs(s["canvasMapping"][0] - origin[0]) > 2
                 or abs(s["canvasMapping"][1] - origin[1]) > 2,
                 restore=restore)


def latency_zoom(app):
    before = _prepare_fixture(app)
    app.tool("zoom")
    samples_out = []
    total = SAMPLES + WARMUP
    try:
        for repetition in range(total):
            app.click(app.widget(name="actualPixels", kind="button"))
            baseline = _mapping(app)
            point = (baseline[0] + 240 * baseline[2], baseline[1] + 220 * baseline[3])
            app.desktop.focus(app.inspect()["windowID"])
            app.desktop.move(*point)
            started = time.perf_counter()
            app.desktop.button(True)
            app.desktop.button(False)
            while True:
                elapsed = (time.perf_counter() - started) * 1000
                if app.inspect()["canvasMapping"][2] > baseline[2] * 1.2:
                    break
                assert elapsed < 1000, "zoom did not respond within one second"
                time.sleep(0.002)
            samples_out.append({"repetition": repetition, "visible_ms": elapsed,
                                "warmup": repetition < WARMUP})
    finally:
        _write_latency(app, name="zoom", limit_ms=LIMIT_MS, samples_out=samples_out,
                       warmup=WARMUP, observer=OBSERVER_STATE)
    _assert_budget("zoom", samples_out, LIMIT_MS)
    assert before.tobytes() == app.image("zoom-pixels").tobytes(), "Zoom changed document pixels"


LATENCY_CASES = {
    "latency_brush": latency_brush,
    "latency_eraser": latency_eraser,
    "latency_move": latency_move,
    "latency_marquee": latency_marquee,
    "latency_lasso": latency_lasso,
    "latency_wand": latency_wand,
    "latency_crop": latency_crop,
    "latency_clone": latency_clone,
    "latency_heal": lambda app: latency_heal(app, "Content-Aware"),
    "latency_smear_liquify": lambda app: latency_smear(app, "Liquify"),
    "latency_smear_blur": lambda app: latency_smear(app, "Blur"),
    "latency_smear_smudge": lambda app: latency_smear(app, "Smudge"),
    "latency_gradient": latency_gradient,
    "latency_shape": latency_shape,
    "latency_type": latency_type,
    "latency_eyedropper": latency_eyedropper,
    "latency_hand": latency_hand,
    "latency_zoom": latency_zoom,
}

assert set(TOOLS) <= {
    "move", "marquee", "lasso", "wand", "crop", "brush", "spotHealing", "cloneStamp",
    "blur", "gradient", "shape", "type", "eyedropper", "hand", "zoom",
}
