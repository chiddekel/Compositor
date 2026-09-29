"""Report generation and baseline comparison for the graphics E2E bench."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from tests.bench.stats import percentiles


def build_report(*, level, backend, workers, fixture_sha256, environment,
                 phases_samples, totals, peak_rss_mib=None, validation_ok=True,
                 notes="") -> dict:
    phase_stats = {}
    for name, values in phases_samples.items():
        phase_stats[name] = percentiles(values)
    total_stats = percentiles(totals)
    throughput = 1000.0 / (total_stats["p50"] or 1) if total_stats else None
    return {
        "schema": "compositor.e2e_graphics_bench/2",
        "level": level,
        "backend": backend,
        "workers": workers,
        "fixture_sha256": fixture_sha256,
        "environment": environment,
        "total_ms": total_stats,
        "phases_ms": phase_stats,
        "throughput_docs_per_s": throughput,
        "peak_rss_mib": peak_rss_mib,
        "validation": "PASS" if validation_ok else "FAIL",
        "notes": notes,
    }


def write_report(artifacts: Path, report: dict) -> None:
    artifacts.mkdir(parents=True, exist_ok=True)
    (artifacts / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = [
        "# Graphics package E2E benchmark",
        "",
        f"Level: **{report.get('level')}** · Backend: `{report.get('backend')}` · "
        f"Workers: {report.get('workers')} · Validation: {report.get('validation')}",
        "",
        f"Fixture SHA-256: `{report.get('fixture_sha256')}`",
        "",
        "| Scenario | Input | Workers | E2E p50 | p95 | p99 | Throughput | Peak RAM | CPU | GPU | Validation |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |",
    ]
    total = report.get("total_ms") or {}
    env = report.get("environment") or {}
    lines.append(
        f"| warm_same_scene | {report.get('level')} | {report.get('workers')} | "
        f"{_fmt(total.get('p50'))} | {_fmt(total.get('p95'))} | {_fmt(total.get('p99'))} | "
        f"{_fmt(report.get('throughput_docs_per_s'), 3)} | "
        f"{_fmt(report.get('peak_rss_mib'), 1)} | "
        f"{env.get('logical_cpus', '—')}c | {env.get('gpu', 'unavailable')} | "
        f"{report.get('validation')} |"
    )
    lines += ["", "## Phases (p50 / p95 / p99)", ""]
    for name, stats in (report.get("phases_ms") or {}).items():
        if not stats:
            continue
        lines.append(
            f"- `{name}`: {stats['p50']:.1f} / {stats['p95']:.1f} / {stats['p99']:.1f} ms "
            f"(n={stats['n']})"
        )
    if report.get("notes"):
        lines += ["", report["notes"], ""]
    (artifacts / "report.md").write_text("\n".join(lines) + "\n")
    _try_charts(artifacts, report)


def _fmt(value, digits=1):
    if value is None:
        return "—"
    return f"{value:.{digits}f}"


def _try_charts(artifacts: Path, report: dict) -> None:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:
        return
    phases = report.get("phases_ms") or {}
    if not phases:
        return
    names = list(phases.keys())
    p50 = [phases[n]["p50"] for n in names]
    fig, ax = plt.subplots(figsize=(8, 3.5))
    ax.bar(names, p50)
    ax.set_ylabel("p50 ms")
    ax.set_title(f"Phase latency — {report.get('level')} / {report.get('backend')}")
    fig.autofmt_xdate(rotation=30)
    fig.tight_layout()
    fig.savefig(artifacts / "chart-phases.png", dpi=120)
    plt.close(fig)


def compare(baseline: dict, candidate: dict, max_regression_percent: float = 20.0) -> list:
    """Return list of regression strings; empty means OK."""
    errors = []
    for key in ("schema",):
        if baseline.get(key) != candidate.get(key):
            errors.append(f"schema mismatch: {baseline.get(key)} vs {candidate.get(key)}")
    be = baseline.get("environment") or {}
    ce = candidate.get("environment") or {}
    for key in ("machine_class", "backend", "logical_cpus"):
        if be.get(key) is not None and be.get(key) != ce.get(key):
            errors.append(f"environment {key} differs: {be.get(key)} vs {ce.get(key)}")
    if baseline.get("fixture_sha256") and baseline["fixture_sha256"] != candidate.get("fixture_sha256"):
        errors.append("fixture_sha256 differs — re-baseline required")
    if candidate.get("validation") != "PASS":
        errors.append("candidate validation is not PASS")
    bt = (baseline.get("total_ms") or {}).get("p50")
    ct = (candidate.get("total_ms") or {}).get("p50")
    if bt and ct and ct > bt * (1 + max_regression_percent / 100):
        errors.append(f"p50 regression: {ct:.1f} ms > {bt:.1f}×{1 + max_regression_percent / 100:.2f}")
    br = baseline.get("peak_rss_mib")
    cr = candidate.get("peak_rss_mib")
    # RSS gate uses 25% on PR by design (caller may pass 25).
    rss_limit = max(max_regression_percent, 25.0)
    if br and cr and cr > br * (1 + rss_limit / 100):
        errors.append(f"peak RSS regression: {cr:.1f} > {br:.1f}×{1 + rss_limit / 100:.2f}")
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    cmp = sub.add_parser("compare")
    cmp.add_argument("baseline", type=Path)
    cmp.add_argument("candidate", type=Path)
    cmp.add_argument("--max-regression-percent", type=float, default=20.0)
    args = parser.parse_args(argv)
    if args.cmd == "compare":
        baseline = json.loads(args.baseline.read_text())
        candidate = json.loads(args.candidate.read_text())
        errors = compare(baseline, candidate, args.max_regression_percent)
        if errors:
            print("REGRESSION")
            for e in errors:
                print(" -", e)
            raise SystemExit(1)
        print("OK")


if __name__ == "__main__":
    main()
