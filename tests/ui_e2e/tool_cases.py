"""Tool-rail journeys. Every editor operation is performed with native desktop input."""
from collections import Counter
import json
import math

from PIL import Image, ImageChops, ImageDraw


TOOLS = {
    "move": "Move / Transform (V)",
    "marquee": "Marquee (M)",
    "lasso": "Lasso (L)",
    "wand": "Magic (W) · Tab switches Wand and Object",
    "crop": "Crop (C)",
    "brush": "Brush (B) · Eraser (E)",
    "spotHealing": "Spot Healing Brush (J)",
    "cloneStamp": "Clone Stamp (S) · Option-click sets the source",
    "blur": "Smear (R)",
    "gradient": "Gradient (G)",
    "shape": "Shape (U) · Shift-U switches Rectangle/Ellipse",
    "type": "Type (T)",
    "eyedropper": "Eyedropper (I)",
    "hand": "Hand (H)",
    "zoom": "Zoom (Z)",
}


def line(start, end, count=25):
    return [(start[0] + (end[0] - start[0]) * i / count,
             start[1] + (end[1] - start[1]) * i / count) for i in range(count + 1)]


def changed(app, previous):
    def finished(snapshot):
        state = snapshot["state"]
        assert not state.get("alert"), state.get("alert")
        return not state["busy"] and state["undoName"] != previous
    app.wait(finished, "committed tool operation", timeout=30)


def undo_pixels(app, before, name="undo-tool"):
    app.undo()
    app.wait(lambda s: s["state"]["canRedo"] and not s["state"]["busy"], "tool undo")
    assert app.image(name).tobytes() == before.tobytes(), "Undo did not restore the original pixels"


def import_fixture(app, healing=False):
    image = Image.new("RGBA", (640, 480), "white")
    draw = ImageDraw.Draw(image)
    if healing:
        draw.ellipse((306, 226, 334, 254), fill="black")
    else:
        draw.rectangle((160, 140, 319, 299), fill="black")
        draw.rectangle((420, 140, 499, 219), fill=(230, 40, 60, 255))
        draw.rectangle((420, 320, 499, 399), fill=(30, 80, 220, 255))
    path = app.artifacts / "fixture.png"
    image.save(path)
    app.click(app.widget(text="Import image", kind="button"))
    app.field(str(path), name="fileNameEdit", commit=False)
    app.desktop.key("Return")
    app.wait(lambda s: s["state"].get("width") == 640 and s["state"].get("height") == 480
             and len(s["state"].get("layers", [])) == 1 and not s["state"]["busy"], "imported fixture", timeout=30)
    app.click(app.widget(name="actualPixels", kind="button"))
    actual = app.image("imported")
    assert actual.tobytes() == image.tobytes(), "Image import changed fixture pixels"
    return actual


def inventory_and_tooltips(app):
    app.create()
    rail = [w for w in app.inspect()["widgets"] if w.get("kind") == "button"
            and "swiftUIToolRailContainer" in w["ancestors"]]
    labels = {w["label"] for w in rail}
    assert set(TOOLS.values()) <= labels, "A tool is missing from the tool rail"
    utility = {"Foreground color", "Background color", "Swap colors", "Default colors"}
    assert labels <= set(TOOLS.values()) | utility, "New tool needs an E2E journey: " + repr(labels - set(TOOLS.values()) - utility)
    (app.artifacts / "tools.json").write_text(json.dumps(TOOLS, indent=2))
    for name, label in TOOLS.items():
        app.tool(name)
        app.desktop.move(1100, 700)
        button = app.widget(label=label, kind="button", ancestor="swiftUIToolRailContainer")
        x, y, width, height = button["rect"]
        app.desktop.move(x + width / 2, y + height / 2)
        tooltip = app.wait(lambda s: next((w for w in s["widgets"]
                           if w["class"] == "QTipLabel" and w.get("text") == label), None), "tooltip for " + name)
        path = app.request("capture", name="tooltip-" + name + ".png")["path"]
        x, y, width, height = tooltip["rect"]
        pixels = Image.open(path).convert("RGB").crop((x, y, x + width, y + height))
        dominant = Counter(pixels.getdata()).most_common(1)[0][0]
        assert dominant == (36, 36, 39), f"{name} tooltip has unthemed background {dominant}"
        assert any(min(rgb) > 200 for rgb in pixels.getdata()), f"{name} tooltip text is not visible"
    app.desktop.move(1100, 700)


