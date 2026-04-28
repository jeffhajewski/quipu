# Quipu Core

Native daemon and CLI, planned in Zig.

Responsibilities:

- Own the LatticeDB file.
- Expose JSON-RPC protocol.
- Enforce schema and migrations.
- Implement deterministic write templates.
- Run retrieval, context assembly, forgetting, verification, and stream workers.

Current scaffold:

- `src/protocol.zig` dispatches JSON-RPC requests and implements `system.health`.
- `src/storage.zig` defines the storage adapter boundary for graph, FTS, vector, stream, transaction, and verification operations.
- `src/in_memory_storage.zig` provides the first test adapter while LatticeDB assumptions are verified.
