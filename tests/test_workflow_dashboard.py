#!/usr/bin/env python3
"""Exercise workflow states, terminal layouts and interruption without GitHub access."""
import argparse
import curses
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("dashboard", ROOT / "scripts/watch-flatpak-build.py")
dashboard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dashboard)


def sample():
    return {"runs": [
        {"id": 22, "name": "linux swift tests", "head_branch": "GNU_Linux", "head_sha": "abcdef0123",
         "status": "in_progress", "path": ".github/workflows/linux-swift-tests.yml",
         "jobs": [{"name": "Linux contract checks", "status": "in_progress", "steps": []}]},
        {"id": 21, "name": "Flatpak alpha release", "head_branch": "linux-v1.5.4-linux-alpha.3",
         "head_sha": "abcdef0123", "status": "in_progress", "path": ".github/workflows/flatpak-release.yml",
         "jobs": [{"name": "build", "status": "in_progress", "steps": [
             {"name": "Checkout", "status": "completed", "conclusion": "success"},
             {"name": "Build signed Flatpak", "status": "in_progress"},
             {"name": "Publish release", "status": "pending"}]}]},
    ], "fetched_at": 1770000000}


class Screen:
    def __init__(self, keys=(), size=(32, 110)):
        self.keys, self.size = list(keys) + [ord("q")], size
        self.cells = {}

    def getmaxyx(self):
        return self.size

    def erase(self):
        self.cells = {}

    def timeout(self, value):
        pass

    def keypad(self, value):
        pass

    def refresh(self):
        pass

    def addstr(self, y, x, text, style):
        assert 0 <= y < self.size[0]
        for char in text:
            width = 0 if dashboard.unicodedata.combining(char) else 2 if dashboard.unicodedata.east_asian_width(char) in "WF" else 1
            assert 0 <= x < self.size[1] and x + width <= self.size[1], (x, char, self.size)
            self.cells[y, x] = (char, style)
            x += width

    def getch(self):
        key = self.keys.pop(0)
        if isinstance(key, tuple):
            self.size = key
            return curses.KEY_RESIZE
        return key

    def text(self):
        return "\n".join("".join(self.cells.get((y, x), (" ", 0))[0] for x in range(self.size[1])) for y in range(self.size[0]))


