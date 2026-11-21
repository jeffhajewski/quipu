# Architecture

See [../SPEC.md](../SPEC.md) for the full design. This file tracks implementation notes as the runtime lands.
For one message followed from `memory.remember` through the background jobs
to a rendered context, with the jobs, streams and token budget in one place,
see [how-it-works.md](how-it-works.md).

## Storage Adapters

The Zig runtime owns memory semantics and talks to storage through
`core/src/storage.zig`.

Implemented adapters:

- `InMemoryAdapter`: test adapter with graph-like node/edge records, simple text
  search, stream records, and invariant verification.
- `LatticeAdapter`: durable adapter over the LatticeDB 0.18 C ABI. Build it
  with `-Denable-lattice=true` plus `-Dlattice-include` and `-Dlattice-lib`.

The Lattice adapter stores Quipu nodes as Lattice nodes with stable public qids
in properties, creates real Lattice edges for provenance when endpoints exist,
keeps shadow edge records for adapter verification, and publishes Quipu events
through Lattice native durable streams.
It uses Lattice FTS for lexical retrieval, stores deterministic
`lattice_hash_embed` vectors or OpenAI-compatible provider embeddings on Quipu
nodes, exposes Lattice vector search for `memory.search`, and adds adapter-side
token aggregation so the current
natural-language retrieval semantics match the in-memory adapter.

The CLI accepts `--vector-dimensions`, `--embedding-provider`,
`--embedding-url`, and `--embedding-model`. Vectors use cosine distance, and a
store's dimensions are fixed when it is created. The adapter opens the store
with LatticeDB's changefeed off, because the changefeed keeps the old value of
every changed property and would retain forgotten text. A node that is forgotten or
stops being searchable has its vector removed from the index and keeps its id,
labels and edges. Opening a store removes any vector such a node still holds,
which covers stores written before LatticeDB 0.18 could remove one.

Provider embeddings are batched per `memory.remember` call. Before writing
nodes, the runtime collects the index text of each vector-indexed node the call
will write (unchunked messages, the chunks of long messages, and deterministic
extractions) and calls `storage.Adapter.prefetchEmbeddings`. The Lattice adapter
sends the distinct, non-blank texts in batched requests (`input` as an array, at
most 128 inputs and 128 KiB of text each) and caches the vectors by exact text;
`putNode` uses a cached vector only when the node's index text matches it
byte for byte, and otherwise embeds the text in its own request as before. A
failed batch only leaves its texts to that per-node path. The runtime clears the
cache when the call returns. Model, dimensions and index text are unchanged, so
a node's vector is the one the per-node path would request; forgetting removes
it the same way. Hash embeddings and the in-memory adapter skip the prefetch.

`system.health` reports the active storage backend and capability flags so SDKs,
evals, and operators can tell whether durable storage and vector search are
available without probing backend-specific APIs.

## Streams and Jobs

Quipu uses named durable streams as the event backbone and materializes work into
idempotent `Job` nodes. The stream names live in `core/src/streams.zig`; the
materializer in `core/src/jobs.zig` reads stream records and creates one job per
`{stream, sequence, worker_kind}` key.

`memory.remember` now publishes `quipu.extract.requested` when extraction is
enabled and immediately materializes that stream record into a pending extract
job. The same materializer can be replayed from the CLI:

```bash
quipu --db /tmp/quipu.lattice jobs materialize
quipu --db /tmp/quipu.lattice jobs materialize quipu.retrieval.logged
quipu --db /tmp/quipu.lattice jobs materialize --after 100 --limit 500 quipu.audit
```

This gives the current single-process prototype a durable stream-to-job
boundary. Extraction, consolidation, summaries and patterns use it; nothing
is queued for forgetting or feedback, which run inside their requests.
The extractor, for one: `quipu serve --background on` leases `extract`
jobs between requests, makes the model calls on other threads, and writes the
results back on the request thread (see
[algorithms.md](algorithms.md#background-worker)). Job leases carry wall-clock
times, and an expired lease returns its job to `pending`.

## CLI and Schema

`quipu init` writes the current schema metadata node (`q_schema_current`) and the
initial applied migration record (`q_migration_0001_initial`) into the active
store. `quipu verify` checks that schema metadata and migration state are
present, then returns storage invariant issues and the forgetting checks:
tombstones without residual text, no live memory derived from or compiled from
forgotten evidence, and one current value per single-value slot.
`quipu verify leaks` also scans live text for copies of forgotten text. Lattice-enabled builds use
`QUIPU_DB_PATH` or
`~/.quipu/default/quipu.lattice` for persistent commands when `--db` is omitted.

The CLI now exposes thin wrappers over the JSON-RPC runtime:

```bash
quipu remember --text "Use pnpm." --project repo:quipu
quipu retrieve --query "package manager" --project repo:quipu --need current_facts
quipu inspect q_fact_6
quipu forget --id q_msg_4 --dry-run
quipu feedback --retrieval q_retr_10 --rating helpful
```

These commands build JSON-RPC requests and dispatch through the same runtime path
used by SDKs and MCP.
