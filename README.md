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

The installer builds the Zig core and downloads the LatticeDB `0.6.0` native
library for durable graph, full-text, vector, and stream storage. You need
`git`, `curl`, `tar`, and `zig` installed.

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
- `memory.search`: lexical, vector, and hybrid search modes.
- `memory.inspect`: inspect a node, its provenance, dependents, and stream-backed
  audit records.
- `memory.forget`: qid or query selectors, dry-run closure reports, tombstones,
  redaction state, and suppression of derived memories and contaminated core
  summaries backed by forgotten evidence.
- `memory.feedback` and `memory.core.*` for retrieval feedback and user-managed
  core memory blocks.
- Native LatticeDB-backed persistence with graph nodes/edges, FTS, hash-vector
  search, and durable streams.
- Durable stream events can be materialized into idempotent `Job` nodes for
  extraction, consolidation, forgetting, retrieval logging, and feedback work.
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
- Full LoCoMo local run: readiness `ready`, 1,986 questions, LatticeDB `0.6.0`
  verification passed on all 10 conversations, core Lattice deterministic exact
  match 13.7%, evidence recall 19.6%, with reports under
  `artifacts/benchmarks/locomo-full/`.
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
```

Check the store:

```bash
quipu --db "$HOME/.quipu/memory.lattice" health
quipu --db "$HOME/.quipu/memory.lattice" verify
```

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
    print(remembered["messageQids"])
    print(retrieved["prompt"])
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

  console.log(retrieved.prompt);
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

The LatticeDB adapter stores Quipu nodes as durable graph nodes with public qids,
creates provenance edges, indexes text with Lattice FTS, stores deterministic
`lattice_hash_embed` vectors for search, and publishes events through Lattice
native durable streams.

## Current Status

Quipu is a working core prototype, not a packaged production daemon yet.

Implemented:

- Contract-first JSON-RPC protocol schemas and conformance fixtures.
- Zig runtime for the public memory methods.
- In-memory and LatticeDB `0.6.0` storage adapters.
- Schema metadata, initial migration record, and schema-aware verification.
- Retrieval, inspection, feedback, core memory blocks, forgetting, and audit
  stream logging.
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
- Provider-backed embeddings, BM25/reranking, and learned scoring.
- LLM-backed extraction and consolidation workers.
- Provider-backed answer/judge scoring for LoCoMo publication.
- LongMemEval and MemoryAgentBench adapters.
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
  --allow-failures \
  --markdown artifacts/benchmarks/locomo-full/report.md
PYTHONPATH=evals/src python3 -m quipu_evals.core_runner \
  --strict \
  --output artifacts/evals/core-results.json \
  --manifest artifacts/evals/core-manifest.json
just benchmark-locomo-smoke
just benchmark-locomo-full /path/to/locomo10.json
just benchmark-locomo-download
```

Build with an explicit LatticeDB release:

```bash
cd core
zig build -Denable-lattice=true \
  -Dlattice-include=/path/to/latticedb/include \
  -Dlattice-lib=/path/to/latticedb/lib
```

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
