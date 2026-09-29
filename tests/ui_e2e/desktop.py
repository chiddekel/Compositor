"""Native X11 input via XTest — private Xvfb (default), nested Xephyr (`--visible`), or a host DISPLAY."""
import ctypes as C
import ctypes.util
import json
import os
import select
import subprocess
import time


def _free_display():
    for number in range(20, 80):
        if not os.path.exists(f"/tmp/.X{number}-lock"):
            return number
    raise RuntimeError("No free X display for visible e2e")


class Desktop:
    def __init__(self, artifacts, mode="xvfb", display=None):
        """mode: 'xvfb' | 'xephyr' (visible nested) | 'host' (session DISPLAY)."""
        self.log = open(artifacts / "xvfb.log", "w")
        self.events = open(artifacts / "input.jsonl", "w")
        self.server = None
        self.visible = mode != "xvfb"
        if mode == "host":
            self.display_name = display or os.environ.get("DISPLAY")
            if not self.display_name:
                raise RuntimeError("host visible mode requires DISPLAY")
            self.log.write(f"host display {self.display_name}\n")
            self.log.flush()
        else:
            read_fd, write_fd = os.pipe()
            try:
                try:
                    if mode == "xephyr":
                        xephyr = os.environ.get("COMPOSITOR_XEPHYR", "Xephyr")
                        number = _free_display()
                        # Nested server window on the user's desktop — not headless, same focus model as Xvfb.
                        self.server = subprocess.Popen(
                            [xephyr, f":{number}", "-screen", "1600x1000x24", "-ac", "-br",
                             "-title", "Compositor UI E2E", "-resizeable", "-displayfd", str(write_fd)],
                            pass_fds=(write_fd,), stdout=self.log, stderr=self.log)
                    else:
                        self.server = subprocess.Popen(
                            ["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "1600x1000x24",
                             "-nolisten", "tcp", "-ac", "-noreset"], pass_fds=(write_fd,),
                            stdout=self.log, stderr=self.log)
                finally:
                    os.close(write_fd)
                if not select.select([read_fd], [], [], 15)[0]:
                    raise RuntimeError(f"{mode} did not become ready")
                number = os.read(read_fd, 64).decode().strip()
                if not number.isdigit():
                    raise RuntimeError(f"{mode} exited before assigning a display")
            finally:
                os.close(read_fd)
            self.display_name = ":" + number
            self.log.write(f"{mode} display {self.display_name}\n")
            self.log.flush()
        self.x = C.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
        self.xt = C.CDLL(ctypes.util.find_library("Xtst") or "libXtst.so.6")
        self.x.XOpenDisplay.argtypes = [C.c_char_p]
        self.x.XOpenDisplay.restype = C.c_void_p
        self.x.XCloseDisplay.argtypes = [C.c_void_p]
        self.x.XFlush.argtypes = [C.c_void_p]
        self.x.XSync.argtypes = [C.c_void_p, C.c_int]
        self.x.XDefaultRootWindow.argtypes = [C.c_void_p]
        self.x.XDefaultRootWindow.restype = C.c_ulong
        self.x.XRaiseWindow.argtypes = [C.c_void_p, C.c_ulong]
        self.x.XMapRaised.argtypes = [C.c_void_p, C.c_ulong]
        self.x.XSetInputFocus.argtypes = [C.c_void_p, C.c_ulong, C.c_int, C.c_ulong]
        self.x.XInternAtom.argtypes = [C.c_void_p, C.c_char_p, C.c_int]
        self.x.XInternAtom.restype = C.c_ulong
        self.x.XSendEvent.argtypes = [C.c_void_p, C.c_ulong, C.c_int, C.c_long, C.c_void_p]
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
            raise RuntimeError(f"Cannot connect to {mode} display {self.display_name}")
        self.root = self.x.XDefaultRootWindow(self.display)
        self._net_active = self.x.XInternAtom(self.display, b"_NET_ACTIVE_WINDOW", False) if mode == "host" else 0
        self.host_mode = mode == "host"

    def focus(self, window):
        self.record("focus", window=window)
        self.x.XMapRaised(self.display, window)
        self.x.XRaiseWindow(self.display, window)
        if self.host_mode and self._net_active:
            class XClientMessageEvent(C.Structure):
                _fields_ = [
                    ("type", C.c_int), ("serial", C.c_ulong), ("send_event", C.c_int),
                    ("display", C.c_void_p), ("window", C.c_ulong), ("message_type", C.c_ulong),
                    ("format", C.c_int), ("data", C.c_long * 5),
                ]
            event = XClientMessageEvent()
            event.type = 33
            event.send_event = 1
            event.display = self.display
            event.window = window
            event.message_type = self._net_active
            event.format = 32
            event.data[0] = 1
            mask = (1 << 20) | (1 << 19)
            self.x.XSendEvent(self.display, self.root, False, mask, C.byref(event))
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
