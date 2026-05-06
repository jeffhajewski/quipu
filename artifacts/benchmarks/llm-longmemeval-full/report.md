# External Benchmark Results

These are Quipu external benchmark run artifacts. The readiness gate
below determines whether the run is publishable; do not cite numbers as
benchmark claims unless the gate status is ready.

Durations are local harness wall-clock timings, not optimized daemon latency.

- Generated: `2026-05-06T06:29:31.542025Z`
- Git commit: `e5de381`
- Result class: `publishable`
- External benchmark: `longmemeval`
- Dataset: `LongMemEval` `xiaowu0162/longmemeval-cleaned longmemeval_oracle.json`
- Suite: `artifacts/benchmarks/llm-longmemeval-full/normalized-longmemeval-suite.json`
- Lattice included: `true`

| Baseline | Storage | Pass | Queries | Forget Ops | Duration | LatticeDB |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `q0_raw_only_fake` | `fake` | no | 96/500 | 0/0 | 635018.2 ms | `-` |
| `full_context` | `deterministic` | no | 218/500 | 0/0 | 593335.7 ms | `-` |
| `recent_only` | `deterministic` | no | 203/500 | 0/0 | 164055.6 ms | `-` |
| `bm25` | `deterministic` | no | 217/500 | 0/0 | 25746.2 ms | `-` |
| `vector_rag` | `deterministic` | no | 164/500 | 0/0 | 121690.9 ms | `-` |
| `hybrid_bm25_vector` | `deterministic` | no | 152/500 | 0/0 | 101556.1 ms | `-` |
| `summary_only` | `deterministic` | no | 217/500 | 0/0 | 295996.2 ms | `-` |
| `memory_cards_only` | `deterministic` | no | 217/500 | 0/0 | 284198.9 ms | `-` |
| `graph_only` | `deterministic` | no | 218/500 | 0/0 | 14756.5 ms | `-` |
| `Q0` | `deterministic` | no | 96/500 | 0/0 | 128229.9 ms | `-` |
| `Q1` | `deterministic` | no | 217/500 | 0/0 | 606.3 ms | `-` |
| `Q2` | `deterministic` | no | 217/500 | 0/0 | 271266.7 ms | `-` |
| `Q3` | `deterministic` | no | 164/500 | 0/0 | 997.4 ms | `-` |
| `Q4` | `deterministic` | no | 217/500 | 0/0 | 603.7 ms | `-` |
| `Q5` | `deterministic` | no | 152/500 | 0/0 | 1434.8 ms | `-` |
| `Q6` | `deterministic` | no | 218/500 | 0/0 | 3862.5 ms | `-` |
| `Q7` | `deterministic` | no | 218/500 | 0/0 | 3858.5 ms | `-` |
| `Q8` | `deterministic` | no | 217/500 | 0/0 | 602.6 ms | `-` |
| `Q9` | `deterministic` | no | 120/500 | 0/0 | 23906.0 ms | `-` |
| `Q10` | `deterministic` | no | 140/500 | 0/0 | 19841.8 ms | `-` |
| `Q11` | `deterministic` | no | 140/500 | 0/0 | 11209.7 ms | `-` |
| `Q12` | `deterministic` | no | 152/500 | 0/0 | 135417.2 ms | `-` |
| `Q13` | `deterministic` | no | 120/500 | 0/0 | 1706.8 ms | `-` |
| `full_quipu` | `deterministic` | no | 121/500 | 0/0 | 163160.0 ms | `-` |
| `core_in_memory` | `memory` | no | 103/500 | 0/0 | 1179683.8 ms | `-` |
| `core_lattice` | `lattice` | no | 0/500 | 0/0 | 1418.4 ms | `0.7.0` |

## Real Benchmark Readiness Gate

Status: `not_ready`

| Requirement | Pass |
| --- | ---: |
| External dataset adapter | yes |
| Full external dataset | yes |
| Replay into daemon | yes |
| Lattice-backed storage | yes |
| Retrieval traces | yes |
| Answer generation | yes |
| Grading | yes |
| Required baselines | yes |
| Quipu ablations | yes |
| Verification pass | no |
| Reproducible report and manifests | yes |

## Published External Reference Points

These are published external results from other systems. They use different answer models, judges, retrieval cutoffs, dataset slices, and sometimes disputed methodologies; use them as orientation, not an apples-to-apples ranking unless the full methodology is aligned.

| System | Benchmark | Score | Metric | Dataset | Source |
| --- | --- | ---: | --- | --- | --- |
| Mem0 Platform v3 top-200 | longmemeval | 93.4 | pass_rate_percent | LongMemEval 500 questions | [mem0ai/memory-benchmarks README](https://github.com/mem0ai/memory-benchmarks) |
| Mem0 Platform v3 top-50 | longmemeval | 90.4 | pass_rate_percent | LongMemEval 500 questions | [mem0ai/memory-benchmarks README](https://github.com/mem0ai/memory-benchmarks) |

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
