# Algorithms

See [../SPEC.md](../SPEC.md) for the full design.

## Search V0

`memory.search` accepts `mode` values of `fts`, `vector`, `hybrid`, and `graph`.
Every adapter indexes one text per node: `searchText` ?? `content` ?? `text` ??
`name` from the node's properties, never the whole properties JSON. Nodes with
`searchable: false`, internal bookkeeping labels (`Job`, `Idempotency`,
`Schema`, `Migration`), and the `Session` / `Turn` containers are never search
hits. Full-text hits are returned sorted by descending score and truncated only
after sorting. An empty query still enumerates nodes, but no runtime path uses
it any more: maintenance work goes through node lookups (below).

The in-memory adapter scores full-text queries with BM25 (k1 = 1.2, b = 0.75)
over lowercased alphanumeric tokens, with a small stopword list and simple
plural folding. Its vector mode returns no hits because it does not advertise
vector capability. The Lattice adapter indexes deterministic
`lattice_hash_embed` vectors by default, or OpenAI-compatible provider
embeddings when configured, as nodes are written. It embeds vector queries
through the same provider and uses Lattice vector search for `vector` and
`hybrid` modes. `hybrid` sorts each channel by score, then fuses lexical and
vector ranks with reciprocal-rank fusion (k = 60) before the runtime applies
scope, deleted-state, label, and temporal filters.

`graph` mode starts from the same lexical or hybrid seed set, expands through
stored `Entity` nodes connected by `MENTIONS` / `MENTIONED_IN` edges, then
applies the normal runtime filters. Entity nodes are indexed by their canonical
name and aliases (`searchText`) for seeding, but are hidden from retrieval
results unless callers explicitly request the `Entity` label. Mentions are
recorded on messages: a chunk hit expands through its parent message, and a
chunked message reached through an entity contributes its chunks.

### Index units: messages and chunks

`memory.remember` stores every message as a `Message` node with `sessionQid`,
`sessionId` (caller-provided, nullable), `turnQid`, and `messageIndex` (0-based
position in the call). A message longer than 1,200 bytes is also split into
`Chunk` nodes (`kind: "chunk"`, `content`, `role`, `createdAt`, `messageQid`,
`chunkIndex`, `chunkCount`, the session/turn fields, scope, and
`privacyClass`), linked by `Message -[HAS_CHUNK]-> Chunk` and
`Chunk -[EVIDENCED_BY]-> Message`. Splits prefer a paragraph break, then a
sentence or line end, then whitespace within the last 200 bytes before the
limit, and never split a UTF-8 codepoint. Concatenating the chunks reproduces
the original content exactly, so the full raw text is preserved even though the
`Message` node's own `content` is clamped. A chunked message is marked
`searchable: false` with a `chunkCount`; shorter messages stay unchunked and are
searched directly. `Episode` nodes are `searchable: false` while they only copy
the first message of a turn.

### Node lookups

Maintenance paths never enumerate "every node" through search. They use
`findNodes`, part of the storage adapter contract, and edge lookups:

- `findNodes` selects nodes by label and by exact values of top-level string
  properties, in creation order (oldest or newest first), one page at a time
  with a cursor. Paging continues until the matches run out; no caller stops
  at a fixed cap.
- `slotKey`, `state`, `evidenceQid`, `blockKey`, `cardKind` and `status` are
  indexed. A lookup on them costs about the size of its result. The Lattice
  adapter mirrors them into native node properties behind equality indexes,
  and backfills the copies when it opens an older store. The in-memory adapter
  caches the values per node. Other properties are matched by a scan.
- Edge lookups by source or target (`findEdges` with `from_qid` or `to_qid`)
  use per-node edge indexes on both backends. Closures pass an unlimited limit.

| Path | Lookup |
| --- | --- |
| Supersession | `slotKey` = slot and `state` = `current` |
| Related memory cards | `MemoryCard` by `slotKey`, then by `cardKind`, newest first |
| Core get, retrieval core items | label `Core`, plus `blockKey` when given |
| Core consolidation | every node, oldest first, until `limit` sources |
| Job leasing | label `Job` with `status` = `pending`, oldest first |
| Forget closure, inspect | provenance edges plus `evidenceQid` |
| Inspect audit trail | the audit stream, read page by page to the end |
| `quipu verify` | every node, page by page |

