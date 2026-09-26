"""Downloaded Photoshop documents driven through native import, conversion and save UI."""
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageStat


FIXTURES = Path(__file__).parent / "fixtures/psd-tools"
MANIFEST = json.loads((FIXTURES / "manifest.json").read_text())
BLENDS = {"norm": "Normal", "pass": "Normal", "mul ": "Multiply"}


def fixture(name):
    path = FIXTURES / name
    expected = MANIFEST["fixtures"][name]
    assert hashlib.sha256(path.read_bytes()).hexdigest() == expected["sha256"], "PSD fixture checksum mismatch: " + name
    return path.resolve(), expected


def choose_file(app, path):
    if path.suffix in (".psd", ".psb"):
        app.click(app.widget(text="Import image", kind="button"))
    else:
        app.desktop.key("Control_L", "o")
    app.field(str(path), name="fileNameEdit", commit=False)
    app.desktop.key("Return")


def conversion_ready(app):
    def ready(snapshot):
        assert not snapshot["state"].get("error"), snapshot["state"].get("error")
        errors = [w.get("text", "") for w in snapshot["widgets"] if w["name"] in ("qt_msgbox_label", "qt_msgbox_informativelabel")]
        assert not errors, "Photoshop import failed: " + " ".join(errors)
        if snapshot["state"]["layers"] and not snapshot["state"]["conversionSheetOpen"]:
            return {"already_imported": True}
        buttons = [w for w in snapshot["widgets"] if w.get("kind") == "button"
                   and w.get("text") in ("Import", "Open") and w["enabled"]
                   and w["windowID"] != snapshot["windowID"]]
        if snapshot["state"].get("conversionSheetOpen") and buttons:
            return buttons[0]
        return None
    return app.wait(ready, "ready Photoshop conversion dialog", timeout=60)


def check_structure(state, expected):
    assert (state["width"], state["height"]) == (expected["width"], expected["height"]), "PSD dimensions changed"
    actual = state["layers"]
    records = expected["layers"]
    assert len(actual) == len(records), f"PSD layers lost: expected {len(records)}, got {len(actual)}"
    ids = {layer["id"]: i for i, layer in enumerate(actual)}
    for index, (layer, source) in enumerate(zip(actual, records)):
        for key, source_key in (("name", "name"), ("visible", "visible"), ("isGroup", "group")):
            assert layer[key] == source[source_key], f"PSD layer {index} {key}: {layer[key]!r} != {source[source_key]!r}"
        assert ids.get(layer.get("parentID")) == source["parent"], f"PSD hierarchy changed at {index}"
        assert abs(layer["opacity"] - source["opacity"]) < .001, f"PSD opacity changed at {index}"
        assert layer["blendMode"] == BLENDS[source["blend"]], f"PSD blend mode changed at {index}"
        if source["raster_mask"]:
            assert layer["hasMask"], f"PSD mask missing at {index}"


def stable_layers(state):
    return state["layers"]


def save_project(app, name):
    project = app.artifacts / (name + ".comp")
    app.desktop.focus(app.inspect()["windowID"])
    app.menu_ready()
    app.desktop.key("Control_L", "Shift_L", "s")
    app.field(str(project), name="fileNameEdit", commit=False)
    app.desktop.key("Return")
    app.wait(lambda s: (project / "manifest.json").is_file() and not s["state"]["modified"], "saved PSD project", timeout=60)
    return project


