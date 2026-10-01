# Evals

The controlled architecture study is specified in
[`memory-experiments.md`](memory-experiments.md): raw versus assertion retrieval,
predicate histories, selective resolution, and disposable summaries. These
experiments are separate from the deterministic fixture ablations below.

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

Core graph runs can populate the entity graph before retrieval by passing
`--core-entity-provider deterministic` or `--core-entity-provider openrouter`
to the benchmark runner. The harness replays each scenario into a persistent
core DB, runs `quipu jobs run entity-resolve`, then reopens the DB for graph
retrieval. The worker writes stable `Entity` nodes and `MENTIONS` edges, so
graph mode remains reproducible and inspectable.

As of the current LatticeDB `0.6.0` integration, LoCoMo graph+ER is smoke-tested
but the full LoCoMo graph+ER pass is blocked by LatticeDB failures observed on
large-message writes, stream rereads during worker processing, and
`lattice_close` deinit after write-heavy runs. Keep full publishable claims on
the last generated full LoCoMo raw/hybrid reports until those LatticeDB issues
are fixed and a new full graph+ER report is generated.

Optional LLM answer and judge hooks use the unified provider IDs documented in
[`docs/providers.md`](providers.md). OpenRouter remains supported for
embeddings and as a universal answer/judge provider:

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
- `QUIPU_LLM_MODEL` and `QUIPU_JUDGE_MODEL` for generic provider clients
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

LoCoMo and LongMemEval have smoke fixtures:

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

`just benchmark-longmemeval-smoke` runs the same path against a small
LongMemEval-shaped timestamped chat fixture. It is not a LongMemEval score.

The synthesis lab at
`evals/suites/external/longmemeval_synthesis_lab.yaml` is a larger handwritten
LongMemEval-flavored regression gate for answer synthesis. It contains 48
queries over abstention, preferences, temporal reasoning, multi-session
aggregation, knowledge updates, user-only evidence, assistant-only evidence,
aliases, and scope conflicts. Use `just benchmark-synthesis-lab-retrieval` to
check retrieval/evidence cheaply, then `just benchmark-synthesis-lab-answer` to
exercise LatticeDB graph retrieval with provider-backed answering and
`abstainIfWeak`.

Note on the synthesis lab: the daemon no longer has extractor rules or answer
slot gates keyed to this lab's fixture sentences (Denver trip, Orion, Alpha/Beta
sprints, retreat tickets, and so on). Those rules were benchmark-specific and
have been removed. The lab now measures the general path: raw evidence plus the
`memory.answer` reader, with heuristic aggregation no longer short-circuiting
the model. Its scores are not comparable with runs from before this change, and
the deterministic (no-provider) answer path is expected to score low on it. The
suite is kept as a smoke test for the reader path.

Failure reports can be generated from a benchmark directory or result JSON:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.analyze_answer_failures \
  artifacts/benchmarks/synthesis-lab-answer \
  --suite evals/suites/external/longmemeval_synthesis_lab.yaml \
  --json-output artifacts/benchmarks/synthesis-lab-answer/failures.json \
  --markdown-output artifacts/benchmarks/synthesis-lab-answer/failures.md
```

Full LoCoMo runs should use `--result-class publishable`, a real dataset path,
LatticeDB enabled, deterministic baselines/ablations, provider configuration,
verification status, and generated trace artifacts. Full LongMemEval runs use
the same readiness requirements. MemoryAgentBench remains a planned adapter.

The deterministic baseline and ablation matrix does not call an answer model.
It grades exact answers found in the retrieved prompt, which is useful for
synthetic fixtures but can under-score real datasets whose answers require
reasoning or synthesis. To verify core-based answering on real-style fixtures,
run the core path with `--core-answer-method answer --core-answer-provider
openrouter`, or run `quipu_evals.core_runner` with `--answer-method answer
--answer-provider openai|anthropic|google|openrouter|ollama|custom`. This
provider-backed path requires the selected provider's API key unless using a
local provider such as Ollama; without that key, skipped or absent LLM-answer
runs are expected.

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
  --core-retrieval-mode graph \
  --core-entity-provider deterministic \
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

## Real LongMemEval Dataset

Quipu can normalize the official cleaned LongMemEval files released by
`xiaowu0162/longmemeval-cleaned`:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks \
  --external-benchmark longmemeval \
  --download-longmemeval \
  --longmemeval-variant oracle \
  --result-class publishable \
  --include-baselines \
  --include-ablations \
  --include-lattice \
  --require-lattice \
  --skip-core \
  --core-retrieval-mode graph \
  --core-entity-provider deterministic \
  --reuse-existing \
  --allow-failures \
  --markdown artifacts/benchmarks/longmemeval-full/report.md
```

