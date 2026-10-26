#!/usr/bin/env python3
"""Watch local patches, verification evidence and logs; run checks from a terminal."""
import argparse
import curses
from functools import lru_cache
import importlib.util
import json
import locale
import os
from pathlib import Path
import queue
import re
import shlex
import signal
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("workflow_dashboard", ROOT / "scripts/watch-flatpak-build.py")
workflow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workflow)
TABS = ("Overview", "Patches", "Logs", "Checks", "CI")
SECRET = re.compile(r"(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|Bearer\s+\S+)", re.I)
ASSIGNMENT = re.compile(r"((?:password|passwd|api_key|access_token|secret)(?:\s*[=:]\s*|\s+))\S+", re.I)


def safe(value):
    return ASSIGNMENT.sub(r"\1[redacted]", SECRET.sub("[redacted]", workflow.clean(value)))


def command(root, argv, timeout=5):
    result = subprocess.run(argv, cwd=root, capture_output=True, text=True, errors="replace", timeout=timeout,
                            env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", GH_PROMPT_DISABLED="1"))
    if result.returncode:
        raise RuntimeError(safe(result.stderr.strip() or f"{argv[0]} exited {result.returncode}"))
    return result.stdout


def changed_files(raw):
    parts, result, index = raw.split("\0"), [], 0
    while index < len(parts):
        entry = parts[index]
        index += 1
        if not entry:
            continue
        item = {"status": entry[:2], "path": entry[3:]}
        if "R" in item["status"] or "C" in item["status"]:
            item["old_path"] = parts[index]
            index += 1
        result.append(item)
    return result


def tail(path, lines=300):
    try:
        with path.open("rb") as stream:
            size = stream.seek(0, os.SEEK_END)
            stream.seek(max(0, size - 65536))
            data = stream.read(65536).decode("utf-8", errors="replace")
        return [safe(line) for line in data.splitlines()[-lines:]]
    except OSError as error:
        return [safe(error)]


def evidence(root):
    path = root / ".build/evidence/compatibility-verification-summary.json"
    if not path.exists():
        path = path.with_name("dither-sampling-verification-summary.json")
    try:
        data = json.loads(path.read_text())
        rows = []
        for name, item in data.get("application", {}).items():
            rows.append(f"Application {name}: {item.get('passed', '?')}/{item.get('total', '?')}")
        for key, label, passed, total in [("nativeSampling", "Sampling", "withinOne", "cases"),
                                           ("nativeMotion", "Motion blur", "withinOne", "cases"),
                                           ("curve", "Curve coverage", "withinOne", "total")]:
            item = data.get(key, {})
            if item:
                rows.append(f"{label}: {item.get(passed, '?')}/{item.get(total, '?')}")
        swift = data.get("fullSwift", {})
        if swift:
            rows.append(f"Swift: {swift.get('tests', '?')} tests; {swift.get('goldenIssues', '?')} golden differences")
            other = swift.get('nonGoldenFailures', swift.get('nonGoldenIssues', '?'))
            rows.append(f"Swift other failures: {other}")
        return {"rows": rows, "path": str(path.relative_to(root)), "updated": path.stat().st_mtime}
    except (OSError, ValueError, TypeError, AttributeError) as error:
        return {"rows": ["No readable verification summary yet: " + safe(error)], "updated": None}


def snapshot(root, explicit_logs=()):
    result = {"updated": time.time(), "files": [], "logs": [], "errors": [], "evidence": evidence(root)}
    try:
        result["files"] = changed_files(command(root, ["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"]))
        result["branch"] = command(root, ["git", "branch", "--show-current"]).strip() or "detached"
        try:
            result["head"] = command(root, ["git", "rev-parse", "--short", "HEAD"]).strip()
        except RuntimeError:
            result["head"] = "no commits"
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        result["errors"].append(safe(error))
    paths = set(explicit_logs)
    for directory in [root / ".build/evidence", root / ".build/compat-monitor"]:
        paths.update(directory.glob("*.log"))
    for path in paths:
        try:
            stat = path.stat()
            if path.is_file():
                result["logs"].append({"path": str(path), "updated": stat.st_mtime, "bytes": stat.st_size})
        except OSError:
            continue
    result["logs"].sort(key=lambda item: item["updated"], reverse=True)
    result["logs"] = result["logs"][:40]
    return result


class LocalPoller:
    def __init__(self, root, logs, interval):
        self.root, self.logs, self.interval = root, logs, interval
        self.events = queue.Queue(maxsize=1)
        self.stop, self.wake = threading.Event(), threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        while not self.stop.is_set():
            value = snapshot(self.root, self.logs)
            try:
                self.events.get_nowait()
            except queue.Empty:
                pass
            self.events.put(value)
            self.wake.wait(self.interval)
            self.wake.clear()

    def close(self):
        self.stop.set()
        self.wake.set()
        self.thread.join(timeout=1)


class CheckRunner:
    def __init__(self, root):
        self.root, self.lock = root, threading.Lock()
        self.process, self.thread = None, None
        self.cancelled = threading.Event()
        self.value = {"status": "idle"}

    def state(self):
        with self.lock:
            return dict(self.value)

    def start(self, name, steps):
        if self.thread and self.thread.is_alive():
            return False
        folder = self.root / ".build/compat-monitor"
        folder.mkdir(parents=True, exist_ok=True)
        log = folder / f"check-{time.time_ns()}.log"
        log.touch()
        self.cancelled.clear()
        with self.lock:
            self.value = {"name": safe(name), "status": "running", "started": time.time(), "log": str(log)}
        self.thread = threading.Thread(target=self.run, args=(steps, log), daemon=True)
        self.thread.start()
        return True

    def run(self, steps, log):
        code = 0
        try:
            with log.open("w") as output:
                for argv in steps:
                    with self.lock:
                        if self.cancelled.is_set():
                            break
                        output.write("$ " + safe(shlex.join(argv)) + "\n")
                        output.flush()
                        self.process = subprocess.Popen(argv, cwd=self.root, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, errors="replace", start_new_session=True,
                            env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", GH_PROMPT_DISABLED="1", NO_COLOR="1"))
                        process = self.process
                    try:
                        with process.stdout:
                            for line in iter(lambda: process.stdout.readline(16384), ""):
                                output.write(safe(line.rstrip("\r\n")) + "\n")
                                output.flush()
                        code = process.wait()
                    finally:
                        self.finish_process_group(process)
                        with self.lock:
                            self.process = None
                    if code:
                        break
        except OSError as error:
            code = 127
            with log.open("a") as output:
                output.write(safe(error) + "\n")
        finally:
            with self.lock:
                self.process = None
                self.value.update(status="cancelled" if self.cancelled.is_set() else "failure" if code else "success",
                                  returncode=code, finished=time.time())

    @staticmethod
    def finish_process_group(process):
        # A leader can exit while descendants ignore TERM and close their output.
        # Keep ownership until the entire check group has been stopped.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        else:
            deadline = time.monotonic() + 0.25
            while time.monotonic() < deadline:
                try:
                    os.killpg(process.pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.01)
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait()

    def cancel(self, force=False):
        with self.lock:
            self.cancelled.set()
            if self.process:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL if force else signal.SIGTERM)
                except ProcessLookupError:
                    pass

    def close(self):
        if self.thread and self.thread.is_alive():
            self.cancel()
            self.thread.join(timeout=2)
            if self.thread.is_alive():
                self.cancel(force=True)
                self.thread.join(timeout=1)


def checks(args):
    result = {"hygiene": [["git", "diff", "--check"], ["git", "diff", "--cached", "--check"]],
              "dashboard": [[sys.executable, "tests/test_compat_monitor.py"]],
              "upstream": [["git", "ls-remote", "upstream", "refs/heads/main"]]}
    if args.library:
        result["sampling"] = [[sys.executable, "tests/test_image_sampling.py", str(args.library)]]
    for item in args.check:
        name, separator, value = item.partition("=")
        argv = shlex.split(value)
        if not separator or not name.strip() or not argv:
            raise ValueError("--check requires NAME=COMMAND, for example 'unit=python3 tests/test_workflow_dashboard.py'")
        result[name.strip()] = [argv]
    return result


def patch_rows(root, item):
    if not item:
        return ["No file selected."]
    path = root / item["path"]
    if path.is_symlink():
        return ["Symbolic link; content preview omitted."]
    if any(word in path.name.lower() for word in [".env", "credential", "secret", "id_rsa", "token"]):
        return ["Preview hidden for a potentially sensitive file."]
    try:
        if item["status"] == "??":
            with path.open("rb") as stream:
                raw = stream.read(131072)
            if b"\0" in raw:
                return ["Binary file; preview omitted."]
            text = raw.decode("utf-8", errors="replace")
        else:
            text = command(root, ["git", "--no-pager", "diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", item["path"]])
        return [safe(line) for line in text.splitlines()[:1200]] or ["No text diff available."]
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        return [safe(error)]


@lru_cache(maxsize=16)
def cached_patch(root, path, status, head, modified, size):
    return patch_rows(Path(root), {"path": path, "status": status})


def plain(value, task):
    lines = [f"COMPOSITOR / COMPAT MONITOR   {value.get('branch', '?')}  {value.get('head', '?')}",
             f"{len(value['files'])} changed files | check: {task.get('name', '--')} [{task['status']}]",
             "RECORDED EVIDENCE (not a fresh test run)"]
    lines.extend(value["evidence"]["rows"])
    lines.extend(["", "CHANGES"] + [safe(f"{item['status']} {item['path']}") for item in value["files"]])
    lines.extend(["", "RECENT LOGS"] + [safe(item["path"]) for item in value["logs"][:5]])
    lines.extend("ERROR: " + safe(error) for error in value["errors"])
    if task.get("log"):
        lines.extend(["", "CHECK OUTPUT"] + tail(Path(task["log"]), 12))
    if value.get("ci"):
        lines += ["", "GITHUB ACTIONS"] + workflow.plain(value["ci"]).splitlines()
    return "\n".join(safe(line) for line in lines)


def draw(screen, value, task, tab, selection, offset, message, available, ci=None):
    height, width = screen.getmaxyx()
    screen.erase()

    def put(y, x, text, style=0):
        if 0 <= y < height and x < width - 1:
            try:
                screen.addstr(y, x, workflow.clipped(safe(text), width - x - 1), style)
            except curses.error:
                pass

    def color(number):
        return curses.color_pair(number) if curses.has_colors() and "NO_COLOR" not in os.environ else 0

    put(0, 1, f"COMPOSITOR  /  COMPAT MONITOR    {value.get('branch', '?')}  {value.get('head', '?')}", curses.A_BOLD | color(3))
    if width < 64 or height < 16:
        put(2, 1, "Make the terminal at least 64 columns x 16 rows.  q: quit")
        screen.refresh()
        return
    put(2, 1, "   ".join(f"[{i + 1} {name}]" if i == tab else f" {i + 1} {name} " for i, name in enumerate(TABS)), curses.A_BOLD)
    put(4, 1, f"{len(value['files'])} changed files   CHECK {task.get('name', '--')}: {task['status'].upper()}   LIVE")
    put(5, 1, "─" * (width - 3), curses.A_DIM)
    rows = []
    if tab == 0:
        rows = [("RECORDED VERIFICATION / historical until checks are rerun", curses.A_BOLD)]
        rows += [(line, 0) for line in value["evidence"]["rows"]]
        updated = value["evidence"].get("updated")
        if updated:
            rows.append(("Evidence modified: " + time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(updated)), curses.A_DIM))
        rows += [("", 0), ("LIVE WORKTREE / open Patches for a diff", curses.A_BOLD)]
        rows += [(f"{item['status']}  {item['path']}", 0) for item in value["files"]]
    elif tab == 1:
        files = value["files"]
        if files:
            item = files[selection % len(files)]
            try:
                stat = (Path(value["root"]) / item["path"]).lstat()
                modified, size = stat.st_mtime_ns, stat.st_size
            except OSError:
                modified = size = None
            rows = [(f"FILE {selection % len(files) + 1}/{len(files)}  {item['status']}  {item['path']}", curses.A_BOLD)]
            rows += [(line, color(1) if line.startswith("+") else color(2) if line.startswith("-") else 0)
                     for line in cached_patch(value["root"], item["path"], item["status"], value.get("head"), modified, size)]
        else:
            rows = [("Worktree is clean.", 0)]
    elif tab == 2:
        logs = value["logs"]
        path = logs[selection % len(logs)]["path"] if logs else task.get("log")
        if path:
            content = tail(Path(path))
            visible = max(1, height - 10)
            end = max(0, len(content) - offset)
            rows = [("FOLLOW LOG  " + path, curses.A_BOLD)] + [(line, 0) for line in content[max(0, end - visible):end]]
        else:
            rows = [("Waiting for a build/test log. Use --log PATH to follow another file.", 0)]
    elif tab == 3:
        rows = [("ENTER runs the selected check / x cancels only the check started here", curses.A_BOLD)]
        selected = selection % len(available)
        for i, (name, steps) in enumerate(available.items()):
            if not max(0, selected - 2) <= i < max(5, selected + 3):
                continue
            rows.append((("> " if i == selection % len(available) else "  ") + name, curses.A_BOLD if i == selection % len(available) else 0))
            if i == selected:
                rows += [("    " + shlex.join(argv), curses.A_DIM) for argv in steps]
        if task.get("log"):
            rows += [("", 0), ("LATEST CHECK OUTPUT", curses.A_BOLD)] + [(line, 0) for line in tail(Path(task["log"]), 6)]
    else:
        rows = [("GitHub polling is opt-in: press c to connect or start with --ci.", 0)] if not ci else [
            (line, 0) for line in workflow.plain(ci).splitlines()]
        if ci and ci.get("stale_error"):
            rows[:0] = [("STALE CI DATA / " + ci["stale_error"], color(2) | curses.A_BOLD)]
    if tab not in [2, 3]:
        rows = rows[offset:]
    for y, (line, style) in enumerate(rows[:height - 9], 6):
        put(y, 1, line, style)
    notice = " | ".join(value["errors"]) or message
    put(height - 4, 1, "─" * (width - 3), curses.A_DIM)
    put(height - 3, 1, notice, color(2) if value["errors"] else curses.A_DIM)
    footer = "1-5 view  j/k select  Enter run  r refresh  x stop  q quit"
    put(height - 2, 1, footer, curses.A_BOLD)
    screen.refresh()