def complex_psd(app, name):
    path, expected = fixture(name)
    # Leave the original empty tab open so Close Project does not quit the app.
    app.click(app.widget(name="newCanvasToolbar", kind="button"))
    app.wait(lambda s: any(len(w.get("tabs", [])) == 2 for w in s["widgets"]), "second PSD tab")
    with app.metrics.measure("psd_open_and_convert", fixture=name, sha256=expected["sha256"]):
        choose_file(app, path)
        button = conversion_ready(app)
        notices = []
        if not button.get("already_imported"):
            app.artifacts_now("conversion")
            notices = [w["text"] for w in app.inspect()["widgets"] if w.get("kind") == "label"
                       and w["windowID"] == button["windowID"]]
            assert not app.inspect()["state"]["layers"], "PSD applied before conversion was accepted"
            app.click(button)
        app.wait(lambda s: not s["state"]["conversionSheetOpen"] and bool(s["state"]["layers"]), "imported Photoshop layers", timeout=60)
    state = app.inspect()["state"]
    check_structure(state, expected)
    original = app.image("psd-imported")
    assert max(ImageStat.Stat(original.convert("RGB")).var) > 1, "Complex PSD imported as an empty/flat canvas"
    if name == "hidden-groups.psd":
        reference = Image.open(FIXTURES / "hidden-groups-merged.png").convert("RGBA")
        difference = ImageChops.difference(original, reference)
        assert max(ImageStat.Stat(difference).mean) <= 2, "Hidden-group composite differs from Photoshop's merged image"

    with app.metrics.measure("psd_save", fixture=name):
        project = save_project(app, "imported")
    manifest = json.loads((project / "manifest.json").read_text())
    saved = manifest["layers"]
    for index, source in enumerate(expected["layers"]):
        if source["clipped"]:
            assert saved[index].get("maskSourceID"), f"PSD clipping link missing at {index}"
        if source["kind"] == "curves":
            assert saved[index].get("adjustment", {}).get("kind") == "Curves", "Curves layer was flattened"
    saved_state = stable_layers(app.inspect()["state"])
    with app.metrics.measure("psd_reopen", fixture=name):
        app.desktop.focus(app.inspect()["windowID"])
        app.desktop.key("Control_L", "w")
        app.wait(lambda s: not s["state"]["layers"], "closed imported PSD")
        choose_file(app, project)
        app.wait(lambda s: len(s["state"]["layers"]) == len(saved_state), "reopened layered PSD project", timeout=60)
    assert stable_layers(app.inspect()["state"]) == saved_state, "Save/reopen changed PSD layer metadata"
    assert app.image("psd-reopened").tobytes() == original.tobytes(), "Save/reopen changed imported PSD pixels"

    app.click(app.widget(name="addBlankLayer", kind="button"))
    app.wait(lambda s: len(s["state"]["layers"]) == len(saved_state) + 1, "new layer on imported PSD")
    app.tool("brush")
    app.brush(size=12)
    app.palette("#ff00ff")
    width, height = expected["width"], expected["height"]
    app.stroke([(width * (.1 + i * .005), height * .1) for i in range(41)])
    assert app.image("psd-painted").tobytes() != original.tobytes(), "Imported PSD did not accept paint"
    app.undo()
    app.wait(lambda s: s["state"]["canRedo"], "undo PSD edit")
    assert app.image("psd-edit-undone").tobytes() == original.tobytes(), "Undo damaged imported PSD pixels"
    if name == "smart-object-slice.psd":
        assert any("smart object was rasterized" in text for text in notices), "Missing smart-object conversion warning"
    if name == "layer_effects.psd":
        assert any("effects" in text.lower() and "discard" in text.lower() for text in notices), "PSD layer effects were discarded without a conversion warning"


def cancel_psd(app):
    path, _ = fixture("smart-object-slice.psd")
    before = app.inspect()["state"]
    choose_file(app, path)
    button = conversion_ready(app)
    assert not button.get("already_imported"), "Smart-object conversion was applied without confirmation"
    cancel = next(w for w in app.inspect()["widgets"] if w.get("text") == "Cancel"
                  and w.get("kind") == "button" and w["windowID"] == button["windowID"])
    app.click(cancel)
    app.wait(lambda s: not s["state"]["conversionSheetOpen"], "cancelled PSD conversion")
    app.artifacts_now("cancelled")
    after = app.inspect()["state"]
    assert stable_layers(after) == stable_layers(before) == [], "Cancel imported PSD layers"
    assert not after["modified"], "Cancel left a modified document"
    app.create()
    app.brush(size=12)
    app.stroke([(100 + i * 4, 240) for i in range(50)])
    assert app.image("paint-after-cancel").getchannel("A").getbbox(), "Cancel left the editor unusable"


PSD_CASES = {"psd_" + name.removesuffix(".psd").replace("-", "_"): (lambda app, n=name: complex_psd(app, n))
             for name, data in MANIFEST["fixtures"].items() if data["depth"] == 8}
