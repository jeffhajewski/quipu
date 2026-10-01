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

The prompt is assembled from the structured context sections, so callers that need typed memory should use `result.context` and callers that need direct model input can use `result.prompt`. Derived memory renders in its own sections with state and validity dates. Raw evidence is grouped by session in chronological order, with dated session headers and `[qid] speaker: text` lines. When `time.validAt` is set, the prompt starts with `Current date: YYYY-MM-DD (Weekday)`. See [algorithms.md](algorithms.md#context-rendering).

`memory.answer` accepts the same retrieval fields, runs the same scoped context
assembly, and returns `answer`, `provider`, optional `model`, `items`, `context`,
`confidence`, warnings, and optional trace output. When `options.includeDebug`
is true, the response also includes `prompt`, the exact memory context string
sent to the reader. Otherwise `prompt` is `null`. When `options.includeDebug`
or `options.logTrace` is true, answer responses also include `answerTrace`:
the answer path (`llm_reader`, `deterministic_fallback`, or `abstain`),
answerability, support qids, `supportValid`, candidate answers, raw provider
text when present, normalized answer, and validation status.

There is one answer path. With an answer provider configured, every non-empty
context goes to the reader along with the question date. With no retrieved
items, the answer is `[abstain]` and no provider is called. With no provider,
a deterministic fallback returns the top current derived fact's value, or else
the top raw evidence text. Reader support qids are checked against the
retrieved items. Unknown qids are dropped and set `supportValid: false` with an
`invalid_support` warning, but the reader's answer is kept. An honest
`answerable: false` answer is also kept. `confidence` comes from the reader's
value, clamped to `[0, 1]`.

`options.abstainIfWeak` is supported on `memory.answer`. The default is
backward-compatible (`false`). When set to `true`, unanswerable, unsupported, or
unparseable answers return exactly `[abstain]`. Reader prompt, JSON mode, and
provider wire formats are documented in
[providers.md](providers.md#memoryanswer-reader).

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

LLM-backed answer and entity-resolution providers can be configured once with
`--llm-provider`, `--llm-model`, `--llm-base-url`, `--llm-api-key`,
`--llm-temperature`, and `--llm-max-tokens`, or separately with
`--answer-provider`, `--answer-url`, `--answer-model`, `--entity-provider`,
`--entity-url`, and `--entity-model`. Matching environment variables include
`QUIPU_LLM_PROVIDER`, `QUIPU_LLM_MODEL`, `QUIPU_LLM_BASE_URL`,
`QUIPU_LLM_API_KEY`, `QUIPU_ANSWER_PROVIDER`, `QUIPU_ANSWER_MODEL`,
`QUIPU_ENTITY_PROVIDER`, and `QUIPU_ENTITY_MODEL`. See
[`docs/providers.md`](providers.md) for provider IDs, API key variables, and
config file examples.

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
