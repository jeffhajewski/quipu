# Quipu

Evidence-backed temporal memory for long-horizon AI agents.

Quipu is pronounced **KEE-poo**. The name comes from knotted Andean record
systems: durable memory encoded as structure, not just loose text.

Quipu gives an agent a local memory layer it can inspect, verify, update, and
forget. It stores raw evidence, extracts scoped facts and preferences from that
evidence, retrieves the right memories for a task, and keeps enough provenance
that you can ask why a memory exists or remove it later.

```bash
curl -fsSL https://raw.githubusercontent.com/jeffhajewski/quipu/main/scripts/install.sh | bash
export PATH="$HOME/.quipu/bin:$PATH"
quipu --db "$HOME/.quipu/memory.lattice" health
```

The installer builds the Zig core against a system-installed LatticeDB `0.18.0`
native library for durable graph, full-text, vector, and stream storage. You
need `git`, `zig`, `lattice.h`, and `liblattice` installed; set
`LATTICE_INCLUDE` and `LATTICE_LIB_DIR` when they are not in standard system
paths.

## Why Quipu

Agents do not just need longer prompts. They need memory with discipline.

Most memory layers eventually become a pile of chunks. They can recall stale
facts, mix data across users or projects, lose the evidence behind a summary, or
fail to fully suppress deleted information. Quipu is built around stricter
invariants:

- Raw evidence is preserved unless it is explicitly forgotten.
- Derived facts link back to the messages that justify them.
- Current facts are temporal: old values become historical, not silently wrong.
- Retrieval is scoped, budgeted, and inspectable.
- Forgetting propagates from raw evidence to derived memories.
- SDKs stay thin; memory semantics live in the local daemon.

The result is a memory system that is useful for real agent work: repo
preferences, user style, project procedures, facts that change over time, and
audit trails for what the agent used.

## What It Does

Quipu currently supports:

- `memory.remember`: store raw sessions, turns, and messages.
- Deterministic extraction for package-manager facts, test commands, and
  response-style preferences.
- Temporal supersession for single-valued facts and preferences.
- `memory.retrieve`: return both a rendered prompt and structured context
  packet with scope filtering, needs filtering, token budgeting, event windows,
  `validAt`, warnings, and optional trace output.
- `memory.answer`: retrieve scoped evidence and answer with either the
  deterministic local fallback or a configured chat-model reader that gets the
  session-grouped context and the question date.
- `memory.search`: lexical, vector, reciprocal-rank hybrid, and graph search
  modes.
- `memory.inspect`: inspect a node, its provenance, dependents, and stream-backed
  audit records.
- `memory.forget`: qid or query selectors, dry-run closure reports, tombstones,
  redaction state, and suppression of derived memories and contaminated core
  summaries backed by forgotten evidence.
- `memory.feedback` and `memory.core.*` for retrieval feedback and user-managed
  core memory blocks.
- Native LatticeDB-backed persistence with graph nodes/edges, FTS,
  configurable hash or OpenAI-compatible vector search, and durable streams.