def dashboard(screen, args, available):
    try:
        curses.curs_set(0)
    except curses.error:
        pass
    if curses.has_colors() and "NO_COLOR" not in os.environ:
        curses.start_color()
        try:
            curses.use_default_colors()
            curses.init_pair(1, curses.COLOR_GREEN, -1)
            curses.init_pair(2, curses.COLOR_RED, -1)
            curses.init_pair(3, curses.COLOR_CYAN, -1)
        except curses.error:
            pass
    screen.keypad(True)
    screen.timeout(100)
    poller = LocalPoller(args.root, args.log, args.interval)
    runner = CheckRunner(args.root)
    poller.thread.start()
    value = {"root": str(args.root), "files": [], "logs": [], "errors": [], "evidence": {"rows": ["Loading..."]}}
    tab = selection = offset = 0
    message = "Local monitoring / no commits, patches or pushes are performed by this dashboard."
    client = ci_poller = ci = None

    def connect():
        nonlocal client, ci_poller, message
        if ci_poller:
            return
        client = workflow.GitHub(args.repo, args.branch or value.get("branch", "GNU_Linux"), 4)
        ci_poller = workflow.Poller(client, args.ci_interval)
        ci_poller.thread.start()
        message = "Connecting to GitHub..."

    try:
        if args.ci:
            connect()
        while True:
            try:
                value = poller.events.get_nowait()
                value["root"] = str(args.root)
            except queue.Empty:
                pass
            if ci_poller:
                while True:
                    try:
                        kind, payload = ci_poller.events.get_nowait()
                        if kind == "snapshot":
                            ci = payload
                        elif kind == "error":
                            ci = dict(ci or {"runs": []}, stale_error=safe(payload))
                            message = "GitHub: " + safe(payload) + " (retaining last snapshot)"
                    except queue.Empty:
                        break
            draw(screen, value, runner.state(), tab, selection, offset, message, available, ci)
            key = screen.getch()
            if key in [ord("q"), 27]:
                break
            if ord("1") <= key <= ord("5"):
                tab, selection, offset = key - ord("1"), 0, 0
            elif key == 9:
                tab, selection, offset = (tab + 1) % len(TABS), 0, 0
            elif key in [ord("j"), curses.KEY_DOWN]:
                selection += 1
                offset = 0
            elif key in [ord("k"), curses.KEY_UP]:
                selection = max(0, selection - 1)
                offset = 0
            elif key == curses.KEY_PPAGE:
                offset = offset + 8 if tab == 2 else max(0, offset - 8)
            elif key == curses.KEY_NPAGE:
                offset = max(0, offset - 8) if tab == 2 else offset + 8
            elif key == ord("f"):
                offset = 0
            elif key == ord("r"):
                poller.wake.set()
                if ci_poller:
                    ci_poller.wake.set()
            elif key == ord("c"):
                connect()
                tab, offset = 4, 0
            elif key == ord("x"):
                if runner.state()["status"] == "running":
                    runner.cancel(force=runner.cancelled.is_set())
                    message = "Cancellation requested; press x again to force-stop this check's process group."
                else:
                    message = "No check is running."
            elif key in [10, 13] and tab == 3:
                name = list(available)[selection % len(available)]
                if runner.start(name, available[name]):
                    message = f"Running {name}; output is saved under .build/compat-monitor/."
                else:
                    message = "A check is already running. Wait or press x to cancel it."
    finally:
        runner.close()
        poller.close()
        if ci_poller:
            ci_poller.close()
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--interval", type=float, default=1, help="Local refresh seconds (minimum 0.2)")
    parser.add_argument("--log", type=Path, action="append", default=[], help="Additional log to follow")
    parser.add_argument("--library", type=Path, help="Bridge library for the sampling check")
    parser.add_argument("--check", action="append", default=[], metavar="NAME=COMMAND", help="Extra check; argv is parsed without a shell")
    parser.add_argument("--run-check", metavar="NAME", help="Run one named check, then print its result and exit")
    parser.add_argument("--once", action="store_true", help="Print one snapshot and exit")
    parser.add_argument("--json", action="store_true", help="Print one machine-readable snapshot")
    parser.add_argument("--plain", action="store_true", help="Continuous text output instead of curses")
    parser.add_argument("--ci", action="store_true", help="Enable read-only GitHub Actions polling using gh")
    parser.add_argument("--repo", default="chiddekel/Compositor")
    parser.add_argument("--branch")
    parser.add_argument("--ci-interval", type=float, default=30)
    args = parser.parse_args()
    args.root = args.root.resolve()
    args.log = [path.resolve() for path in args.log]
    if args.library:
        args.library = args.library.resolve()
    if not args.root.is_dir() or not 0.2 <= args.interval <= 3600 or not 5 <= args.ci_interval <= 3600:
        parser.error("Root must exist; interval must be 0.2..3600 seconds and CI interval 5..3600 seconds")
    try:
        available = checks(args)
    except ValueError as error:
        parser.error(str(error))
    if args.run_check and args.run_check not in available:
        parser.error("Unknown check; available: " + ", ".join(available))
    try:
        if args.once or args.json or args.run_check or args.plain or not sys.stdin.isatty() or not sys.stdout.isatty() or os.environ.get("TERM") == "dumb":
            runner = CheckRunner(args.root)
            client = workflow.GitHub(args.repo, args.branch or "GNU_Linux", 4) if args.ci else None
            ci_snapshot = ci_error = None
            next_ci = 0
            try:
                if args.run_check:
                    runner.start(args.run_check, available[args.run_check])
                    while runner.state()["status"] == "running":
                        time.sleep(0.05)
                while True:
                    value = snapshot(args.root, args.log)
                    task = runner.state()
                    value["check"] = task
                    if client and time.monotonic() >= next_ci:
                        client.branch = args.branch or value.get("branch", "GNU_Linux")
                        try:
                            ci_snapshot = client.snapshot()
                            ci_error = "; ".join(run["load_error"] for run in ci_snapshot["runs"] if run.get("load_error")) or None
                        except (OSError, RuntimeError, ValueError) as error:
                            ci_error = safe(error)
                        next_ci = time.monotonic() + args.ci_interval
                    if ci_snapshot:
                        value["ci"] = ci_snapshot
                    if ci_error:
                        value["errors"].append("GitHub: " + safe(ci_error))
                    print(json.dumps(value, indent=2) if args.json else plain(value, task), flush=True)
                    if args.once or args.json or args.run_check:
                        return 1 if task["status"] in ["failure", "cancelled"] else 2 if value["errors"] else 0
                    time.sleep(args.interval)
            finally:
                runner.close()
        locale.setlocale(locale.LC_ALL, "")
        return curses.wrapper(dashboard, args, available)
    except KeyboardInterrupt:
        return 130
    except curses.error as error:
        print("Terminal: " + safe(error) + "; use --once or set TERM=xterm-256color in an interactive terminal.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
