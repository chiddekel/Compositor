#!/usr/bin/env python3
"""Live, read-only terminal dashboard for Compositor's GitHub Actions builds."""
import argparse
from collections import deque
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import json
import locale
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*?(?:\x07|\x1b\\))")
ACTIVE = {"in_progress", "queued", "waiting", "pending", "requested"}
FAILED = {"failure", "timed_out", "action_required", "startup_failure"}


def clean(value):
    return "".join(c if c.isprintable() else " " for c in ANSI.sub("", str(value or "")))


def clipped(value, width):
    result, used = [], 0
    for char in clean(value):
        size = 0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in "WF" else 1
        if used + size > max(0, width):
            break
        result.append(char)
        used += size
    return "".join(result)


def state(item):
    return (item.get("conclusion") or "unknown") if item.get("status") == "completed" else item.get("status", "pending")


def duration(item, now=None):
    start = item.get("started_at") or item.get("run_started_at") or item.get("created_at")
    if not start:
        return "--"
    try:
        beginning = datetime.fromisoformat(start.replace("Z", "+00:00"))
        end = item.get("completed_at") or (item.get("updated_at") if item.get("status") == "completed" else None)
        ending = datetime.fromisoformat(end.replace("Z", "+00:00")) if end else now or datetime.now(timezone.utc)
        seconds = max(0, int((ending - beginning).total_seconds()))
    except (ValueError, TypeError):
        return "--"
    if seconds >= 3600:
        return f"{seconds // 3600}h {seconds % 3600 // 60:02}m"
    return f"{seconds // 60:02}:{seconds % 60:02}"


def step_counts(jobs):
    steps = [step for job in jobs for step in job.get("steps", [])]
    return sum(step.get("status") == "completed" for step in steps), len(steps)


def related_runs(runs, branch, limit):
    return sorted(
        (run for run in runs if run.get("head_branch") == branch
         or (run.get("head_branch") or "").startswith("linux-v")),
        key=lambda run: (run.get("created_at", ""), run["id"]), reverse=True,
    )[:limit]


class GitHub:
    def __init__(self, repo, branch, limit, run_id=None, verbose=0):
        self.repo, self.branch, self.limit, self.run_id = repo, branch, limit, run_id
        self.finished_jobs = {}
        self.cancel = threading.Event()
        self.verbose = min(verbose, 3)
        self.diagnostics = deque(maxlen=100)
        self.diagnostic_lock = threading.Lock()
        self.request_count = 0

    def trace(self, message):
        if self.verbose >= 3:
            with self.diagnostic_lock:
                self.diagnostics.append({"time": time.time(), "message": clean(message)})

    def api(self, endpoint):
        if self.cancel.is_set():
            raise RuntimeError("Request cancelled")
        started = time.monotonic()
        with self.diagnostic_lock:
            self.request_count += 1
        self.trace(f"GET {endpoint}")
        process = subprocess.Popen(
            ["gh", "api", f"repos/{self.repo}/{endpoint}"], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, env=dict(os.environ, GH_PROMPT_DISABLED="1"),
        )
        deadline = time.monotonic() + 25
        try:
            while True:
                if self.cancel.is_set():
                    raise RuntimeError("Request cancelled")
                if time.monotonic() >= deadline:
                    raise RuntimeError("GitHub request timed out; retrying on the next refresh")
                try:
                    output, error = process.communicate(timeout=0.25)
                    break
                except subprocess.TimeoutExpired:
                    continue
            if process.returncode:
                raise RuntimeError(clean(error).strip() or "GitHub request failed; check gh auth status")
            self.trace(f"OK {endpoint} ({time.monotonic() - started:.2f}s)")
            return json.loads(output)
        except (RuntimeError, ValueError, OSError) as error:
            self.trace(f"FAILED {endpoint}: {type(error).__name__} ({time.monotonic() - started:.2f}s)")
            raise
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def jobs(self, run):
        key = (run["id"], run.get("run_attempt"), run.get("updated_at"))
        if key in self.finished_jobs:
            self.trace(f"CACHE run {run['id']} attempt {run.get('run_attempt', 1)}: completed jobs")
            return self.finished_jobs[key]
        jobs, page = [], 1
        while True:
            batch = self.api(f"actions/runs/{run['id']}/jobs?per_page=100&page={page}&filter=latest")["jobs"]
            jobs.extend(batch)
            if len(batch) < 100:
                break
            page += 1
        if run["status"] == "completed":
            self.finished_jobs[key] = jobs
        return jobs

    def snapshot(self):
        started = time.monotonic()
        if self.run_id:
            runs = [self.api(f"actions/runs/{self.run_id}")]
        else:
            runs = related_runs(self.api("actions/runs?per_page=100")["workflow_runs"], self.branch, self.limit)
        with ThreadPoolExecutor(max_workers=4) as pool:
            pending = {pool.submit(self.jobs, run): run for run in runs}
            for future in as_completed(pending):
                run = pending[future]
                try:
                    run["jobs"] = future.result()
                except (RuntimeError, KeyError, ValueError) as error:
                    run["jobs"] = []
                    run["load_error"] = clean(error)
        self.trace(f"REFRESH {len(runs)} workflows in {time.monotonic() - started:.2f}s")
        with self.diagnostic_lock:
            diagnostics, requests = list(self.diagnostics), self.request_count
        return {"runs": runs, "fetched_at": time.time(), "diagnostics": diagnostics,
                "requests": requests, "poll_seconds": time.monotonic() - started}


