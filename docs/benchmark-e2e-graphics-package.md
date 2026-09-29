# E2E graphics package benchmark

CI-grade end-to-end benchmark for Compositor’s graphics pipeline. It measures a full
production-shaped workflow — not microbenchmarks of single functions — and refuses to
treat a faster, incorrect render as a win.

Implementation lives under [`tests/bench/`](../tests/bench/). The interactive UI E2E
satellite is [`bench_e2e_graphics_2k`](../tests/ui_e2e/bench_cases.py) (SMALL, non-gating
until stable).

## Architecture

| Harness | Role |
| --- | --- |
| **Engine** (`tests/bench`) | Primary. Deterministic fixtures → scene build → full-resolution export → validate. Supports cold/warm, workers, pressure, soak. |
| **UI E2E** | Secondary. Xephyr/Xvfb path for SMALL interactive fidelity (import, PPI, draw, save). |

Workers are **separate OS processes** (one Host or one reference pipeline each).

Document PPI: SMALL default 72 (UI satellite may set 300); MEDIUM/STRESS use **300**.

## Scenario phases

Every level runs the same phase machine; counts and sizes scale.

1. Input assets → decode/load  
2. Document creation @ W×H × PPI  
3. Composition (blend modes, opacity)  
4. Transforms (translate / scale / rotate)  
5. Text rendering (mixed faces)  
6. Vector (shapes + gradients)  
7. Bitmap processing (strokes / soft edges)  
8. Masks / clipping  
9. Transparency / blending  
10. Filters / effects  
11. Resize / crop (metadata PPI and/or bounds)  
12. Final render → encode/export → disk  
13. Result validation  

Phase timings: `decode_ms`, `compose_ms`, `render_export_ms`, `validate_ms`, `total_ms`.

## Dataset levels

Generator (committed seed + code; CI regenerates bytes):

```sh
python3 tests/bench/fixtures/generate.py --seed 20260929 --level small
python3 tests/bench/fixtures/generate.py --seed 20260929 --level medium
python3 tests/bench/fixtures/generate.py --seed 20260929 --level stress
```

| Level | Canvas | Objects (approx.) | Bitmaps | PPI |
| --- | --- | --- | --- | --- |
| SMALL | 1920×1080 | ~15 | 3 × ≤1k | 72 |
| MEDIUM | 3840×2160 | ~200–400 | 12 × ≤2k | 300 |
| STRESS | 3840×2160 or 7680×4320 | ≥2k | 24 × ≤4k | 300 |

Reports embed `fixture_sha256` for the generated pack.

## Cold / warm protocol

Per worker, in order (never averaged together):

1. `cold_start` — process spawn → ready  
2. `first_pipeline` — first full E2E on scene A  
3. `warm_same_scene` — re-export scene A (30–100 measured iters)  
4. `warm_reload_same` — rebuild identical scene from fixtures  
5. `warm_next_scenes` — rotate scenes A→B→C  

Wall times include harness overhead; they are **not** GPU frame time.

## Concurrency

`workers ∈ {1, 2, 4, 8, cpu_count}` (PR capped at 8). Each worker gets an exclusive
fixture copy and output directory. Report aggregate throughput and per-worker percentiles.

Run CPU-only and `COMPOSITOR_FORCE_GPU` matrices separately when comparing backends.

## Metrics schema

`compositor.e2e_graphics_bench/2` JSON:

- Totals and phases: min, mean, **p50, p95, p99**, max, n  
- `throughput_docs_per_s`  
- CPU ms / %, peak RSS MiB  
- `export_bytes`, `pixels_processed`  
- Optional GPU block (`gpu_util_pct`, `vram_mib`, …) when tools exist  

Environment lock: machine class, CPU, logical CPUs, backend, binary hash, fixture hash.

## Memory pressure

`python3 -m tests.bench.runner pressure --level small` grows object/bitmap/layer counts
until a ceiling or OOM. Emits `ram_vs_complexity.json` and flags RSS cliffs.

## Soak

Nightly: ≥10 000 warm MEDIUM exports (or reduced STRESS). Sliding window of 500:

- Fail if window p50 rises **>15%** vs first window  
- Fail if peak RSS rises **>10%** with unchanged complexity  
- Fail on any validation error or crash  

## Validation

Every measured iteration must pass before its timing enters percentiles:

| Check | Rule |
| --- | --- |
| Format / size | PNG, exact W×H |
| PPI | Manifest / recipe resolution matches level |
| SSIM vs golden | ≥ **0.995** (CPU/reference), ≥ **0.990** (GPU) |
| Pixel budget | max abs channel Δ ≤ 3 on ≤ 0.1% of pixels |

Update goldens only with `BENCH_UPDATE_GOLDEN=1` and review.

## Measurement hygiene

- Discard 1 cold + 3 pipeline warm-ups  
- Measured: ≥50 SMALL, ≥30 MEDIUM, ≥15 STRESS (if wall-clock limited)  
- Optional `BENCH_PIN_CPU=1` (taskset)  
- Release builds only; idle machine for baselines  

## Report

Markdown + JSON table:

`Scenario | Input | Workers | E2E p50 | p95 | p99 | Throughput | Peak RAM | CPU | GPU | Validation`

Charts (when matplotlib is available): latency vs complexity, throughput vs concurrency,
RAM vs complexity, soak degradation.

### Interpreting results

| Signal | Likely cause |
| --- | --- |
| Throughput flat, CPU idle | Lock, disk, or GPU serial section |
| Throughput flat, CPU saturated | Shared resource (IO / single GPU) |
| Cold ≫ warm | Cache / lazy init / shader / font cost |
| Soak p50 or RSS climb | Leak or fragmentation |
| Faster but SSIM fail | Incorrect optimization — do not ship |

## CI regression thresholds

| Lane | Workload | Fail when |
| --- | --- | --- |
| PR | SMALL + MEDIUM warm, 1 worker | validation fail; **p50 > baseline × 1.20**; **peak RSS > baseline × 1.25** |
| Nightly | STRESS + concurrency + soak | **p50 > baseline × 1.15**; soak rules; crash |
| UI E2E SMALL | satellite | publish artifacts; non-gating until marked stable |

Baselines: [`tests/bench/baselines/`](../tests/bench/baselines/).

## How to run

```sh
# Generate fixtures
python3 tests/bench/fixtures/generate.py --seed 20260929 --level small --out /tmp/bench-fixtures

# Reference engine (no Host required) — methodology + CI smoke
python3 -m tests.bench.runner run --backend reference --level small --workers 1 \
  --artifacts /tmp/bench-out

# Compare against baseline
python3 -m tests.bench.report compare \
  tests/bench/baselines/ci-linux-x86_64.json /tmp/bench-out/report.json \
  --max-regression-percent 20

# Host-backed (requires built CompositorHost + Xvfb)
COMPOSITOR_BENCH_ALLOW_COMMANDS=1 \
  python3 -m tests.bench.runner run --backend host --level small \
  --artifacts /tmp/bench-host

# Pressure / soak
python3 -m tests.bench.runner pressure --backend reference --artifacts /tmp/bench-pressure
python3 -m tests.bench.runner soak --backend reference --iters 10000 --artifacts /tmp/bench-soak
```

Shell wrapper: [`scripts/run-graphics-bench.sh`](../scripts/run-graphics-bench.sh).

## Operator notes

- Prefer sequential runs; do not overlap with UI E2E or other heavy jobs.  
- Re-seed baselines only after intentional workload or machine-class changes.  
- GPU numbers are best-effort; absence of GPU tools is recorded as `gpu: unavailable`, not a pass.  