class DashboardTests(unittest.TestCase):
    def render(self, snapshot=None, keys=(), size=(32, 110), wait=False, error=None, verbose=0):
        snapshot = snapshot or sample()

        class Poller:
            def __init__(self, client, interval):
                self.events, self.wake = queue.Queue(), threading.Event()
                self.events.put(("snapshot", snapshot))
                if error:
                    self.events.put(("error", error))
                self.thread = type("Thread", (), {"start": lambda self: None})()

            def close(self):
                pass

        screen = Screen(keys, size)
        args = argparse.Namespace(ascii=False, interval=15, repo="chiddekel/Compositor", branch="GNU_Linux", wait=wait, verbose=verbose)
        with patch.object(dashboard, "Poller", Poller), patch.object(curses, "curs_set"), patch.object(curses, "has_colors", return_value=False):
            result = dashboard.dashboard(screen, args, argparse.Namespace(verbose=verbose))
        return result, screen

    def test_filter_keeps_linux_branch_and_release_tags(self):
        runs = [dict(id=1, head_branch="main", created_at="2026-10-21"),
                dict(id=2, head_branch="GNU_Linux", created_at="2026-10-22"),
                dict(id=3, head_branch="linux-v1.5.4-linux-alpha.3", created_at="2026-10-22"),
                dict(id=4, head_branch="other", created_at="2026-10-23")]
        self.assertEqual([r["id"] for r in dashboard.related_runs(runs, "GNU_Linux", 8)], [3, 2])

    def test_running_step_is_not_reported_as_finished(self):
        run = sample()["runs"][1]
        self.assertEqual(dashboard.step_counts(run["jobs"]), (1, 3))
        run["jobs"][0]["steps"][1].update(status="completed", conclusion="failure")
        run["jobs"][0]["steps"][2].update(status="completed", conclusion="skipped")
        self.assertEqual(dashboard.step_counts(run["jobs"]), (3, 3))
        self.assertEqual(dashboard.state(run["jobs"][0]["steps"][1]), "failure")

    def test_completed_duration_does_not_keep_growing(self):
        run = dict(status="completed", run_started_at="2026-10-21T10:00:00Z", updated_at="2026-10-21T10:02:30Z")
        self.assertEqual(dashboard.duration(run, datetime(2030, 1, 1, tzinfo=timezone.utc)), "02:30")

    def test_remote_text_cannot_emit_terminal_escape_sequences(self):
        text = "\x1b]52;c;clipboard\x07\x1b[31mBuild\x1b[0m\nnext\x9b"
        self.assertEqual(dashboard.clean(text), "Build next ")
        self.assertEqual(dashboard.clipped("A界B", 3), "A界")

    def test_selecting_workflow_updates_details(self):
        _, initial = self.render()
        self.assertIn("Build signed Flatpak", initial.text())
        _, switched = self.render(keys=[ord("j")])
        self.assertIn("LINUX CONTRACT CHECKS", switched.text())
        self.assertNotIn("Build signed Flatpak", switched.text())

    def test_resize_and_small_terminal_do_not_overflow(self):
        for size in [(20, 76), (24, 80), (40, 160)]:
            self.render(size=size, keys=[curses.KEY_NPAGE, curses.KEY_PPAGE])
        _, small = self.render(keys=[(24, 80), (18, 64)])
        self.assertIn("Make the terminal", small.text())

    def test_wait_reports_failed_workflow(self):
        snapshot = sample()
        snapshot["runs"] = [snapshot["runs"][1]]
        snapshot["runs"][0].update(status="completed", conclusion="failure")
        result, _ = self.render(snapshot=snapshot, wait=True)
        self.assertEqual(result, 1)

    def test_partial_api_failure_remains_visible(self):
        snapshot = sample()
        snapshot["runs"][1].update(load_error="GitHub rate limit exceeded", jobs=[])
        _, screen = self.render(snapshot)
        self.assertIn("API: GitHub rate limit", screen.text())
        self.assertIn("rate limit", dashboard.plain(snapshot))

    def test_active_step_is_visible_on_a_short_screen(self):
        snapshot = sample()
        steps = snapshot["runs"][1]["jobs"][0]["steps"]
        steps[:0] = [dict(name=f"Setup {i}", status="completed", conclusion="success") for i in range(20)]
        _, screen = self.render(snapshot, size=(24, 80))
        self.assertIn("Build signed Flatpak", screen.text())
        self.assertIn("FOLLOW", screen.text())

    def test_failure_takes_priority_over_another_running_job(self):
        rows = [("job", "in_progress"), ("  > Build", "in_progress")]
        rows += [("  + Done", "success")] * 12 + [("  x Failed smoke check", "failure")]
        offset = dashboard.focus_offset(rows, 5)
        self.assertTrue(any("Failed smoke" in label for label, _ in rows[offset:offset + 5]))

    def test_failed_refresh_marks_retained_data_as_stale(self):
        _, screen = self.render(error="GitHub request timed out")
        self.assertIn("STALE", screen.text())
        self.assertIn("API ERROR", screen.text())
        self.assertIn("Build signed Flatpak", screen.text())

    def test_verbosity_levels_add_details_without_changing_default(self):
        snapshot = sample()
        run = snapshot['runs'][1]
        run.update(run_attempt=2, event="push", created_at="2026-10-21T10:00:00Z")
        job = run['jobs'][0]
        job.update(id=99, runner_name="build-worker", labels=["ubuntu-24.04"])
        snapshot.update(requests=3, poll_seconds=0.5, diagnostics=[dict(time=1770000000, message="OK actions/runs/21 (0.12s)")])
        compact = dashboard.plain(snapshot)
        verbose = dashboard.plain(snapshot, 1)
        very_verbose = dashboard.plain(snapshot, 2)
        debug = dashboard.plain(snapshot, 3)
        self.assertNotIn("Run ID", compact)
        self.assertIn("Run ID 21 / attempt 2", verbose)
        self.assertIn("Job ID 99", verbose)
        self.assertNotIn("build-worker", verbose)
        self.assertIn("Runner: build-worker / ubuntu-24.04", very_verbose)
        self.assertIn("started=", very_verbose)
        self.assertIn("REQUEST TRACE / 3 requests", debug)
        self.assertIn("OK actions/runs/21", debug)

    def test_trace_is_bounded_and_disabled_by_default(self):
        client = dashboard.GitHub("example/repo", "GNU_Linux", 8)
        client.trace("ignored")
        self.assertEqual(list(client.diagnostics), [])
        client.verbose = 3
        for i in range(150):
            client.trace(f"GET actions/runs/{i}")
        self.assertEqual(len(client.diagnostics), 100)
        self.assertEqual(client.diagnostics[-1]["message"], "GET actions/runs/149")

    def test_verbose_ui_and_trace_fit_small_terminal(self):
        self.render(verbose=3, size=(24, 80))
        _, screen = self.render(keys=[ord("d")], size=(24, 80))
        self.assertIn("REQUEST TRACE", screen.text())
        _, screen = self.render(keys=[ord("v")], size=(24, 80))
        self.assertIn("v / updated", screen.text())

    def test_only_completed_jobs_are_cached(self):
        client = dashboard.GitHub("example/repo", "GNU_Linux", 8)
        run = dict(id=12, status="in_progress", updated_at="now", run_attempt=1)
        with patch.object(client, "api", return_value={"jobs": []}) as api:
            client.jobs(run)
            client.jobs(run)
            self.assertEqual(api.call_count, 2)
            run["status"] = "completed"
            client.jobs(run)
            client.jobs(run)
            self.assertEqual(api.call_count, 3)
            run["run_attempt"] = 2
            client.jobs(run)
            self.assertEqual(api.call_count, 4)

    def test_quit_cancels_an_inflight_request(self):
        client = dashboard.GitHub("example/repo", "GNU_Linux", 8)
        real_popen = subprocess.Popen
        children = []

        def slow_request(args, **kwargs):
            process = real_popen([sys.executable, "-c", "import time; time.sleep(30)"], **kwargs)
            children.append(process)
            return process

        timer = threading.Timer(0.05, client.cancel.set)
        started = time.monotonic()
        timer.start()
        try:
            with patch.object(dashboard.subprocess, "Popen", side_effect=slow_request):
                with self.assertRaisesRegex(RuntimeError, "cancelled"):
                    client.api("actions/runs")
        finally:
            timer.join()
        self.assertLess(time.monotonic() - started, 2)
        self.assertTrue(all(process.poll() is not None for process in children))


if __name__ == "__main__":
    unittest.main()
