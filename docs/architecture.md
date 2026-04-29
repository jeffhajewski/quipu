# Architecture

See [../SPEC.md](../SPEC.md) for the full design. This file tracks implementation notes as the runtime lands.

## Storage Adapters

The Zig runtime owns memory semantics and talks to storage through
`core/src/storage.zig`.

Implemented adapters:

- `InMemoryAdapter`: test adapter with graph-like node/edge records, simple text
  search, stream records, and invariant verification.
- `LatticeAdapter`: optional durable adapter over the LatticeDB 0.6 C ABI. Build it
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

The LatticeDB 0.6 C ABI exposes `lattice_open_options.vector_dimensions`, and
the CLI accepts `--vector-dimensions`, `--embedding-provider`,
`--embedding-url`, and `--embedding-model`. Current local smoke tests show
LatticeDB 0.6 commits fail with `LatticeIo` at `1017` persisted dimensions and
above, even when the page size is increased. For OpenRouter, Quipu therefore
defaults the core adapter to 768-dimensional `openai/text-embedding-3-small`
embeddings until the large-vector persistence issue is fixed.

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

This gives the current single-process prototype the same durable stream-to-job
boundary that later extractor, consolidation, forgetting, and feedback workers
will use.

## CLI and Schema

`quipu init` writes the current schema metadata node (`q_schema_current`) and the
initial applied migration record (`q_migration_0001_initial`) into the active
store. `quipu verify` checks that schema metadata and migration state are
present before returning storage invariant issues. Lattice-enabled builds use
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
