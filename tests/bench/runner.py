"""CLI entry for the graphics package E2E benchmark."""
from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import os
import platform
import resource
import shutil
import sys
import time
import traceback
from pathlib import Path

# `python3 -m tests.bench.runner` from repo root.
REPO = Path(__file__).resolve().parents[2]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from tests.bench.fixtures.generate import generate
from tests.bench.levels import DEFAULT_SEED, LEVELS
from tests.bench.pipeline import reexport_reference, run_host_pipeline, run_reference_pipeline
from tests.bench.report import build_report, write_report
from tests.bench.stats import percentiles


def _env_block(backend: str) -> dict:
    return {
        "machine_class": os.environ.get("BENCH_MACHINE_CLASS", "local"),
        "backend": backend,
        "cpu": platform.processor() or platform.machine(),
        "logical_cpus": os.cpu_count() or 1,
        "kernel": platform.release(),
        "python": platform.python_version(),
        "gpu": os.environ.get("BENCH_GPU", "unavailable"),
    }


def _rss_mib() -> float:
    # Linux: ru_maxrss is KiB.
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024.0


def _prepare_fixtures(level: str, seed: int, root: Path) -> Path:
    out = root / level
    if not (out / "recipe.json").exists():
        generate(level, seed, out)
    return out


def _worker_run(args):
    """One worker process: cold/warm protocol for a single level."""
    (worker_id, level, backend, fixtures_src, artifacts, seed, pin) = args
    try:
        if pin and hasattr(os, "sched_setaffinity"):
            cores = os.cpu_count() or 1
            os.sched_setaffinity(0, {worker_id % cores})
        fixtures = artifacts / f"fixtures-w{worker_id}"
        if fixtures.exists():
            shutil.rmtree(fixtures)
        shutil.copytree(fixtures_src, fixtures)
        work = artifacts / f"worker-{worker_id}"
        work.mkdir(parents=True, exist_ok=True)
        golden_dir = REPO / "tests" / "bench" / "goldens"

        cold_t0 = time.perf_counter()
        # Touch import path / Host spawn as cold_start.
        if backend == "host":
            from tests.bench.host_session import HostSession
            session = HostSession(work / "bridge")
            cold_ms = (time.perf_counter() - cold_t0) * 1000
        else:
            session = None
            # Reference cold: import Pillow + load recipe.
            _ = run_reference_pipeline
            cold_ms = (time.perf_counter() - cold_t0) * 1000

        recipe = json.loads((fixtures / "recipe.json").read_text())
        scenes = recipe["scenes"]
        warmup_n = recipe["warmup_pipelines"]
        warm_iters = recipe["warm_iters"]

        def pipeline(scene, tag):
            out = work / tag
            out.mkdir(parents=True, exist_ok=True)
            if backend == "host":
                return run_host_pipeline(fixtures, out, scene=scene,
                                         golden_dir=golden_dir, session=session)
            return run_reference_pipeline(fixtures, out, scene=scene,
                                          golden_dir=golden_dir, backend=backend)

        # Warm-up pipelines (discarded).
        for i in range(warmup_n):
            pipeline(scenes[0], f"warmup-{i}")

        first = pipeline(scenes[0], "first")
        first_ms = first["total_ms"]

        # warm_same_scene measured iters.
        warm_totals = []
        phase_acc = {"decode_ms": [], "compose_ms": [], "render_export_ms": [], "validate_ms": []}
        held = first
        for i in range(warm_iters):
            if backend == "reference":
                sample = reexport_reference(held, work / "reexports", f"{i}")
                # Re-exports skip decode/compose; record zeros for those phases.
                phase_acc["decode_ms"].append(0.0)
                phase_acc["compose_ms"].append(0.0)
                phase_acc["render_export_ms"].append(sample["phases"]["render_export_ms"]["wall_ms"])
                phase_acc["validate_ms"].append(0.0)
            else:
                sample = pipeline(scenes[0], f"warm-{i}")
                for name in phase_acc:
                    phase_acc[name].append(sample["phases"].get(name, {}).get("wall_ms", 0.0))
            warm_totals.append(sample["total_ms"])

        # warm_reload_same
        reload_samples = []
        for i in range(min(5, warm_iters)):
            row = pipeline(scenes[0], f"reload-{i}")
            reload_samples.append(row["total_ms"])

        # warm_next_scenes
        next_samples = []
        for scene in scenes:
            row = pipeline(scene, f"next-{scene}")
            next_samples.append(row["total_ms"])

        if session is not None:
            session.close()

        return {
            "worker_id": worker_id,
            "ok": True,
            "cold_start_ms": cold_ms,
            "first_pipeline_ms": first_ms,
            "warm_totals": warm_totals,
            "phase_acc": phase_acc,
            "reload_totals": reload_samples,
            "next_totals": next_samples,
            "peak_rss_mib": _rss_mib(),
            "fixture_sha256": (fixtures / "fixture_sha256").read_text().strip(),
            "validation": "PASS",
        }
    except Exception as exc:
        return {
            "worker_id": worker_id,
            "ok": False,
            "error": f"{exc}\n{traceback.format_exc()}",
            "peak_rss_mib": _rss_mib(),
            "validation": "FAIL",
        }


