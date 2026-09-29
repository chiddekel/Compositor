"""Percentile helpers shared by the graphics package benchmark."""
from __future__ import annotations

import math
import statistics


def percentiles(values):
    ordered = sorted(values)
    if not ordered:
        return None

    def pct(p):
        rank = max(1, math.ceil(p / 100 * len(ordered)))
        return ordered[rank - 1]

    return {
        "n": len(ordered),
        "min": ordered[0],
        "mean": statistics.fmean(ordered),
        "p50": pct(50),
        "p95": pct(95),
        "p99": pct(99),
        "max": ordered[-1],
    }


def flag_outliers(values, stats=None):
    """Return indices whose value exceeds p99 (for analysis; do not silently drop)."""
    stats = stats or percentiles(values)
    if not stats:
        return []
    return [i for i, v in enumerate(values) if v > stats["p99"]]
