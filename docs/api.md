# API

See [../SPEC.md](../SPEC.md) for the full design. This file tracks implemented public behavior.

## Retrieval V0

`memory.retrieve` returns both a rendered prompt and a structured context packet. The in-memory core currently supports:

- `needs` filtering for `core`, `current_facts`, `procedural`, `recent_episodes`, and `raw`.
- `budgetTokens` truncation with `token_budget_truncated` warnings.
- `time.validAt` for temporal facts and procedures.
- `time.eventWindowStart` / `time.eventWindowEnd` for timestamped raw and derived memories.
- `options.includeDebug` or `options.logTrace` to include a retrieval trace with candidate, kept, and dropped counts.
- `options.rerank` (default `true`) and `options.rerankCandidates` (default 50)
  for the optional cross-encoder reranker. Both are ignored when no reranker is
  configured. With one configured, the trace gains a `rerank` block and a
  failed call adds the `rerank_failed` warning. See
  [providers.md](providers.md#reranker).
- Optional `mode` values `fts`, `vector`, `hybrid`, and `graph`. Retrieval
  defaults to lexical search unless the active storage backend advertises a
  non-hash embedding model, in which case it defaults to hybrid search.
- `options.queryExpansion` (`off` by default, `rules`, or `llm`) runs
  candidate generation for the query and for sub-queries split from it, then
  fuses the lists, so both sides of "which came first, X or Y?" reach the
  budget. `rules` is deterministic; `llm` sends only the question to the
  expansion provider and falls back to the query alone with the
  `query_expansion_failed` warning. `memory.answer` accepts it too. The trace
  and `answerTrace` gain a `queryExpansion` block. See
  [algorithms.md](algorithms.md#query-expansion).

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

Two more `memory.answer` options default to `false`:

- `options.readerReasoning` asks the reader to review the evidence in a
  `reasoning` field before answering. The review is returned as
  `answerTrace.reasoning`, never in `answer`.
- `options.temporalHints` appends each session header's offset from
  `time.validAt` (`, 10 days ago`). `memory.retrieve` accepts it too. See
  [algorithms.md](algorithms.md#temporal-hints).

`answerTrace` reports `readerMode` (`none`, `direct`, or `reasoning`),
`temporalHints`, and `timeReferences`, plus `queryExpansion` when
`options.queryExpansion` is not `off`.

`options.factKeys` (on `memory.retrieve` and `memory.answer`, default `false`)
lets claims written by LLM fact extraction (`quipu jobs run extract`) act as
extra search keys. An assertion hit is returned as its source chunk or message,
never as the claim, and raw lines show the claims' event dates as
`[event YYYY-MM-DD]`. The trace gains a `factKeys` block. With the option off,
assertions take no part in retrieval. See
[algorithms.md](algorithms.md#fact-keys).

`options.facts` (on `memory.retrieve` and `memory.answer`, default `false`)
puts the matching claims that consolidation (`--consolidate on`) found
replaced, each with the claim that replaced it, ahead of the raw evidence, as
a `<facts>` section of dated lines: `(superseded, YYYY-MM-DD to YYYY-MM-DD)`
and `(current, from YYYY-MM-DD)`. A claim with no replacement is not listed,
so there is no section when the question touches no replaced fact. The section
uses at most 30% of the token budget, taken from the raw evidence. The facts
are returned in `context.currentFacts` as items of type `fact` whose evidence
is the message they were drawn from; a superseded one has
`state: "superseded"` and `validTo` set. The trace gains a `facts` block. `Update` nodes are never returned as
items. See [algorithms.md](algorithms.md#the-facts-section).

A question that names a time ("what did I buy 10 days ago?", "who did I go
with last Saturday?") needs no option. With `time.validAt` given, the time is
resolved by date arithmetic to a window of days. What people said inside that
window is placed ahead of the other candidates, most relevant first, using at
most half the token budget; the resolved date is stated on a
`Time references:` line (`"last Saturday" = 2023-03-04 (Sat)`) after
`Current date:`; and each session dated inside the window says so in its
header. A question that names no time is unaffected. The trace gains a
`timeAnchors` block. See [algorithms.md](algorithms.md#time-anchors).

Pattern nodes need no option. When the background work has built a node from
occasions that recur (the same kind of thing told on six or more days), and
the question is about those occasions, the node is placed ahead of the raw
evidence in a `<patterns>` section and returned in `context.patterns` as one
item of type `pattern`. Its text says that the memory worked it out and from
how many occasions, and its evidence is the messages of those occasions, each
quoted. It uses at most 40% of the token budget. A question no node owns has
an empty `context.patterns` and the context it would have had. The trace
gains a `patterns` block when the scope has a node that could be shown. See
[algorithms.md](algorithms.md#pattern-nodes).

## Search V0

`memory.search` supports `mode: "fts"`, `"vector"`, `"hybrid"`, and `"graph"`.
`vector` uses the active storage adapter's text embedding and vector search when
the backend advertises that capability. `hybrid` uses reciprocal-rank fusion
over lexical and vector hits. `graph` expands lexical/hybrid seeds through
resolved entity edges before applying the normal runtime filters.

`Assertion` nodes are hidden from search results unless `labels` includes
`"Assertion"`; such results have type `assertion`.

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
qid. Provenance lists the targets of the node's `EVIDENCED_BY`, `DERIVED_FROM`
and `COMPILED_FROM` edges (relations `evidenced_by`, `derived_from`,
`compiled_from`), plus its `evidenceQid` when no edge records it. Dependents
are the live nodes derived directly from it, whatever their label. Audit
records come from the whole audit stream, read page by page, and match the qid
as a JSON string. They expose the stream name, sequence, and raw JSON payload.

## Forgetting V0

`memory.forget` accepts explicit `selector.qids` and query-based selectors with
`selector.query`, `selector.scope`, and `selector.timeWindow`. Dry runs return
the same closure report without mutating storage.

A query selector selects every full-text match, not only the best-ranked ones,
so a dry run reports the full set a forget would touch.

When propagation is enabled, forgetting a raw evidence node tombstones every
node derived from it through `EVIDENCED_BY` or `DERIVED_FROM` edges, whatever
its label and at any depth: facts, preferences, procedures, memory cards,
episodes, and any new derived label. Core summaries compiled from those nodes
are contaminated and tombstoned, and entities that only forgotten messages
mention are forgotten. Each node is reported once per request. The
result reports matched roots, deleted or redacted roots, invalidated fact-like
memories, contaminated summaries, and per-node actions in `report`. The
closure follows edges, so it is complete at any store size. See
[algorithms.md](algorithms.md#forgetting-v0).
