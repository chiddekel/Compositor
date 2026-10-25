#!/usr/bin/env python3
"""Exercise the local monitor, real check lifecycles and terminal bounds offline."""
import argparse
import curses
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("compat_monitor", ROOT / "scripts/watch-compat.py")
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class Screen:
    def __init__(self, size):
        self.size, self.cells = size, {}

    def getmaxyx(self):
        return self.size

    def erase(self):
        self.cells.clear()

    def addstr(self, y, x, text, style):
        assert 0 <= y < self.size[0]
        assert x + len(text) < self.size[1]
        self.cells[y] = text

    def refresh(self):
        pass


class MonitorTests(unittest.TestCase):
    def wait(self, runner):
        deadline = time.monotonic() + 5
        while runner.state()["status"] == "running" and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertNotEqual(runner.state()["status"], "running")

    def test_status_preserves_spaces_newlines_and_rename_paths(self):
        rows = monitor.changed_files(" M source with spaces.swift\0R  new name.swift\0old name.swift\0?? line\nname.py\0")
        self.assertEqual(rows[0]["path"], "source with spaces.swift")
        self.assertEqual(rows[1]["old_path"], "old name.swift")
        self.assertEqual(rows[2]["path"], "line\nname.py")

    def test_text_strips_terminal_controls_and_redacts_common_credentials(self):
        token = "ghp_" + "x" * 36
        value = monitor.safe("\x1b]52;c;clipboard\x07\x1b[31mFAIL\x1b[0m password=hunter2 " + token)
        self.assertEqual(value, "FAIL password=[redacted] [redacted]")

    def test_missing_and_partial_evidence_are_not_reported_as_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertIn("No readable", monitor.evidence(root)["rows"][0])
            folder = root / ".build/evidence"
            folder.mkdir(parents=True)
            (folder / "dither-sampling-verification-summary.json").write_text('{"application":')
            self.assertIn("No readable", monitor.evidence(root)["rows"][0])

    def test_stable_verification_checkpoint_takes_priority_over_old_experiment(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / ".build/evidence"
            folder.mkdir(parents=True)
            (folder / "dither-sampling-verification-summary.json").write_text(json.dumps({
                "nativeSampling": {"withinOne": 172, "cases": 172}}))
            (folder / "compatibility-verification-summary.json").write_text(json.dumps({
                "nativeSampling": {"withinOne": 204, "cases": 204}}))
            result = monitor.evidence(root)
            self.assertEqual(result["rows"], ["Sampling: 204/204"])
            self.assertIn("compatibility-verification-summary.json", result["path"])
            (folder / "compatibility-verification-summary.json").write_text('{"application":')
            self.assertIn("No readable", monitor.evidence(root)["rows"][0])

    def test_check_failure_stops_remaining_steps_and_sanitizes_saved_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = monitor.CheckRunner(root)
            try:
                runner.start("probe", [[sys.executable, "-c", "print('password=hidden'); raise SystemExit(7)"],
                                       [sys.executable, "-c", "open('should-not-exist', 'w').close()"]])
                self.wait(runner)
                state = runner.state()
                self.assertEqual((state["status"], state["returncode"]), ("failure", 7))
                self.assertFalse((root / "should-not-exist").exists())
                log = Path(state["log"]).read_text()
                self.assertNotIn("password=hidden", log)
                self.assertIn("password=[redacted]", log)
            finally:
                runner.close()

    def test_all_steps_must_finish_before_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner = monitor.CheckRunner(Path(temporary))
            try:
                runner.start("two steps", [[sys.executable, "-c", "print('first')"],
                                           [sys.executable, "-c", "print('second')"]])
                self.wait(runner)
                self.assertEqual(runner.state()["status"], "success")
                self.assertIn("second", Path(runner.state()["log"]).read_text())
            finally:
                runner.close()

    def test_cancellation_stops_the_owned_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner = monitor.CheckRunner(Path(temporary))
            runner.start("sleep", [[sys.executable, "-c", "import time; time.sleep(30)"]])
            deadline = time.monotonic() + 2
            while runner.process is None and time.monotonic() < deadline:
                time.sleep(0.01)
            process = runner.process
            self.assertIsNotNone(process)
            runner.close()
            self.assertEqual(runner.state()["status"], "cancelled")
            self.assertIsNotNone(process.poll())

    def test_snapshot_reads_a_real_repository_with_an_unborn_branch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "new file.py").write_text("print('hello')\n")
            value = monitor.snapshot(root)
            self.assertEqual(value["errors"], [])
            self.assertEqual(value["head"], "no commits")
            self.assertEqual(value["files"][0]["path"], "new file.py")

    def test_quit_stops_a_descendant_that_ignores_termination_and_closes_output(self):
        self.check_descendant_cleanup(cancel=True)

    def test_completed_check_stops_descendants_that_close_output(self):
        self.check_descendant_cleanup(cancel=False)

    def check_descendant_cleanup(self, cancel):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = monitor.CheckRunner(root)
            child = "import os,signal,time; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); Path('child.pid').write_text(str(os.getpid())); time.sleep(30)"
            parent = f"import subprocess,sys,time; from pathlib import Path; subprocess.Popen([sys.executable, '-c', {child!r}], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\nwhile not Path('child.pid').exists(): time.sleep(0.01)\n"
            if cancel:
                parent += "time.sleep(30)"
            pid = None

            def running():
                try:
                    os.kill(pid, 0)
                    stat = Path(f"/proc/{pid}/stat")
                    return not stat.exists() or stat.read_text().rsplit(") ", 1)[1][0] != "Z"
                except ProcessLookupError:
                    return False
                except FileNotFoundError:
                    return False

            try:
                runner.start("descendant", [[sys.executable, "-c", parent]])
                deadline = time.monotonic() + 3
                while not (root / "child.pid").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((root / "child.pid").exists())
                pid = int((root / "child.pid").read_text())
                if cancel:
                    runner.close()
                else:
                    self.wait(runner)
                deadline = time.monotonic() + 2
                while running() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertFalse(running(), "The process group must stop after its leader exits")
                self.assertEqual(runner.state()["status"], "cancelled" if cancel else "success")
            finally:
                runner.close()
                if pid is not None and running():
                    os.kill(pid, signal.SIGKILL)

    def test_sensitive_untracked_file_is_not_previewed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".env").write_text("private-data")
            self.assertIn("hidden", monitor.patch_rows(root, {"status": "??", "path": ".env"})[0])

    def test_patch_preview_updates_after_a_file_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "probe.py"
            source.write_text("first version\n")
            value = {"root": str(root), "branch": "main", "head": "1234567", "errors": [],
                     "files": [{"status": "??", "path": "probe.py"}], "logs": [], "evidence": {"rows": []}}
            with patch.object(curses, "has_colors", return_value=False):
                screen = Screen((24, 80))
                monitor.draw(screen, value, {"status": "idle"}, 1, 0, 0, "", {"check": []})
                self.assertIn("first version", "\n".join(screen.cells.values()))
                source.write_text("updated second version\n")
                monitor.draw(screen, value, {"status": "idle"}, 1, 0, 0, "", {"check": []})
                self.assertIn("updated second version", "\n".join(screen.cells.values()))
                self.assertNotIn("first version", "\n".join(screen.cells.values()))

    def test_symlink_contents_are_not_previewed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "link.py").symlink_to("/etc/passwd")
            self.assertIn("Symbolic link", monitor.patch_rows(root, {"status": "??", "path": "link.py"})[0])

    def test_every_tab_fits_small_and_wide_terminals(self):
        value = {"root": str(ROOT), "branch": "GNU_Linux", "head": "1234567", "errors": [],
                 "files": [{"status": "??", "path": "scripts/watch-compat.py"}], "logs": [],
                 "evidence": {"rows": ["Application CPU: 146/173"], "updated": None}}
        available = {"hygiene": [["git", "diff", "--check"]]}
        with patch.object(curses, "has_colors", return_value=False):
            for size in [(14, 50), (16, 64), (24, 80), (40, 160)]:
                for tab in range(5):
                    screen = Screen(size)
                    monitor.draw(screen, value, {"status": "idle"}, tab, 0, 0, "ready", available)
                    self.assertIn("COMPAT MONITOR", screen.cells[0])
                    if size[0] >= 16 and size[1] >= 64:
                        self.assertIn("q quit", screen.cells[size[0] - 2])

    def test_custom_check_is_argv_and_not_a_shell_program(self):
        args = argparse.Namespace(library=None, check=['probe=python3 -c "print(1)"'])
        self.assertEqual(monitor.checks(args)["probe"], [["python3", "-c", "print(1)"]])

    def test_cli_returns_failure_for_a_failed_check(self):
        result = subprocess.run([sys.executable, str(ROOT / "scripts/watch-compat.py"), "--json",
                                 "--check", f"probe={sys.executable} -c 'raise SystemExit(4)'", "--run-check", "probe"],
                                cwd=ROOT, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["check"]["returncode"], 4)

    def test_plain_local_refresh_does_not_overpoll_github(self):
        value = {"branch": "GNU_Linux", "head": "1234567", "files": [], "logs": [],
                 "errors": [], "evidence": {"rows": []}}
        with patch.object(sys, "argv", ["watch-compat.py", "--plain", "--ci"]), \
             patch.object(sys, "stdout", io.StringIO()), \
             patch.object(monitor, "snapshot", return_value=value), \
             patch.object(monitor.workflow, "GitHub") as client, \
             patch.object(monitor.time, "monotonic", return_value=100), \
             patch.object(monitor.time, "sleep", side_effect=[None, KeyboardInterrupt]):
            client.return_value.snapshot.return_value = {"runs": []}
            self.assertEqual(monitor.main(), 130)
            self.assertEqual(client.return_value.snapshot.call_count, 1)


if __name__ == "__main__":
    unittest.main()
