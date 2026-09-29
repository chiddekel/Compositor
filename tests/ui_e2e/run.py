#!/usr/bin/env python3
"""Drive the shipping Qt/Swift application through native desktop mouse and keyboard input."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import traceback
import xml.etree.ElementTree as ET

from PIL import Image
from desktop import Desktop
from tool_cases import TOOL_CASES, TOOLS
from latency_cases import LATENCY_CASES
from psd_cases import PSD_CASES
from metrics import Metrics, metadata, write_report

ROOT = Path(__file__).resolve().parents[2]


class App:
    def __init__(self, args, artifacts):
        self.artifacts = artifacts
        self.large_psb = args.large_psb
        artifacts.mkdir(parents=True, exist_ok=False, mode=0o700)
        host_display = None
        desktop_mode = "xvfb"
        if getattr(args, "visible", False):
            # Nested Xephyr window on the desktop (not headless). Host DISPLAY focus is unreliable on Xwayland.
            desktop_mode = "xephyr"
        self.desktop = Desktop.__new__(Desktop)
        self.desktop.__init__(artifacts, mode=desktop_mode, display=host_display)
        self.sequence = 0
        self.log = open(artifacts / "app.log", "w")
        sdk = re.search(r"^runtime-version:\s*['\"]?([^'\"\s]+)",
                        (ROOT / "com.compositor.Client.yaml").read_text(), re.M).group(1)
        env = {
            "DISPLAY": self.desktop.display_name, "QT_QPA_PLATFORM": "xcb",
            "QT_QPA_PLATFORMTHEME": "", "XDG_CURRENT_DESKTOP": "UIE2E", "QT_USE_PORTAL": "0",
            "QT_IM_MODULE": "compose", "QT_ACCESSIBILITY": "0", "NO_AT_BRIDGE": "1",
            "COMPOSITOR_UI_E2E_DIR": str(artifacts),
            "COMPOSITOR_IN_WINDOW_MENUS": "1",
            "COMPOSITOR_SKIA_BRIDGE": str(ROOT / "build/lib/libCompositorSkiaBridge.so"),
            "COMPOSITOR_IMAGEIO_BACKEND": str(ROOT / "build/lib/libCompositorQtImageIO.so"),
            "XDG_CONFIG_HOME": str(artifacts / "profile/config"),
            "XDG_DATA_HOME": str(artifacts / "profile/data"),
            "XDG_CACHE_HOME": str(artifacts / "profile/cache"),
            "COMPOSITOR_BRUSH_BACKEND": args.backend,
        }
        if args.compress_input:
            env["COMPOSITOR_UI_E2E_COMPRESS_INPUT"] = "1"
        # Do not inherit grab/smoke/profile flags from an interactive developer session.
        environment = {k: v for k, v in os.environ.items() if not k.startswith("COMPOSITOR_")}
        # Flatpak selects the X11 socket from its own environment before applying --env overrides.
        environment["DISPLAY"] = self.desktop.display_name
        environment.pop("WAYLAND_DISPLAY", None)
        environment.pop("SESSION_MANAGER", None)
        environment.pop("XAUTHORITY", None)
        environment.update({k: env[k] for k in ("QT_IM_MODULE", "QT_ACCESSIBILITY", "NO_AT_BRIDGE", "XDG_CURRENT_DESKTOP")})
        command = ["flatpak", "run", "--command=bash", "--devel", "--filesystem=" + str(ROOT),
                   "--filesystem=" + str(artifacts), "--filesystem=/tmp", "--share=ipc", "--device=dri",
                   "--socket=x11"]
        command += ["--env=" + key + "=" + value for key, value in env.items()]
        command += ["org.kde.Sdk//" + sdk, "-c", 'cd "$1" && exec "$2"',
                    "ui-e2e", str(ROOT), str(Path(args.binary).resolve())]
        self.process = subprocess.Popen(["dbus-run-session", "--"] + command,
                                        env=environment, stdout=self.log, stderr=self.log, start_new_session=True)
        self.desktop.focus(self.inspect(timeout=45)["windowID"])
        self.metrics = Metrics(artifacts, args.binary)

    def request(self, action, timeout=15, **payload):
        self.sequence += 1
        payload.update(id=self.sequence, action=action)
        temporary = self.artifacts / "request.tmp"
        temporary.write_text(json.dumps(payload))
        temporary.replace(self.artifacts / "request.json")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError("Application exited: " + str(self.process.returncode))
            try:
                response = json.loads((self.artifacts / "response.json").read_text())
                if response.get("id") == self.sequence:
                    if not response.get("ok"):
                        raise AssertionError(response)
                    return response
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(0.01)
        raise TimeoutError("UI did not answer " + action)

    def inspect(self, **kwargs):
        return self.request("inspect", **kwargs)

    def wait(self, predicate, description, timeout=10):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            last = self.inspect()
            value = predicate(last)
            if value:
                return value
            time.sleep(0.03)
        state = {k: v for k, v in last.get("state", {}).items() if k != "shortcuts"}
        raise AssertionError("Timed out waiting for " + description + "; state=" + json.dumps(state))

    def widget(self, *, label=None, name=None, text=None, kind=None, ancestor=None):
        def match(snapshot):
            found = [w for w in snapshot["widgets"]
                     if (label is None or (w["label"] or w.get("placeholder")) == label)
                     and (name is None or w["name"] == name)
                     and (text is None or w.get("text") == text)
                     and (kind is None or w.get("kind") == kind)
                     and (ancestor is None or ancestor in w["ancestors"])]
            if len(found) > 1:
                raise AssertionError("Ambiguous widget: " + repr(found))
            return found[0] if found else None
        return self.wait(match, repr((label, name, text, kind, ancestor)))

    def click(self, widget, double=False):
        assert widget["enabled"], "Widget is disabled: " + repr(widget)
        self.desktop.focus(widget["windowID"])
        x, y, width, height = widget["rect"]
        self.desktop.click(x + width / 2, y + height / 2, double=double)

    def field(self, value, commit=True, **selector):
        self.click(self.widget(kind="field", **selector))
        self.desktop.key("Control_L", "a")
        self.desktop.text(str(value))
        self.wait(lambda s: any(w.get("kind") == "field" and w["focused"] and w["text"] == str(value)
                               for w in s["widgets"]), "typed field value " + str(value))
        if commit:
            self.desktop.key("Return")

    def create(self, width=640, height=480):
        self.field(width, name="widthInput", commit=False)
        self.field(height, name="heightInput", commit=False)
        self.click(self.widget(name="createCanvas", kind="button"))
        self.wait(lambda s: len(s["state"].get("layers", [])) == 1
                  and s["state"]["width"] == width and s["state"]["height"] == height, "new document")
        self.desktop.key("b")
        self.wait(lambda s: s["state"].get("tool") == "brush", "Brush tool")

    def brush(self, size=12, hardness=100, opacity=100, smoothing=0):
        for label, value, state_key, expected in [
            ("Size", size, "brushDiameter", size), ("Hardness", hardness, "brushHardness", hardness / 100),
            ("Opacity", opacity, "brushOpacity", opacity / 100), ("Smoothing", smoothing, "brushSmoothing", smoothing)]:
            self.field(value, label=label, ancestor="swiftUIOptionsContainer")
            self.wait(lambda s: abs(s["state"].get(state_key, -999) - expected) < 0.001, label + " binding")

    def points(self, points):
        x, y, sx, sy = self.inspect()["canvasMapping"]
        return [(x + px * sx, y + py * sy) for px, py in points]

    def tool(self, name):
        button = self.widget(label=TOOLS[name], kind="button", ancestor="swiftUIToolRailContainer")
        with self.metrics.measure("select_" + name):
            self.click(button)
            self.wait(lambda s: s["state"].get("tool") == name, "selected tool " + name)

    def option(self, text):
        self.click(self.widget(text=text, kind="button", ancestor="swiftUIOptionsContainer"))

    def gesture(self, points, modifier=None, interval=0.012):
        with self.metrics.measure("gesture", points=len(points), interval_ms=interval * 1000) as record:
            self._gesture(points, modifier, interval, record)

    def _gesture(self, points, modifier, interval, record):
        before = self.inspect()
        self.desktop.focus(before["windowID"])
        screen = self.points(points)
        if modifier:
            self.desktop.hold(modifier, True)
        try:
            self.desktop.move(*screen[0])
            self.desktop.button(True)
            self.wait(lambda s: s["pointerPresses"] > before["pointerPresses"], "pointer press")
            for point in screen[1:]:
                self.desktop.move(*point)
                time.sleep(interval)
            released = time.perf_counter()
            self.desktop.button(False)
            self.wait(lambda s: s["pointerReleases"] > before["pointerReleases"], "pointer release")
            record["release_to_observed_ms"] = (time.perf_counter() - released) * 1000
        finally:
            if modifier:
                self.desktop.hold(modifier, False)

    def palette(self, color):
        self.click(self.widget(label="Foreground color", kind="button", ancestor="swiftUIToolRailContainer"))
        self.field(color, label="Hex color", commit=False)
        self.click(self.widget(text="OK", kind="button", ancestor="floatingPanel.ColorPickerSheet"))
        self.wait(lambda s: not s["state"].get("colorPickerTitle"), "closed color picker")

    def stroke(self, points, interval=0.003, stall=False, undo_name="Brush Stroke"):
        state = self.inspect()["state"]
        parameters = {key: state.get(key) for key in ("brushDiameter", "brushHardness", "brushOpacity", "brushSmoothing")}
        parameters.update(points=len(points), interval_ms=interval * 1000, stall=stall)
        with self.metrics.measure("stroke", **parameters) as record:
            self._stroke(points, interval, stall, undo_name, record)

    def _stroke(self, points, interval, stall, undo_name, record):
        before = self.inspect()
        self.desktop.focus(before["windowID"])
        screen = self.points(points)
        self.desktop.move(*screen[0])
        self.desktop.button(True)
        self.wait(lambda s: s["pointerPresses"] > before["pointerPresses"], "stroke press")
        if stall:
            self.request("stall", milliseconds=300)
        for point in screen[1:]:
            self.desktop.move(*point, flush=not stall)
            if interval and not stall:
                time.sleep(interval)
        released = time.perf_counter()
        self.desktop.button(False)
        self.desktop.x.XSync(self.desktop.display, False)
        self.wait(lambda s: s["pointerReleases"] > before["pointerReleases"]
                  and s["state"].get("undoName") == undo_name, "finished stroke", timeout=20)
        record["release_to_observed_ms"] = (time.perf_counter() - released) * 1000

    def image(self, name):
        path = self.request("export", name=name + ".png")["path"]
        return Image.open(path).convert("RGBA")

    def menu_ready(self):
        self.wait(lambda s: any(a["enabled"] and a["text"] == "Undo " + s["state"]["undoName"]
                               for a in s["actions"]), "enabled Undo menu item")

    def undo(self):
        self.menu_ready()
        self.desktop.key("Control_L", "z")

    def redo(self):
        self.wait(lambda s: any(a["enabled"] and a["text"] == "Redo " + s["state"]["redoName"]
                               for a in s["actions"]), "enabled Redo menu item")
        self.desktop.key("Control_L", "Shift_L", "z")

    def artifacts_now(self, name):
        snapshot = self.inspect(timeout=3)
        (self.artifacts / (name + ".json")).write_text(json.dumps(snapshot, indent=2))
        self.request("capture", name=name + ".png", timeout=3)

    def close(self):
        if getattr(self, "metrics", None):
            self.metrics.stop_event.set()
            self.metrics.thread.join()
        if getattr(self, "process", None):
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait()
        if getattr(self, "log", None):
            self.log.close()
        if getattr(self, "desktop", None):
            self.desktop.close()


class TrajectoryFailure(AssertionError):
    pass


def brush_circle(app, burst=False):
    app.create()
    app.brush(size=10)
    if not burst:
        app.click(app.widget(name="actualPixels", kind="button"))
    points = [(320 + 140 * math.cos(i * 2 * math.pi / 180),
               240 + 140 * math.sin(i * 2 * math.pi / 180)) for i in range(181)]
    app.stroke(points, interval=0.004, stall=burst)
    image = app.image("circle")
    covered = sum(max(image.getpixel((round(x) + dx, round(y) + dy))[3]
                      for dx in range(-3, 4) for dy in range(-3, 4)) > 180 for x, y in points[:-1])
    if covered < 175:
        raise TrajectoryFailure(f"Circle only covers {covered}/180 expected path points")
    assert image.getpixel((320, 240))[3] == 0, "Circle cut across its center"
    for y in range(image.height):
        for x in range(image.width):
            if image.getpixel((x, y))[3] > 128:
                assert abs(math.hypot(x - 320, y - 240) - 140) < 9, f"Stroke wandered off the circle at {x, y}"


def brush_burst(app):
    brush_circle(app, burst=True)


def inspect_only(app):
    app.artifacts_now("initial")


def rename(app, old, draft, ending, expected):
    app.click(app.widget(text=old, kind="label", ancestor="layersList"), double=True)
    field = app.widget(label="Layer name", kind="field")
    assert field["focused"] and field["selected"] == old, "Rename did not focus/select the name"
    app.desktop.text(draft)
    if ending == "blur":
        app.click(app.widget(name="actualPixels", kind="button"))
    else:
        app.desktop.key(ending)
    app.wait(lambda s: s["state"]["layers"][0]["name"] == expected
             and not any(w.get("placeholder") == "Layer name" for w in s["widgets"]), "rename completion")
    assert app.widget(name="addBlankLayer", kind="button")["enabled"], "Rename left layer actions disabled"
    assert app.inspect()["state"]["tool"] == "brush", "Typing a name activated a tool shortcut"


def layer_rename(app):
    app.create()
    rename(app, "Layer 1", "brush layer", "Return", "brush layer")
    app.undo()
    app.wait(lambda s: s["state"]["layers"][0]["name"] == "Layer 1", "rename undo")
    app.redo()
    app.wait(lambda s: s["state"]["layers"][0]["name"] == "brush layer", "rename redo")
    rename(app, "brush layer", "cancelled", "Escape", "brush layer")
    rename(app, "brush layer", "saved on blur", "blur", "saved on blur")
    app.click(app.widget(name="addBlankLayer", kind="button"))
    app.wait(lambda s: len(s["state"]["layers"]) == 2, "add layer after rename")


def color_picker(app, cancel=False, submit=False):
    app.create()
    app.brush(size=24)
    app.click(app.widget(label="Foreground color", kind="button", ancestor="swiftUIOptionsContainer"))
    app.field("#2fa573", label="Hex color", commit=submit)
    app.click(app.widget(text="Cancel" if cancel else "OK", kind="button"))
    app.wait(lambda s: not s["state"].get("colorPickerTitle"), "closed color picker")
    app.stroke([(100 + 4 * i, 240) for i in range(111)])
    pixel = app.image("paint").getpixel((320, 240))
    expected = (0, 0, 0, 255) if cancel else (47, 165, 115, 255)
    assert pixel == expected, f"Picker-to-brush color: expected {expected}, got {pixel}"


def brush_parameters(app):
    app.create()
    app.brush(size=24, opacity=50)
    line = [(100 + 4 * i, 240) for i in range(111)]
    app.stroke(line)
    image = app.image("opacity")
    assert 126 <= image.getpixel((320, 240))[3] <= 129, "Opacity field did not affect paint"
    assert image.getpixel((320, 225))[3] == 0, "Size field did not constrain brush width"
    assert image.getpixel((320, 231))[3] > 100, "Brush narrower than requested"
    original = image.tobytes()
    app.undo()
    # Linux omits New Canvas from the undo stack (baseline); Mac keeps the name.
    app.wait(lambda s: s["state"]["undoName"] in ("New Canvas", ""), "stroke undo")
    assert app.image("undo").getchannel("A").getbbox() is None, "Undo left painted pixels"
    app.redo()
    app.wait(lambda s: s["state"]["undoName"] == "Brush Stroke", "stroke redo")
    assert app.image("redo").tobytes() == original, "Redo changed the stroke"
    app.brush(size=40, opacity=100)
    app.click(app.widget(text="Erase", kind="button", ancestor="swiftUIOptionsContainer"))
    app.stroke([(320, 210 + i) for i in range(61)], undo_name="Erase")
    erased = app.image("erase")
    assert erased.getpixel((320, 240))[3] == 0, "Erase mode did not remove paint"
    assert erased.getpixel((200, 240))[3] > 100, "Erase changed pixels outside the stroke"


def soft_brush(app, size=64):
    app.create()
    app.brush(size=size, hardness=0)
    app.stroke([(100 + 4 * i, 240) for i in range(111)])
    image = app.image("soft")
    center, edge, outside = [image.getpixel((320, y))[3] for y in (240, 240 + round(size * 0.4), 240 + round(size * 0.55))]
    assert center > edge > outside == 0, f"Hardness did not create a soft edge: {center, edge, outside}"


def smoothing(app):
    app.create()
    points = [(100 + i * 6, 240 + (10 if i % 2 else -10)) for i in range(71)]
    app.brush(size=6)
    app.stroke(points)
    raw = app.image("raw")
    app.undo()
    app.wait(lambda s: s["state"]["undoName"] in ("New Canvas", ""), "raw stroke undo")
    app.brush(size=6, smoothing=30)
    app.stroke(points)
    smooth = app.image("smooth")
    def span(image):
        return image.getchannel("A").crop((160, 200, 460, 280)).getbbox()
    a, b = span(raw), span(smooth)
    assert a and b and b[3] - b[1] < (a[3] - a[1]) * 0.8, f"Smoothing did not reduce deviation: {a}, {b}"


def save_reopen(app):
    # Keep an empty tab open: closing the last document intentionally exits the application.
    app.click(app.widget(name="newCanvasToolbar", kind="button"))
    app.wait(lambda s: any(len(w.get("tabs", [])) == 2 for w in s["widgets"]), "second document tab")
    app.create()
    app.brush(size=24)
    app.stroke([(100 + 4 * i, 240) for i in range(111)])
    original = app.image("before-save").tobytes()
    rename(app, "Layer 1", "saved layer", "Return", "saved layer")
    project = app.artifacts / "drawing.comp"
    app.menu_ready()
    app.desktop.key("Control_L", "Shift_L", "s")
    app.field(str(project), name="fileNameEdit", commit=False)
    app.artifacts_now("save-dialog")
    app.desktop.key("Return")
    app.wait(lambda s: (project / "manifest.json").exists() and not s["state"].get("modified"), "saved project")
    app.desktop.focus(app.inspect()["windowID"])
    app.desktop.key("Control_L", "w")
    app.wait(lambda s: not s["state"].get("layers"), "closed project")
    app.desktop.key("Control_L", "o")
    app.field(str(project), name="fileNameEdit", commit=False)
    app.artifacts_now("open-dialog")
    app.desktop.key("Return")
    app.wait(lambda s: s["state"].get("width") == 640 and s["state"].get("height") == 480
             and len(s["state"].get("layers", [])) == 1
             and s["state"]["layers"][0]["name"] == "saved layer", "reopened project")
    assert app.image("reopened").tobytes() == original, "Save/reopen changed painted pixels"


def brush_performance(app):
    app.create()
    app.click(app.widget(name="actualPixels", kind="button"))
    points = [(320 + 140 * math.cos(i * 2 * math.pi / 180),
               240 + 140 * math.sin(i * 2 * math.pi / 180)) for i in range(181)]
    configurations = [(size, smoothing, 100) for size in (12, 64, 256) for smoothing in (0, 30)]
    configurations += [(64, 0, 0), (256, 0, 0)]
    for size, smoothing_value, hardness in configurations:
        app.brush(size=size, smoothing=smoothing_value, hardness=hardness)
        reference = None
        for trial in range(6):
            app.stroke(points, interval=.003)
            record = app.metrics.records[-1]
            record["name"] = f"brush_{size}px_smoothing_{smoothing_value}_hardness_{hardness}"
            record["parameters"]["trial"] = trial
            if trial == 0:
                # One warm-up per configuration; keep it outside the repeated distribution.
                record["name"] += "_warmup"
            painted = app.image(f"benchmark-{size}-{smoothing_value}-{hardness}-{trial}")
            assert painted.getchannel("A").getbbox(), "Benchmark produced no paint"
            assert painted.getpixel((320, 240))[3] == 0, "Circle cut across its center"
            if smoothing_value == 0:
                hits = sum(painted.getpixel((round(x), round(y)))[3] > 0 for x, y in points)
                assert hits >= 175, f"Benchmark dropped trajectory samples: {hits}/181"
            if reference is not None:
                assert painted.tobytes() == reference, "Repeated input produced different pixels"
            reference = painted.tobytes()
            app.undo()
            # Linux: New Canvas is the undo floor and is not named on the stack.
            app.wait(lambda s: s["state"]["undoName"] in ("New Canvas", ""), "benchmark stroke undo")
            assert app.image("benchmark-undo").getchannel("A").getbbox() is None, "Benchmark undo left paint"


CASES = {"inspect": inspect_only, "brush_burst": brush_burst, "brush_curve": brush_circle, "layer_rename": layer_rename,
         "color_accept": color_picker, "color_cancel": lambda app: color_picker(app, cancel=True),
         "color_submit": lambda app: color_picker(app, submit=True), "brush_parameters": brush_parameters,
         "soft_brush": soft_brush, "soft_brush_large": lambda app: soft_brush(app, size=256),
         "smoothing": smoothing, "save_reopen": save_reopen, "brush_performance": brush_performance}
CASES.update(TOOL_CASES)
CASES.update(LATENCY_CASES)
CASES.update(PSD_CASES)
from tip_cases import TIP_CASES
CASES.update(TIP_CASES)
from bench_cases import BENCH_CASES
CASES.update(BENCH_CASES)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=str(ROOT / ".build/release/CompositorHostBootstrap"))
    parser.add_argument("--artifacts", required=True)
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--backend", choices=["cpu", "auto"], default="auto")
    parser.add_argument("--large-psb", help="Path to the pinned 1.27 GiB PhotoshopAPI benchmark; enables psb_large_import")
    parser.add_argument("--compress-input", action="store_true")
    parser.add_argument("--check-input-regression", action="store_true",
                        help="Also prove that restoring event compression breaks the circle test")
    parser.add_argument("--visible", action="store_true",
                        help="Show UI in a nested Xephyr window (non-headless); default is private Xvfb")
    args = parser.parse_args()
    if args.case and "psb_large_import" in args.case and not args.large_psb:
        parser.error("psb_large_import requires --large-psb PATH")
    artifacts = Path(args.artifacts).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    suite = ET.Element("testsuite", name="Compositor desktop UI")
    failures = 0
    report = {"environment": metadata(args.binary, args.backend), "cases": {}}
    names = args.case or [key for key in CASES if key not in ("inspect", "psb_large_import", "tip_color_range")]
    if args.large_psb and "psb_large_import" not in names:
        names.append("psb_large_import")
    if args.check_input_regression:
        names = names + ["input_regression_control"]
    report["expected_cases"] = names
    for name in names:
        started = time.monotonic()
        case = ET.SubElement(suite, "testcase", name=name)
        app = None
        try:
            case_args = argparse.Namespace(**vars(args))
            negative = name == "input_regression_control"
            if negative:
                case_args.compress_input = True
            app = App.__new__(App)
            app.__init__(case_args, artifacts / name)
            if negative:
                try:
                    brush_burst(app)
                except TrajectoryFailure as error:
                    ET.SubElement(case, "system-out").text = str(error)
                    print("Detected intentional regression:", error, flush=True)
                else:
                    raise AssertionError("Negative control did not detect compressed pointer input")
            else:
                CASES[name](app)
            app.artifacts_now("passed")
            print("PASS", name, flush=True)
        except Exception:
            failures += 1
            failure = traceback.format_exc()
            ET.SubElement(case, "failure", type=type(sys.exception()).__name__).text = failure
            print("FAIL", name, failure, flush=True)
            if app:
                try:
                    app.artifacts_now("failed")
                except Exception:
                    pass
        finally:
            if app:
                if getattr(app, "metrics", None):
                    try:
                        measurements = app.metrics.finish()
                        measurements["result"] = "FAIL" if case.find("failure") is not None else "PASS"
                        report["cases"][name] = measurements
                        (app.artifacts / "metrics.json").write_text(json.dumps(measurements, indent=2))
                    except Exception:
                        failures += 1
                        ET.SubElement(case, "failure", type="MetricsError").text = traceback.format_exc()
                        print("FAIL", name, "metrics collection", traceback.format_exc(), flush=True)
                app.close()
            case.set("time", str(round(time.monotonic() - started, 3)))
            report["failures"] = failures
            write_report(artifacts, report)
    suite.set("tests", str(len(suite)))
    suite.set("failures", str(failures))
    ET.ElementTree(suite).write(artifacts / "junit.xml", encoding="utf-8", xml_declaration=True)
    print("Artifacts:", artifacts)
    return int(failures > 0)


if __name__ == "__main__":
    sys.exit(main())
