# API

See [../SPEC.md](../SPEC.md) for the full design. This file tracks implemented public behavior.

## Methods

The daemon dispatches sixteen JSON-RPC methods (`Runtime.dispatch`). Ten are
the public surface: they have a schema in
[`protocol/schemas/methods.schema.json`](../protocol/schemas/methods.schema.json)
and fixtures in `protocol/conformance/`, and the SDKs and the MCP adapter
wrap them. Six are operational: the CLI and the eval harness call them, they
have no schema, and no SDK wraps them.

| Method | Does | Described in |
| --- | --- | --- |
| `system.health` | reports the backend, its capabilities and which workers can run | [how-it-works.md](how-it-works.md#orientation) |
| `memory.remember` | stores and indexes messages, queues the background jobs | [how-it-works.md](how-it-works.md#memoryremember-synchronous) |
| `memory.retrieve` | builds a context for a question | [Retrieval V0](#retrieval-v0) |
| `memory.answer` | builds the same context and has a reader answer from it | [providers.md](providers.md#memoryanswer-reader), [algorithms.md](algorithms.md#answering) |
| `memory.search` | ranked search over raw and derived memory | [Search V0](#search-v0) |
| `memory.inspect` | one node with its evidence and audit events | [Inspection V0](#inspection-v0) |
| `memory.forget` | tombstones nodes and everything derived from them | [Forgetting V0](#forgetting-v0) |
| `memory.feedback` | records a rating for a retrieval id | [data-model.md](data-model.md#deterministic-derived-memory) (`Feedback`) |
| `memory.core.get` | reads the core blocks of a scope | [data-model.md](data-model.md#deterministic-derived-memory) (`Core`) |
| `memory.core.update` | writes or replaces a core block | [data-model.md](data-model.md#deterministic-derived-memory) (`Core`) |
| `memory.core.consolidate` | compiles a core block from a scope's memories | [Operational methods](#operational-methods) |
| `memory.extract.run` | runs pending `extract` jobs | [Operational methods](#operational-methods) |
| `memory.consolidate.run` | runs pending `consolidate` jobs | [Operational methods](#operational-methods) |
| `memory.summaries.run` | runs pending `summary` jobs | [Operational methods](#operational-methods) |
| `memory.patterns.run` | runs pending `pattern` jobs | [Operational methods](#operational-methods) |
| `memory.entityResolve.run` | runs pending `entity_resolve` jobs | [Operational methods](#operational-methods) |

The dispatcher's error responses carry one of three string codes:
`invalid_request` (a missing or malformed parameter), `not_found` (an
unknown method or qid) and `provider_error` (a job runner was called with no
usable provider).

### Operational methods

The five `*.run` methods are what `quipu jobs run
extract|consolidate|summaries|patterns|entity-resolve` calls. Each leases
the pending jobs of its kind, runs them and returns when they are done, so a
caller that holds a daemon open (the eval harness) can run the background
work at a moment of its choosing instead of with `--background on`. In a
daemon whose background worker has a batch in flight, the batch is finished
first. What each job does is in
[how-it-works.md](how-it-works.md#the-background-work-in-the-order-the-worker-runs-it).

Parameters, all optional: `owner` (the lease owner, a label), `limit` (jobs
to lease, default 100,000) and, for `memory.extract.run` and
`memory.consolidate.run`, `concurrency` (provider calls at once, default 8).
Every result has `leasedCount`, `succeededCount`, `failedCount` and
`lastError`. The model-backed four add `provider`, `model`, `promptVersion`,
`calls` and `counts`, and:

| Method | Also returns |
| --- | --- |
| `memory.extract.run` | `materializedCount`, `jsonRetries`, `sourceMessages`, `assertionsWritten`, `recallMessages`, `recallAssertions` |
| `memory.consolidate.run` | `claims`, `earlier`, `updatesWritten` |
| `memory.summaries.run` | `scopes` |
| `memory.patterns.run` | `scopes` |
| `memory.entityResolve.run` | `materializedCount` |

The extract, consolidate and summary runners answer `provider_error` when no
extract provider is configured, and the pattern runner when neither a
pattern provider nor an extract provider is.

`memory.core.consolidate` takes `scope`, `blockKey` (default
`project_summary`) and `limit` (default 50), compiles a `Core` block from up
to `limit` live memories of the scope, oldest first, and returns `blockQid`,
`blockKey`, `status` (`stored` or `updated`) and `sourceCount`. The block has
a `COMPILED_FROM` edge to each source, so forgetting a source forgets the
block. It makes no model call.

## Retrieval V0

`memory.retrieve` returns both a rendered prompt and a structured context packet. The in-memory core currently supports:

- `needs` filtering for `core`, `current_facts`, `preferences`, `procedural`, `recent_episodes`, and `raw`.
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

Summary nodes need no option either, and they are read first. When the
background work has written session and topic summaries for the scope, the
question is compared with them and with the claims under them. The topics it
is nearest are shown in a `<threads>` section ahead of the sessions, each
under its title and summary with its facts as dated lines, and are returned
in `context.threads`: a topic as one item of type `summary` whose evidence
is the message of each fact shown, quoting the fact, and a fact outside any
topic as an item of type `assertion`. The dated facts nearest the question,
up to four, lead the topics in the order they happened, each an item of type
`assertion`, with a line under them that gives the days between them. Raw
evidence then comes only from the sessions the summaries and those facts
point at, and from sessions not summarised yet, and each session header
carries the session's title and, while the summaries fit in 15% of the
budget left after the facts and patterns sections, its summary. The section uses at most 45% of the token budget left
after the facts and patterns sections. A scope with no summaries has an empty
`context.threads` and the context it would have had. The trace gains a
`threads` block when summaries were read. See
[algorithms.md](algorithms.md#reading-the-summaries-first).

## Search V0

`memory.search` supports `mode: "fts"`, `"vector"`, `"hybrid"`, and `"graph"`.
`vector` uses the active storage adapter's text embedding and vector search when
the backend advertises that capability. `hybrid` uses reciprocal-rank fusion
over lexical and vector hits. `graph` expands lexical/hybrid seeds through
resolved entity edges before applying the normal runtime filters.

`Entity`, `Assertion` and `Update` nodes are hidden from search results
unless `labels` names the label; an `Assertion` result has type `assertion`.

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

`mode` is `hard_delete`, `redact` or `expire`. In every mode the node's
properties are replaced by a tombstone that keeps its qid, label and edges
and none of its text, and the node leaves the full-text and vector indexes.
The modes differ in what the tombstone records: `redact` leaves `state:
"redacted"` and is counted in `nodesRedacted`; `hard_delete` and `expire`
leave `state: "deleted"` and are counted in `nodesDeleted`. Nodes reached
through propagation are always tombstoned as `hard_delete`.

`jobsQueued` lists the jobs the call queued: one `summary` job and one
`pattern` job for each scope that lost a summary or a pattern node, which
rebuild that scope's nodes from what remains. It is empty for a dry run and
when nothing derived by those jobs was forgotten.