def selection(app, tool, mode):
    if tool == "wand":
        before = import_fixture(app)
    else:
        app.create()
        before = app.image("before-selection")
    app.tool(tool)
    app.option(mode)
    if tool == "wand":
        app.gesture([(240, 220)])
    elif mode == "Polygonal":
        for point in [(160, 140), (320, 140), (320, 300), (160, 300)]:
            app.gesture([point])
        app.desktop.key("Return")
    elif mode == "Freehand":
        points = []
        corners = [(160, 140), (320, 140), (320, 300), (160, 300), (160, 140)]
        for start, end in zip(corners, corners[1:]):
            points.extend(line(start, end, count=10))
        app.gesture(points)
    else:
        app.gesture(line((160, 140), (320, 300)))
    app.wait(lambda s: s["state"]["hasSelection"] and not s["state"]["busy"], "nonempty selection", timeout=30)
    app.artifacts_now("selection")
    app.tool("brush")
    app.brush(size=12)
    app.palette("#00cc44")
    app.stroke(line((80, 220), (560, 220), 120))
    painted = app.image("selection-painted")
    assert painted.getpixel((240, 220)) == (0, 204, 68, 255), "Selected interior did not accept paint"
    for point in [(100, 220), (400, 220), (540, 220)]:
        assert painted.getpixel(point) == before.getpixel(point), "Selection leaked paint at " + repr(point)
    undo_pixels(app, before)
    app.tool(tool)
    app.option("Deselect")
    app.wait(lambda s: not s["state"]["hasSelection"], "deselected")


def shape(app, kind):
    app.create()
    before = app.image("before-shape")
    previous = app.inspect()["state"]["undoName"]
    app.tool("shape")
    app.option(kind)
    app.gesture(line((160, 140), (320, 300)))
    changed(app, previous)
    image = app.image("shape")
    assert image.getpixel((240, 220))[3] > 240, "Shape did not fill its center"
    assert image.getpixel((100, 100))[3] == 0, "Shape painted outside its bounds"
    if kind == "Rectangle":
        assert image.getpixel((170, 150))[3] == 255, "Rectangle corner is missing"
    elif kind == "Ellipse":
        assert image.getpixel((170, 150))[3] == 0, "Ellipse has a rectangular corner"
    else:
        assert image.getpixel((180, 260))[3] == 0, "Line filled its whole bounding box"
    undo_pixels(app, before)


def gradient(app, kind):
    app.create()
    before = app.image("before-gradient")
    app.tool("gradient")
    app.option(kind)
    app.gesture(line((200, 220), (440, 220)))
    app.wait(lambda s: bool(s["state"].get("gradientLine")), "gradient preview")
    app.option("Cancel")
    app.wait(lambda s: not s["state"].get("gradientLine"), "cancelled gradient")
    assert app.image("cancelled").tobytes() == before.tobytes(), "Cancel changed document pixels"
    app.gesture(line((200, 220), (440, 220)))
    previous = app.inspect()["state"]["undoName"]
    app.option("Apply")
    changed(app, previous)
    image = app.image("gradient")
    alpha = [image.getpixel((x, 220))[3] for x in (210, 320, 430)]
    assert alpha[0] > alpha[1] > alpha[2], "Gradient did not fade along its axis: " + repr(alpha)
    if kind == "Radial":
        assert abs(image.getpixel((320, 220))[3] - image.getpixel((200, 340))[3]) <= 3, "Radial gradient is asymmetric"
    else:
        assert image.getpixel((320, 120))[3] == image.getpixel((320, 320))[3], "Linear gradient varies perpendicular to its axis"
    undo_pixels(app, before)


