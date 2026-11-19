# Changelog

## Unreleased

- The Lattice storage adapter targets LatticeDB `0.18.0` and no longer links
  against `0.17.0` or earlier. Stores written with `0.15.0` open as they are.
  A store created by this build cannot be opened by LatticeDB `0.16.0` or
  earlier.
- The adapter turns LatticeDB's changefeed off and drops the events an existing
  store holds. The changefeed keeps the old and new value of every property
  change, so forgotten text stayed in it. Quipu's own streams are unaffected.
- A forgotten or unsearchable node's vector is removed from the vector index
  with LatticeDB `0.18.0`'s `lattice_node_remove_vector`; the node keeps its
  id, labels and edges. Opening a store removes any vector such a node still
  holds.
- Full-text queries split words the way LatticeDB `0.17.0` and later do, so
  words with letters outside ASCII are searched whole. A new store also matches
  them without regard to case or accents; a store created earlier keeps its
  ASCII-only index.
- A store opened with different vector dimensions than it was created with
  fails with `VectorConfigMismatch`.
- Background extraction: `quipu serve --background on` (or
  `QUIPU_BACKGROUND=on`) runs queued `extract` jobs between requests. The model
  calls happen off the request path, so `memory.remember` and retrieval are
  not delayed by them. It is off by default. `memory.extract.run` on such a
  daemon waits for the batch in flight before running the rest. When the
  provider does not answer, jobs keep their attempts and the worker backs off.
- Extracted claims no longer keep relative times. "Yesterday", "last week",
  "10 days ago" and the like are written as calendar dates, resolved against
  the date of the message by a fixed grammar, not by the model: "went to the
  dentist yesterday" is stored as "went to the dentist on Monday, May 8,
  2023". Times that cannot be placed ("recently") get "(said on DATE)". A
  claim that names one day takes that day as its `eventDate`. The model's
  wording is kept as `statedText` and remains what search indexes, and the
  extract job result counts
  `timesResolved`, `eventDatesDerived` and `eventDatesCorrected`.
- Extracted claims place loose counts of time. "A few weeks ago", "several
  months ago" and "a couple of days ago" are read as three, five and two, and
  the claim keeps the words with the date after them: "a few weeks ago (around
  April 18, 2023)". They used to get "(said on DATE)".
- Extracted claims store the days their event may have happened on, as
  `eventStart` and `eventEnd`, whenever the claim names one time: a day, a
  week, a weekend, a month, a year, or a counted time such as "two weeks ago"
  with the same slack a question naming it gets. A question that names a time
  brings in claims whose span overlaps it, not only claims dated to one day.
  The model's `eventDate` is dropped when it disagrees with the span, and the
  extract job result counts `eventSpans`. Claims stored earlier keep working
  by their `eventDate`.
- Consolidation of knowledge updates, off by default: with `--consolidate on`
  (or `QUIPU_CONSOLIDATE=on`) each extracted conversation queues a
  `consolidate` job. It asks the extract model which earlier claims of the same
  author the new claims replace, then verifies each proposed pair with a second
  call and a deterministic check of both values against the claim texts. A
  pair that passes is stored as an `Update` node, derived from both claims and
  evidenced by both messages, so forgetting either removes it. No message or
  claim is rewritten. Run the jobs with `quipu jobs run consolidate`,
  `memory.consolidate.run`, or the background worker.
- `options.facts` on `memory.retrieve` and `memory.answer` (default `false`)
  puts the matching claims that consolidation found replaced, each with the
  claim that replaced it, ahead of the raw evidence as dated lines:
  `(superseded, DATE to DATE)` and `(current, from DATE)`, using at most 30%
  of the token budget. A claim with no replacement is not listed, so a
  question that touches no replaced fact gets no facts section. The facts are
  items of type `fact` in
  `context.currentFacts`, and `trace.facts` counts them. `system.health`
  reports `capabilities.facts` and a real `workers.consolidator` state.