For a quick real-file normalization check, add
`--longmemeval-max-conversations 5`. The normalizer writes
`normalized-longmemeval-suite.json` into the benchmark artifact directory.

## SOTA sprint harness

`quipu_evals.sota_longmemeval` measures the daemon itself on a frozen
LongMemEval-S development slice, so its numbers are comparable with the E1
prototype and, loosely, with published LongMemEval-S work. It replaces the old
LongMemEval core runs for this purpose. Those used the easier oracle variant,
and their pass rule required exact substring containment, the judge, *and* full
evidence recall.

**Slice.** [`evals/experiments/sota-dev-selection.json`](../evals/experiments/sota-dev-selection.json)
holds 70 question IDs. There are 10 per category: single-session user,
assistant and preference, multi-session, knowledge-update, temporal-reasoning,
and abstention (`_abs`). The seed is `quipu-sota-dev-20261001`. E1's 56 spent
questions and their ordinary/`_abs` families are excluded, and the slice takes
at most one question per family. It is development data: tune on it, and never
report it as held-out.

**Pipeline.**

- *Isolation.* Each question gets its own daemon (`serve-stdio`) with a fresh
  store: the in-memory build per process, or a new `--db` per question with
  `--lattice`. `HOME` and the working directory are a temp directory, so no
  `~/.quipu` config or default DB leaks in.
- *Provider keys.* The daemon never receives a provider key. Its answer
  provider, and with `--embedding-provider-via-proxy` its embedding provider,
  point at a local caching proxy, `quipu_evals.caching_proxy`, at
  `http://127.0.0.1:PORT/q/<questionId>/v1/...`. The proxy injects the
  OpenRouter key and caches by a hash of the endpoint plus the canonical request
  body. It logs usage, cost and latency per question, and refuses new upstream
  calls past `--max-spend-usd`.
- *Ingest.* `memory.remember` runs once per haystack session, in date order. The
  `sessionId` is anonymized as `s01`, `s02`…, because upstream IDs reveal
  evidence sessions. Every message carries the session timestamp, keeps its
  order, and is stripped as in E1. Empty turns are dropped.
- *Answer.* `memory.answer` receives `time.validAt` = question date, an
  explicit `budgetTokens`, and `includeDebug`/`includeEvidence`. The daemon's own
  answer path calls the reader model.
- *Judge.* Grading uses the official LongMemEval judge only: E1's
  `official_judge`, the pinned upstream `get_anscheck_prompt`, and
  GPT-4o-2024-08-06 at temperature 0. Runtime and judge errors are counted as
  errors and reported as a completion rate, never as wrong answers.

**Metrics** are reported per question, overall, and per category at each budget:

- judge correctness;
- gold-session and gold-turn coverage of the reader context. Item qids, chunk
  evidence and derived-item evidence are mapped to (session, turn) through the
  `messageQids` that `memory.remember` returns, then scored against LongMemEval
  `has_answer` turns. A raw-items-only variant is also recorded;
- reader-context tokens with `o200k_base`, counted over `prompt` when the daemon
  returns it, else over the daemon's `promptFromContext` rendering of `context`;