class Poller:
    def __init__(self, client, interval):
        self.client, self.interval = client, interval
        self.events = queue.Queue()
        self.wake, self.stop = threading.Event(), threading.Event()
        self.thread = threading.Thread(target=self.work, daemon=True)

    def work(self):
        while not self.stop.is_set():
            self.wake.clear()
            self.events.put(("loading", None))
            try:
                self.events.put(("snapshot", self.client.snapshot()))
            except (RuntimeError, ValueError, KeyError, OSError) as error:
                self.events.put(("error", clean(error)))
            self.wake.wait(self.interval)

    def close(self):
        self.stop.set()
        self.client.cancel.set()
        self.wake.set()


def run_metadata(run, verbose):
    rows = []
    if verbose:
        rows.append(f"Run ID {run['id']} / attempt {run.get('run_attempt', 1)} / event {clean(run.get('event', 'unknown'))}")
    if verbose >= 2:
        actor = (run.get("triggering_actor") or run.get("actor") or {}).get("login", "unknown")
        rows.extend([f"Workflow: {clean(run.get('path', 'unknown'))}",
                     f"Commit: {clean(run.get('head_sha', 'unknown'))}",
                     f"Triggered by: {clean(actor)}",
                     f"Created: {clean(run.get('created_at', '--'))}",
                     f"Started: {clean(run.get('run_started_at', '--'))}",
                     f"Updated: {clean(run.get('updated_at', '--'))}"])
    return rows


def job_metadata(job, verbose):
    rows = []
    if verbose:
        rows.append(f"Job ID {job.get('id', '--')} / elapsed {duration(job)}")
    if verbose >= 2:
        labels = ", ".join(clean(label) for label in job.get("labels", [])) or "not assigned"
        rows.extend([f"Runner: {clean(job.get('runner_name') or 'waiting')} / {labels}",
                     f"Started: {clean(job.get('started_at') or '--')}",
                     f"Finished: {clean(job.get('completed_at') or '--')}"])
    return rows


def trace_rows(snapshot):
    return [(datetime.fromtimestamp(event["time"]).strftime("%H:%M:%S") + "  " + clean(event["message"]), "pending")
            for event in snapshot.get("diagnostics", [])] or [("Waiting for request diagnostics; press r to refresh.", "pending")]


def plain(snapshot, verbose=0):
    lines = ["COMPOSITOR / GNU-LINUX / FLATPAK", ""]
    for run in snapshot["runs"]:
        jobs = run.get("jobs", [])
        done, total = step_counts(jobs)
        lines.append(f"{clean(run['name'])}  #{run.get('run_number', run['id'])}  {state(run).upper()}  {duration(run)}")
        lines.append(f"  {clean(run.get('head_branch'))}  {run.get('head_sha', '')[:7]}  {done}/{total} steps finished")
        lines.extend("  " + line for line in run_metadata(run, verbose))
        if run.get("load_error"):
            lines.append("  API: " + run["load_error"])
        for job in jobs:
            lines.append(f"  {clean(job['name'])} [{state(job)}] {duration(job)}")
            lines.extend("    " + line for line in job_metadata(job, verbose))
            for step in job.get("steps", []):
                timing = f" [{duration(step)}]" if verbose else ""
                number = f"#{step.get('number', '--')} " if verbose else ""
                lines.append(f"    {state(step):13} {number}{clean(step['name'])}{timing}")
                if verbose >= 2:
                    lines.append(f"      started={clean(step.get('started_at') or '--')} finished={clean(step.get('completed_at') or '--')}")
        lines.append("  " + run.get("html_url", ""))
        lines.append("")
    if not snapshot["runs"]:
        lines.append("No GNU_Linux or linux-v* workflow runs found.")
    lines.append("Counts describe finished workflow steps, not compiler progress.")
    if verbose >= 3:
        lines.extend(["", f"REQUEST TRACE / {snapshot.get('requests', 0)} requests / last refresh {snapshot.get('poll_seconds', 0):.2f}s"])
        lines.extend(label for label, _ in trace_rows(snapshot))
    return "\n".join(lines)


