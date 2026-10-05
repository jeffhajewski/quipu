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

To measure the daemon on LoCoMo with an LLM judge, use the
[LoCoMo harness](#locomo-harness) instead. The pipeline below predates it.

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
# Reranked runs add: --reranker-url http://127.0.0.1:7341/v1/rerank (see "Rerank server" below)
# Diagnostics: --needs raw, --mode fts|vector|hybrid|graph, --no-extract, --daemon-arg X,
#   --answer-option KEY=JSON (e.g. rerank=false)

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

**Rerank server.** `quipu_evals.rerank_server` serves the Cohere-compatible
`POST /v1/rerank` that the daemon's `--reranker-url` expects. It is backed by a
`sentence-transformers` CrossEncoder, `BAAI/bge-reranker-v2-m3` by default with
a maximum length of 512. It needs torch, so it runs from its own venv. It picks
mps, cuda or cpu, serializes scoring with one lock, and caches scores in
`$A/sota/cache/rerank/scores.jsonl` keyed by sha256 of the model identity,
query and document. A request that names another model gets a 400.

```bash
HF_HOME=$A/sota/hf-cache PYTHONPATH=evals/src $A/sota/rerank-venv/bin/python \
  -m quipu_evals.rerank_server --port 7341 --cache-dir $A/sota/cache/rerank &

$PY -m quipu_evals.sota_longmemeval run --daemon-binary $A/sota/bin/<name>/bin/quipu \
  --run-name <run-name> --lattice --embedding-provider-via-proxy --vector-dimensions 1536 \
  --reranker-url http://127.0.0.1:7341/v1/rerank
# Same daemon, reranker bypassed per request: add --answer-option rerank=false
```

`--reranker-model` defaults to the server's model, read from its `/health`.
The manifest records the model and the server's maximum length and device. The
configuration hash covers the model and maximum length but not the URL. Rows
keep each answer's rerank status and latency, and `report.md` gains a Rerank
table. Expect a 50-document call to take about 1.5 to 3.5 s on Apple-silicon
MPS. Concurrent workers queue on the scoring lock, and repeated documents are
cache hits.

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

## LoCoMo harness

`quipu_evals.sota_locomo` runs LoCoMo through the same daemon harness as
LongMemEval, to check that gains on the LongMemEval dev slice transfer to a
second benchmark. It reuses the daemon client, caching proxy, coverage mapping
and summaries from `sota_longmemeval`. It replaces the old LoCoMo numbers,
which came from a broken pipeline graded by exact containment.

**Data.** `sota_locomo download` fetches two files into
`$QUIPU_ARTIFACTS/benchmarks/locomo/`, checks their SHA256, and writes
`provenance.json`:

- `locomo10.json` from `snap-research/locomo@3eb6f2c`, SHA256
  `79fa87e9…ea698ff4`. It holds 10 conversations and 1,986 questions.
- `locomo-audit-errors.json`, the `errors.json` of `dial481/locomo-audit@9493fb4`,
  SHA256 `f298ef46…1b5fe55e`. It lists 156 audited questions: 99 with a wrong
  answer and 57 with wrong evidence ids only.

Both are CC BY-NC 4.0 and stay in ignored `artifacts/`. The legacy
`just benchmark-locomo-download` target fetches unpinned upstream `main` and
runs the old external-benchmark pipeline; this harness does not use it.

**Categories.** The ids in `locomo10.json` are 1 multi-hop (282 questions),
2 temporal (321), 3 open-domain (96), 4 single-hop (841) and 5 adversarial
(446). This follows the official evaluation code and the audit's "Note on
Category ID Mapping". The paper's prose lists the categories in a different
order, and the old normalizer in `locomo.py` used that order until this sprint.
Headline accuracy covers categories 1–4, 1,540 questions, as published
comparisons do. Category 5 is run and reported separately.

**Pipeline.**

- *Isolation.* Each conversation gets a daemon with a fresh store and a
  temporary `HOME`, as in the LongMemEval harness. With `--lattice`, each store
  is a new `--db`.
- *Ingest.* Each session becomes one `memory.remember` call, in date order,
  with `sessionId` `s01`, `s02`… after the LoCoMo session number. Every message
  carries its session's date-time plus its turn position in seconds, so order
  is preserved. Some samples list date-times for sessions with no turns; those
  are ignored.
- *Speakers.* The daemon accepts any `role` string and renders it as the line's
  speaker (`[qid] Caroline: …`), so the speaker's name is the role. Neither
  speaker is the `assistant`. The daemon indexes and embeds message content
  only, so a speaker's own turns are not searchable by their name.
  `--speaker-mode prefix` is a diagnostic alternative: role `user` and
  content `Caroline: …`.
- *Images.* A turn's BLIP caption is appended as `[shares image: <caption>]`,
  and a caption-only turn becomes just that. This matches what other systems
  and the original evaluation feed their readers. The crawler `query` field is
  annotator metadata, never used. `--no-captions` drops captions.
- *Answer.* Every question goes through `memory.answer`, with `time.validAt`
  one minute after the last message of the last session, an explicit
  `budgetTokens`, and `includeDebug`/`includeEvidence`. Retrieval logging is
  off (`logRetrieval: false`), so answers never write to the store and
  question order cannot change results.
- *Parallelism.* `serve-stdio` handles one request at a time. After ingest,
  the Lattice daemon is closed and the store is copied, so several daemons can
  answer one conversation in parallel. `--workers N` is the total number of
  answering daemons: conversations run in parallel, and leftover workers become
  extra daemons per conversation (`--answer-replicas` overrides).
- *Judge.* The Mem0 paper's LoCoMo judge, `ACCURACY_PROMPT` from
  `mem0ai/mem0@aae5989` `evaluation/metrics/llm_judge.py`, kept verbatim and
  pinned by SHA256 in a unit test. It runs as one user message on
  `openai/gpt-4o-mini-2024-07-18`, at temperature 0 with a JSON response
  format, once per answer. Judge calls go through the caching proxy, so the
  spend cap covers them. Category 5 is judged against the gold
  "Not mentioned in the conversation". The original evaluation scores that
  category the same way. Judge errors count as errors, never as wrong answers.
- *Keys.* Every answer is graded against the official key. For the 99 questions
  whose answer the audit corrects, a second judgment against the audit's
  `correct_answer` gives an audit-corrected key, reported beside the official
  one as a sensitivity check. Neither key is ever substituted for the other.
- *Evidence coverage.* LoCoMo `evidence` dialog ids (`D1:3`) are normalized,
  including packed (`"D8:6; D9:17"`) and malformed (`"D:11:26"`) entries. They
  are mapped to remembered message qids, and returned items, chunk evidence and
  derived-item evidence are mapped through `messageQids`, exactly as in the
  LongMemEval harness. Coverage is also computed against the audit's corrected
  evidence ids.

Question ids follow the audit's scheme, `locomo_<conversation>_qa<index>` with
a 0-based index into the conversation's `qa` list. Rows carry o200k context
tokens, reader prompt tokens, answer latency and proxy cost. Reruns reuse
per-question results whose configuration hash matches.

```bash
export QUIPU_ARTIFACTS=${QUIPU_ARTIFACTS:-$PWD/artifacts}
A=$QUIPU_ARTIFACTS
PY=$A/experiments/venv/bin/python                     # has tiktoken
export TIKTOKEN_CACHE_DIR=$A/experiments/tokenizer-cache PYTHONPATH=evals/src
export DYLD_LIBRARY_PATH=/path/to/latticedb/lib       # Lattice builds only

python3 -m quipu_evals.sota_locomo download           # pinned, sha256-checked

# Smoke: first conversation, first 20 questions.
$PY -m quipu_evals.sota_locomo run --daemon-binary $A/sota/bin/lattice-d1d5445/bin/quipu \
  --run-name locomo-smoke-d1d5445 --lattice --embedding-provider-via-proxy --vector-dimensions 1536 \
  --reader-model openai/gpt-4o-mini-2024-07-18 --budgets 1024,4096 \
  --limit-conversations 1 --limit-questions 20 --workers 4 --max-spend-usd 1

# Full: 10 conversations, 1,986 questions, both budgets; report in $A/sota/locomo/<run-name>/.
$PY -m quipu_evals.sota_locomo run --daemon-binary $A/sota/bin/lattice-d1d5445/bin/quipu \
  --run-name locomo-full-d1d5445 --lattice --embedding-provider-via-proxy --vector-dimensions 1536 \
  --reader-model openai/gpt-4o-mini-2024-07-18 --budgets 1024,4096 --workers 20 --max-spend-usd 3
# Subsets: --categories 1,2,3,4, --conversations conv-26, --questions locomo_0_qa3 ...
# Diagnostics: --speaker-mode prefix, --no-captions, --answer-option KEY=JSON, --needs, --mode
```

The same steps are available as `just sota-locomo-download` and
`just sota-locomo-run <bin-name> <run-name> [flags]`. Run directories hold
`manifest.json`, `cases/<sample>/<qid>.json` with full contexts and judgments,
`conversations/<sample>.json` with ingest stats and the qid map, `proxy.jsonl`,
`logs/`, `report.json` and `report.md`.

**Caveats.** These numbers are not an apples-to-apples leaderboard claim:

- *Category 5 is excluded* from the headline, as in published comparisons.
- *The answer key is noisy.* The audit finds 6.4% of category 1–4 answers
  wrong, which caps a perfect system near 93.6%. Per category, the caps are
  90.1% multi-hop, 91.9% temporal, 90.6% open-domain and 95.7% single-hop.
- *The judge is lenient.* It is told to accept any answer that "touches on the
  same topic". The audit's vague-but-topical wrong answers pass it 62.8% of the
  time. Vendor-run judges are known to add about 5–6 points over independent
  re-runs.
- *Published systems differ* in reader model, answer prompt, judge runs
  (some take a majority of three) and category handling. Compare runs of this
  harness with each other, not with leaderboard tables.
- *Coverage is a proxy.* LoCoMo evidence ids are sparse: multi-hop questions
  often cite one turn of several, and 57 cite the wrong turn.

### First LoCoMo results, October 5, 2026

**Setup.** The sprint's default daemon (`d1d5445`, Lattice build): hybrid
BM25 + vector retrieval with `openai/text-embedding-3-small` at 1,536
dimensions. The reader and the judge are both `openai/gpt-4o-mini-2024-07-18`.
Budgets are 1,024 and 4,096 tokens. Runs `locomo-full-d1d5445` (speaker name
as role, the protocol default) and `locomo-prefix-d1d5445` (diagnostic,
`--speaker-mode prefix`, categories 1–4 only) are in `$A/sota/locomo/`.

Categories 1–4, 1,540 questions, at 1,024 / 4,096 tokens:

| Run | Official key | Audit key | Gold-turn coverage | Completion |
| --- | ---: | ---: | ---: | ---: |
| Speaker name as role (default) | 65.5% / 79.5% | 65.8% / 79.5% | 56.1% / 79.0% | 100% |
| `Name:` prefix in content (diagnostic) | 78.5% / 83.7% | 79.5% / 84.4% | 72.9% / 89.8% | 92.7% |

The prefix run stopped short because the OpenRouter account ran out of
credits. Provider 402s hit 112 answers at 1,024 tokens and 114 at 4,096,
spread over 173 questions. They count as errors, not wrong answers. Rerunning
the same command completes them and reuses the rest.

Per category, official key, at 1,024 / 4,096 tokens:

| Category | n | Speaker as role | Prefix (completed) |
| --- | ---: | ---: | ---: |
| Multi-hop (1) | 282 | 47.2% / 73.0% | 70.8% / 82.9% |
| Temporal (2) | 321 | 60.7% / 63.9% | 69.5% / 67.9% |
| Open-domain (3) | 96 | 42.7% / 58.3% | 61.5% / 62.5% |
| Single-hop (4) | 841 | 76.1% / 90.1% | 87.7% / 93.7% |
| Adversarial (5), separate | 446 | 34.3% / 22.2% | not run |

**What we learned:**

- *Speaker names are not searchable when they are only the role.* The daemon
  indexes and embeds message content, not `role`. In role mode, Caroline's
  own turns cannot match "Caroline", while Melanie's turns that address her by
  name can. On the 1,428 / 1,426 questions both runs completed, putting the
  name in the content wins 236/38 at 1,024 tokens (+13.9 pp, exact McNemar
  p < .001) and 116/49 at 4,096 (+4.7 pp, p < .001). Gold-turn coverage rises
  by 17 and 11 points. Making the speaker searchable is a daemon change, not a
  harness choice.
- *More context helps on LoCoMo.* At 4,096 tokens, accuracy beats 1,024 tokens
  272/56 in role mode. On the LongMemEval dev slice, GPT-4o-mini lost accuracy
  with more context. At 1,024 tokens, 410 of 531 wrong answers had no gold turn
  in context, and the reader mostly abstained.
- *Temporal questions are the reader's weak spot.* At 4,096 tokens, temporal
  gold-turn coverage is 86%, yet accuracy is 64%. 72 of the 116 wrong temporal
  answers had every gold turn in context. The reader resolves "next month" or
  "last week" against the wrong session date, or reports the date of a later
  mention as the event date.
- *Adversarial questions expose speaker confusion.* Category 5 asks one
  speaker about the other's experiences. The reader attributes the other
  speaker's turn to the named person: about half of the wrong answers repeat
  the adversarial answer. More context makes this worse (34% to 22%).
- *The audit key moves little overall:* +0.3 and 0 points in role mode. On the
  99 corrected questions, judgments flip in both directions.

**Latency and cost.** Answer latency p50 was 1.8 s at 1,024 tokens and 1.5 s at
4,096, with p95 at 2.9 s and 2.6 s. The 4,096 call reuses the cached query
embedding. Ingest took 34 s per conversation on average, about 590 messages,
with a `memory.remember` p50 of 1.1 s per session. The role-mode run cost
$1.92 for 3,972 answers with judgments, about $0.0002 / $0.0006 per reader
call. Total spend for the smoke, the full run and both prefix diagnostics was
$3.35.