def cmd_run(args):
    artifacts = Path(args.artifacts)
    artifacts.mkdir(parents=True, exist_ok=True)
    fixtures_root = artifacts / "fixtures"
    fixtures = _prepare_fixtures(args.level, args.seed, fixtures_root)
    workers = args.workers
    if workers <= 0:
        workers = os.cpu_count() or 1
    pin = os.environ.get("BENCH_PIN_CPU") == "1"

    jobs = [
        (i, args.level, args.backend, fixtures, artifacts / "work", args.seed, pin)
        for i in range(workers)
    ]
    if workers == 1:
        results = [_worker_run(jobs[0])]
    else:
        with mp.Pool(workers) as pool:
            results = pool.map(_worker_run, jobs)

    (artifacts / "workers.json").write_text(json.dumps(results, indent=2) + "\n")
    if not all(r.get("ok") for r in results):
        write_report(artifacts, build_report(
            level=args.level, backend=args.backend, workers=workers,
            fixture_sha256=(fixtures / "fixture_sha256").read_text().strip(),
            environment=_env_block(args.backend),
            phases_samples={}, totals=[], peak_rss_mib=max(r.get("peak_rss_mib") or 0 for r in results),
            validation_ok=False,
            notes="One or more workers failed:\n" + "\n".join(
                r.get("error", "") for r in results if not r.get("ok")),
        ))
        print("FAIL — see workers.json", file=sys.stderr)
        return 1

    warm_totals = []
    phase_acc = {"decode_ms": [], "compose_ms": [], "render_export_ms": [], "validate_ms": []}
    for r in results:
        warm_totals.extend(r["warm_totals"])
        for k, vals in r["phase_acc"].items():
            phase_acc[k].extend(vals)

    report = build_report(
        level=args.level, backend=args.backend, workers=workers,
        fixture_sha256=results[0]["fixture_sha256"],
        environment=_env_block(args.backend),
        phases_samples=phase_acc, totals=warm_totals,
        peak_rss_mib=max(r["peak_rss_mib"] for r in results),
        validation_ok=True,
        notes=(
            f"cold_start p50≈{percentiles([r['cold_start_ms'] for r in results])['p50']:.1f} ms; "
            f"first_pipeline p50≈{percentiles([r['first_pipeline_ms'] for r in results])['p50']:.1f} ms; "
            f"reload p50≈{percentiles(sum((r['reload_totals'] for r in results), []))['p50']:.1f} ms; "
            f"next_scenes p50≈{percentiles(sum((r['next_totals'] for r in results), []))['p50']:.1f} ms."
        ),
    )
    report["cold_start_ms"] = percentiles([r["cold_start_ms"] for r in results])
    report["first_pipeline_ms"] = percentiles([r["first_pipeline_ms"] for r in results])
    write_report(artifacts, report)
    print(json.dumps({"ok": True, "p50": report["total_ms"]["p50"],
                      "throughput": report["throughput_docs_per_s"]}, indent=2))
    return 0


def cmd_pressure(args):
    """Gradually increase complexity; record RSS and latency cliffs."""
    artifacts = Path(args.artifacts)
    artifacts.mkdir(parents=True, exist_ok=True)
    steps = []
    # Synthetic ladder: regenerate SMALL-like packs with growing shape counts.
    from tests.bench.levels import LEVELS
    base = dict(LEVELS["small"])
    ceiling_rss = float(os.environ.get("BENCH_PRESSURE_RSS_MIB", "8192"))
    shapes = base["shapes"]
    duplicates = base["duplicates"]
    for step in range(12):
        level_name = f"pressure_{step}"
        # Mutate LEVELS temporarily via custom generate by writing recipe overrides.
        fixtures = artifacts / "fixtures" / level_name
        meta = generate("small", args.seed + step, fixtures)
        recipe_path = fixtures / "recipe.json"
        recipe = json.loads(recipe_path.read_text())
        recipe["shapes"] = shapes
        recipe["duplicates"] = duplicates
        recipe["texts"] = base["texts"] + step * 2
        recipe["effect_layers"] = base["effect_layers"] + step
        recipe_path.write_text(json.dumps(recipe, indent=2) + "\n")
        out = artifacts / f"step-{step}"
        t0 = time.perf_counter()
        try:
            row = run_reference_pipeline(fixtures, out, scene="A", backend="reference")
            ok = True
            err = None
            total = row["total_ms"]
        except Exception as exc:
            ok = False
            err = str(exc)
            total = (time.perf_counter() - t0) * 1000
        rss = _rss_mib()
        steps.append({
            "step": step, "shapes": shapes, "duplicates": duplicates,
            "texts": recipe["texts"], "total_ms": total, "rss_mib": rss,
            "ok": ok, "error": err,
        })
        if not ok or rss >= ceiling_rss:
            break
        shapes = int(shapes * 1.5) + 1
        duplicates = int(duplicates * 1.5) + 1

    cliff = None
    for i in range(1, len(steps)):
        prev, cur = steps[i - 1], steps[i]
        if prev["rss_mib"] > 0 and cur["rss_mib"] > prev["rss_mib"] * 1.5:
            cliff = {"at_step": cur["step"], "rss_before": prev["rss_mib"], "rss_after": cur["rss_mib"]}
            break
    payload = {"schema": "compositor.e2e_graphics_bench.pressure/1", "steps": steps, "rss_cliff": cliff}
    (artifacts / "ram_vs_complexity.json").write_text(json.dumps(payload, indent=2) + "\n")
    print(json.dumps({"ok": all(s["ok"] for s in steps), "steps": len(steps), "cliff": cliff}, indent=2))
    return 0 if all(s["ok"] for s in steps[:-1]) or steps[-1]["ok"] else 1


