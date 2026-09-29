"""Minimal Host session driver for the engine benchmark (Xvfb + observation bridge)."""
from __future__ import annotations

import json
import os
import signal
import subprocess
import time
import uuid
from pathlib import Path


class HostSession:
    """Talks to CompositorHost via COMPOSITOR_UI_E2E_DIR request/response files.

    Requires COMPOSITOR_BENCH_ALLOW_COMMANDS=1 for session `command` actions.
    """

    def __init__(self, bridge_dir: Path, binary: Path | None = None):
        self.bridge_dir = Path(bridge_dir)
        self.bridge_dir.mkdir(parents=True, exist_ok=True)
        for name in ("request.json", "response.json"):
            path = self.bridge_dir / name
            if path.exists():
                path.unlink()
        self.binary = Path(binary or os.environ.get(
            "COMPOSITOR_HOST_BINARY",
            Path(__file__).resolve().parents[2] / ".build/release/CompositorHostBootstrap",
        ))
        if not self.binary.exists():
            raise FileNotFoundError(f"CompositorHost not found: {self.binary}")
        env = os.environ.copy()
        env["COMPOSITOR_UI_E2E_DIR"] = str(self.bridge_dir)
        env["COMPOSITOR_BENCH_ALLOW_COMMANDS"] = "1"
        env.setdefault("QT_QPA_PLATFORM", "offscreen")
        # Prefer Xvfb when DISPLAY is unset.
        self._xvfb = None
        if not env.get("DISPLAY"):
            display = ":" + str(90 + (os.getpid() % 40))
            self._xvfb = subprocess.Popen(
                ["Xvfb", display, "-screen", "0", "1440x900x24", "-nolisten", "tcp"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            env["DISPLAY"] = display
            time.sleep(0.3)
        self.process = subprocess.Popen(
            [str(self.binary)],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        # Wait until inspect answers.
        deadline = time.time() + 60
        last = None
        while time.time() < deadline:
            try:
                last = self.request("inspect", timeout=5)
                if last.get("ok"):
                    break
            except Exception as exc:
                last = {"error": str(exc)}
            time.sleep(0.2)
        else:
            self.close()
            raise RuntimeError(f"Host did not become ready: {last}")

    def request(self, action: str, timeout=30, **payload):
        req_id = str(uuid.uuid4())
        body = {"id": req_id, "action": action, **payload}
        req = self.bridge_dir / "request.json"
        resp = self.bridge_dir / "response.json"
        if resp.exists():
            resp.unlink()
        req.write_text(json.dumps(body))
        deadline = time.time() + timeout
        while time.time() < deadline:
            if resp.exists():
                try:
                    data = json.loads(resp.read_text())
                except json.JSONDecodeError:
                    time.sleep(0.02)
                    continue
                if data.get("id") == req_id:
                    resp.unlink(missing_ok=True)
                    return data
            time.sleep(0.02)
            if self.process.poll() is not None:
                err = self.process.stderr.read().decode("utf-8", "replace") if self.process.stderr else ""
                raise RuntimeError(f"Host exited early: {err[-2000:]}")
        raise TimeoutError(f"no response for {action}")

    def command(self, command: dict, timeout=60):
        reply = self.request("command", timeout=timeout, command=command)
        if not reply.get("ok"):
            raise RuntimeError(f"command failed: {reply}")
        return reply

    def close(self):
        if getattr(self, "process", None) and self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait()
        if getattr(self, "_xvfb", None) and self._xvfb.poll() is None:
            self._xvfb.terminate()
            try:
                self._xvfb.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self._xvfb.kill()