- ingest time and answer latency (p50/p95);
- LLM calls and cost from the proxy;
- a coarse wrong-answer attribution: no LLM call, retrieval miss, partial
  retrieval, or full coverage but a wrong reader.

Run from the repository root. From a worktree, set `QUIPU_ARTIFACTS` to the
main checkout's `artifacts/` directory. `OPENROUTER_API_KEY` must be set. The
module defaults resolve the dataset, E1 splits and upstream evaluator under
`$QUIPU_ARTIFACTS/experiments/`.

```bash
export QUIPU_ARTIFACTS=${QUIPU_ARTIFACTS:-$PWD/artifacts}
A=$QUIPU_ARTIFACTS
PY=$A/experiments/venv/bin/python                     # has tiktoken
export TIKTOKEN_CACHE_DIR=$A/experiments/tokenizer-cache PYTHONPATH=evals/src

# Frozen slice (already committed; this reproduces it byte-for-byte).
python3 -m quipu_evals.sota_longmemeval select

# Build a daemon. The in-memory build is full-text only.
python3 -m quipu_evals.sota_longmemeval build --out $A/sota/bin/baseline-a583bdc
# Lattice + embeddings, once the LatticeDB port lands:
python3 -m quipu_evals.sota_longmemeval build --lattice \
  --lattice-include /path/to/latticedb/zig-out/include \
  --lattice-lib /path/to/latticedb/zig-out/lib --out $A/sota/bin/<name>

# Daemon run: both budgets, 8 parallel daemons, report in $A/sota/<run-name>/.
$PY -m quipu_evals.sota_longmemeval run \
  --daemon-binary $A/sota/bin/baseline-a583bdc/bin/quipu \
  --run-name daemon-baseline-a583bdc --budgets 1024,4096 --workers 8
# Lattice runs add: --lattice --embedding-provider-via-proxy [--vector-dimensions N] [--db-dir DIR]
# Diagnostics: --needs raw, --mode fts|vector|hybrid|graph, --no-extract, --daemon-arg X

# E1 raw-arm reference on the same slice (the parity target).
python3 -m quipu_evals.longmemeval_study prepare \
  --dataset $A/experiments/upstream/longmemeval_s_cleaned.json \
  --selection evals/experiments/sota-dev-selection.json --output $A/sota/e1-splits
$PY -m quipu_evals.longmemeval_study evaluate --suite $A/sota/e1-splits/sota-dev.json \
  --cache $A/sota/cache/study --output $A/sota/e1-raw-reference \
  --arms raw --budgets 1024 4096 --workers 8 \
  --upstream $A/experiments/LongMemEval-upstream/src/evaluation/evaluate_qa.py
$PY -m quipu_evals.sota_longmemeval summarize-e1 --report $A/sota/e1-raw-reference/report.json

# Paired comparison, B versus A: wins/losses, exact McNemar p, bootstrap 95%.
$PY -m quipu_evals.sota_longmemeval compare \
  --a $A/sota/e1-raw-reference/report.json \
  --b $A/sota/daemon-baseline-a583bdc/report.json --output $A/sota/compare-baseline-vs-e1
```

The same steps are available as `just sota-test`, `just sota-build <name>`,
`just sota-run <name> <run-name> [flags]`, `just sota-e1-reference` and
`just sota-compare <a> <b> <out>`.

Each run directory contains:

- `manifest.json`: harness git commit and dirty flag, binary SHA256 and
  `build-info.json`, models, seed, and selection/dataset/grader hashes;
- `cases/<qid>.json`: full contexts, item references, answer traces and
  judgments;
- `proxy.jsonl`, the per-request provider log;
- `logs/<qid>.stderr`;
- `report.json` and `report.md`.

Reruns reuse per-question results whose configuration hash matches; pass
`--fresh` to recompute. Identical provider requests are served from
`$A/sota/cache/` at no cost. `--offline` serves cache hits only. Caches and
reports may contain benchmark text. Keep them in ignored `artifacts/`.

### Day-1 baseline, October 1, 2026

**Setup.**