def cmd_soak(args):
    artifacts = Path(args.artifacts)
    artifacts.mkdir(parents=True, exist_ok=True)
    fixtures = _prepare_fixtures(args.level, args.seed, artifacts / "fixtures")
    window = 500
    held = run_reference_pipeline(fixtures, artifacts / "seed", scene="A", backend="reference")
    totals = []
    rss_series = []
    failures = 0
    for i in range(args.iters):
        try:
            sample = reexport_reference(held, artifacts / "soak", f"{i}")
            totals.append(sample["total_ms"])
            rss_series.append(_rss_mib())
        except Exception:
            failures += 1
            totals.append(float("nan"))
            rss_series.append(_rss_mib())
        if (i + 1) % window == 0:
            chunk = [t for t in totals[-window:] if t == t]
            first = [t for t in totals[:window] if t == t]
            if first and chunk:
                p50_first = percentiles(first)["p50"]
                p50_now = percentiles(chunk)["p50"]
                rss_first = max(rss_series[:window])
                rss_now = max(rss_series[-window:])
                if p50_now > p50_first * 1.15:
                    payload = {"fail": "p50_degradation", "first": p50_first, "now": p50_now, "iter": i}
                    (artifacts / "soak-fail.json").write_text(json.dumps(payload, indent=2))
                    print(json.dumps(payload, indent=2))
                    return 1
                if rss_now > rss_first * 1.10:
                    payload = {"fail": "rss_growth", "first": rss_first, "now": rss_now, "iter": i}
                    (artifacts / "soak-fail.json").write_text(json.dumps(payload, indent=2))
                    print(json.dumps(payload, indent=2))
                    return 1
    summary = {
        "schema": "compositor.e2e_graphics_bench.soak/1",
        "iters": args.iters,
        "failures": failures,
        "total_ms": percentiles([t for t in totals if t == t]),
        "peak_rss_mib": max(rss_series) if rss_series else None,
    }
    (artifacts / "soak.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"ok": failures == 0, **{k: summary[k] for k in ("iters", "failures")}}, indent=2))
    return 0 if failures == 0 else 1


def main(argv=None):
    parser = argparse.ArgumentParser(prog="tests.bench.runner")
    sub = parser.add_subparsers(dest="cmd", required=True)

    run = sub.add_parser("run", help="Cold/warm E2E with optional workers")
    run.add_argument("--level", choices=sorted(LEVELS), default="small")
    run.add_argument("--backend", choices=("reference", "host"), default="reference")
    run.add_argument("--workers", type=int, default=1)
    run.add_argument("--seed", type=int, default=DEFAULT_SEED)
    run.add_argument("--artifacts", required=True)

    pressure = sub.add_parser("pressure", help="Memory pressure ladder")
    pressure.add_argument("--seed", type=int, default=DEFAULT_SEED)
    pressure.add_argument("--artifacts", required=True)

    soak = sub.add_parser("soak", help="Long-running warm re-export soak")
    soak.add_argument("--level", choices=sorted(LEVELS), default="medium")
    soak.add_argument("--iters", type=int, default=10_000)
    soak.add_argument("--seed", type=int, default=DEFAULT_SEED)
    soak.add_argument("--artifacts", required=True)

    args = parser.parse_args(argv)
    if args.cmd == "run":
        raise SystemExit(cmd_run(args))
    if args.cmd == "pressure":
        raise SystemExit(cmd_pressure(args))
    if args.cmd == "soak":
        raise SystemExit(cmd_soak(args))
    raise SystemExit(1)


if __name__ == "__main__":
    main()
