# Quipu Core

Native daemon and CLI, planned in Zig.

Responsibilities:

- Own the memory database file.
- Expose JSON-RPC protocol.
- Enforce schema and migrations.
- Implement deterministic write templates.
- Run retrieval, context assembly, forgetting, verification, and stream workers.

Current scaffold:

- `src/protocol.zig` dispatches JSON-RPC requests and implements `system.health`.
- `src/storage.zig` defines the storage adapter boundary for graph, FTS, text embedding, vector search, stream, transaction, capability, and verification operations.
- `src/in_memory_storage.zig` provides the adapter-local/no-lattice fallback adapter and verifier.
- `src/lattice_storage.zig` provides the default LatticeDB-backed adapter over the Lattice C ABI, including native durable streams.
- `src/extractor.zig` defines the deterministic extraction boundary and validates candidate facts, preferences, and procedures before writes.
- `src/runtime.zig` implements the JSON-RPC runtime for raw `memory.remember`, deterministic package-manager/test-command/preference extraction, current-slot supersession, context packet assembly, needs filtering, token budgeting, valid-at and event-window retrieval, provenance/dependent inspection, dry-run forget closure reports, redaction tombstones, `memory.search` modes, `memory.retrieve`, `memory.inspect`, `memory.forget`, `memory.feedback`, and `memory.core.*`.

Local commands:

```bash
zig build test
zig build
./zig-out/bin/quipu health
./zig-out/bin/quipu verify
./zig-out/bin/quipu rpc-stdin < request.json
printf '%s\n' '{"jsonrpc":"2.0","id":"1","method":"system.health","params":{}}' | ./zig-out/bin/quipu serve-stdio
```

LatticeDB build with explicit system paths:

```bash
zig build \
  -Dlattice-include=/path/to/latticedb/include \
  -Dlattice-lib=/path/to/latticedb/lib

./zig-out/bin/quipu --db /tmp/quipu.lattice health
```
