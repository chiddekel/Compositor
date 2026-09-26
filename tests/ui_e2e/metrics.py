"""Linux app-process measurements; the Python driver and Xvfb are excluded."""
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import threading
import time


def summary(values):
    ordered = sorted(values)
    return {"count": len(values), "median": statistics.median(values),
            "p95": ordered[math.ceil(len(ordered) * .95) - 1], "max": max(values)}


class Metrics:
    def __init__(self, artifacts, binary):
        marker = ("COMPOSITOR_UI_E2E_DIR=" + str(artifacts)).encode()
        matches = []
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                if (entry / "exe").resolve().name == Path(binary).name and marker in (entry / "environ").read_bytes().split(b"\0"):
                    matches.append(entry)
            except (OSError, RuntimeError):
                continue
        if len(matches) != 1:
            raise RuntimeError("Expected one isolated app process for metrics, found " + str(matches))
        self.proc = matches[0]
        self.ticks = os.sysconf("SC_CLK_TCK")
        self.page = os.sysconf("SC_PAGE_SIZE")
        self.records = []
        self.initial = self.sample()
        self.peak_rss = self.initial["rss_mib"]
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self.poll, daemon=True)
        self.thread.start()

    def sample(self):
        # stat's comm field may contain spaces or parentheses.
        fields = (self.proc / "stat").read_text().rsplit(")", 1)[1].split()
        return {"clock": time.perf_counter(),
                "cpu_ms": (int(fields[11]) + int(fields[12])) * 1000 / self.ticks,
                "rss_mib": int(fields[21]) * self.page / 1024**2}

    def poll(self):
        while not self.stop_event.wait(.05):
            try:
                self.peak_rss = max(self.peak_rss, self.sample()["rss_mib"])
            except OSError:
                return

    @contextmanager
    def measure(self, name, **parameters):
        before = self.sample()
        record = {"name": name, "parameters": parameters, "completed": False}
        try:
            yield record
            record["completed"] = True
        finally:
            after = self.sample()
            record.update(wall_ms=(after["clock"] - before["clock"]) * 1000,
                          cpu_ms=after["cpu_ms"] - before["cpu_ms"],
                          rss_delta_mib=after["rss_mib"] - before["rss_mib"])
            self.records.append(record)

    def finish(self):
        self.stop_event.set()
        self.thread.join()
        final = self.sample()
        status = dict(line.split(":", 1) for line in (self.proc / "status").read_text().splitlines())
        wall = (final["clock"] - self.initial["clock"]) * 1000
        cpu = final["cpu_ms"] - self.initial["cpu_ms"]
        groups = {}
        for record in self.records:
            if record["completed"]:
                groups.setdefault(record["name"], []).append(record)
        aggregates = {name: {key: summary([r[key] for r in records if key in r])
                            for key in ("wall_ms", "cpu_ms", "release_to_observed_ms")
                            if any(key in r for r in records)} for name, records in groups.items()}
        return {"wall_ms": wall, "cpu_ms": cpu, "average_cpu_percent_one_core": cpu / wall * 100,
                "initial_rss_mib": self.initial["rss_mib"], "final_rss_mib": final["rss_mib"],
                "sampled_peak_rss_mib": max(self.peak_rss, final["rss_mib"]),
                "process_lifetime_peak_rss_mib": int(status["VmHWM"].split()[0]) / 1024,
                "operations": self.records, "operation_summary": aggregates}


def metadata(binary, backend):
    cpu = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                if line.startswith("model name")), platform.machine())
    source = Path(__file__).parent
    workload = b"".join((source / name).read_bytes() for name in
                        ("run.py", "desktop.py", "tool_cases.py", "psd_cases.py", "fixtures/psd-tools/manifest.json"))
    return {"schema": 1, "binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
            "workload_sha256": hashlib.sha256(workload).hexdigest(),
            "backend_requested": backend, "kernel": platform.release(), "cpu": cpu,
            "logical_cpus": os.cpu_count(), "display": "Xvfb 1600x1000, X11/XTest",
            "notes": "App process only. CPU clock tick resolution; RSS sampled every 50 ms. "
                     "Case totals exclude startup but include UI input pacing, polling and exports. "
                     "Release latency includes polling (10 ms bridge/driver, 30 ms retry); not presentation latency. "
                     "No GPU utilization or power measurement. Compare identical cases on the same idle host."}


def write_report(path, report):
    (path / "metrics.json").write_text(json.dumps(report, indent=2))
    lines = ["# Desktop E2E performance", "", report["environment"]["notes"], "",
             "| Case | Result | Wall ms | CPU ms | Peak RSS MiB |", "| --- | --- | ---: | ---: | ---: |"]
    for name, row in report["cases"].items():
        lines.append(f'| {name} | {row["result"]} | {row["wall_ms"]:.1f} | {row["cpu_ms"]:.1f} | {row["process_lifetime_peak_rss_mib"]:.1f} |')
    lines += ["", "## Operations", "", "Median / p95. Single samples do not establish a distribution.", "",
              "| Case / operation | n | Wall ms | CPU ms | Release to observed ms |",
              "| --- | ---: | ---: | ---: | ---: |"]
    for name, row in report["cases"].items():
        for operation, group in row["operation_summary"].items():
            def cell(key):
                value = group.get(key)
                return f'{value["median"]:.1f} / {value["p95"]:.1f}' if value else "—"
            lines.append(f'| {name} / {operation} | {group["wall_ms"]["count"]} | {cell("wall_ms")} | {cell("cpu_ms")} | {cell("release_to_observed_ms")} |')
    (path / "metrics.md").write_text("\n".join(lines) + "\n")