## Retrieval V0

Candidate generation uses lexical search by default for in-memory and
hash-vector stores, and hybrid search by default when the active backend
advertises a non-hash embedding model. Callers can override this with
`mode: "fts"`, `"vector"`, `"hybrid"`, or `"graph"`.

1. Search the adapter with the selected candidate mode; every mode returns hits
   sorted by descending score. The runtime asks for four times the candidate
   limit (80 items) so filtering still leaves enough chunks to fill the budget.
2. Apply scope, deleted-state, temporal validity, and event-window filters.
   `Session`, `Turn`, internal, and `searchable: false` nodes never become
   items unless the label is explicitly requested.
3. Map hits to items and sort them by score (ties: newer first). A chunk hit is
   a raw-evidence item of type `message` whose qid is the chunk and whose
   evidence points at the parent message.
4. Optionally add scoped core blocks when `needs` includes `core`.
5. Filter candidates by requested memory needs.
6. Apply the raw-evidence policy. Raw items stay eligible and compete by rank
   alongside derived memory. A raw item is dropped only when its message is the
   evidence of a slot memory that is stale at query time (superseded, or not
   valid at `time.validAt`) and the current version of that slot is in the same
   packet, so stale "uses npm" evidence does not sit next to the current "uses
   pnpm" fact. Memory cards that restate a fact, preference, or procedure slot
   already in the packet are dropped as duplicates.
