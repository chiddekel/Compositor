#!/usr/bin/env python3
"""Exercise real XKB layout switching in a private Xvfb server, leaving the desktop unchanged."""
import ctypes
import ctypes.util
import json
import os
from pathlib import Path
import select
import shlex
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PROBE = Path(os.environ.get("COMPOSITOR_KEYBOARD_PROBE", ROOT / ".build/linux-contract-native/test_keyboard_layout")).resolve()
X11 = ctypes.CDLL(ctypes.util.find_library("X11"))
XTST = ctypes.CDLL(ctypes.util.find_library("Xtst"))
X11.XOpenDisplay.argtypes = [ctypes.c_char_p]
X11.XOpenDisplay.restype = ctypes.c_void_p
X11.XkbLockGroup.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint]
X11.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
X11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
X11.XCloseDisplay.argtypes = [ctypes.c_void_p]
X11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
X11.XDefaultRootWindow.restype = ctypes.c_ulong
X11.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong),
                          ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)),
                          ctypes.POINTER(ctypes.c_uint)]
X11.XFree.argtypes = [ctypes.c_void_p]
X11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
X11.XInternAtom.restype = ctypes.c_ulong
X11.XChangeProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong,
                               ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
XTST.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]


def line(process):
    if not select.select([process.stdout], [], [], 20)[0]:
        raise RuntimeError("Native keyboard probe timed out")
    text = process.stdout.readline()
    if not text:
        raise RuntimeError(f"Native keyboard probe exited before reporting a result: {process.poll()}")
    return text.strip()


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def check(layout, key, expected_typed, expected_latin, shift=False, expected_code=None):
    read_fd, write_fd = os.pipe()
    server = subprocess.Popen(["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "800x600x24", "-nolisten", "tcp"],
                              pass_fds=[write_fd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.close(write_fd)
    display, probe = None, None
    try:
        with os.fdopen(read_fd) as stream:
            if not select.select([stream], [], [], 20)[0]:
                raise RuntimeError("Xvfb did not allocate a display")
            name = ":" + stream.readline().strip()
        environment = dict(os.environ, DISPLAY=name)
        # Keep a client connected so Xvfb does not reset the keymap after xkbcomp exits.
        display = X11.XOpenDisplay(name.encode())
        assert display, "Cannot open the private test display"
        with tempfile.TemporaryDirectory(prefix="compositor-keymap-") as folder:
            keymap = Path(folder, "layout.xkb")
            keymap.write_bytes(subprocess.check_output(["xkbcli", "compile-keymap", "--layout", layout]))
            subprocess.run(["xkbcomp", str(keymap), name], env=environment, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        probe = subprocess.Popen([
            "flatpak", "run", "--user", "--command=bash", "--socket=x11", f"--filesystem={ROOT}",
            f"--filesystem={PROBE.parent}",
            f"--env=DISPLAY={name}", "--env=QT_QPA_PLATFORM=xcb", "org.kde.Sdk//6.11", "-c",
            f"exec {shlex.quote(str(PROBE))}"],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        ready = line(probe)
        assert ready.startswith("WINDOW "), ready
        X11.XSetInputFocus(display, int(ready.split()[1]), 1, 0)
        assert X11.XkbLockGroup(display, 0x0100, 1), "Cannot activate the Russian layout"
        X11.XSync(display, 0)
        if shift:
            XTST.XTestFakeKeyEvent(display, 50, 1, 0)
        XTST.XTestFakeKeyEvent(display, key, 1, 0)
        XTST.XTestFakeKeyEvent(display, key, 0, 0)
        if shift:
            XTST.XTestFakeKeyEvent(display, 50, 0, 0)
        X11.XSync(display, 0)
        result = json.loads(line(probe))
        assert result["typed"] == expected_typed, result
        assert result["latin"] == (expected_latin or ""), result
        assert (result["code"] != 0xffff) == (expected_latin is not None), result
        if expected_code is not None:
            assert result["code"] == expected_code, result
        assert probe.wait(timeout=10) == 0
        print(f"PASS {layout} shift={shift}: {result}", flush=True)
    finally:
        if probe:
            stop(probe)
        if display:
            X11.XCloseDisplay(display)
        stop(server)


def check_wayland(layout, code, normal, shifted):
    """Read the actual keymap supplied by an isolated Weston compositor through wl_keyboard."""
    read_fd, write_fd = os.pipe()
    server = subprocess.Popen(["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "800x600x24", "-nolisten", "tcp"],
                              pass_fds=[write_fd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.close(write_fd)
    compositor, display = None, None
    try:
        with os.fdopen(read_fd) as stream:
            if not select.select([stream], [], [], 20)[0]:
                raise RuntimeError("Xvfb did not allocate a display")
            name = ":" + stream.readline().strip()
        with tempfile.TemporaryDirectory(prefix="compositor-wayland-") as folder:
            display = X11.XOpenDisplay(name.encode())
            assert display, "Cannot open Weston's private X11 backend"
            keymap = Path(folder, "layout.xkb")
            keymap.write_bytes(subprocess.check_output(["xkbcli", "compile-keymap", "--layout", layout]))
            subprocess.run(["xkbcomp", str(keymap), name], env=dict(os.environ, DISPLAY=name), check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # Weston's X11 backend rebuilds its map from this conventional root property, not the uploaded map.
            rules = f"evdev\0pc105\0{layout}\0\0\0".encode()
            atom = X11.XInternAtom(display, b"_XKB_RULES_NAMES", 0)
            X11.XChangeProperty(display, X11.XDefaultRootWindow(display), atom, 31, 8, 0, rules, len(rules))
            X11.XSync(display, 0)
            config = Path(folder, "weston.ini")
            config.write_text(f"[keyboard]\nkeymap_layout={layout}\n")
            socket = Path(folder, "keyboard-test")
            compositor = subprocess.Popen([
                "weston", "--backend=x11", "--renderer=pixman", "--shell=kiosk-shell.so",
                "--socket=keyboard-test", "--idle-time=0", f"--config={config}", f"--log={folder}/weston.log"],
                env=dict(os.environ, DISPLAY=name, XDG_RUNTIME_DIR=folder),
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 10
            while not socket.exists():
                if compositor.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError(Path(folder, "weston.log").read_text())
                time.sleep(0.05)
            # The X11 backend advertises its keyboard only after its window receives focus.
            root, parent, count = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_uint()
            children = ctypes.POINTER(ctypes.c_ulong)()
            assert X11.XQueryTree(display, X11.XDefaultRootWindow(display), ctypes.byref(root),
                                 ctypes.byref(parent), ctypes.byref(children), ctypes.byref(count))
            assert count.value, "Weston did not create an X11 backend window"
            X11.XSetInputFocus(display, children[count.value - 1], 1, 0)
            X11.XFree(children)
            X11.XSync(display, 0)
            output = subprocess.check_output([
                "flatpak", "run", "--user", "--command=bash", f"--filesystem={ROOT}", f"--filesystem={folder}",
                f"--filesystem={PROBE.parent}",
                f"--env=WAYLAND_DISPLAY={socket}", "--env=QT_QPA_PLATFORM=wayland", "org.kde.Sdk//6.11", "-c",
                f"exec {shlex.quote(str(PROBE))} --lookup {code}"],
                text=True, timeout=20)
            result = json.loads(output)
            assert result.get("layouts"), result
            assert result["normal"] == normal and result["shifted"] == shifted, (result, Path(folder, "weston.log").read_text())
            print(f"PASS Wayland {layout} scanCode={code}: {result}", flush=True)
    finally:
        if compositor:
            stop(compositor)
        if display:
            X11.XCloseDisplay(display)
        stop(server)


if __name__ == "__main__":
    check("us,ru", 56, "и", "b")
    check("us,ru", 56, "И", "B", shift=True)
    check("de,ru", 29, "н", "z", expected_code=16)
    check("fr,ru", 24, "й", "a", expected_code=12)
    check("us,ru", 12, "№", "#", shift=True)
    check("de,ru", 12, "№", None, shift=True)
    check("fr,ru", 12, "№", "3", shift=True, expected_code=20)
    check("ru", 56, "и", "b")
    check_wayland("us,ru", 12, "3", "#")
    check_wayland("de,ru", 29, "z", "Z")
    check_wayland("de,ru", 12, "3", "§")
    check_wayland("fr,ru", 24, "a", "A")