def crop(app):
    before = import_fixture(app)
    app.tool("crop")
    app.gesture(line((100, 80), (500, 380)))
    app.option("Cancel")
    assert app.image("cancelled-crop").tobytes() == before.tobytes(), "Cancel changed crop pixels"
    app.gesture(line((100, 80), (500, 380)))
    app.option("Apply Crop")
    app.wait(lambda s: s["state"]["width"] == 400 and s["state"]["height"] == 300, "cropped dimensions", timeout=30)
    assert app.image("cropped").tobytes() == before.crop((100, 80, 500, 380)).tobytes(), "Crop did not preserve the selected region"
    undo_pixels(app, before)


def move(app):
    before = import_fixture(app)
    app.tool("move")
    previous = app.inspect()["state"]["undoName"]
    app.gesture(line((240, 220), (280, 250)))
    changed(app, previous)
    state = app.inspect()["state"]
    origin = state["layers"][0]["transform"]["origin"]
    assert abs(origin[0] - 40) <= 1 and abs(origin[1] - 30) <= 1, "Move offset differs from drag: " + repr(origin)
    image = app.image("moved")
    assert image.getpixel((180, 180)) == (255, 255, 255, 255), "Original edge did not move"
    assert image.getpixel((340, 240)) == (0, 0, 0, 255), "Moved feature is missing"
    assert image.getpixel((20, 20))[3] == 0, "Exposed canvas is not transparent"
    undo_pixels(app, before)


def eyedropper(app):
    before = import_fixture(app)
    app.tool("eyedropper")
    app.gesture([(460, 180)])
    expected = [230 / 255, 40 / 255, 60 / 255]
    app.wait(lambda s: all(abs(a - b) < 0.005 for a, b in zip(s["state"]["foregroundColor"], expected)), "sampled red")
    app.tool("brush")
    app.brush(size=24)
    app.stroke(line((100, 380), (300, 380)))
    assert app.image("sampled-paint").getpixel((200, 380)) == before.getpixel((460, 180)), "Brush did not use sampled color"


def navigation(app, tool):
    before = import_fixture(app)
    original = app.inspect()["canvasMapping"]
    app.tool(tool)
    if tool == "hand":
        app.gesture(line((320, 240), (380, 280)))
        mapping = app.inspect()["canvasMapping"]
        assert abs(mapping[0] - original[0] - 60) <= 1 and abs(mapping[1] - original[1] - 40) <= 1, "Hand did not pan by the drag offset"
        assert mapping[2:] == original[2:], "Hand changed the zoom"
    else:
        app.gesture([(320, 240)])
        app.wait(lambda s: s["canvasMapping"][2] > original[2] * 1.9, "zoomed in")
        app.gesture([(320, 240)], modifier="Alt_L")
        app.wait(lambda s: abs(s["canvasMapping"][2] - original[2]) < 0.01, "zoomed out")
    assert app.image("navigated").tobytes() == before.tobytes(), "Navigation changed document pixels"


def clone_stamp(app):
    before = import_fixture(app)
    app.tool("brush")
    app.brush(size=36)
    app.tool("cloneStamp")
    app.gesture([(460, 180)], modifier="Alt_L")
    previous = app.inspect()["state"]["undoName"]
    app.gesture(line((240, 380), (280, 380)))
    changed(app, previous)
    image = app.image("cloned")
    assert image.getpixel((240, 380)) == before.getpixel((460, 180)), "Clone Stamp did not copy the source"
    assert image.getpixel((460, 180)) == before.getpixel((460, 180)), "Clone Stamp damaged its source"
    undo_pixels(app, before)


