"""Load-level definitions for the E2E graphics package benchmark."""

LEVELS = {
    "small": {
        "name": "SMALL",
        "width": 1920,
        "height": 1080,
        "ppi": 72,
        "bitmaps": 3,
        "bitmap_side": 768,
        "shapes": 4,
        "texts": 3,
        "effect_layers": 2,
        "duplicates": 2,
        "scenes": ["A", "B", "C"],
        "warm_iters": 50,
        "warmup_pipelines": 3,
    },
    "medium": {
        "name": "MEDIUM",
        "width": 3840,
        "height": 2160,
        "ppi": 300,
        "bitmaps": 12,
        "bitmap_side": 1536,
        "shapes": 80,
        "texts": 40,
        "effect_layers": 24,
        "duplicates": 120,
        "scenes": ["A", "B", "C"],
        "warm_iters": 30,
        "warmup_pipelines": 3,
    },
    "stress": {
        "name": "STRESS",
        "width": 3840,
        "height": 2160,
        "ppi": 300,
        "bitmaps": 24,
        "bitmap_side": 2048,
        "shapes": 800,
        "texts": 400,
        "effect_layers": 200,
        "duplicates": 800,
        "scenes": ["A", "B", "C"],
        "warm_iters": 15,
        "warmup_pipelines": 3,
        # Optional 8K stress override via env BENCH_STRESS_8K=1
        "width_8k": 7680,
        "height_8k": 4320,
    },
}

GENERATOR_VERSION = 1
DEFAULT_SEED = 20260929