PSD_CASES["psd_conversion_cancel"] = cancel_psd


def rejected_psd(app, name, message):
    path, expected = fixture(name)
    with app.metrics.measure("psd_reject", fixture=name, sha256=expected["sha256"]):
        choose_file(app, path)
        label = app.wait(lambda s: next((w for w in s["widgets"] if message in w.get("text", "")), None),
                         "clear Photoshop rejection message", timeout=60)
    app.artifacts_now("rejected")
    assert not app.inspect()["state"]["layers"], "Rejected PSD left partially imported layers"
    button = next(w for w in app.inspect()["widgets"] if w.get("kind") == "button"
                  and w["windowID"] == label["windowID"] and w.get("text", "").replace("&", "") in ("OK", "Close"))
    app.click(button)
    app.create()
    app.brush(size=12)
    app.stroke([(100 + i * 4, 240) for i in range(50)])
    assert app.image("paint-after-rejection").getchannel("A").getbbox(), "PSD error left the editor unusable"


PSD_CASES["psd_unsupported_depth"] = lambda app: rejected_psd(app, "16bit5x5.psd", "Only 8-bit RGB Photoshop files can be imported")
PSD_CASES["psd_unsupported_32bit"] = lambda app: rejected_psd(app, "pen-text.psd", "Only 8-bit RGB Photoshop files can be imported")


LARGE_PSB_SHA256 = "2d33180d6ffd7b8fe3785311fca8f18cd5cac08d705362dff5d89a6450574468"


def large_psb(app):
    path = Path(app.large_psb).resolve()
    assert path.stat().st_size == 1364358110, "Unexpected large PSB size"
    with path.open("rb") as file:
        assert hashlib.file_digest(file, "sha256").hexdigest() == LARGE_PSB_SHA256, "Large PSB checksum mismatch"
    with app.metrics.measure("large_psb_import", bytes=path.stat().st_size, sha256=LARGE_PSB_SHA256):
        choose_file(app, path)
        def result(snapshot):
            errors = [w for w in snapshot["widgets"] if w["name"] in ("qt_msgbox_label", "qt_msgbox_informativelabel")]
            if errors:
                return {"rejected": " ".join(w.get("text", "") for w in errors), "windowID": errors[0]["windowID"]}
            buttons = [w for w in snapshot["widgets"] if w.get("kind") == "button" and w.get("text") == "Import"
                       and w["enabled"] and w["windowID"] != snapshot["windowID"]]
            return buttons[0] if snapshot["state"]["conversionSheetOpen"] and buttons else None
        button = app.wait(result, "large PSB parsed and ready", timeout=300)
    if button.get("rejected"):
        app.artifacts_now("large-rejected")
        assert not app.inspect()["state"]["layers"], "Large PSB rejection left partial layers"
        close = next(w for w in app.inspect()["widgets"] if w.get("kind") == "button"
                     and w["windowID"] == button["windowID"] and w.get("text", "").replace("&", "") == "OK")
        app.click(close)
        app.create()
        app.brush(size=12)
        app.stroke([(100 + i * 4, 240) for i in range(50)])
        assert app.image("paint-after-large-rejection").getchannel("A").getbbox(), "Large PSB rejection left the editor unusable"
        # Error recovery is required, but cannot turn a rejected large document into a passing import.
        raise AssertionError("Large PSB import rejected (UI recovered): " + button["rejected"])
    with app.metrics.measure("large_psb_apply", sha256=LARGE_PSB_SHA256):
        app.artifacts_now("large-conversion")
        app.click(button)
        app.wait(lambda s: not s["state"]["conversionSheetOpen"] and len(s["state"]["layers"]) == 80,
                 "80 imported large PSB layers", timeout=300)
    state = app.inspect()["state"]
    assert (state["width"], state["height"]) == (8000, 4500)
    assert sum(layer["isGroup"] for layer in state["layers"]) == 4
    app.tool("hand")
    app.gesture([(4000, 2250), (4200, 2400)])
    app.artifacts_now("large-imported")


PSD_CASES["psb_large_import"] = large_psb
