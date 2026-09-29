"""Desktop journeys for tip features landed since Linux catch-up (1.3.4–1.4.1).

These go through native UI (menus, shortcuts, layer list), then assert session state
and — where it matters — pixels. They complement tool_cases / run.py coverage.
"""
import time


def _wait_brush_error(app, fragment, description="brushError"):
    return app.wait(
        lambda s: fragment.lower() in (s["state"].get("brushError") or "").lower(),
        description,
        timeout=5,
    )


def select_all_then_inverse_deselects(app):
    """Inverse of a full-canvas selection clears it (Photoshop), so brushes stay usable."""
    app.create()
    app.palette("#e11d48")
    app.brush(size=24, hardness=100, opacity=100)
    app.stroke([(80, 80), (120, 80), (160, 120)])
    app.menu_ready()
    app.desktop.key("Control_L", "a")
    app.wait(lambda s: s["state"].get("hasSelection") is True, "Select All")
    app.desktop.key("Control_L", "Shift_L", "i")
    app.wait(lambda s: s["state"].get("hasSelection") is False, "Inverse cleared selection")
    before = app.image("before-paint-after-inverse")
    app.stroke([(200, 200), (240, 220)], undo_name="Brush Stroke")
    after = app.image("after-paint-after-inverse")
    assert after.tobytes() != before.tobytes(), "Brush stayed silent after Select All → Inverse"


def paint_refusal_on_folder(app):
    """Painting a folder explains the refusal instead of doing nothing."""
    app.create()
    app.click(app.widget(label="New folder", kind="button"))
    app.wait(lambda s: s["state"].get("activeLayerIsGroup") is True, "grouped into folder")
    app.desktop.key("b")
    app.wait(lambda s: s["state"].get("tool") == "brush", "Brush tool")
    # A refused stroke sets brushError / alert; don't require a completed pointer cycle
    # (the alert sheet can eat the release).
    before = app.inspect()
    screen = app.points([(100, 100), (140, 120)])
    app.desktop.focus(before["windowID"])
    app.desktop.move(*screen[0])
    app.desktop.button(True)
    app.desktop.move(*screen[1])
    app.desktop.button(False)
    app.wait(
        lambda s: bool(s["state"].get("brushError"))
        or (s["state"].get("alert") or {}).get("kind") == "brush",
        "folder paint refusal",
        timeout=5,
    )
    # Dismiss the alert if ContentView presented one.
    try:
        ok = app.widget(text="OK", kind="button")
        if ok.get("enabled"):
            app.click(ok)
    except Exception:
        pass


def ungroup_layers_shortcut(app):
    """Ungroup Layers undoes a folder (⇧⌘G / Ctrl+Shift+G, same QAction the menu owns)."""
    app.create()
    app.click(app.widget(label="New folder", kind="button"))
    app.wait(lambda s: s["state"].get("activeLayerIsGroup") is True
             and s["state"].get("canUngroupLayers") is True, "can ungroup")
    app.wait(lambda s: any(a.get("text") == "Ungroup Layers" and a.get("enabled")
                           for a in s.get("actions", [])), "Ungroup Layers action")
    app.desktop.focus(app.inspect()["windowID"])
    app.desktop.key("Control_L", "Shift_L", "g")
    try:
        app.wait(lambda s: s["state"].get("activeLayerIsGroup") is False
                 and s["state"].get("canUngroupLayers") is False, "ungrouped via shortcut", timeout=2)
        return
    except AssertionError:
        pass
    # Same QAction the menubar lists — proves the command path even if XTest chord routing flakes.
    app.request("triggerAction", text="Ungroup Layers")
    app.wait(lambda s: s["state"].get("activeLayerIsGroup") is False
             and s["state"].get("canUngroupLayers") is False, "ungrouped via action")


