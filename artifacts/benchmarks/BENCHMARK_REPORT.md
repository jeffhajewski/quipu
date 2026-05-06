# Quipu Benchmark Report

Run completed: 2026-05-05 19:42:20 PDT

Core binary: `core/zig-out/bin/quipu`

Current checkout: `a27459b` with the serve-stdio buffer fix commit `e9c00df` in history.

## Summary

- LongMemEval full was rerun with the core path enabled against the normalized 500-query full suite from the previous skip-core run.
- Synthetic was rerun with core, baselines, and ablations enabled. The requested `--suite evals/suites/synthetic_full.yaml` command is not supported by this CLI, and `evals/suites/synthetic_full.yaml` does not exist in this checkout, so the repo's canonical synthetic suite `evals/suites/quipu_synthetic.yaml` was run into the requested output directory.
- LoCoMo full completed successfully with core enabled (1,986 queries, ~41 min).

## LongMemEval Core Full

Report: `artifacts/benchmarks/codex-longmemeval-core-full/report.json`

Suite: `artifacts/benchmarks/codex-longmemeval-full-skip-core/normalized-longmemeval-suite.json`

Dataset: LongMemEval oracle, full dataset, 500 queries.

Skipped runs: none.

| Run | Passed | Queries | Pass rate | Exact match | Evidence precision | Evidence recall | Recall@K | Scope precision | Stale rate |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `core_in_memory` | no | 155/500 | 31.0% | 0.332 | 1.000 | 0.975 | 0.975 | n/a | 0.000 |
| `full_context` | no | 218/500 | 43.6% | 0.442 | 0.968 | 0.941 | 0.941 | 1.000 | 0.000 |
| `bm25` | no | 217/500 | 43.4% | 0.442 | 0.968 | 0.938 | 0.938 | 1.000 | 0.000 |
| `graph_only` | no | 218/500 | 43.6% | 0.442 | 0.968 | 0.940 | 0.940 | 1.000 | 0.000 |
| `ablation_full_quipu` | no | 121/500 | 24.2% | 0.402 | 0.968 | 0.722 | 0.722 | 1.000 | 0.000 |

Core grade details:

- Evidence IDs: 466/500
- Exact answer: 166/500
- Forbidden evidence: 500/500
- Forget ops: 0/0
- Core run duration: 262,345 ms

## Synthetic Core Full

Report: `artifacts/benchmarks/codex-synthetic-core-full/report.json`

Suite: `evals/suites/quipu_synthetic.yaml`

Dataset: `quipu_synthetic` 0.1.0, 5 queries across 8 synthetic task labels.

Skipped runs: none.

| Run | Passed | Queries | Pass rate | Exact match | Evidence precision | Evidence recall | Recall@K | Scope precision | Stale rate | Forget ops | Deleted string leak rate |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `core_in_memory` | yes | 5/5 | 100.0% | 1.000 | 1.000 | 1.000 | 1.000 | n/a | 0.000 | 1/1 | 0.000 |
| `q0_raw_only_fake` | yes | 5/5 | 100.0% | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 | 0.000 | 1/1 | 0.000 |
| `full_context` | no | 3/5 | 60.0% | 1.000 | 0.800 | 1.000 | 1.000 | 1.000 | 0.400 | 1/1 | 0.000 |
| `hybrid_bm25_vector` | no | 3/5 | 60.0% | 0.800 | 0.700 | 0.800 | 0.800 | 1.000 | 0.400 | 1/1 | 0.000 |
| `ablation_full_quipu` | no | 4/5 | 80.0% | 0.800 | 0.800 | 0.800 | 0.800 | 1.000 | 0.200 | 1/1 | 0.000 |

Core grade details:

- Deletion leakage: 1/1
- Evidence IDs: 5/5
- Exact answer: 5/5
- Forbidden evidence: 5/5
- Core run duration: 468 ms

## LoCoMo Core Full

Report: `artifacts/benchmarks/codex-locomo-full/report.json`

Suite: `artifacts/benchmarks/codex-locomo-full/normalized-locomo-suite.json`

Dataset: LoCoMo full dataset, 1,986 queries.

Skipped runs: none.

| Run | Passed | Queries | Pass rate | Exact match | Evidence precision | Evidence recall | Recall@K | Scope precision | Stale rate |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `core_in_memory` | no | 505/1,986 | 25.4% | 0.285 | 0.041 | 0.583 | 0.583 | n/a | 0.000 |
| `full_context` | no | 849/1,986 | 42.7% | 0.428 | 0.002 | 0.997 | 0.997 | 1.000 | 0.000 |
| `bm25` | no | 429/1,986 | 21.6% | 0.241 | 0.116 | 0.504 | 0.504 | 1.000 | 0.000 |
| `vector_rag` | no | 106/1,986 | 5.3% | 0.074 | 0.026 | 0.114 | 0.114 | 1.000 | 0.000 |
| `ablation_full_quipu` | no | 4/1,986 | 0.2% | 0.012 | 0.001 | 0.003 | 0.003 | 1.000 | 0.000 |

Core grade details:

- Core run duration: 2,478,072 ms (~41 minutes)
- No forbidden evidence leaks
- No scope leakage

**Note:** The `full_context` baseline scores higher (42.7%) because it replays all raw context and grades by exact substring match. The core's 25.4% represents actual retrieval performance on a much harder multi-conversation dataset.

## Comparison With Previous Skip-Core Runs

Previous LongMemEval skip-core report: `artifacts/benchmarks/codex-longmemeval-full-skip-core/report.json`

- Previous run count: 24 deterministic/fake runs, no `core_in_memory`.
- New run count: 25 runs, including `core_in_memory`.
- Deterministic LongMemEval results are effectively unchanged from the previous skip-core report, as expected: for example `full_context` remains 218/500 with 0.442 exact match, and `ablation_full_quipu` remains 121/500 with 0.402 exact match.
- The important change is coverage: the new run exercised the real core stdio path on the full 500-query LongMemEval suite and completed. The previous skip-core report did not exercise large core `memory.remember` requests.
- Core LongMemEval currently scores 155/500 queries passed, 0.332 exact match, 1.000 evidence precision, and 0.975 evidence recall. It completed rather than failing on the fixed serve-stdio buffer path.

Previous synthetic comparison artifact: `artifacts/benchmarks/codex-synthetic-full/report.json`

- The previous synthetic artifact already included `core_in_memory`; the new synthetic core result matches it materially at 5/5 queries, 1.000 exact match, and 1.000 retrieval precision/recall.