def details(run, ascii_only=False, verbose=0):
    symbols = {"success": "+" if ascii_only else "✓", "failure": "x" if ascii_only else "✕",
               "skipped": "-", "cancelled": "-", "in_progress": ">", "queued": ".", "pending": "."}
    rows = [(line, "metadata") for line in run_metadata(run, verbose)]
    if run.get("load_error"):
        rows.append(("API: " + run["load_error"], "failure"))
    for job in run.get("jobs", []):
        rows.append((f"{clean(job['name']).upper()}  {state(job).replace('_', ' ')}  {duration(job)}", state(job)))
        rows.extend(("    " + line, "metadata") for line in job_metadata(job, verbose))
        if not job.get("steps"):
            rows.append(("  Waiting for a runner; no steps have started.", "pending"))
        for step in job.get("steps", []):
            status = state(step)
            timing = f" [{duration(step)}]" if verbose else ""
            number = f"#{step.get('number', '--')} " if verbose else ""
            rows.append((f"  {symbols.get(status, '!')}  {number}{clean(step['name'])}{timing}", status))
            if verbose >= 2:
                rows.append((f"    start {clean(step.get('started_at') or '--')} / end {clean(step.get('completed_at') or '--')}", "metadata"))
        rows.append(("", "pending"))
    return rows or [("Waiting for GitHub to create jobs...", "pending")]


