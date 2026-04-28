# Quipu

Evidence-backed temporal memory for long-horizon AI agents.

Quipu is a local-first memory system for agents. The intended production runtime is a native Zig daemon backed by LatticeDB; the current implementation is an in-memory Zig prototype with the public JSON-RPC protocol, thin SDK validators, conformance fixtures, and smoke evals.

See [SPEC.md](./SPEC.md) for the full architecture and invariants.

## Status

Implemented now:

- Zig core runtime with `system.health`, `memory.remember`, `memory.search`, `memory.retrieve`, `memory.inspect`, `memory.forget`, `memory.feedback`, `memory.core.get`, and `memory.core.update`.
- In-memory storage adapter with graph-like nodes/edges, simple full-text search, streams, transaction stubs, and invariant verification.
- Deterministic extraction for package manager facts, response-style preferences, and test-command procedures, including temporal supersession and evidence links.
- Retrieval V0 that returns both a rendered prompt and structured context packet, with scope filtering, needs filtering, token budgeting, `validAt`, event windows, warnings, and optional trace output.
- Forgetting paths for dry-run reports, hard-delete tombstones, redaction state, and invalidation of derived memories backed by forgotten evidence.
- JSON-RPC schemas and conformance fixtures shared by SDK tests.
- Thin TypeScript and Python SDKs that validate protocol shape and can call a local `quipu serve-stdio` process.
- Python eval harness with a raw fake baseline and a Zig core smoke baseline.

Not implemented yet:

- Durable LatticeDB storage and migrations.
- Long-running socket or HTTP daemon process.
- Real vector/BM25/reranking retrieval.
- LLM-backed extraction, consolidation workers, and plugin provider loading.
- MCP adapter implementation beyond the design placeholder.

## Architecture

```text
Agent runtime / app
  -> TypeScript SDK, Python SDK, CLI, or future MCP adapter
  -> JSON-RPC 2.0 protocol
  -> Zig core runtime
  -> storage adapter
  -> current in-memory adapter, future LatticeDB adapter
```

The daemon remains the canonical owner of memory semantics. SDKs validate inputs, submit protocol calls, and return typed results; they should not duplicate extraction, retrieval, temporal, or forgetting behavior.

## Quickstart

Build and query the current in-memory core:

```bash
cd core
zig build
./zig-out/bin/quipu health
```

Send one JSON-RPC request over stdin:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":"1","method":"system.health","params":{}}' \
  | ./zig-out/bin/quipu rpc-stdin
```

Use the persistent stdio mode for SDKs and integration tests:

```bash
./zig-out/bin/quipu serve-stdio
```

Example request sequence for `serve-stdio`:

```json
{"jsonrpc":"2.0","id":"1","method":"memory.remember","params":{"scope":{"projectId":"repo:test"},"messages":[{"role":"user","content":"This repo uses pnpm. Run just test before committing.","createdAt":"2026-04-01T10:00:00Z"}]}}
{"jsonrpc":"2.0","id":"2","method":"memory.retrieve","params":{"query":"What should I run before committing?","scope":{"projectId":"repo:test"},"needs":["current_facts","procedural"],"options":{"includeDebug":true}}}
```

Because the current adapter is in-memory, data is lost when the process exits.

## Development

Target contributors should have Zig, Python 3.10 or newer, Node.js, npm, and `just`. Until every toolchain is installed locally, `python3 scripts/run_tests.py` skips unavailable optional checks and CI runs the checks with Python and Node configured.

Common commands:

```bash
just test
just fmt
just ci

cd core && zig build test
cd sdk/typescript && npm test
PYTHONPATH=evals/src python3 -m quipu_evals.runner evals/suites/quipu_synthetic.yaml
PYTHONPATH=evals/src python3 -m quipu_evals.core_runner
```

## Repository Layout

- `core/`: Zig runtime, CLI entrypoint, protocol dispatch, storage adapter boundary, in-memory adapter, deterministic extractor, and core tests.
- `protocol/`: JSON-RPC schemas and conformance fixtures.
- `sdk/typescript/`: thin TypeScript SDK and protocol tests.
- `sdk/python/`: thin Python SDK and protocol tests.
- `evals/`: synthetic scenario schema, fake baseline, Zig core runner, graders, and tests.
- `docs/`: implementation notes for API, algorithms, data model, evals, architecture, security, and publication.
- `mcp/`: MCP adapter placeholder.
- `examples/`: planned integration examples.

## Protocol

Quipu uses JSON-RPC 2.0 envelopes. The current public methods are:

- `system.health`
- `memory.remember`
- `memory.retrieve`
- `memory.search`
- `memory.inspect`
- `memory.forget`
- `memory.feedback`
- `memory.core.get`
- `memory.core.update`

See [protocol/README.md](./protocol/README.md), [docs/api.md](./docs/api.md), and [protocol/schemas/methods.schema.json](./protocol/schemas/methods.schema.json) for the implemented contract.

## License

MIT.