- When the question names a time ("10 days ago", "last Saturday", "in
  January") and `time.validAt` is given, `memory.retrieve` and
  `memory.answer` resolve it by date arithmetic: what people said inside that
  window is placed ahead of the other candidates, within half the token
  budget; a `Time references:` line states the resolved date; and each
  session dated inside the window says so in its header (`this is the
  question's "last Saturday"`). A hedge ("roughly two weeks ago") widens the
  window and a weekday ("the Wednesday two months ago") narrows it to a day.
  There is no option: `options.timeAnchors`, which gated the first part while
  it was being measured, is gone, and the `Time references:` line no longer
  needs `options.temporalHints`. `trace.timeAnchors` counts the windows and
  items, and `system.health` reports `capabilities.timeAnchors`.
- Pattern nodes. After a conversation is extracted, a `pattern` job groups
  alike sentences that people wrote on different occasions and, for a group of
  six or more occasions, asks the extract model what the group is about, which
  generalisations it might support, and whether each one's circumstance and
  outcome were present on each occasion. The daemon counts the answers and
  keeps a generalisation only when the counts support it (Fisher's exact test,
  p ≤ 0.06, and a difference of at least 60 points). The result is a `Pattern`
  node evidenced by every message it counts: either the regularity with its
  counts, or the statement that the occasions were compared and nothing held.
  There is no option. It needs a store that embeds text and an extract
  provider, uses the extract model unless `--pattern-model` (or
  `--pattern-provider`, `--pattern-url`, `QUIPU_PATTERN_*`) names another,
  and runs in the background worker, with `quipu jobs run patterns`
  or with `memory.patterns.run`. Sentence vectors are kept in `SentenceIndex`
  nodes, one per message, without the text.
- `memory.retrieve` and `memory.answer` show a pattern node to a question it
  owns (more than half of the ten stored sentences nearest the question are
  the node's own): a `<patterns>` section ahead of the raw evidence, an item
  of type `pattern` in the new `context.patterns` array, and `trace.patterns`.
  At most one node, at most 40% of the token budget. `context.patterns` is
  always present and empty for a question no node owns. `system.health`
  reports `capabilities.patterns` and `workers.patterns`.
- Forgetting a message tombstones its sentence index and every pattern node
  that counted it, and queues a rebuild of the scope's pattern nodes from what
  remains. A pattern node forgotten on its own, with its messages kept, may be
  worked out again by a later pass.
- A chat call to a model provider is given up after five minutes with
  `ProviderTimeout`. It used to wait without limit, so a connection that died
  while the machine slept left `memory.extract.run`, or the background
  worker's batch, waiting for good.
- Job leases use wall-clock time (they used 0), and an expired lease returns
  its job to `pending`, or dead-letters it once its attempts run out.
  `quipu jobs lease|complete|fail` record real times too.
- `system.health` reports `workers.extractor` as `stopped` when an extract
  provider is configured but jobs run only on request (it said `running`), and
  `workers.entityResolver` as `stopped` when configured, for the same reason.
- LLM fact extraction: `quipu jobs run extract` (and the operational
  `memory.extract.run` RPC) runs the queued `extract` jobs through a chat model
  configured with `--extract-provider`, `--extract-url` and `--extract-model`
  (falling back to `--llm-*`). The prompt (`quipu.extract.speaker-facts.v4`)
  asks for the facts each author states about themselves, with an optional
  event date; the assistant's replies are not sent. Claims are grounded on a
  quote from the message with unique-quote index repair, and malformed JSON
  gets bounded retries. Accepted claims become `Assertion` nodes linked
  `EVIDENCED_BY` to their message and chunk. Quarantined claims are counted on
  the job, never stored. Forgetting a message tombstones its assertions.
- `options.factKeys` on `memory.retrieve` and `memory.answer` (default `false`):
  assertion hits return their source chunk or message, never the claim, and
  raw lines show claim event dates as `[event YYYY-MM-DD]`. With it off,
  assertions take no part in retrieval. `trace.factKeys` reports how claims
  shaped the candidates, and `system.health` reports the extractor.
- Memory items may have type `assertion`, but only from `memory.search` with
  `labels: ["Assertion"]`.
- `memory.retrieve` and `memory.answer` accept `options.queryExpansion`: `off`
  (default, unchanged retrieval), `rules` (deterministic splits of choice
  questions and `between X and Y` intervals), or `llm` (up to four sub-queries
  from a chat provider that sees only the question). Each query runs the
  normal candidate generation; the lists are fused by reciprocal rank, and each
  query's top two items lead the fused list. A failed LLM expansion falls back
  to the original query with the `query_expansion_failed` warning.
  `trace.queryExpansion` and `answerTrace.queryExpansion` report the queries,
  and `system.health` reports `capabilities.queryExpansion`.
- New `--expand-provider`, `--expand-model`, and `--expand-url` flags (and
  `QUIPU_EXPAND_*` variables) choose the expansion provider. It defaults to the
  answer provider.
- The Lattice storage adapter targets LatticeDB `0.15.0` and no longer builds
  against `0.8.x` or earlier. **Database files written by earlier LatticeDB
  versions or earlier Quipu builds are not compatible and must be rebuilt** by
  re-ingesting into a new `--db` path; Quipu is pre-release and does not migrate
  them.
- Nodes carry a shared `QuipuNode` label and are enumerated by label scan; edges
  are native Lattice edges; streams use native sequence numbers.
- Full-text search covers only a node's `searchText`, `content`, `text`, or
  `name` (entities fall back to canonical name and aliases), ranks by BM25 over
  any query term, and excludes internal, `Session`, `Turn`, `searchable:false`,
  and deleted nodes. Property names and other property values no longer match.
- `Chunk` nodes are vector-indexed. Forgotten or unsearchable nodes lose their
  embedding.
- With the `openrouter` or `openai` embedding provider, vectors default to the
  model's native 1536 dimensions and the `dimensions` request parameter is sent
  only when a width is configured.
- Forgetting, supersession, core blocks, related cards, job leasing and the
  inspect audit trail no longer enumerate the first 1,000 (or 100,000) nodes or
  audit events. On stores past that size they missed every node outside the
  scan's first 1,000, an arbitrary subset on both backends: forgetting could
  leave derived facts, cards, episodes or core blocks that still carried the
  deleted text, and supersession could leave two current values for a slot.
- An empty full-text query on the Lattice adapter now enumerates in creation
  order, as documented, instead of label-scan order.
- The storage adapter contract adds `findNodes`: paged lookups by label and by
  top-level property, in creation order. `slotKey`, `state`, `evidenceQid`,
  `blockKey`, `cardKind` and `status` are indexed. The Lattice adapter backs
  them with native equality indexes and backfills older stores when it opens
  them.
- The in-memory adapter keeps nodes in creation order and indexes edges by
  endpoint, so `findEdges` costs the node's degree.
- The forget closure follows `EVIDENCED_BY`, `DERIVED_FROM` and
  `COMPILED_FROM` edges (and `evidenceQid`) for any label, transitively.
  Forgetting any message of a turn now forgets the turn's episode, not only
  forgetting its first message. An entity mentioned only by forgotten messages
  is forgotten with them. Forget-by-query selects every match instead of the
  top 1,000.
- Tombstones of raw text keep `leakFingerprints`, hashes of 8-token windows of
  the forgotten text. `quipu verify` adds forgetting checks (tombstones without
  text, live memory derived or compiled from forgotten evidence, entities
  mentioned only by forgotten nodes, duplicate current slots), and `quipu verify leaks` / `--leaks` / `all` scans live
  text for copies of forgotten text. Verification issues can carry
  `relatedQid`.
- Superseding a memory now changes only `state` and `validTo`, so a
  superseded memory card keeps its card fields.
- A new memory card links to the newest live cards in scope with its slot,
  then with its kind (up to 8), instead of the first 8 the enumeration
  happened to return.
- `memory.inspect` lists provenance from edges (`evidenced_by`,
  `derived_from`, `compiled_from`) and matches audit events on the exact qid.
- `zig build test -Dtest-filter=TEXT` runs only matching core tests.

## 0.1.0

- Initial specification and repository skeleton.
