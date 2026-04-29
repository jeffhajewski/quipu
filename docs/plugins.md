# Plugins

Quipu's first plugin-facing surface is the MCP adapter in
[`../mcp`](../mcp). It is intentionally thin: MCP tools map one-to-one to public
Quipu JSON-RPC methods and forward requests to `quipu serve-stdio`.

Implemented MCP tools:

- `quipu_health`
- `quipu_remember`
- `quipu_retrieve`
- `quipu_search`
- `quipu_inspect`
- `quipu_forget`
- `quipu_feedback`
- `quipu_core_get`
- `quipu_core_update`

## Provider Boundary

`core/src/providers.zig` now defines the first provider-facing boundary:

- `ProviderConfig`: extractor, embedding, and reranker endpoint descriptors.
- `ProviderEndpoint`: `none`, `deterministic`, `command`, or `http` provider
  shape.
- `ExtractorPlugin`: vtable-based extractor interface used by the runtime.

The runtime still uses the deterministic extractor by default, but it now calls it
through `ExtractorPlugin`. Command and HTTP providers are validated as config
shapes only; execution, sandboxing, retries, and schema-checked provider output
are the next implementation layer.
