# Benchmark Results

These are Quipu synthetic smoke benchmark results. They are useful for
tracking current correctness and basic runtime health, but they are not a
claim of performance on external long-memory benchmarks yet.

Durations are local harness wall-clock timings, not optimized daemon latency.

- Generated: `2026-04-29T13:34:30.909997Z`
- Git commit: `73c890f+dirty`
- Suite: `evals/suites/quipu_synthetic.yaml`
- Lattice included: `true`

| Baseline | Storage | Pass | Queries | Forget Ops | Duration | LatticeDB |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `q0_raw_only_fake` | `fake` | yes | 5/5 | 1/1 | 0.5 ms | `-` |
| `core_in_memory` | `memory` | yes | 5/5 | 1/1 | 635.4 ms | `-` |
| `core_lattice` | `lattice` | yes | 5/5 | 1/1 | 484.0 ms | `0.6.0` |

## What This Covers

- Temporal current and historical fact retrieval.
- Cross-scope contamination checks.
- Evidence ID faithfulness checks.
- Preference supersession checks.
- Forgetting leakage checks for deleted strings.

## What This Does Not Cover Yet

- LoCoMo, LongMemEval, or MemoryAgentBench.
- Real provider embeddings, reranking, or LLM extraction quality.
- Long-running daemon transport latency.
- Large-store retrieval latency or storage growth.
