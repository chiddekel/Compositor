"""Native X11 input on a private Xvfb display; no Qt event or editor-command injection."""
import ctypes as C
import ctypes.util
import json
import os
import select
import subprocess
import time


class Desktop:
    def __init__(self, artifacts):
        read_fd, write_fd = os.pipe()
        self.log = open(artifacts / "xvfb.log", "w")
        self.events = open(artifacts / "input.jsonl", "w")
        try:
            try:
                self.server = subprocess.Popen(
                    ["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "1600x1000x24",
                     "-nolisten", "tcp", "-ac", "-noreset"], pass_fds=(write_fd,),
                    stdout=self.log, stderr=self.log)
            finally:
                os.close(write_fd)
            if not select.select([read_fd], [], [], 10)[0]:
                raise RuntimeError("Xvfb did not become ready")
            number = os.read(read_fd, 64).decode().strip()
            if not number.isdigit():
                raise RuntimeError("Xvfb exited before assigning a display")
        finally:
            os.close(read_fd)
        self.display_name = ":" + number
        self.x = C.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
        self.xt = C.CDLL(ctypes.util.find_library("Xtst") or "libXtst.so.6")
        self.x.XOpenDisplay.argtypes = [C.c_char_p]
        self.x.XOpenDisplay.restype = C.c_void_p
        self.x.XCloseDisplay.argtypes = [C.c_void_p]
        self.x.XFlush.argtypes = [C.c_void_p]
        self.x.XSync.argtypes = [C.c_void_p, C.c_int]
        self.x.XSetInputFocus.argtypes = [C.c_void_p, C.c_ulong, C.c_int, C.c_ulong]
        self.x.XStringToKeysym.argtypes = [C.c_char_p]
        self.x.XStringToKeysym.restype = C.c_ulong
        self.x.XKeysymToKeycode.argtypes = [C.c_void_p, C.c_ulong]
        self.x.XKeysymToKeycode.restype = C.c_uint
        self.x.XkbKeycodeToKeysym.argtypes = [C.c_void_p, C.c_uint, C.c_int, C.c_int]
        self.x.XkbKeycodeToKeysym.restype = C.c_ulong
        self.xt.XTestFakeMotionEvent.argtypes = [C.c_void_p, C.c_int, C.c_int, C.c_int, C.c_ulong]
        self.xt.XTestFakeButtonEvent.argtypes = [C.c_void_p, C.c_uint, C.c_int, C.c_ulong]
        self.xt.XTestFakeKeyEvent.argtypes = [C.c_void_p, C.c_uint, C.c_int, C.c_ulong]
        self.display = self.x.XOpenDisplay(self.display_name.encode())
        if not self.display:
            raise RuntimeError("Cannot connect to private Xvfb display")

    def focus(self, window):
        # Xvfb has no window manager to assign keyboard focus when a window is clicked.
        self.record("focus", window=window)
        self.x.XSetInputFocus(self.display, window, 2, 0)
        self.x.XSync(self.display, False)

    def move(self, x, y, flush=True):
        self.record("move", x=round(x), y=round(y))
        self.xt.XTestFakeMotionEvent(self.display, -1, round(x), round(y), 0)
        if flush:
            self.x.XFlush(self.display)

    def button(self, down, number=1):
        self.record("button", down=down, number=number)
        self.xt.XTestFakeButtonEvent(self.display, number, int(down), 0)
        self.x.XFlush(self.display)

    def click(self, x, y, double=False):
        self.move(x, y)
        for _ in range(2 if double else 1):
            self.button(True)
            time.sleep(0.025)
            self.button(False)
            time.sleep(0.04)

    def keycode(self, name):
        symbol = self.x.XStringToKeysym(name.encode())
        code = self.x.XKeysymToKeycode(self.display, symbol)
        if not code:
            raise RuntimeError("No desktop keycode for " + name)
        return code

    def key(self, *names):
        self.record("key", keys=names)
        codes = [self.keycode(name) for name in names]
        for code in codes:
            self.xt.XTestFakeKeyEvent(self.display, code, 1, 8)
        for code in reversed(codes):
            self.xt.XTestFakeKeyEvent(self.display, code, 0, 8)
        self.x.XFlush(self.display)

    def hold(self, name, down):
        self.record("modifier", key=name, down=down)
        self.xt.XTestFakeKeyEvent(self.display, self.keycode(name), int(down), 8)
        self.x.XSync(self.display, False)

    def text(self, text):
        self.record("text", text=text)
        shift = self.keycode("Shift_L")
        for character in text:
            symbol = ord(character)
            code = self.x.XKeysymToKeycode(self.display, symbol)
            if not code:
                raise RuntimeError("No desktop keycode for " + repr(character))
            shifted = self.x.XkbKeycodeToKeysym(self.display, code, 0, 0) != symbol
            if shifted:
                self.xt.XTestFakeKeyEvent(self.display, shift, 1, 8)
            self.xt.XTestFakeKeyEvent(self.display, code, 1, 8)
            self.xt.XTestFakeKeyEvent(self.display, code, 0, 8)
            if shifted:
                self.xt.XTestFakeKeyEvent(self.display, shift, 0, 8)
        self.x.XFlush(self.display)

    def record(self, event, **data):
        self.events.write(json.dumps(dict(event=event, time=time.monotonic(), **data)) + "\n")
        self.events.flush()

    def close(self):
        if getattr(self, "display", None):
            self.x.XCloseDisplay(self.display)
            self.display = None
        if getattr(self, "server", None):
            self.server.terminate()
            try:
                self.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.server.kill()
                self.server.wait()
        for name in ("log", "events"):
            if getattr(self, name, None):
                getattr(self, name).close()