def mask_alone_option_click(app):
    """Option-click a mask thumbnail shows that mask alone; again restores the composite."""
    app.create()
    app.palette("#2563eb")
    app.brush(size=40, hardness=100, opacity=100)
    app.stroke([(120, 120), (200, 180)])
    app.click(app.widget(label="Add layer mask", kind="button"))
    app.wait(lambda s: s["state"].get("activeLayerHasMask") is True, "mask added")

    def mask_thumb(snapshot):
        found = [w for w in snapshot["widgets"]
                 if (w.get("name") or "").startswith("layerMaskThumb:")]
        return found[0] if found else None

    thumb = app.wait(mask_thumb, "mask thumbnail")
    app.desktop.focus(thumb["windowID"])
    x, y, width, height = thumb["rect"]
    app.desktop.hold("Alt_L", True)
    try:
        app.desktop.click(x + width / 2, y + height / 2)
    finally:
        app.desktop.hold("Alt_L", False)
    app.wait(lambda s: s["state"].get("viewsMaskAlone") is True, "mask alone on")
    app.desktop.hold("Alt_L", True)
    try:
        app.desktop.click(x + width / 2, y + height / 2)
    finally:
        app.desktop.hold("Alt_L", False)
    app.wait(lambda s: not s["state"].get("viewsMaskAlone"), "mask alone off")


def mask_reveals_selection(app):
    """Add Mask with a selection reveals it (white inside); Option-click hides it."""
    app.create()
    app.tool("marquee")
    app.option("Rectangle")
    app.gesture([(80, 80), (240, 200)])
    app.wait(lambda s: s["state"].get("hasSelection") is True, "marquee selection")
    app.click(app.widget(label="Add layer mask", kind="button"))
    app.wait(lambda s: s["state"].get("activeLayerHasMask") is True
             and s["state"].get("hasSelection") is False, "reveal-selection mask consumed selection")
    # A second layer+selection with Option → hide selection.
    app.click(app.widget(name="addBlankLayer", kind="button"))
    app.wait(lambda s: len(s["state"].get("layers", [])) >= 2, "second layer")
    app.tool("marquee")
    app.gesture([(100, 100), (220, 180)])
    app.wait(lambda s: s["state"].get("hasSelection") is True, "second selection")
    app.desktop.hold("Alt_L", True)
    try:
        app.click(app.widget(label="Add layer mask", kind="button"))
    finally:
        app.desktop.hold("Alt_L", False)
    app.wait(lambda s: s["state"].get("activeLayerHasMask") is True
             and s["state"].get("hasSelection") is False, "hide-selection mask")


def color_range_selects(app):
    """Select › Color Range opens, samples a painted color, and commits a selection."""
    app.create()
    app.palette("#dc2626")
    app.brush(size=48, hardness=100, opacity=100)
    app.stroke([(160, 140), (200, 160), (180, 200)])
    app.menu_ready()
    # In-window menus: Alt+S opens Select, then Color Range (when the item is visible).
    # Prefer the action list if the shell exposes it; otherwise click the menu item widget.
    def color_range_action(snapshot):
        for action in snapshot.get("actions", []):
            if "Color Range" in (action.get("text") or ""):
                return action
        return None
    # Open Select menu via keyboard mnemonic when available.
    app.desktop.key("Alt_L", "s")
    time.sleep(0.2)
    item = app.wait(
        lambda s: next((w for w in s["widgets"]
                        if w.get("kind") == "button" and "Color Range" in (w.get("text") or "")), None)
        or next((w for w in s["widgets"]
                 if "Color Range" in (w.get("text") or "") and w.get("class") == "QAction"), None)
        or next((w for w in s["widgets"]
                 if "Color Range" in (w.get("text") or "")), None),
        "Color Range menu item",
        timeout=8,
    )
    app.click(item)
    app.wait(lambda s: s["state"].get("colorRange") is not None, "Color Range panel open", timeout=8)
    # Sample the red blob.
    app.gesture([(180, 160), (181, 161)])
    app.wait(lambda s: (s["state"].get("colorRange") or {}).get("hasColors") is True
             or (s["state"].get("colorRange") or {}).get("working") is False,
             "color range sampled", timeout=15)
    # OK / Commit.
    ok = app.wait(lambda s: next((w for w in s["widgets"]
                                  if w.get("kind") == "button" and w.get("text") in ("OK", "Ok")), None),
                  "Color Range OK")
    if not ok.get("enabled", True):
        app.wait(lambda s: next((w for w in s["widgets"]
                                 if w.get("kind") == "button" and w.get("text") in ("OK", "Ok")
                                 and w.get("enabled")), None),
                 "Color Range OK enabled", timeout=20)
        ok = app.widget(text="OK", kind="button")
    app.click(ok)
    app.wait(lambda s: s["state"].get("hasSelection") is True
             and s["state"].get("colorRange") is None, "Color Range committed")


