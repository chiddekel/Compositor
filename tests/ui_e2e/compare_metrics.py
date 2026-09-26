#!/usr/bin/env python3
"""Compare two successful, matching desktop workloads. Negative deltas are better."""
import argparse
import json
from pathlib import Path


def compare(before, after):
    for report in (before, after):
        if report["failures"] or set(report["expected_cases"]) != set(report["cases"]):
            raise ValueError("Both reports must be complete and pass all correctness and metric checks")
    for key in ("schema", "cpu", "logical_cpus", "kernel", "backend_requested", "display", "workload_sha256"):
        if before["environment"][key] != after["environment"][key]:
            raise ValueError("Incompatible benchmark environment: " + key)
    if before["cases"].keys() != after["cases"].keys():
        raise ValueError("Compare runs containing the same cases")
    rows = []
    for name, old in before["cases"].items():
        new = after["cases"][name]
        if old["result"] != "PASS" or new["result"] != "PASS":
            raise ValueError("Correctness must pass before comparing speed: " + name)
        # Require identical workloads, including input cadence and brush settings.
        def workload(case):
            return [(op["name"], op["parameters"], op["completed"]) for op in case["operations"]]
        if workload(old) != workload(new):
            raise ValueError("Operation workload differs: " + name)

        def add(label, metric, a, b):
            # CPU clock ticks can yield zero for very short operations; percentages are undefined.
            rows.append((label, metric, a, b, (b / a - 1) * 100 if a else None))

        for metric in ("wall_ms", "cpu_ms", "process_lifetime_peak_rss_mib"):
            add(name, metric, old[metric], new[metric])
        for operation, group in old["operation_summary"].items():
            if operation.endswith("_warmup"):
                continue
            for metric, values in group.items():
                statistic = "p95" if metric == "release_to_observed_ms" else "median"
                add(name + "/" + operation, metric + "/" + statistic, values[statistic],
                    new["operation_summary"][operation][metric][statistic])
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--max-regression-percent", type=float,
                        help="Optional explicit gate; establish machine variance before setting a budget")
    args = parser.parse_args()
    if args.max_regression_percent is not None and args.max_regression_percent < 0:
        parser.error("Regression budget must be nonnegative")
    try:
        rows = compare(json.loads(args.baseline.read_text()), json.loads(args.candidate.read_text()))
    except (ValueError, KeyError) as error:
        parser.error(str(error))
    print("Negative changes mean less time or memory. Pixel correctness passed in both reports.\n")
    print("| Case / operation | Metric | Baseline | Candidate | Change |")
    print("| --- | --- | ---: | ---: | ---: |")
    failed = False
    for label, metric, before, after, change in rows:
        delta = f"{change:+.1f}%" if change is not None else "n/a (zero baseline)"
        print(f"| {label} | {metric} | {before:.1f} | {after:.1f} | {delta} |")
        if args.max_regression_percent is not None and change is not None and change > args.max_regression_percent:
            failed = True
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