7. Optionally rerank with a cross-encoder. This step runs only when a reranker
   is configured ([providers.md](providers.md#reranker)) and
   `options.rerank` is not `false`. The leading `options.rerankCandidates`
   items (default 50) go to the reranker in one call. Raw evidence is sent as
   `YYYY-MM-DD role: text` from its raw source, so the model sees when and who.
   Derived memory is sent as its text. Those items are reordered by
   descending relevance score, with ties keeping the fused order. Window items
   the reranker did not score follow in fused order, and items past the window
   keep their fused order after them. Item `score` values stay the fused scores;
   rerank scores appear only in `trace.rerank`. If the call fails or times out,
   the fused order stands and the `rerank_failed` warning is added.
8. Pack items greedily in rank order into `budgetTokens` (default 4096),
   estimating each item as `ceil(text_bytes / 4.2) + 16` tokens; the overhead
   covers the rendered line prefix, date and speaker tags, and amortized session
   headers. Items that do not fit are skipped and counted in the trace.
9. Split kept items into context sections and render the prompt from those sections.

Retrieval must return scoped, evidence-backed, budgeted context packets rather
than arbitrary top-k chunks. Reranking changes which items fit the budget, not
how kept items are rendered.

Forgetting a message, whether selected by qid, by a query selector, or through
its `Session` / `Turn`, tombstones and redacts all of its chunks. A query
selector that matches a chunk resolves to the parent message, so the whole
message and every chunk are forgotten together. See [Forgetting V0](#forgetting-v0).

### Context rendering

`memory.retrieve` and `memory.answer` render `prompt` with one deterministic
renderer. Retrieval rank decides which items are kept; it does not decide the
order they are shown in.

```text
Current date: 2023-05-30 (Tuesday)          <- retrieve only, when time.validAt is set
<memory>
<facts>
[q_fact_2] (superseded, 2023-05-01 to 2023-05-22) The repo uses npm.
[q_fact_9] (current, from 2023-05-22) The repo uses pnpm.
</facts>
<sessions>
## session s-early 2023-05-20 (Sat)
[q_msg_3] user: My dog Rex likes the park.
[q_msg_4] 2023-05-21 user: Follow-up written the next day.
## session s-late 2023-05-22 (Mon)
[q_chunk_10_0] assistant (1/2): first 1,200-byte chunk
[q_chunk_10_1] assistant (2/2): second chunk
## other
[q_obs_7] 2023-05-21 observation: Observed build failure
</sessions>
</memory>
```

- Derived memory (`core`, `facts`, `preferences`, `procedures`) is rendered in
  its own sections as `[qid] (state, validity) text`, ordered by `validFrom`.
- Raw evidence (messages, chunks, episodes, observations) is grouped by
  session. The header shows the caller's `sessionId` when present, otherwise
  the session qid, plus the session's earliest ISO date and weekday. Sessions
  are ordered chronologically. Items within a session are ordered by session
  qid, `messageIndex`, `chunkIndex`, then `createdAt`. A line repeats its date
  only when it differs from the session date. Items without a session go last
  under `## other`.
- Message and chunk items supply role, date, session, and index metadata
  through their raw source (the node's `role`, `createdAt`, `sessionQid`,
  `sessionId`, `messageIndex`, `chunkIndex`, `chunkCount`). Other raw items
  read the same properties from their node. If a session id is missing, it is
  looked up on the Session node. Nodes written before these properties existed
  are placed through the owning Turn's `HAS_*` edge. Qids are compared in
  natural order (`q_chunk_9_1` before `q_chunk_10_0`). Session and Turn nodes
  never render as items.
- Text is written on one line with whitespace collapsed. Context section tags
  inside stored text are defanged (`</memory>` becomes `[/memory]`), so memory
  cannot close or forge a section.
- Fixed overhead per item is the bracketed qid, the speaker, and an optional
  date or chunk marker, plus a share of its session header. This fits inside the
  per-item allowance of the budget estimator.

### Temporal hints

`options.temporalHints` (on `memory.retrieve` and `memory.answer`, default
`false`) adds two deterministic hints computed from `time.validAt`. Without a
parseable `validAt`, nothing changes. The hints never affect retrieval.

1. Each dated session header ends with its offset from the question date. The
   offset is in days under 60 days (`today`, `1 day ago`, `10 days ago`), then
   approximate months under two years, then years. Both larger forms keep the
   exact day count:

   ```text
   ## session s01 2023-01-13 (Fri), ~5 months (144 days) ago
   ## session s07 2023-02-11 (Sat), ~4 months (115 days) ago
   ## session s25 2023-04-19 (Wed), 48 days ago
   ## session s40 2023-05-30 (Tue), 7 days ago
   ```

2. A fixed phrase grammar (`core/src/temporal.zig`) resolves relative time
   expressions in the query against the question date. The result is rendered
   as `Time references: "last month" = 2023-04-01 to 2023-04-30; ...` right
   after `Current date:`. In `memory.retrieve` it goes in `prompt`. In
   `memory.answer` it goes in the reader's user turn and in
   `answerTrace.timeReferences`. If nothing matches, the line is omitted.
   Matching is case-insensitive over word tokens, in question order, with
   repeats dropped. N is 1 to 999 or one to twelve. Weeks start on Monday.

   | Phrase | Resolves to |
   | --- | --- |
   | `today`, `yesterday`, `day before yesterday`, `last night` | that day |
   | `N days ago` | that day |
   | `N weeks/months/years ago`, `a week ago` | `around` that day (months clamp to month end) |
   | `past/last/previous N days/weeks/months/years` | N units back to today |
   | `past week/month/year`, `the last week/month/year` | one unit back to today |
   | `last/previous week`, `last weekend` | the previous Monday to Sunday, or its Saturday and Sunday |
   | `last/previous month`, `last/previous year` | the previous calendar month or year |
   | `this week/month/year` | period start to today |
   | `since the start/beginning of the year/month/week`, `since <Month>` | that start to today |
   | `earlier this year/month/week` | period start to yesterday |
   | `last <weekday>` | the most recent such day before today |
   | `last <Month>` | the most recent such month before the current month |
   | `in/during <Month>` | the most recent such month not after the current month |
   | `in/during <Month> [of] <year>`, `<Month> <year>`, `in <year>` | that month or year |

   `last/this/past` + unit is not resolved before `of` ("the last week of
   June"). Month-end and leap-year arithmetic is exact. For example,
   2024-03-31 minus one month is 2024-02-29, and "last month" on 2024-03-01 is
   2024-02-01 to 2024-02-29.

Header offsets add a few tokens per session that the budget estimator does not
count. In a six-question LongMemEval-S smoke run at a 4K budget, they added 16
to 94 context tokens per question, about 50 on average.

### Answering

`memory.answer` runs the same retrieval path and has exactly one answer path.
It never routes on question wording.

1. If retrieval kept no items, the answer is `[abstain]` and no reader is called.
2. If an answer provider is configured, it is always called. The reader gets
   the rendered context and, when `time.validAt` is set, a trusted
   `Current date: YYYY-MM-DD (Weekday)` line in its user turn. The reader prompt
   is described in [providers.md](providers.md#memoryanswer-reader).
3. Without a provider (deterministic/no-key mode), the answer is the value of
   the top current derived fact, or else the top raw evidence text.

Two per-request reader options are off by default, so they can be A/B tested
without changing the default path:

- `options.readerReasoning` uses the reasoning reader prompt (see
  [providers.md](providers.md#optional-reader-modes)). The reader lists the
  relevant lines by qid, date, and speaker, takes the latest value of a changed
  attribute, enumerates before counting, does date math step by step, treats
  its own earlier replies as evidence, grounds recommendations in stated
  preferences, and checks the question's premise. It writes this review in a
  leading `reasoning` field before `answer`.
- `options.temporalHints` adds session offsets and resolved time references
  (see [Temporal hints](#temporal-hints)).

The reader must return
`{"answer":"...","answerable":true|false,"supportQids":[...],"confidence":0..1}`.
The runtime parses it, tolerating code fences, surrounding prose, an
`abstained` flag, and extra keys. It then validates support:

- `supportQids` that are not in the context (item qids or their evidence qids)
  are dropped and the `invalid_support` warning is added. An answerable answer
  with no support adds `missing_support`. In both cases
  `answerTrace.supportValid` is `false`, and the reader's answer is still
  returned. The daemon never invents support qids.
- `answerable: false` keeps the reader's explanation of what is unknown as the
  answer. Unparseable output keeps the raw text with status `parse_error`.
- Only `options.abstainIfWeak: true` replaces an unanswerable, unsupported, or
  unparseable answer with exactly `[abstain]`.
- `confidence` is the reader's value clamped to `[0, 1]`. If the reader gives no
  value, it defaults to 0.5 for answerable answers and 0 otherwise. The
  deterministic fallback reports 0.5 for a derived fact and 0.25 for raw
  evidence.
- In reasoning mode, `reasoning` must be a non-empty string. It is trimmed and
  returned only as `answerTrace.reasoning`, never in `answer`. A missing, empty,
  or null value adds `missing_reasoning`, and any other type adds
  `invalid_reasoning`. Unparseable output adds `missing_reasoning` next to
  `parse_error`. None of these discards the answer or changes the validation
  status. In direct mode a volunteered `reasoning` field is ignored.

`answerTrace.strategy` only describes which path ran: `llm_reader`,
`deterministic_fallback`, or `abstain`. `answerTrace.readerMode` is `none` when
no reader was called, else `direct` or `reasoning`. `answerTrace.temporalHints`
is true when hints were applied (requested, with a parseable `validAt`), and
`answerTrace.timeReferences` holds the `Time references:` payload the reader
received, if any. With `options.includeDebug`, the response also carries
`prompt`, the exact memory context string the reader received. With temporal
hints that includes the header offsets. The `Current date:` and
`Time references:` lines are in the user turn, not in `prompt`.

## Entity Resolution V0

Entity resolution is async. `memory.remember` can publish
`quipu.entity.resolve.requested` events when an entity provider is configured.
`quipu jobs run entity-resolve` materializes those stream entries into durable
jobs, leases them, calls either the deterministic fixture resolver or an
OpenRouter-compatible chat model, validates the JSON entity shape, writes stable
`Entity` nodes, and links source messages through graph edges.

The remote resolver is deliberately outside the synchronous write path so NER/ER
latency does not block ingestion. Graph retrieval improves as entity jobs catch
up, while lexical/vector retrieval remains available immediately.

## Extraction V0

The current extractor is deterministic and intentionally narrow. It emits candidate facts, preferences, and procedures for package manager, test command, repo style, project constraint, and response style memories. It has no benchmark-specific rules.

Matching is case-insensitive and word-bounded, so `npm` does not match inside `pnpm` or `npmjs`, and `just test` does not match inside `adjust test`. Rules also need a cue:

- A package manager must follow a usage word (`uses npm`, `switched to pnpm`), or the text must mention a "package manager".
- A test command must follow an imperative (`run just test`) or appear in backticks.
- A response style must be an explicit request (`prefer concise`, `please be brief`, `response style: detailed`, or a sentence starting with "Be concise"), not descriptive prose such as "to be concise".

Runtime treats extractor candidates as untrusted:

1. Validate that slot, label, value, and text are well formed.
2. Reject label/slot mismatches before any graph write.
3. Supersede only the current memory with the same scoped slot key. The
   `slotKey` and `state` indexes find every current memory for the slot,
   however deep in the store it sits; each match in the candidate's scope is
   rewritten with `state: "superseded"` and `validTo`, keeping all its other
   properties.
4. Store the accepted derived node with temporal validity and raw evidence.
5. Link the derived node to its message evidence with `EVIDENCED_BY`.

This mirrors the future plugin contract: extractor output can propose memories, but deterministic runtime validation owns all mutation.

## Forgetting V0

`memory.forget` selects roots, then tombstones a closure computed from
provenance edges, never from an enumeration of the store.

Roots:

- `selector.qids` names roots directly. A `Session` or `Turn` root also selects
  the messages it holds (`HAS_TURN`, `HAS_MESSAGE`).
- `selector.query` selects every full-text match, not a top-k. A chunk hit
  resolves to its parent message. Internal labels and already-forgotten nodes
  are skipped, and `selector.scope` and `selector.timeWindow` filter the
  matches.

Closure, for each root:

1. A message's chunks (`HAS_CHUNK`) are forgotten with it, in the request's
   mode, whether or not `propagate` is set.
2. With `propagate` (the default), every live node with an `EVIDENCED_BY` or
   `DERIVED_FROM` edge to the root or one of its chunks is invalidated, whatever
   its label, and so on transitively. A node whose `evidenceQid` names forgotten
   evidence is included even if its edge write was lost. Facts, preferences,
   procedures, memory cards and episodes fall out of this rule, and so would
   any new derived label. An episode is derived from every message of its turn,
   so forgetting any of them forgets the episode.
3. Every live node compiled from a forgotten node (`COMPILED_FROM`, which core
   consolidation writes) is contaminated and tombstoned. A block rebuilt in
   place keeps its old edges, so a block whose `evidenceQids` no longer lists
   the forgotten node is left alone.
4. An entity that a forgotten node `MENTIONS` is forgotten once no live node
   outside the request mentions it, since its name came only from forgotten
   text. An entity another live message still mentions stays.

A node reached from several roots is reported and tombstoned once. Dry runs
report the same closure without writing.

A tombstone replaces the node's properties with `kind`, `deleted: true`,
`state`, `mode`, `reason` and `previousLabel`, so the node leaves the full-text
and vector indexes. Tombstones of raw text (`Message`, `Chunk`, `Observation`,
`ToolCall`) also keep `leakFingerprints`: 64-bit hashes of windows of 8
normalized tokens taken every 4 tokens (one hash of the whole text when it has
4 to 7 tokens; shorter texts get none). The text itself is gone. Anyone holding
the store can still test whether a guessed phrase was forgotten.

### Verification

`quipu verify` runs these checks over the whole store, through the adapter
interface, alongside the schema and adapter checks:

- `tombstone_retains_text`: a tombstone still carries content properties.
- `active_derived_from_deleted_evidence`: a live node, or a live chunk, has a
  provenance edge or `evidenceQid` pointing at a tombstone. A forget with
  `propagate: false` leaves these by design.
- `core_compiled_from_deleted_evidence`: a live core block still cites a
  tombstone.
- `entity_only_from_deleted_evidence`: a live entity whose every mention comes
  from a tombstone.
- `duplicate_current_slot`: two current single-value memories share a label,
  scope and slot key.

`quipu verify leaks` (also `--leaks`, and part of `verify all`) adds an
exact-string scan. Every string property of every live node, which covers what
the full-text and vector indexes hold and what core blocks say, is hashed in
the same windows and compared against every tombstone's fingerprints. A copied
run of 11 or more tokens is always caught. A match counts as a leak
(`forgotten_text_leak`, with `relatedQid` naming the tombstone) only when no
live node the copy was derived or compiled from, at any depth, holds the same
window. A fact quoting a live message is not a leak. A raw node with no sources
is its own evidence, so text the user wrote again in another message is not
reported. Forget that message by query instead.