def retouch(app, tool, mode):
    before = import_fixture(app, healing=tool == "spotHealing")
    app.tool("brush")
    app.brush(size=80, hardness=100)
    app.tool(tool)
    app.option(mode)
    previous = app.inspect()["state"]["undoName"]
    points = line((300, 240), (340, 240)) if tool == "spotHealing" else line((300, 220), (370, 220))
    app.gesture(points)
    changed(app, previous)
    image = app.image("retouched")
    assert image.tobytes() != before.tobytes(), mode + " left pixels unchanged"
    assert image.getpixel((30, 30)) == before.getpixel((30, 30)), mode + " damaged distant pixels"
    if tool == "spotHealing":
        assert min(image.getpixel((320, 240))[:3]) > 180, mode + " did not remove the dark spot"
    elif mode == "Blur":
        assert 5 < image.getpixel((320, 220))[0] < 250, "Blur did not soften the hard edge"
    else:
        assert image.getpixel((340, 220))[0] < 230, mode + " did not push color beyond the old edge"
    undo_pixels(app, before)


def text_tool(app):
    app.create()
    before = app.image("before-text")
    app.tool("type")
    app.gesture([(180, 220)])
    app.wait(lambda s: s["state"].get("textDraft") is not None, "text editor")
    app.click(app.widget(name="canvas.textEditor"))
    app.desktop.text("Brush test")
    app.wait(lambda s: s["state"].get("textDraft", {}).get("content") == "Brush test", "typed canvas text")
    previous = app.inspect()["state"]["undoName"]
    app.desktop.key("Control_L", "Return")
    app.wait(lambda s: not s["state"].get("textDraft"), "committed text")
    changed(app, previous)
    image = app.image("text")
    bounds = image.getchannel("A").getbbox()
    assert bounds and bounds[2] - bounds[0] > 20 and bounds[3] - bounds[1] > 5, "Text did not render glyphs"
    assert image.getpixel((30, 30))[3] == 0, "Text painted outside its area"
    undo_pixels(app, before)


def idle(app):
    before = import_fixture(app)
    app.desktop.key("a")
    app.wait(lambda s: s["state"]["tool"] == "idle", "no tool selected")
    previous = app.inspect()["state"]["undoName"]
    app.gesture(line((200, 200), (300, 280)))
    assert app.image("idle").tobytes() == before.tobytes(), "Idle tool modified pixels"
    assert app.inspect()["state"]["undoName"] == previous, "Idle tool added history"


TOOL_CASES = {
    "tool_inventory_tooltips": inventory_and_tooltips,
    "tool_move": move,
    "tool_crop": crop,
    "tool_eyedropper": eyedropper,
    "tool_clone_stamp": clone_stamp,
    "tool_type": text_tool,
    "tool_idle": idle,
}
for tool, modes in [("marquee", ["Rectangle", "Ellipse"]), ("lasso", ["Freehand", "Polygonal"]), ("wand", ["Wand", "Object"])]:
    for mode in modes:
        TOOL_CASES[f"tool_{tool}_{mode.lower()}"] = lambda app, t=tool, m=mode: selection(app, t, m)
for kind in ["Rectangle", "Ellipse", "Line"]:
    TOOL_CASES["tool_shape_" + kind.lower()] = lambda app, k=kind: shape(app, k)
for kind in ["Linear", "Radial"]:
    TOOL_CASES["tool_gradient_" + kind.lower()] = lambda app, k=kind: gradient(app, k)
for tool in ["hand", "zoom"]:
    TOOL_CASES["tool_" + tool] = lambda app, t=tool: navigation(app, t)
for tool, modes in [("spotHealing", ["Content-Aware", "Create Texture", "Proximity Match"]), ("blur", ["Liquify", "Blur", "Smudge"])]:
    for mode in modes:
        TOOL_CASES[f"tool_{tool}_{mode.lower().replace(' ', '_').replace('-', '_')}"] = lambda app, t=tool, m=mode: retouch(app, t, m)