- Summary nodes: after extraction, a background job writes a title and
  summary of each conversation and of each group of claims about one subject,
  as nodes evidenced by the messages they rest on. Retrieval reads them
  first: the topics nearest a question are shown as threads of dated facts,
  and they decide which conversations raw messages are taken from. See
  [docs/algorithms.md](./docs/algorithms.md#reading-the-summaries-first).
- Pattern nodes: after extraction, a background job groups what a person
  wrote about one kind of recurring occasion, has the extract model propose
  generalisations and answer them occasion by occasion, and stores what the
  counts support, or that nothing held, as a node evidenced by every message
  it counted. `memory.retrieve` and `memory.answer` show a node only to a
  question that is about its occasions, with no option. See
  [docs/algorithms.md](./docs/algorithms.md#pattern-nodes).
- Durable stream events can be materialized into idempotent `Job` nodes for
  extraction, async entity resolution, consolidation, forgetting, retrieval
  logging, and feedback work.
- Python and TypeScript SDKs that validate JSON-RPC shape and talk to a local
  `quipu serve-stdio` process.
- A dependency-free MCP stdio adapter with tools, docs/schema resources, and
  workflow prompts for tool-calling hosts.
- Synthetic evals that check temporal truth, cross-scope leakage, evidence
  faithfulness, forgetting leakage, and emit run manifests.
- External benchmark readiness gates, LoCoMo smoke fixtures, a real LoCoMo
  `locomo10.json` normalizer, retrieval trace artifacts, and reproducible
  benchmark manifests.
- Deterministic external benchmark baselines (`full_context`, `recent_only`,
  `bm25`, `vector_rag`, `hybrid_bm25_vector`, `summary_only`,
  `memory_cards_only`, `graph_only`) plus Q0-Q13/full Quipu ablation runs.

## Current Benchmark Snapshot

The current benchmark surface has two honest result classes:

- `synthetic_smoke`: deterministic CI fixtures for temporal truth, scope,
  evidence, preferences, and forgetting.
- `external_smoke`: tiny normalized fixtures shaped like external benchmarks.

One local `publishable` LoCoMo run has passed the readiness gate with the full
external dataset, LatticeDB storage, retrieval traces, deterministic answer and
grading, baselines, ablations, verification, and reproducible manifests. Treat
it as a Quipu reproducibility result, not an apples-to-apples leaderboard claim
against published systems that use different answer models, judges, retrieval
cutoffs, category subsets, or dataset slices.

Latest local synthetic run:

- Q0 raw-only fake baseline: 5/5 queries, 1/1 forgetting checks.
- Core in-memory baseline: 5/5 queries, 1/1 forgetting checks.
- Core LatticeDB `0.6.0` baseline: 5/5 queries, 1/1 forgetting checks.

See [docs/benchmark-results.md](./docs/benchmark-results.md) for the generated
report and caveats.

Current external benchmark status:

- LoCoMo mini fixture: covers single-hop, multi-hop, temporal, adversarial,
  event-summary, and forgetting paths. This validates the harness, not LoCoMo
  performance.
- Real LoCoMo adapter: normalizes the upstream SNAP `locomo10.json` shape into
  Quipu scenarios and can run local deterministic baseline, ablation, and core
  benchmark passes with artifacts.
- LongMemEval mini fixture and real adapter: normalizes the official cleaned
  LongMemEval oracle/S/M JSON files into timestamped session events and
  session-level evidence queries. This is wired for reproducible runs, not a
  published LongMemEval score.
- LongMemEval-S development slice (70 questions, official judge): with a
  GPT-4o-mini reader the daemon scores 75.7% at 1,024 tokens and 71.4% at
  4,096, matching the E1 prototype; with Claude Sonnet 5.5 it scores 87.1% at
  4,096. Development-slice result, not a leaderboard claim; see
  [docs/sota-sprint-results.md](./docs/sota-sprint-results.md).
- LongMemEval-S knowledge-update category (all 78 questions, official judge,
  GPT-4o-mini reader): 75.6% at 4,096 tokens and 84.6% at 1,024 by default;
  85.9% and 88.5% with background extraction, consolidation and
  `options.facts`. One category, not a benchmark score; same document.
- LongMemEval-S temporal-reasoning category (all 133 questions, official
  judge, GPT-4o reader, 4,096 tokens): 78.9% with background extraction,
  consolidation, `options.factKeys` and `options.facts`, now that a time the
  question names is resolved for the reader; 69.9% without the background
  jobs before that change. With a GPT-4o-mini reader the default was 68.4%
  and the background jobs cost answers. One category, not a benchmark score;
  same document.
- Pattern questions on eight hand-written journals (24 questions, GPT-4o for
  the pattern jobs, the reader and the judge, 1,200 tokens): 6 of 8 planted
  patterns answered with pattern nodes against 1 of 8 from raw evidence, 6 of
  8 "nothing explains it" questions against 3 of 8, and 8 of 8 lookups either
  way. The journals and the pipeline have the same author; this is a check
  that the daemon reproduces the prototype, not a benchmark score. On 55
  LongMemEval-S temporal questions the pattern jobs changed no context and
  no answer. Same document.
- Full LoCoMo local raw-retrieval run: 1,986 questions, LatticeDB `0.6.0`,
  core Lattice answer-containment exact match 28.55%, evidence recall 58.27%,
  with reports under `artifacts/benchmarks/locomo-core-lattice-raw-fast-full/`.
- Same-suite provider semantic baselines using OpenRouter
  `openai/text-embedding-3-small` at the provider default dimensionality:
  vector RAG exact 25.28%, evidence recall 57.90%; hybrid BM25/vector exact
  26.64%, evidence recall 58.07%, with reports under
  `artifacts/benchmarks/locomo-full-openrouter-semantic/`.
- Lattice graph retrieval with deterministic entity resolution is wired through
  the benchmark harness and passes the LoCoMo graph smoke with verification and
  trace artifacts under `artifacts/benchmarks/locomo-graph-smoke/`. The full
  LoCoMo graph+ER run was blocked on LatticeDB `0.6.0` `LatticeIo`/close issues
  with large-message writes, stream rereads, and dense edge materialization.
  The LatticeDB `0.18.0` adapter writes 64KB values, appends streams without
  rereading them, and stores edges natively; the run has not been repeated yet.
- Local BM25 on the same normalized suite: exact 24.12%, evidence recall
  50.42%. Full context remains the local upper bound at exact 42.80% and
  evidence recall 99.70%.
- External benchmark reports include published reference points from other
  memory systems where available. They are orientation only: answer models,
  judges, retrieval cutoffs, dataset slices, and methodologies differ.

## Try It

Start a local durable Quipu process:

```bash
quipu --db "$HOME/.quipu/memory.lattice" serve-stdio
```

Or send JSON-RPC directly:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":"1","method":"memory.remember","params":{"scope":{"projectId":"repo:quipu"},"messages":[{"role":"user","content":"This repo uses pnpm. Run just test before committing.","createdAt":"2026-04-28T10:15:00Z"}]}}' \
  | quipu --db "$HOME/.quipu/memory.lattice" rpc-stdin

printf '%s\n' '{"jsonrpc":"2.0","id":"2","method":"memory.retrieve","params":{"query":"What should I run before committing?","scope":{"projectId":"repo:quipu"},"needs":["procedural"],"options":{"includeDebug":true}}}' \
  | quipu --db "$HOME/.quipu/memory.lattice" rpc-stdin

printf '%s\n' '{"jsonrpc":"2.0","id":"3","method":"memory.answer","params":{"query":"What should I run before committing?","scope":{"projectId":"repo:quipu"},"needs":["procedural"],"options":{"includeDebug":true}}}' \
  | quipu --db "$HOME/.quipu/memory.lattice" rpc-stdin
```

Check the store:

```bash
quipu --db "$HOME/.quipu/memory.lattice" health
quipu --db "$HOME/.quipu/memory.lattice" verify
```

Provider-backed vector search can be enabled in the Lattice adapter with an
OpenAI-compatible embeddings endpoint:

```bash
export OPENROUTER_API_KEY=...
QUIPU_EMBEDDING_PROVIDER=openrouter \
  quipu --db "$HOME/.quipu/memory.lattice" \
  remember --project repo:quipu --text "The launch code is heliotrope."
```

With the `openrouter` or `openai` embedding provider, the core Lattice adapter
stores `text-embedding-3-small` vectors at their native 1536 dimensions and
does not send a `dimensions` parameter. Set `QUIPU_VECTOR_DIMENSIONS` (or
`--vector-dimensions`) to ask the provider for shorter vectors. The vector width
is fixed when a store is created. The `LatticeIo` commit failure at `1017`
dimensions and above seen with LatticeDB `0.6.0` does not occur with `0.18.0`:
2,000 1536-dimensional vectors commit and reopen intact on 4KB and 8KB pages.

Provider-backed answer generation and async entity resolution use the unified
LLM provider surface:

```bash
export OPENAI_API_KEY=...
quipu --db "$HOME/.quipu/memory.lattice" \
  --llm-provider openai \
  --llm-model gpt-4o \
  remember --project repo:quipu --text "Alice Smith owns the Lisbon rollout."
quipu --db "$HOME/.quipu/memory.lattice" jobs run entity-resolve
quipu --db "$HOME/.quipu/memory.lattice" \
  --llm-provider openai \
  answer --project repo:quipu --mode graph --query "Who owns the Lisbon rollout?"
```

OpenRouter, Anthropic, Google Gemini, Ollama, Groq, Together, Mistral,
DeepSeek, Kimi/Moonshot, Cohere, Azure OpenAI, and custom OpenAI-compatible
endpoints are documented in [`docs/providers.md`](docs/providers.md).

For local smoke tests without model keys, use
`--entity-provider deterministic` and omit `--answer-provider`; `memory.answer`
falls back to returning the top current derived fact, or else the top raw
evidence text.

Use the CLI directly:

```bash
quipu --db "$HOME/.quipu/memory.lattice" init
quipu --db "$HOME/.quipu/memory.lattice" remember \
  --project repo:quipu \
  --text "This repo uses pnpm. Run just test before committing."
quipu --db "$HOME/.quipu/memory.lattice" retrieve \
  --project repo:quipu \
  --query "test command" \
  --need procedural \
  --debug
quipu --db "$HOME/.quipu/memory.lattice" answer \
  --project repo:quipu \
  --query "What should I run before committing?" \
  --need procedural
quipu --db "$HOME/.quipu/memory.lattice" consolidate --project repo:quipu
quipu --db "$HOME/.quipu/memory.lattice" forget \
  --project repo:quipu \
  --query "pnpm" \
  --dry-run
```

## SDK Examples

Python:

```python
from quipu import Quipu

with Quipu.local(db_path="/tmp/quipu.lattice") as q:
    remembered = q.remember(
        scope={"projectId": "repo:quipu"},
        messages=[{"role": "user", "content": "Use pnpm for this repo."}],
    )
    retrieved = q.retrieve(
        query="package manager",
        scope={"projectId": "repo:quipu"},
        needs=["current_facts"],
        options={"includeDebug": True},
    )
    answered = q.answer(
        query="What package manager does this repo use?",
        scope={"projectId": "repo:quipu"},
        needs=["current_facts"],
    )
    print(remembered["messageQids"])
    print(retrieved["prompt"])
    print(answered["answer"])
```

TypeScript:

```ts
import { Quipu } from "@quipu/memory";

const q = await Quipu.local({ dbPath: "/tmp/quipu.lattice" });

try {
  await q.remember({
    scope: { projectId: "repo:quipu" },
    messages: [{ role: "user", content: "Run just test before committing." }],
  });

  const retrieved = await q.retrieve({
    query: "test command",
    scope: { projectId: "repo:quipu" },
    needs: ["procedural"],
    options: { includeDebug: true },
  });
  const answered = await q.answer({
    query: "What should I run before committing?",
    scope: { projectId: "repo:quipu" },
    needs: ["procedural"],
  });

  console.log(retrieved.prompt);
  console.log(answered.answer);
} finally {
  q.close();
}
```

SDK packaging is still settling; from source, use `sdk/python` and
`sdk/typescript` directly.

## How It Works

```text
Agent runtime / app
  -> Python SDK, TypeScript SDK, CLI, or MCP adapter
  -> JSON-RPC 2.0 protocol
  -> Zig core runtime
  -> storage adapter
  -> in-memory adapter or LatticeDB adapter
```

The Zig core owns memory semantics. Storage adapters provide graph records,
full-text search, vector search, streams, transactions, and verification.

The LatticeDB adapter stores Quipu nodes as durable graph nodes with public qids
under a shared `QuipuNode` label, stores provenance edges as native Lattice
edges, ranks text with BM25 over one declared full-text index of each searchable
node's `searchText`, `content`, `text`, or `name`, stores deterministic
`lattice_hash_embed` or OpenAI-compatible provider vectors for search, and
publishes events through Lattice native durable streams.

## Current Status

Quipu is a working core prototype, not a packaged production daemon yet.

Implemented:

- Contract-first JSON-RPC protocol schemas and conformance fixtures.
- Zig runtime for the public memory methods.
- LatticeDB-backed storage adapter for normal runtime and tests, plus an
  in-memory adapter for adapter-local/no-lattice builds only.
- Schema metadata, initial migration record, and schema-aware verification.
- Retrieval, inspection, feedback, core memory blocks, forgetting, and audit
  stream logging.
- Reciprocal-rank hybrid retrieval, graph expansion over resolved entities, and
  provider-backed `memory.answer`.
- Optional cross-encoder reranking through a Cohere/Jina-compatible endpoint,
  switchable per request.
- Python/TypeScript SDK validators and stdio clients.
- Python/TypeScript `local` helpers that auto-start the core over stdio.
- MCP tools, resources, and prompts.
- Synthetic eval harness, strict core eval baseline, and run manifests.
- External benchmark readiness gate, LoCoMo mini smoke fixture, real LoCoMo
  dataset normalizer, retrieval trace artifacts, and `just` targets for LoCoMo
  smoke/full/download runs.
- Deterministic required baselines and Q0-Q13/full Quipu ablation manifests for
  benchmark reports.

Still in progress:

- Long-running socket or HTTP daemon.
- Release artifacts for Quipu itself.
- Full migration runner and compatibility checks.
- Learned scoring beyond deterministic RRF/graph boosts and the optional reranker.
- LLM-backed consolidation beyond knowledge updates, summaries and pattern
  nodes (reflections, procedures). Extraction, the opt-in update
  consolidation (`--consolidate on`, read back with `options.facts`),
  summaries and pattern nodes run as a background worker when the daemon is
  started with `--background on`; entity resolution still runs only on
  request.
- Judge scoring for LoCoMo publication.
- MemoryAgentBench adapter.
- Richer host integrations.

## Development

Common checks:

```bash
just test
just fmt
just ci

cd core && zig build test
cd sdk/typescript && npm test
PYTHONPATH=evals/src python3 -m quipu_evals.core_runner --strict
PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks \
  --include-lattice \
  --markdown docs/benchmark-results.md
PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks \
  --external-benchmark locomo \
  --include-baselines \
  --include-ablations \
  --allow-failures \
  --markdown artifacts/benchmarks/locomo-smoke/report.md
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
  --allow-failures \
  --markdown artifacts/benchmarks/locomo-full/report.md
PYTHONPATH=evals/src python3 -m quipu_evals.core_runner \
  --strict \
  --output artifacts/evals/core-results.json \
  --manifest artifacts/evals/core-manifest.json
just benchmark-locomo-smoke
just benchmark-locomo-graph-smoke
just benchmark-locomo-full /path/to/locomo10.json
just benchmark-locomo-download
```

Build with an explicit system LatticeDB `0.18.0` install:

```bash
git clone --depth 1 --branch v0.18.0 https://github.com/jeffhajewski/latticedb.git
(cd latticedb && zig build -Doptimize=ReleaseSafe)
cd core
zig build \
  -Dlattice-include=/path/to/latticedb/zig-out/include \
  -Dlattice-lib=/path/to/latticedb/zig-out/lib
```

Build LatticeDB with `-Doptimize=ReleaseSafe` (as CI does) for anything you
time: a Debug `liblattice` ingests about 35 times slower.

## Repository Layout

- `core/`: Zig runtime, CLI entrypoint, storage adapters, deterministic
  extraction, retrieval, forgetting, audit streams, and tests.
- `protocol/`: JSON-RPC schemas and conformance fixtures.
- `sdk/typescript/`: thin TypeScript SDK and protocol tests.
- `sdk/python/`: thin Python SDK and protocol tests.
- `mcp/`: dependency-free MCP stdio adapter with tools, resources, and prompts.
- `evals/`: synthetic scenario schema, deterministic baselines/ablations, Zig
  core runner, graders, external smoke fixtures, real LoCoMo normalizer, run
  manifests, readiness gates, trace artifacts, and tests.
- `docs/`: implementation notes for API, algorithms, data model, evals,
  architecture, security, and publication.
- `examples/`: planned integration examples.

## Protocol

Public JSON-RPC methods:

- `system.health`
- `memory.remember`
- `memory.retrieve`
- `memory.answer`
- `memory.search`
- `memory.inspect`
- `memory.forget`
- `memory.feedback`
- `memory.core.get`
- `memory.core.update`

See [protocol/README.md](./protocol/README.md), [docs/api.md](./docs/api.md),
and [protocol/schemas/methods.schema.json](./protocol/schemas/methods.schema.json)
for the implemented contract.

## License

MIT.
