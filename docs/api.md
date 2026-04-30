# API

See [../SPEC.md](../SPEC.md) for the full design. This file tracks implemented public behavior.

## Retrieval V0

`memory.retrieve` returns both a rendered prompt and a structured context packet. The in-memory core currently supports:

- `needs` filtering for `core`, `current_facts`, `procedural`, `recent_episodes`, and `raw`.
- `budgetTokens` truncation with `token_budget_truncated` warnings.
- `time.validAt` for temporal facts and procedures.
- `time.eventWindowStart` / `time.eventWindowEnd` for timestamped raw and derived memories.
- `options.includeDebug` or `options.logTrace` to include a retrieval trace with candidate, kept, and dropped counts.
- Optional `mode` values `fts`, `vector`, `hybrid`, and `graph`. Retrieval
  defaults to lexical search unless the active storage backend advertises a
  non-hash embedding model, in which case it defaults to hybrid search.

The prompt is assembled from the structured context sections, so callers that need typed memory should use `result.context` and callers that need direct model input can use `result.prompt`.

`memory.answer` accepts the same retrieval fields, runs the same scoped context
assembly, and returns `answer`, `provider`, optional `model`, `items`, `context`,
warnings, and optional trace output. It uses a deterministic local fallback when
no answer provider is configured, or an OpenRouter-compatible chat model when
the process is started with `--answer-provider openrouter`.

## Search V0

`memory.search` supports `mode: "fts"`, `"vector"`, `"hybrid"`, and `"graph"`.
`vector` uses the active storage adapter's text embedding and vector search when
the backend advertises that capability. `hybrid` uses reciprocal-rank fusion
over lexical and vector hits. `graph` expands lexical/hybrid seeds through
resolved entity edges before applying the normal runtime filters.

`system.health.result.storage` reports backend capability flags, including
`backend`, `durable`, `fullText`, `vector`, `vectorDimensions`, and
`embeddingModel`.

Lattice-enabled CLI processes accept storage-level vector flags before the
command: `--vector-dimensions`, `--page-size`, `--embedding-provider`,
`--embedding-url`, and `--embedding-model`. The matching environment variables
are `QUIPU_VECTOR_DIMENSIONS`, `QUIPU_LATTICE_PAGE_SIZE`,
`QUIPU_EMBEDDING_PROVIDER`, `QUIPU_EMBEDDING_URL`,
`QUIPU_EMBEDDING_MODEL`, and `QUIPU_EMBEDDING_API_KEY`.

Answer and entity-resolution providers are configured with
`--answer-provider`, `--answer-url`, `--answer-model`, `--entity-provider`,
`--entity-url`, and `--entity-model`. Matching environment variables are
`QUIPU_ANSWER_PROVIDER`, `QUIPU_ANSWER_URL`, `QUIPU_ANSWER_MODEL`,
`QUIPU_ENTITY_PROVIDER`, `QUIPU_ENTITY_URL`, and `QUIPU_ENTITY_MODEL`; all
OpenRouter-compatible chat calls use `OPENROUTER_API_KEY` unless
`QUIPU_MODEL_API_KEY` is set.

## Inspection V0

`memory.inspect` returns the stored node, provenance references, dependent
derived memories, and stream-backed audit records that mention the inspected
qid. Audit records currently expose the stream name, sequence, and raw JSON
payload.

## Forgetting V0

`memory.forget` accepts explicit `selector.qids` and query-based selectors with
`selector.query`, `selector.scope`, and `selector.timeWindow`. Dry runs return
the same closure report without mutating storage.

When propagation is enabled, forgetting a raw evidence node tombstones derived
facts, preferences, procedures, memory cards, episodes, and any core summaries
compiled from those nodes. The result reports matched roots, deleted or redacted
roots, invalidated fact-like memories, contaminated summaries, and per-node
actions in `report`.
