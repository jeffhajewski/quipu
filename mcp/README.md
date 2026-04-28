# Quipu MCP Adapter

Expose Quipu memory tools to MCP-compatible hosts while keeping all memory
semantics in the Quipu JSON-RPC core.

The adapter is a dependency-free Node stdio server. It speaks MCP JSON-RPC on
stdin/stdout and forwards tool calls to `quipu serve-stdio`.

## Usage

Build the core binary first:

```bash
cd ../core
zig build
```

Then run the adapter:

```bash
node mcp/src/server.mjs
```

By default the adapter uses `core/zig-out/bin/quipu serve-stdio`. To point at a
different core binary, set `QUIPU_CORE_BINARY`.

## Tools

- `quipu_health`
- `quipu_remember`
- `quipu_retrieve`
- `quipu_search`
- `quipu_inspect`
- `quipu_forget`
- `quipu_feedback`
- `quipu_core_get`
- `quipu_core_update`

Resources and prompts are intentionally empty for now. The first adapter pass is
limited to a thin tool bridge over the public Quipu protocol.
