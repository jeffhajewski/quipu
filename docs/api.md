# API

See [../SPEC.md](../SPEC.md) for the full design. This file tracks implemented public behavior.

## Retrieval V0

`memory.retrieve` returns both a rendered prompt and a structured context packet. The in-memory core currently supports:

- `needs` filtering for `core`, `current_facts`, `procedural`, `recent_episodes`, and `raw`.
- `budgetTokens` truncation with `token_budget_truncated` warnings.
- `time.validAt` for temporal facts and procedures.
- `time.eventWindowStart` / `time.eventWindowEnd` for timestamped raw and derived memories.
- `options.includeDebug` or `options.logTrace` to include a retrieval trace with candidate, kept, and dropped counts.

The prompt is assembled from the structured context sections, so callers that need typed memory should use `result.context` and callers that need direct model input can use `result.prompt`.

## Search V0

`memory.search` supports `mode: "fts"`, `"vector"`, `"hybrid"`, and `"graph"`.
`fts` and `graph` currently use lexical adapter search. `vector` uses the active
storage adapter's text embedding and vector search when the backend advertises
that capability. `hybrid` merges lexical and vector hits by qid before applying
the normal runtime filters.

`system.health.result.storage` reports backend capability flags, including
`backend`, `durable`, `fullText`, `vector`, `vectorDimensions`, and
`embeddingModel`.