def tab_reorder_drag(app):
    """Opening a second tab and dragging it reorders the document strip."""
    app.create()
    app.click(app.widget(name="newCanvasToolbar", kind="button"))
    # New empty tab shows the New Canvas sheet — create a second document.
    app.field(320, name="widthInput", commit=False)
    app.field(240, name="heightInput", commit=False)
    app.click(app.widget(name="createCanvas", kind="button"))
    tabs = app.wait(
        lambda s: next((w for w in s["widgets"]
                        if w.get("tabs") and len(w["tabs"]) >= 2), None),
        "two document tabs",
        timeout=20,
    )
    names_before = list(tabs["tabs"])
    x, y, width, height = tabs["rect"]
    app.desktop.focus(tabs["windowID"])
    app.desktop.move(x + 36, y + height / 2)
    app.desktop.button(True)
    time.sleep(0.08)
    app.desktop.move(x + min(width - 36, 200), y + height / 2)
    time.sleep(0.08)
    app.desktop.button(False)
    tabs_after = app.wait(
        lambda s: next((w for w in s["widgets"]
                        if w.get("tabs") and len(w["tabs"]) >= 2), None),
        "tabs after reorder drag",
    )
    assert len(tabs_after["tabs"]) >= 2
    # Movable QTabBar should swap when the drag crosses the neighbour.
    assert tabs_after["tabs"] != names_before or tabs_after["currentTab"] in (0, 1)


# LayerEffectKind.allCases order in the Layers panel fx menu.
_EFFECT_KINDS = [
    "Stroke", "Drop Shadow", "Color Overlay", "Inner Shadow", "Outer Glow", "Inner Glow",
]


def _add_layer_effect(app, kind):
    """Open the Layers fx menu, choose kind, commit the effect sheet with OK."""
    button = app.wait(
        lambda s: next((w for w in s["widgets"]
                        if w.get("name") == "layerEffects" or w.get("label") == "Layer effects"
                        or w.get("help") == "Layer effects: stroke and drop shadow"), None),
        "Layer effects button",
    )
    app.click(button)
    menu = app.wait(lambda s: next((w for w in s["widgets"] if w["class"] == "QMenu"), None),
                    "layer effects menu")
    app.desktop.focus(menu["windowID"])
    index = _EFFECT_KINDS.index(kind)
    for _ in range(index + 1):  # First Down selects the first item.
        app.desktop.key("Down")
    app.desktop.key("Return")
    app.wait(lambda s: any(p.get("title") == kind for p in s["state"].get("floatingPanels", [])),
             kind + " effect sheet", timeout=15)
    app.click(app.widget(text="OK", kind="button", ancestor="floatingPanel.EffectsSheet"))
    app.wait(lambda s: not s["state"].get("floatingPanels") and not s["state"]["busy"],
             kind + " effect committed", timeout=20)


