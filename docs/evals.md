# Evals

The eval harness starts with the shared scenario schema in `evals/suites/quipu_synthetic.yaml`. The current suite file is JSON-compatible YAML so the scaffold can load it with Python's standard library before external YAML dependencies are introduced.

Quipu reports three result classes:

- `synthetic_smoke`: small deterministic fixtures for CI and regression checks.
- `external_smoke`: tiny normalized fixtures shaped like external benchmarks.
- `publishable`: full external benchmark runs with LatticeDB storage, baselines,
  ablations, traces, verification, and reproducible manifests.

Only `publishable` reports may be used for external benchmark claims.

Run the smoke baseline with:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.runner \
  evals/suites/quipu_synthetic.yaml \
  --baseline q0_raw_only_fake \
  --output artifacts/evals/q0-results.json \
  --manifest artifacts/evals/q0-manifest.json
```

The Q0 fake baseline stores raw scenario events in memory, retrieves by scope-filtered lexical overlap, and grades exact answers, expected evidence IDs, forbidden evidence, scope leakage, and deletion leakage. It exists to keep eval fixtures executable before the daemon storage implementation is complete.

The same deterministic runner now supports the required external benchmark
baselines:

- `full_context`
- `recent_only`
- `bm25`
- `vector_rag`
- `hybrid_bm25_vector`
- `summary_only`
- `memory_cards_only`
- `graph_only`

It also supports Quipu ablation IDs `Q0` through `Q13` plus `full_quipu`.
These are deterministic fixture implementations for reproducible comparisons;
provider-backed embeddings, reranking, extraction, and judging are configured
separately from this runner.

Provider-backed semantic baselines are available through OpenRouter. The
benchmark convention used by Mem0 OSS is OpenAI `text-embedding-3-small` for
embeddings, with `gpt-4o-mini` for extraction and `gpt-4o` as the default
answerer/judge in its public runner. Quipu defaults the OpenRouter embedding
model to `openai/text-embedding-3-small` so semantic retrieval can be compared
against BM25 under the same local harness metrics.

The eval-layer semantic baselines use the provider's returned dimensionality.
The core Lattice adapter is more constrained today: with LatticeDB `0.6.0`,
persisted vectors store successfully through `1016` dimensions and fail at
`1017+`, so OpenRouter-backed core runs request 768-dimensional
`openai/text-embedding-3-small` vectors until the LatticeDB large-vector
persistence issue is fixed.

```bash
export OPENROUTER_API_KEY=...
PYTHONPATH=evals/src python3 -m quipu_evals.runner \
  evals/suites/external/locomo_mini.yaml \
  --baseline vector_rag \
  --embedding-provider openrouter \
  --embedding-cache artifacts/provider-cache/openrouter-embeddings.jsonl
```

Core benchmark runs can force the runtime retrieval path with
`--core-retrieval-mode fts|vector|hybrid|graph`. When `QUIPU_EMBEDDING_PROVIDER`
is set to `openrouter`, the core runtime defaults `memory.retrieve` to hybrid
search; without a provider, it defaults to lexical search.

Optional LLM answer and judge hooks are also wired through OpenRouter:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.runner \
  evals/suites/external/locomo_mini.yaml \
  --baseline hybrid_bm25_vector \
  --embedding-provider openrouter \
  --answer-provider openrouter \
  --judge-provider openrouter
```

Model overrides:

- `OPENROUTER_EMBEDDING_MODEL`, default `openai/text-embedding-3-small`
- `OPENROUTER_ANSWER_MODEL`, default `openai/gpt-4o`
- `OPENROUTER_JUDGE_MODEL`, default `openai/gpt-4o`
- `OPENROUTER_EMBEDDING_BATCH_SIZE`, default `32`

The in-memory core smoke baseline runs the compiled Zig process through `quipu serve-stdio`:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.core_runner \
  --strict \
  --output artifacts/evals/core-results.json \
  --manifest artifacts/evals/core-manifest.json
```

This baseline is expected to pass current-fact, historical valid-at, cross-scope, preference-update, and deletion-leak checks against the synthetic smoke suite.

The same suite can run against the optional LatticeDB adapter:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.core_runner \
  --storage lattice \
  --lattice-include /path/to/latticedb/include \
  --lattice-lib /path/to/latticedb/lib \
  --strict \
  --output artifacts/evals/lattice-results.json \
  --manifest artifacts/evals/lattice-manifest.json
```

The manifest uses `quipu.eval.run.v1` and records suite identity, runner,
storage backend, baseline, pass/fail status, aggregate metrics, and result
artifact paths.

## Benchmark Report

The benchmark collector runs the fake Q0 baseline, optional deterministic
baseline/ablation matrix, and the core runtime baseline, with optional LatticeDB
storage, then writes JSON artifacts and a markdown summary:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks \
  evals/suites/quipu_synthetic.yaml \
  --include-baselines \
  --include-ablations \
  --include-lattice \
  --lattice-include /path/to/latticedb/include \
  --lattice-lib /path/to/latticedb/lib \
  --markdown docs/benchmark-results.md
```

Use the generated report as a synthetic smoke benchmark only.

External benchmark reports also include a `publishedComparisons` table with
published reference points from other memory systems when known. These rows are
not used by the readiness gate and are not direct head-to-head claims because
answer models, judges, retrieval cutoffs, dataset slices, and methodologies
often differ.

## External Smoke

The external benchmark path starts with a normalized scenario format:

- top-level metadata names the source benchmark, dataset version, license,
  fixture format, cache environment variable, and task categories;
- scenarios contain chronological events, messages, scopes, queries, expected
  answers, expected evidence event IDs, forbidden evidence, forget operations,
  and metadata;
- all files remain JSON-compatible YAML so the current dependency-free loader
  can parse them.

LoCoMo has the first smoke fixture:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks \
  --external-benchmark locomo \
  --include-baselines \
  --include-ablations \
  --allow-failures \
  --markdown artifacts/benchmarks/locomo-smoke/report.md
```

`just benchmark-locomo-smoke` runs the same command. It validates replay,
retrieval, grading, forgetting, manifests, and the real-benchmark readiness
gate without requiring external model keys. It is not a LoCoMo score.

Full LoCoMo runs should use `--result-class publishable`, a real dataset path,
LatticeDB enabled, deterministic baselines/ablations, provider configuration,
verification status, and generated trace artifacts. LongMemEval and
MemoryAgentBench remain next adapters.

For full runs, `--skip-core` omits the redundant in-memory core pass while
still allowing the LatticeDB core pass when `--include-lattice` is set.
`--reuse-existing` resumes from completed per-run result/manifest artifacts in
the output directory, which is useful after an interrupted full benchmark.

## Real LoCoMo Dataset

Quipu can normalize the upstream SNAP LoCoMo `data/locomo10.json` file directly:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks \
  /path/to/locomo10.json \
  --external-benchmark locomo \
  --result-class publishable \
  --include-baselines \
  --include-ablations \
  --include-lattice \
  --require-lattice \
  --skip-core \
  --reuse-existing \
  --allow-failures \
  --markdown artifacts/benchmarks/locomo-full/report.md
```

For a quick backend check against the real file without a full run:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks \
  /path/to/locomo10.json \
  --external-benchmark locomo \
  --locomo-max-conversations 1 \
  --locomo-max-questions 5 \
  --allow-failures
```

The normalizer writes `normalized-locomo-suite.json` into the benchmark artifact
directory. Dataset downloads and caches belong under `QUIPU_DATASET_CACHE`,
`.quipu-datasets/`, or another ignored local path.
