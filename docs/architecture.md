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
`lattice_hash_embed` vectors on Quipu nodes, exposes Lattice vector search for
`memory.search`, and adds adapter-side token aggregation so the current
natural-language retrieval semantics match the in-memory adapter.

`system.health` reports the active storage backend and capability flags so SDKs,
evals, and operators can tell whether durable storage and vector search are
available without probing backend-specific APIs.