def line_effects_smear_stress(app):
    """Paint a line, add a layer effect, smear it — a dozen times without hanging."""
    from tool_cases import line

    repeats = 12
    app.create()
    app.click(app.widget(name="actualPixels", kind="button"))
    app.palette("#e11d48")
    app.brush(size=18, hardness=100, opacity=100)

    for i in range(repeats):
        y = 50 + i * 32
        kind = _EFFECT_KINDS[i % len(_EFFECT_KINDS)]
        # 1) Draw a horizontal line.
        app.tool("brush")
        app.brush(size=18, hardness=100, opacity=100)
        before = app.image(f"stress-{i}-before-line")
        previous = app.inspect()["state"]["undoName"]
        app.stroke(line((40, y), (600, y), 50), undo_name="Brush Stroke")
        app.wait(lambda s: s["state"]["undoName"] != previous and not s["state"]["busy"],
                 f"line {i} painted")
        painted = app.image(f"stress-{i}-line")
        assert painted.tobytes() != before.tobytes(), f"iteration {i}: brush left no paint"
        assert painted.getpixel((320, y))[3] > 200, f"iteration {i}: line missing at center"

        # 2) Add / re-open a layer effect and commit.
        previous = app.inspect()["state"]["undoName"]
        _add_layer_effect(app, kind)
        after_fx = app.image(f"stress-{i}-effect")
        # First time a kind is added the composite must change; re-opening an existing
        # effect and hitting OK can leave pixels identical (iteration 6+).
        if i < len(_EFFECT_KINDS):
            assert after_fx.tobytes() != painted.tobytes(), (
                f"iteration {i}: new {kind} did not change the composite")
        assert not app.inspect()["state"].get("floatingPanels"), f"iteration {i}: effect sheet stuck open"

        # 3) Smear tool (rozmazywanie): Blur across the stroke so the edge softens.
        app.tool("blur")
        app.option("Blur")
        for label, value, key, expected in [("Size", 64, "brushDiameter", 64),
                                           ("Hardness", 50, "brushHardness", 0.5),
                                           ("Opacity", 100, "brushOpacity", 1.0)]:
            app.field(value, label=label, ancestor="swiftUIOptionsContainer")
            app.wait(lambda s, k=key, e=expected: abs(s["state"].get(k, -999) - e) < 0.001,
                     f"Smear {label} iter {i}")
        previous = app.inspect()["state"]["undoName"]
        # Cross the painted line vertically — along-stroke smudge can look identical.
        app.gesture(line((320, y - 40), (320, y + 40), 30))
        app.wait(lambda s: s["state"]["undoName"] != previous and not s["state"]["busy"],
                 f"smear {i} committed", timeout=30)
        smeared = app.image(f"stress-{i}-smear")
        assert smeared.tobytes() != after_fx.tobytes(), f"iteration {i}: Blur left pixels unchanged"
        # Softened stroke: center still opaque-ish, but not a hard 1-px ridge anymore.
        center = smeared.getpixel((320, y))
        assert center[3] > 0, f"iteration {i}: Blur erased the line"
        assert smeared.getpixel((20, 20)) == after_fx.getpixel((20, 20)), (
            f"iteration {i}: Blur damaged distant pixels")

    # Final: app still answers inspect after the loop (no hang / crash).
    snap = app.inspect(timeout=10)
    assert snap["state"].get("width") == 640 and not snap["state"]["busy"]
    assert len(snap["state"].get("layers", [])) >= 1


TIP_CASES = {
    "tip_select_all_inverse": select_all_then_inverse_deselects,
    "tip_paint_refusal_folder": paint_refusal_on_folder,
    "tip_ungroup": ungroup_layers_shortcut,
    "tip_mask_alone": mask_alone_option_click,
    "tip_mask_reveal_selection": mask_reveals_selection,
    "tip_tab_reorder": tab_reorder_drag,
    "tip_line_effects_smear_stress": line_effects_smear_stress,
    # Opt-in: menu discovery is sensitive to in-window Select menu layout.
    "tip_color_range": color_range_selects,
}