- *Daemon.* Unchanged core at `a583bdc`, built in-memory
  (`-Denable-lattice=false`, ReleaseSafe), so retrieval is full-text only. It
  runs with the daemon defaults (`extract: true`, no `needs`). Its own answer
  path calls GPT-4o-mini-2024-07-18.
- *E1 reference.* The prototype's raw arm on the same 70 questions, with the
  same reader model, judge and budgets. This is the parity target.
- *`needs=raw`.* A diagnostic run of the same binary through the daemon's raw
  lexical path.

Each count is correct answers out of 70, graded by the official judge. All
three runs completed 70/70.

| Run | 1,024 tokens | 4,096 tokens | Gold-turn coverage | Gold-session coverage | Mean context tokens | LLM-answered |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| E1 raw reference | 49 (70.0%) | 52 (74.3%) | 80.6% / 86.5% | 90.8% / 96.2% | 999 / 4,076 | 100% |
| Daemon baseline | 0 (0.0%) | 0 (0.0%) | 1.1% / 3.6% | 18.2% / 44.7% | 858 / 3,409 | 40% / 39% |
| Daemon, `needs=raw` | 7 (10.0%) | 14 (20.0%) | 22.5% / 29.4% | 44.6% / 67.9% | 849 / 3,464 | 34% / 39% |

Correct answers per category, out of 10, at 1,024 / 4,096 tokens:

| Category | E1 raw | Daemon | Daemon `needs=raw` |
| --- | ---: | ---: | ---: |
| Abstention | 9 / 9 | 0 / 0 | 0 / 0 |
| Knowledge update | 5 / 6 | 0 / 0 | 1 / 2 |
| Multi-session | 3 / 2 | 0 / 0 | 2 / 0 |
| Single-session assistant | 9 / 9 | 0 / 0 | 1 / 1 |
| Single-session preference | 5 / 7 | 0 / 0 | 1 / 3 |
| Single-session user | 9 / 10 | 0 / 0 | 1 / 5 |
| Temporal reasoning | 9 / 9 | 0 / 0 | 1 / 3 |

The paired difference between the daemon baseline and E1 is 0 wins / 49
losses at 1,024 tokens and 0 / 52 at 4,096 (exact McNemar p < .001).

**Why the baseline scores zero:**

- *No LLM call.* 42 of 70 answers never reach the LLM. In 23 "how many"/"total"
  questions the answer is the number of retrieved items, for example `19`. The
  rest return the top item's text verbatim from the temporal and span
  heuristics.
- *Abstentions overridden.* Every reader call on the default path abstained:
  28 of 28 at 1,024 tokens, 27 of 27 at 4,096. Answer synthesis replaced each
  abstention with a span from the top item, so the daemon never abstains.
- *Retrieval.* Default full-text ranking counts raw query-term overlap with no
  IDF, so question words like "what" and "my" dominate. Contentless
  `Session`/`Turn` nodes also come back as `raw` items.
- *No dates.* The reader context carries no timestamps, and the reader prompt
  has no question date.
- *Budget accounting.* The daemon's token estimate undercounts. At a 1,024-token
  budget, true `o200k_base` context reached 1,104 tokens (1,209 with
  `needs=raw`).

**Latency and cost.**

- Daemon answer latency is 6 ms p50 (heuristic answers) and about 1.0–1.2 s p95
  (LLM answers). In-memory ingest takes 0.07 s per question, for about 495
  messages.
- E1's reader call takes 1.2–1.4 s p50. E1 embeds the haystack at query time,
  with a retrieval p50 of 22 s on a cold cache.
- Observed spend for all Day-1 runs was **$0.51**:
  - E1 reference: $0.27, of which embeddings were $0.13.
  - Daemon baseline: $0.08.
  - `needs=raw` diagnostic: $0.17.
  - Smoke test: under $0.01.

These are 70 development questions, not held-out or full-benchmark accuracy.
Coverage is a message-level proxy, not semantic sufficiency.
