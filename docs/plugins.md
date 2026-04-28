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

Provider plugins for extractors, embedders, rerankers, and consolidation workers
remain design-level only. See [../SPEC.md](../SPEC.md) for the full plugin
architecture.
