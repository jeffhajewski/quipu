# Benchmark Results

These are Quipu synthetic smoke benchmark results. They are useful for
tracking current correctness and basic runtime health, but they are not a
claim of performance on external long-memory benchmarks yet.

Durations are local harness wall-clock timings, not optimized daemon latency.

- Generated: `2026-05-06T04:56:44.504137Z`
- Git commit: `804fe53+dirty`
- Result class: `synthetic_smoke`
- External benchmark: `-`
- Dataset: `quipu_synthetic` `0.1.0`
- Suite: `evals/suites/quipu_synthetic.yaml`
- Lattice included: `false`

| Baseline | Storage | Pass | Queries | Forget Ops | Duration | LatticeDB |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `q0_raw_only_fake` | `fake` | yes | 5/5 | 1/1 | 4496.9 ms | `-` |
| `core_in_memory` | `memory` | yes | 5/5 | 1/1 | 5188.4 ms | `-` |

## Real Benchmark Readiness Gate

Status: `not_ready`

| Requirement | Pass |
| --- | ---: |
| External dataset adapter | no |
| Full external dataset | no |
| Replay into daemon | yes |
| Lattice-backed storage | no |
| Retrieval traces | yes |
| Answer generation | yes |
| Grading | yes |
| Required baselines | no |
| Quipu ablations | no |
| Verification pass | no |
| Reproducible report and manifests | yes |

## What This Covers

- Temporal current and historical fact retrieval.
- Cross-scope contamination checks.
- Evidence ID faithfulness checks.
- Preference supersession checks.
- Forgetting leakage checks for deleted strings.

## What This Does Not Cover Yet

- Publishable LoCoMo, LongMemEval, or MemoryAgentBench results.
- Real provider embeddings, reranking, or LLM extraction quality.
- Long-running daemon transport latency.
- Large-store retrieval latency or storage growth.