def focus_offset(rows, visible):
    failed = [i for i, (label, status) in enumerate(rows) if status in FAILED]
    running = [i for i, (label, status) in enumerate(rows) if label.startswith("  ") and status == "in_progress"]
    target = (failed or running or [0])[0]
    return max(0, min(target - visible // 3, len(rows) - visible))


def dashboard(screen, args, client):
    import curses
    try:
        curses.curs_set(0)
    except curses.error:
        pass
    screen.timeout(100)
    screen.keypad(True)
    palette = {}
    if curses.has_colors() and not os.environ.get("NO_COLOR"):
        curses.start_color()
        colors = [252, 87, 158, 221, 203, 245, 239] if curses.COLORS >= 256 else [7, 6, 2, 3, 1, 7, 0]
        background = 234 if curses.COLORS >= 256 else 0
        for index, color in enumerate(colors, 1):
            curses.init_pair(index, color, background)
            palette[index] = curses.color_pair(index)
        screen.bkgd(" ", palette[1])
    normal, accent, good, amber, bad, muted, border = [palette.get(i, 0) for i in range(1, 8)]
    bold = curses.A_BOLD
    box = ("+", "+", "+", "+", "-", "|") if args.ascii else ("╭", "╮", "╰", "╯", "─", "│")
    poller = Poller(client, args.interval)
    poller.thread.start()
    snapshot, error, loading, selected, scroll = {"runs": []}, "", True, None, 0
    following = True
    verbosity, diagnostic_view = min(getattr(args, "verbose", 0), 3), False

    def tint(status):
        return good if status == "success" else bad if status in FAILED else amber if status in ACTIVE else muted

    def put(y, x, value, style=0, width=None):
        height, columns = screen.getmaxyx()
        if 0 <= y < height and 0 <= x < columns:
            try:
                screen.addstr(y, x, clipped(value, min(columns - x - 1, width if width is not None else columns)), style)
            except curses.error:
                pass

    def frame(y, x, height, width, title):
        tl, tr, bl, br, horizontal, vertical = box
        put(y, x, tl + horizontal * (width - 2) + tr, border)
        put(y + height - 1, x, bl + horizontal * (width - 2) + br, border)
        for row in range(y + 1, y + height - 1):
            put(row, x, vertical, border)
            put(row, x + width - 1, vertical, border)
        put(y, x + 2, " " + title + " ", accent | bold, width - 4)

    try:
        while True:
            while True:
                try:
                    kind, value = poller.events.get_nowait()
                except queue.Empty:
                    break
                if kind == "snapshot":
                    snapshot, error, loading = value, "", False
                elif kind == "error":
                    error, loading = value, False
                else:
                    loading = True
            runs = snapshot["runs"]
            ids = [run["id"] for run in runs]
            if selected not in ids:
                releases = [r for r in runs if r.get("path", "").endswith("flatpak-release.yml")]
                chosen = next((r for r in releases if r["status"] != "completed"), releases[0] if releases else runs[0] if runs else None)
                selected, scroll, following = (chosen["id"] if chosen else None), 0, True
            run = next((r for r in runs if r["id"] == selected), None)
            if args.wait and run and run["status"] == "completed":
                return 0 if run.get("conclusion") == "success" else 1
            screen.erase()
            height, width = screen.getmaxyx()
            spinner = "|/-\\"[int(time.monotonic() * 5) % 4]
            put(1, 2, "COMPOSITOR", accent | bold)
            put(2, 2, "GNU/LINUX  /  FLATPAK BUILD MONITOR", muted)
            put(1, max(16, width - len(args.repo) - 3), args.repo, normal)
            if width < 76 or height < 20:
                put(5, 2, "Make the terminal at least 76 columns x 20 rows.", amber)
                put(7, 2, "q quit   r refresh   --plain for compact output", muted)
            else:
                active = sum(r["status"] != "completed" for r in runs)
                failures = sum(state(r) in FAILED for r in runs)
                put(4, 2, f"{active} ACTIVE", accent | bold)
                put(4, 17, f"{failures} FAILED", bad if failures else muted)
                put(4, 32, f"{len(runs)} WORKFLOWS", normal)
                connection = "SYNCING" if loading else "STALE" if error else "LIVE"
                put(4, width - 19, f"{spinner if loading else ' '} {connection}", bad if error else accent)
                left, top, pane_height = max(28, min(42, width // 3)), 6, height - 10
                frame(top, 1, pane_height, left, "WORKFLOWS")
                title = "REQUEST TRACE" if diagnostic_view else "JOB STEPS / " + ("FOLLOW" if following else "BROWSE")
                frame(top, left + 2, pane_height, width - left - 3, title)
                visible = max(1, (pane_height - 2) // 3)
                index = ids.index(selected) if selected in ids else 0
                first = max(0, min(index - visible + 1, len(runs) - visible))
                for offset, item in enumerate(runs[first:first + visible]):
                    y = top + 1 + offset * 3
                    marker = ">" if item["id"] == selected else " "
                    status = state(item)
                    put(y, 3, f"{marker} {clean(item['name'])}", (accent | bold) if item["id"] == selected else normal, left - 4)
                    put(y + 1, 5, f"{status.upper().replace('_', ' ')}  {duration(item)}", tint(status), left - 6)
                    put(y + 2, 5, f"{item.get('head_sha', '')[:7]}  {clean(item.get('head_branch'))}", muted, left - 6)
                if not runs:
                    put(top + 2, 4, "Loading workflows..." if loading else "No matching workflows.", muted, left - 5)
                if run:
                    x, available = left + 4, width - left - 8
                    done, total = step_counts(run.get("jobs", []))
                    put(top + 1, x, f"#{run.get('run_number', run['id'])}  {state(run).upper().replace('_', ' ')}  {duration(run)}", tint(state(run)) | bold, available)
                    bar_width = max(8, available - 20)
                    filled = int(bar_width * done / total) if total else 0
                    solid, empty = ("#", ".") if args.ascii else ("━", "─")
                    put(top + 2, x, solid * filled, accent, available)
                    put(top + 2, x + filled, empty * (bar_width - filled), border)
                    put(top + 2, x + bar_width + 2, f"{done}/{total} steps", normal, 17)
                    put(top + 3, x, "Workflow steps, not compiler progress.", muted, available)
                    rows = trace_rows(snapshot) if diagnostic_view else details(run, args.ascii, verbosity)
                    count = pane_height - 6
                    if following:
                        scroll = max(0, len(rows) - count) if diagnostic_view else focus_offset(rows, count)
                    scroll = max(0, min(scroll, max(0, len(rows) - count)))
                    for offset, (label, status) in enumerate(rows[scroll:scroll + count]):
                        put(top + 5 + offset, x, label, tint(status), available)
                    if len(rows) > count:
                        put(top + pane_height - 1, x, f" {scroll + 1}-{min(scroll + count, len(rows))}/{len(rows)}  PgUp/PgDn ", muted, available)
                stamp = datetime.fromtimestamp(snapshot["fetched_at"]).strftime("%H:%M:%S") if snapshot.get("fetched_at") else "--:--:--"
                message = error or f"Updated {stamp}  /  refresh every {args.interval}s  /  {args.branch} + linux-v*"
                if verbosity and not error:
                    message = f"{'v' * verbosity} / updated {stamp} / {snapshot.get('requests', 0)} API requests / refresh {snapshot.get('poll_seconds', 0):.2f}s"
                put(height - 3, 2, ("API ERROR: " if error else "") + message, bad if error else muted, width - 4)
                put(height - 2, 2, "j/k select  PgUp/Dn scroll  a follow  v detail  d trace  r refresh  o web  q quit", accent, width - 4)
            screen.refresh()
            key = screen.getch()
            if key in (ord("q"), 27):
                return 0
            if key in (ord("r"), ord("R")):
                poller.wake.set()
            if key in (ord("j"), curses.KEY_DOWN, ord("k"), curses.KEY_UP) and ids:
                direction = 1 if key in (ord("j"), curses.KEY_DOWN) else -1
                selected = ids[(ids.index(selected) + direction) % len(ids)]
                scroll, following = 0, True
            if key in (curses.KEY_NPAGE, curses.KEY_PPAGE):
                following = False
                scroll += (1 if key == curses.KEY_NPAGE else -1) * max(1, (height - 16) // 2)
            if key in (ord("a"), ord("A")):
                following = True
            if key in (ord("v"), ord("V")):
                verbosity = (verbosity + 1) % 4
                client.verbose = verbosity
            if key in (ord("d"), ord("D")):
                diagnostic_view = not diagnostic_view
                scroll, following = 0, True
                if diagnostic_view:
                    verbosity = client.verbose = 3
                    poller.wake.set()
            if key in (ord("o"), ord("O")) and run:
                subprocess.Popen(["gh", "run", "view", str(run["id"]), "--repo", args.repo, "--web"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        poller.close()


def main(argv=None):
    config_path = ROOT / "flatpak/release.json"
    default_repo = json.loads(config_path.read_text()).get("repository", "chiddekel/Compositor") if config_path.exists() else "chiddekel/Compositor"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=default_repo, help="GitHub OWNER/REPOSITORY")
    parser.add_argument("--branch", default="GNU_Linux")
    parser.add_argument("--run", type=int, help="follow a single workflow run ID")
    parser.add_argument("--interval", type=int, default=15, help="refresh interval in seconds (minimum 5)")
    parser.add_argument("--limit", type=int, default=8, help="number of recent related workflows (1-12)")
    parser.add_argument("--plain", action="store_true", help="stream text instead of opening the TUI")
    parser.add_argument("--once", action="store_true", help="print one snapshot and exit")
    parser.add_argument("--wait", action="store_true", help="with --run, exit when finished; nonzero on failure")
    parser.add_argument("--ascii", action="store_true", help="use ASCII borders and symbols")
    parser.add_argument("-v", "--verbose", action="count", default=0,
                        help="more detail: -v timings/IDs, -vv runners/timestamps, -vvv request diagnostics")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo) or args.repo.startswith("-"):
        parser.error("--repo must be OWNER/REPOSITORY")
    if args.interval < 5 or not 1 <= args.limit <= 12 or (args.run is not None and args.run < 1):
        parser.error("use --interval >= 5, --limit 1-12 and a positive --run ID")
    if args.wait and not args.run:
        parser.error("--wait requires --run")
    if not shutil.which("gh"):
        parser.exit(2, "GitHub CLI is missing. Install gh and run: gh auth login\n")
    client = GitHub(args.repo, args.branch, args.limit, args.run, args.verbose)
    try:
        if args.plain or args.once or not sys.stdin.isatty() or not sys.stdout.isatty() or os.environ.get("TERM") == "dumb":
            while True:
                try:
                    snapshot = client.snapshot()
                    print(plain(snapshot, min(args.verbose, 3)), flush=True)
                    if args.once:
                        return 2 if any(run.get("load_error") for run in snapshot["runs"]) else 0
                    if args.wait and snapshot["runs"][0]["status"] == "completed":
                        return 0 if snapshot["runs"][0].get("conclusion") == "success" else 1
                except (RuntimeError, ValueError, KeyError, OSError) as error:
                    print("GitHub: " + clean(error), file=sys.stderr, flush=True)
                    if args.once:
                        return 2
                time.sleep(args.interval)
        import curses
        locale.setlocale(locale.LC_ALL, "")
        return curses.wrapper(dashboard, args, client)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
