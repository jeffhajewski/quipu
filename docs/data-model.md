# Data Model

Quipu stores memory as a property graph. This page lists every node label and
edge type the daemon writes, the properties each node carries, and how search,
scope and forgetting read them. It describes the code in `core/src`.
[../SPEC.md](../SPEC.md) describes the design; some labels and edges it names
are not written by the code and are not listed here. For what happens to
these nodes in order, from `memory.remember` to a rendered context, see
[how-it-works.md](how-it-works.md).

## Nodes, edges and qids

A node is a `storage.Node`: a `qid` (its id), a `label`, and
`properties_json`, a JSON object holding every other property. To index a
node, the storage adapter reads only a few properties from the object: the
indexed properties, the search text fields, and the `searchable` and
`deleted` flags (see below). Writing a node with an existing qid replaces its
whole property object.

An edge is a `storage.Edge`: a `qid`, `from_qid`, `to_qid`, `edge_type` and
`properties_json`. Every edge the runtime writes has the properties `{}`. The
adapter interface has no call that deletes a node or an edge.

A qid has the form `q_<prefix>_<suffix>`. The suffix comes from one of three
places.

- **Runtime ids.** `Runtime.nextQid(prefix)` returns `q_<prefix>_<n>`, where
  `n` is the counter `next_id`, which goes up by one on every call. Prefixes:
  `sess`, `turn`, `msg`, `tool`, `obs`, `fact`, `pref`, `proc`, `core`, `fb`,
  `pat`, `sum` and `edge`. The ids `q_retr_<n>` (retrieval ids) and
  `q_del_<n>` (forget requests) use the same counter but name no node; they
  appear only in responses and stream events.
- **Hashes.** `hashQid(prefix, key)` returns `q_<prefix>_<hex>`, the Wyhash
  (seed 2) of a key built from what the node is made from. Writing the same
  thing again yields the same qid, so a job that runs twice rewrites its nodes
  instead of adding copies. Prefixes: `card`, `ep`, `ent`, `asrt`, `upd` and
  `edge`. `Job` qids are hashed the same way with seed 0 (`jobs.jobQid`).
- **Names.** Chunk, sentence index, idempotency, schema and migration qids are
  built from another qid or a fixed name; each label below gives its form.

The in-memory adapter starts the counter at 1 in every process. The Lattice
adapter sets it when it opens a store: it reads the qid of every node and
edge, parses the text after the last `_` as a decimal number, and starts one
past the largest (`trackRuntimeId`). Each later node or edge write raises it
the same way. A hashed or named qid whose suffix happens to be all decimal
digits raises it too.

An edge written by `Runtime.putEdge` takes a runtime id, `q_edge_<n>`. An edge
written by `putDeterministicEdge` takes `hashQid("edge",
"<from>:<type>:<to>")`, so writing it again updates the same edge. The
Lattice adapter refuses an edge whose endpoints are not both stored
(`error.NotFound`); the in-memory adapter does not check.

In LatticeDB each node is a native node with two or three labels: its Quipu
label, `QuipuNode`, and `QuipuSearchable` while it is searchable. It holds the
native properties `qid`, `quipuLabel`, `propertiesJson`, `searchText`, a copy
of each indexed property, and the vector `embedding` when it has one. A node
write with the label `QuipuNode`, `QuipuSearchable` or an empty label is
refused.

Every node has `kind`, a lower-case name of its type (`message`,
`memory_card`, ...), and many also have `qtype` with the same value. Every
node is written with `deleted: false` until it is forgotten.

## Labels

The runtime writes 23 labels. In the table, "Search" is whether the node gets
full-text search text, "Vector" whether the Lattice adapter puts it in the
vector index, and "Hidden" whether `memory.search` and `memory.retrieve` keep
it out of their items (`appendNodeItem`). "Unless named" means hidden unless
the request's `labels` names the label. Search and Vector describe the
Lattice adapter; see [Search text and vectors](#search-text-and-vectors) for
the in-memory one.

| Label | qid | Written by | Search | Vector | Hidden |
| --- | --- | --- | --- | --- | --- |
| `Session` | `q_sess_<n>` | `memory.remember` | no | no | always (no item text) |
| `Turn` | `q_turn_<n>` | `memory.remember` | no | no | always (no item text) |
| `Message` | `q_msg_<n>` | `memory.remember` | unless chunked | unless chunked | when chunked |
| `Chunk` | `q_chunk_<m>_<i>` | `memory.remember` | yes | yes | no |
| `ToolCall` | `q_tool_<n>` | `memory.remember` | no (no text field) | no | no |
| `Observation` | `q_obs_<n>` | `memory.remember` | yes | no | no |
| `Fact` | `q_fact_<n>` | `memory.remember` | yes | yes | no |
| `Preference` | `q_pref_<n>` | `memory.remember` | yes | yes | no |
| `Procedure` | `q_proc_<n>` | `memory.remember` | yes | yes | no |
| `MemoryCard` | `q_card_<hex>` | `memory.remember` | yes | yes | no |
| `Episode` | `q_ep_<hex>` | `memory.remember` | no | no | always |
| `Entity` | `q_ent_<hex>` | entity-resolution job | yes | no | unless named |
| `Core` | `q_core_<n>` | `memory.core.update`, `memory.core.consolidate` | yes | yes | no |
| `Feedback` | `q_fb_<n>` | `memory.feedback` | no (no text field) | no | no |
| `Assertion` | `q_asrt_<hex>` | extract job | yes | yes | unless named |
| `Update` | `q_upd_<hex>` | consolidate job | no | no | always |
| `SentenceIndex` | `q_sidx_<m>` | pattern job | no | no | always |
| `Pattern` | `q_pat_<n>` | pattern job | no | no | always |
| `Summary` | `q_sum_<n>` | summary job | no | no | always |
| `Job` | `q_job_<hex>` | stream materializer | no | no | unless named |
| `Idempotency` | `q_idem_<key>` | `memory.remember` | no | no | unless named |
| `Schema` | `q_schema_current` | `schema.ensure` | no | no | unless named |
| `Migration` | `q_migration_0001_initial` | `schema.ensure` | no | no | unless named |

"Always" in the Hidden column means the node is never an item through the
search path: `Session` and `Turn` have no item text, and the others carry
`searchable: false`. `Pattern` and `Summary` nodes reach the reader through
paths of their own (see [algorithms.md](algorithms.md#pattern-nodes) and
[algorithms.md](algorithms.md#reading-the-summaries-first)). An `Assertion`
is also shown, outside `labels`, in the facts section of `memory.retrieve`
(see [algorithms.md](algorithms.md#the-facts-section)).

Apart from labels, search results drop forgotten nodes (unless
`includeDeleted` is set) and nodes outside the request's scope. `Fact`,
`Preference`, `Procedure` and `MemoryCard` items must be `current`, or, when
the request names a time (`time.validAt`), valid at that time.

Scope fields below means `tenantId`, `userId`, `agentId` and `projectId`
(see [Scope](#scope)).

### Raw memory

These labels hold what the caller sent. `memory.remember` writes them in this
order: the `Session`, the `Turn`, each `Message` with its chunks, then tool
calls and observations. They are written whether or not extraction is on.

**`Session`.** One per `memory.remember` call. Each call writes a new
`Session` node, even when it passes the same `sessionId` as an earlier call.

- `kind`: `"session"`.
- `sessionId`: the caller's `sessionId`, or null.
- Scope fields, `deleted`.

**`Turn`.** One per `memory.remember` call, linked from its session by
`HAS_TURN`.

- `kind`: `"turn"`.
- `sessionQid`: its `Session`.
- Scope fields, `deleted`.

**`Message`.** One per entry of `messages`, linked from the turn by
`HAS_MESSAGE`.

- `kind`: `"message"`.
- `role`: as sent. A role other than `user`, `assistant`, `system`, `tool`,
  `developer` and `function` (in any case) is read as a speaker's name.
- `content`: the text. A longer text is cut to at most 64 KiB, ending in
  `…` (`clampPropertyText`).
- `createdAt`: the message's `createdAt`, or null.
- `sessionQid`, `sessionId`, `turnQid`: where it was said.
- `messageIndex`: its 0-based position in the call.
- `searchable`: false when the message is chunked.
- `chunkCount`: the number of chunks, or 0 when it is not chunked.
- `privacyClass`: the request's `privacyClass`, default `"normal"`.
- `searchText`: only on an unchunked message whose role names a speaker:
  `Role: content`, so the speaker's lines match a search for their name.
- Scope fields, `deleted`.

**`Chunk`.** A message longer than 1,200 bytes is also stored as chunks that
together hold its full text (see
[algorithms.md](algorithms.md#index-units-messages-and-chunks)). The qid is
`q_chunk_<m>_<i>`, where `m` is the number of the message's qid and `i` the
0-based chunk index (`chunkQid`).

- `kind`: `"chunk"`.
- `content`: this chunk's slice of the text.
- `role`, `createdAt`, `sessionQid`, `sessionId`, `turnQid`, `messageIndex`,
  `privacyClass`: copied from the message.
- `messageQid`: the message.
- `chunkIndex`, `chunkCount`: its position and the number of chunks.
- `searchText`: `Role: content` when the role names a speaker.
- Scope fields, `deleted`.

**`ToolCall`.** One per entry of the request's `toolCalls`, linked from the
turn by `HAS_TOOL_CALL`. It has none of the fields search text is taken from,
so it is never a search hit.

- `kind`, `qtype`: `"tool_call"`.
- `toolName`: the entry's `toolName` or `name` (required).
- `inputJson`, `outputJson`: strings, default `"{}"`.
- `status`: default `"success"`.
- `errorText`: or null.
- Scope fields, `deleted`.

**`Observation`.** One per entry of `observations`, linked from the turn by
`HAS_OBSERVATION`.

- `kind`, `qtype`: `"observation"`.
- `observationType`: the entry's `type`, default `"generic"`.
- `content`, `text`: both the entry's `content`, or its `text`.
- `createdAt`: the entry's `createdAt`, or null.
- Scope fields, `deleted`.

### Deterministic derived memory

`memory.remember` writes these while it stores the messages, unless the
request sets `extract: false`. No model is called. `Entity`, `Core` and
`Feedback` are written by other calls.

**`Fact`, `Preference`, `Procedure`.** The deterministic extractor
(`extractor.zig`) matches fixed rules against each message and returns
candidates, each with a label and a slot. A slot key names one thing that has
one current value in a scope. The extractor knows five:

| Label | `slotKey` |
| --- | --- |
| `Fact` | `project.package_manager`, `project.repo_style`, `project.constraint` |
| `Preference` | `user.response_style` |
| `Procedure` | `project.test_command` |

Each valid candidate becomes one node (`writeExtractedMemory`) with an
`EVIDENCED_BY` edge to its message:

- `kind`: `"fact"`, `"preference"` or `"procedure"`.
- `text`: one sentence stating the memory.
- `slotKey`, `subject`, `attribute`, `value`: the slot and its value.
- `numericValue`, `unit`: null; no rule sets them.
- `aggregationMode`: `"single_value"`; every rule uses it.
- `state`: `"current"` when written.
- `validFrom`: the message's `createdAt`. `validTo`: null when written.
- `evidenceQid`: the message.
- `quote`: the message's content, cut to 64 KiB.
- Scope fields, `deleted`.

**`MemoryCard`.** Each candidate also becomes a card
(`writeMemoryCardForCandidate`). Its qid is `hashQid("card", "<message
qid>:<slotKey>:<value>")`. It carries the same slot fields as the `Fact`
above (`text`, `slotKey` through `aggregationMode`, `state`, `validFrom`,
`validTo`, `evidenceQid`, `quote`, scope fields, `deleted`), and:

- `kind`, `qtype`: `"memory_card"`.
- `cardKind`: `semantic`, `preference` or `procedural`, from the label.
- `contextDescription`: `"Deterministic extraction from raw message."`
- `contextualDescription`, `keywords`, `tags`: fixed text per slot and label.
- `importance`: 0.6 to 0.9 by slot. `utility`: 0.5.
- `relatedCardQids`: up to 8 live cards in the scope with the same `slotKey`,
  then with the same `cardKind`, newest first. The card has a `RELATED_TO`
  edge to each.

**`Episode`.** One per `memory.remember` call that wrote at least one message
with extraction on (`writeEpisodeForTurn`). Its qid is `hashQid("ep", turn
qid)`. It only copies the first message, so it is kept out of search.

- `kind`, `qtype`: `"episode"`. `episodeType`: `"conversation"`.
- `searchable`: false.
- `sessionQid`, `turnQid`.
- `summary`, `text`, `quote`: the first 1,024 bytes of the first message,
  cut at a UTF-8 boundary.
- `eventTime`: the first message's `createdAt`.
- `state`: `"current"`.
- `evidenceQid`: the first message. `evidenceQids`: every message of the
  call.
- Scope fields, `deleted`.

It has `DERIVED_FROM` edges to the turn and to every message of the call, and
no `EVIDENCED_BY` edge.

**`Entity`.** A named thing a message mentions. When an entity provider is
configured, `memory.remember` queues an entity-resolution job; the job
(`processEntityResolveLease`) sends each live message's text to the provider,
which is either the deterministic one or a model, and writes what comes back
(`writeEntityMentions`; see
[algorithms.md](algorithms.md#entity-resolution-v0)). The qid is
`hashQid("ent", ...)` over the scope fields and the normalized type and name,
so one entity per name and type per scope. The node is written only when no
node has that qid yet: a later mention adds no aliases, and the tombstone of
a forgotten entity stays a tombstone.

- `kind`, `qtype`: `"entity"`.
- `searchText`: the name followed by the aliases, separated by spaces.
- `canonicalName`, `entityType`, `aliases`.
- `state`: `"current"`.
- Scope fields, `deleted`.

Each message that names it has a `MENTIONS` edge to it.

**`Core`.** A core block: a named block of text an agent keeps in view.
`memory.core.update` writes `kind: "core"`, `blockKey`, `text`, `managedBy`
(default `"user"`), the scope fields and `deleted`. With `mode: "replace"`
(the default) it rewrites the live block with the same `blockKey` in the
scope, if there is one (`findCoreBlockQid`); any other mode writes a new
block.

`memory.core.consolidate` writes a block (default key `project_summary`)
compiled from up to `limit` (default 50) live nodes of the scope, oldest
first: `Fact`, `Preference` and `Procedure` nodes in state `current`, and
`MemoryCard` and `Episode` nodes in any state. It rewrites the block with the
same key if there is one. Besides the fields above it stores `qtype:
"core"`, `managedBy: "agent"`, `text` (`Consolidated memory:` followed by one
line `- (<qid>) <text>` per source) and `evidenceQids` (the sources), and it
has a `COMPILED_FROM` edge to each source.

**`Feedback`.** One per `memory.feedback` call: `kind: "feedback"`,
`retrievalId`, `rating` and `deleted`. It has no scope fields and no edges.

### Model-derived memory

Background jobs write these with a chat model and an embedding model. They run
in the daemon's background worker or on request through the operational RPCs
(`memory.extract.run`, `memory.consolidate.run`, `memory.patterns.run`,
`memory.summaries.run`). Pattern and summary jobs are queued only on a store
with vectors, so the in-memory adapter never gets `SentenceIndex`, `Pattern`
or `Summary` nodes.

**`Assertion`.** One claim a person stated, written by the extract job (see
[algorithms.md](algorithms.md#llm-fact-extraction)). `memory.remember` queues
an extract job for its messages unless `extract` is false. The job reads only
the messages whose role is a person's (not `assistant`, `system`, `tool`,
`function` or `developer`), asks the extract provider for claims, grounds
each claim's quote in its message, and writes one node per accepted claim
(`writeExtractTask`, `writeAssertion`). Claims from the job's second reading
are written the same way with the recall prompt version. A claim whose
message was forgotten while the provider call ran is not written.

The qid is `hashQid("asrt", "<message qid>\x1f<quote>\x1f<stated text>")`,
where the stated text is `statedText` when present, else `text`. Rerunning a
job rewrites the same nodes.

- `kind`, `qtype`: `"assertion"`.
- `text`: the claim, with its relative times written as calendar dates. Cut
  to 64 KiB.
- `statedText`: the claim as the model wrote it, when that differs from
  `text`; otherwise null.
- `searchText`: the same value as `statedText`. When it is null, search falls
  back to `text`.
- `quote`: the span of the message the claim rests on, exactly as the message
  has it.
- `eventDate`: `YYYY-MM-DD` or `YYYY-MM`, the day or month the event happened;
  null when absent or rejected.
- `eventStart`, `eventEnd`: the first and last day the event may have
  happened on, `YYYY-MM-DD`; both null when the claim has no time of its own.
- `planned`: the event is a plan or other future event: the model said so,
  or its date falls after the claim was said.
- `sourceMessageQid`, `evidenceQid`: the message.
- `chunkQids`: the chunks the quote overlaps; empty for an unchunked message.
- `messageIndex`, `role`, `createdAt`, `sessionId`: copied from the message.
  `createdAt` is when the claim was said.
- `sessionQid`, `turnQid`: from the job.
- `extractorProvider`, `extractorModel`: the provider that read it.
- `promptVersion`: `quipu.extract.speaker-facts.v4`, or
  `quipu.extract.recall.v1` for the second reading.
- `groundingRepaired`: the model's message index was wrong or missing, and
  the quote located the message.
- `jobQid`: the extract job.
- `state`: `"current"`.
- Scope fields (from the job), `deleted`.

The summary job adds two properties later (`indexSummaryClaims`):

- `vector`: the claim's search text embedded, cut to its first 256
  dimensions, scaled to signed bytes and base64-encoded.
- `vectorModel`: the store's embedding model.

This vector is separate from the one the Lattice adapter keeps for the node's
search text. Rewriting the node (`writeAssertion` again) replaces the whole
property object and drops `vector` and `vectorModel`; the next summary pass
writes them again.

An assertion is never rewritten as superseded. When consolidation finds that a
later claim replaced it, it writes an `Update` node. The facts section reads
the updates that touch a claim (`updateLinks`) and shows the claim as
`superseded`, with `validTo` set to the `createdAt` of the latest update that
replaced it. An update dated after the question's `time.validAt` is ignored.

The node has an `EVIDENCED_BY` edge to its message and to every chunk in
`chunkQids`.

**`Update`.** The record that one claim replaced an earlier one, written by
the consolidate job (`writeUpdate`; see
[algorithms.md](algorithms.md#consolidation-knowledge-updates)). An extract
job queues a consolidate job only when consolidation is switched on
(`--consolidate` or `QUIPU_CONSOLIDATE`); it is off by default. The node is
written only while both claims and both their messages are live. The qid is
`hashQid("upd", "<new claim qid>\x1f<earlier claim qid>")`.

- `kind`, `qtype`: `"update"`.
- `text`, `quote`, `createdAt`: the new claim's text, quote and time.
- `replacedText`, `replacedAt`: the earlier claim's text and time.
- `oldValue`, `newValue`: the value that changed, as the model quoted it
  from the earlier and the new claim.
- `assertionQid`, `evidenceQid`: the new claim and its message.
- `replacedQid`, `replacedMessageQid`: the earlier claim and its message.
- `sessionQid`: the session of the job.
- `consolidatorProvider`, `consolidatorModel`, `promptVersion`
  (`quipu.updates.v2`), `jobQid`.
- `state`: `"current"`. `searchable`: false.
- Scope fields, `deleted`.

It has `DERIVED_FROM` edges to both claims and `EVIDENCED_BY` edges to both
messages, so forgetting either message removes it.

**`SentenceIndex`.** The sentences of one message, as byte ranges and
vectors, never the text. The pattern job writes one per message a person
wrote in the scope (`indexPatternMessages`, `writeSentenceIndex`; see
[algorithms.md](algorithms.md#pattern-nodes)). The qid is `q_sidx_<m>`, where
`m` is the number of the message's qid. The node is written again when the
message's length or the store's embedding model no longer matches it.

- `kind`: `"sentence_index"`.
- `evidenceQid`: the message. `sessionQid`, `createdAt`: copied from it.
- `contentBytes`: the length of the message text it was made from.
- `model`: the store's embedding model. `dims`: dimensions per sentence, at
  most 256.
- `spans`: one `[start, end]` byte range per sentence.
- `vectors`: base64 of every sentence's vector as signed bytes, `dims` per
  sentence.
- Scope fields copied from the message.
- `state`: `"current"`. `searchable`: false. `deleted`.

It has an `EVIDENCED_BY` edge to its message.

**`Pattern`.** What the memory worked out from one kind of occasion that
recurs (`writePatternNode`; see [algorithms.md](algorithms.md#pattern-nodes)).
An occasion is the messages of one `Session` on one day. A node keeps its
qid as its group changes; a node whose group is gone is marked `superseded`
(`supersedePattern`). The pattern provider is used when one is set, else the
extract provider.

- `kind`, `qtype`: `"pattern"`.
- `about`: what the occasions are about. `summary`: the model's summary.
- `finding`: the conclusion written from the counts, or empty.
- `text`: `about: finding` when the node is informative, else `about`.
- `gateKind`: `routine`, `story` or `recurring`, the kind the model named.
- `analysis`: the kind for a routine or story; for a recurring group,
  `regularity`, `none`, `too_few`, or `pending` before any conclusion.
- `informative`: whether a reader should see the finding.
- `occasions`: the number of occasions.
- `gatedAt`: the number of occasions when the kind was last named.
- `claimsAt`: the number of occasions when generalisations were proposed, or
  null.
- `claims`: each proposed generalisation, with `claim`, `when`, `then`, the
  counted `table`, `testable`, `p`, `gap`, `holds`, and `answers`, one code
  per occasion (empty where none).
- `members`: each occasion, with `key`, `day`, `sig`, its `messages`, and
  `units`, the linked sentences as `[message position, sentence index]`.
- `firstSaid`, `lastSaid`: the first and last message's `createdAt`.
- `evidenceQid`: the first message.
- `scopeKey`: the job's scope fields joined by `\x1f`.
- `consolidatorProvider`, `consolidatorModel`, `promptVersion`
  (`quipu.patterns.v1`), `jobQid`.
- `state`: `"current"` or `"superseded"`. `searchable`: false.
- Scope fields, `deleted`.

It has an `EVIDENCED_BY` edge to every message of every occasion.

**`Summary`.** A title and summary of one session or of one topic, a group of
claims about the same thing (`writeSummaryNode`; see
[algorithms.md](algorithms.md#summary-nodes)). A session summary covers the
messages whose `sessionQid` is that `Session`, all roles, which are the
messages of one `memory.remember` call. A node keeps its qid when it is
written again; a node nothing stands behind any more is marked `superseded`
(`retireSummary`).

- `kind`, `qtype`: `"summary"`.
- `summaryType`: `session` or `topic`.
- `title`, `summary`: as the model wrote them. `title` is null when the model
  found nothing to name.
- `declined`: true in that case; the node is kept so the same sources are
  not asked about again.
- `text`: `Title: summary`, or empty when declined.
- `sourceKey`: the number of sources and a hash of their sorted qids
  (`summaries.memberKey`). `sourceCount`: the number of sources.
- `members`: a topic's claims; null for a session.
- `sessionQid`, `sessionId`: the session; null for a topic.
- `firstSaid`, `lastSaid`: when the first and last source was said.
  `createdAt`: the same as `firstSaid`.
- `vector`: base64 of the embedding of `text`, cut to at most 256 dimensions
  as signed bytes; null when declined. `vectorModel`, `dims`.
- `evidenceQid`: the first message.
- `scopeKey`: as on `Pattern`.
- `summarizerProvider`, `summarizerModel`, `promptVersion`
  (`quipu.summaries.v1`), `jobQid`.
- `state`: `"current"` or `"superseded"`. `searchable`: false.
- Scope fields, `deleted`.

A session summary has a `SUMMARIZES` edge to its session; a topic summary has
a `DERIVED_FROM` edge to each claim in `members`. Both have an `EVIDENCED_BY`
edge to every message they rest on.

### Bookkeeping

These labels are internal. Search never indexes them.

**`Job`.** One unit of background work, made from one stream event by
`jobs.materializeStream`. The qid is `q_job_<hex>`, the Wyhash (seed 0) of
`<stream>:<sequence>:<worker kind>`, so an event yields one job however often
it is materialized. Most properties are stored twice, in camelCase and in
snake_case (`streamName` and `stream_name`).

- `kind`, `qtype`: `"job"`. `jobType` (`worker_kind`): the worker kind.
- `streamName`, `streamSequence`: the event.
- `status`: `pending`, `leased`, `succeeded` or `deadlettered`.
- `attempts`, `maxAttempts` (default 3).
- `leaseOwner`, `leaseUntilMs`, `startedAtMs`, `completedAtMs`.
- `errorJson`, and `resultJson` once completed.
- `payloadHash`, `payloadBytes`, `payloadInlined`, `payloadJson`.
- `deleted`.

**`Idempotency`.** Written by `memory.remember` when the request has an
`idempotencyKey`. The qid is `q_idem_` followed by the key with every byte
other than a letter, digit, `_` or `-` replaced by `_`; two keys that differ
only in such bytes share a node. A later call whose key has a node returns
`status: "duplicate"` with the stored qids and writes nothing.

- `kind`: `"idempotency"`. `idempotencyKey`.
- `sessionQid`, `turnQid`, `messageQid` (the first message), `deleted`.

**`Schema`, `Migration`.** `schema.ensure` writes `q_schema_current`
(`Schema`: `schemaVersion` 1, `state: "active"`, `migration: "initial"`,
timestamps 0) and `q_migration_0001_initial` (`Migration`: `name:
"initial"`, `schemaVersion` 1, `status: "applied"`). It runs when the daemon
opens a Lattice store, and in `quipu init` and `quipu quickstart`. Each node
is written once and never changed.

## Edges

The runtime writes 11 edge types. Each runs from the node that was built to
what it was built from or contains.

| Edge | From | To | Written by | Meaning |
| --- | --- | --- | --- | --- |
| `HAS_TURN` | `Session` | `Turn` | `memoryRemember` | the session holds the turn |
| `HAS_MESSAGE` | `Turn` | `Message` | `memoryRemember` | the turn holds the message |
| `HAS_TOOL_CALL` | `Turn` | `ToolCall` | `writeToolCalls` | the turn holds the call |
| `HAS_OBSERVATION` | `Turn` | `Observation` | `writeObservations` | the turn holds the observation |
| `HAS_CHUNK` | `Message` | `Chunk` | `writeMessageChunks` | the chunk is part of the message |
| `EVIDENCED_BY` | `Chunk` | `Message` | `writeMessageChunks` | the chunk's text comes from the message |
| `EVIDENCED_BY` | `Fact`, `Preference`, `Procedure` | `Message` | `writeExtractedMemory` | extracted from the message |
| `EVIDENCED_BY` | `MemoryCard` | `Message` | `writeMemoryCardForCandidate` | extracted from the message |
| `EVIDENCED_BY` | `Assertion` | `Message`, `Chunk` | `writeAssertion` | the claim's quote is in the message and these chunks |
| `EVIDENCED_BY` | `Update` | `Message` (two) | `writeUpdate` | the messages of both claims |
| `EVIDENCED_BY` | `SentenceIndex` | `Message` | `writeSentenceIndex` | the sentences of the message |
| `EVIDENCED_BY` | `Pattern` | `Message` | `writePatternNode` | a message of one of its occasions |
| `EVIDENCED_BY` | `Summary` | `Message` | `writeSummaryNode` | a message it rests on |
| `DERIVED_FROM` | `Episode` | `Turn`, `Message` | `writeEpisodeForTurn` | the episode copies the turn |
| `DERIVED_FROM` | `Update` | `Assertion` (two) | `writeUpdate` | the new claim and the claim it replaced |
| `DERIVED_FROM` | `Summary` (topic) | `Assertion` | `writeSummaryNode` | a claim of the topic |
| `SUMMARIZES` | `Summary` (session) | `Session` | `writeSummaryNode` | the session it summarises |
| `COMPILED_FROM` | `Core` | `Fact`, `Preference`, `Procedure`, `MemoryCard`, `Episode` | `memoryCoreConsolidate` | a source of the compiled block |
| `RELATED_TO` | `MemoryCard` | `MemoryCard` | `writeMemoryCardForCandidate` | a card of the same slot or kind |
| `MENTIONS` | `Message` | `Entity` | `writeEntityMentions` | the message names the entity |

`HAS_TURN`, `HAS_MESSAGE`, `HAS_TOOL_CALL`, `HAS_OBSERVATION` and the
`EVIDENCED_BY` edge of a `Fact`, `Preference` or `Procedure` take runtime
ids. Every other edge is deterministic.

`EVIDENCED_BY` and `DERIVED_FROM` are the provenance edges: with
`propagate`, forgetting their target forgets their source (see
[Lifecycle](#lifecycle)). `COMPILED_FROM`
marks a core block contaminated when a source is forgotten. Graph search
(`memory.search` with `mode: "graph"`) also follows `MENTIONED_IN` edges out
of an entity (`appendMemoryHitsForEntity`), but nothing writes that type.

## Indexed properties

`storage.indexed_properties` lists the properties every adapter indexes for
`findNodes`, the lookup of nodes by label and exact property values. Only a
top-level, non-empty string value is indexed. A lookup on one of these costs
about the size of its result; a lookup on any other property, the scope
fields included, scans. See also [algorithms.md](algorithms.md#node-lookups).

| Property | Lookups |
| --- | --- |
| `slotKey` | current memories of a slot, to supersede them (`supersedeCurrentSlot`); related cards (`relatedCardQidsForCandidate`) |
| `state` | with `slotKey` for supersession; current `Pattern`, `Summary` and `SentenceIndex` nodes of a scope (`preparePatternTask`, `prepareSummaryTask`, `collectPatternItems`, `collectThreadItems`) |
| `evidenceQid` | nodes derived from a forgotten node, when an edge was lost (`forgetting.dependentQids`) |
| `blockKey` | the core block of a key (`findCoreBlockQid`, `memoryCoreGet`) |
| `cardKind` | related cards of the same kind (`relatedCardQidsForCandidate`) |
| `status` | pending and leased jobs (`jobs.leasePendingJobs`, `jobs.reclaimExpiredLeases`) |

The Lattice adapter copies each value into a native node property behind an
equality index, and fills the copies in when it opens a store written before
the index existed (`ensureSchema`). A tombstone has none of these properties
except `state`, so it leaves the slot, evidence, key and status lookups.

## Search text and vectors

The Lattice adapter decides a node's search text in `searchTextFor`. There is
none when:

- the label is `Job`, `Idempotency`, `Schema`, `Migration`, `Session` or
  `Turn` (`isSearchableLabel`);
- the node has `searchable: false`;
- the node has `deleted: true`.

Otherwise the text is the first non-blank string of `searchText`, `content`,
`text` and `name`. A node with none of them falls back to `canonicalName`
followed by its `aliases`; a node with no text at all is not searchable. The
text is stored in the native `searchText` property, and the node gets the
`QuipuSearchable` label, which puts it in the one full-text index (BM25). A
node that stops being searchable loses the label and its `searchText` is
cleared.

A searchable node also gets a vector of its search text when its label is one
of `Message`, `Chunk`, `MemoryCard`, `Fact`, `Preference`, `Procedure`,
`Assertion` or `Core` (`isVectorIndexedLabel`). The vector comes from the
configured embedding provider and is dropped when the node stops being
searchable. `Entity` and `Observation` nodes are searchable but have no
vector.

The labels marked `searchable: false` when written are `Episode`, `Update`,
`SentenceIndex`, `Pattern`, `Summary`, and a chunked `Message`. `Summary`,
`SentenceIndex` and `Assertion` keep vectors of their own as properties
(`vector`, `vectors`), which the jobs and retrieval compare directly; these
are not in the adapter's vector index.

The in-memory adapter differs:

- It has no vectors. Its capabilities report `vector: false`, vector search
  returns nothing and embedding fails with `error.Unsupported`, so the jobs
  that need embeddings are never queued.
- `buildIndex` takes the first of `searchText`, `content`, `text` and `name`
  that is a string, even a blank one, and has no `canonicalName` fallback.
- It does not check `deleted`. A tombstone carries no text field, so it
  indexes nothing anyway.
- It excludes the same six labels and honours `searchable: false`.
- Its tokenizer drops a short list of stop words and folds simple plurals.

## Scope

A scope is up to four strings: `tenantId`, `userId`, `agentId` and
`projectId`. A request passes them in `scope` (`parseScope`), and most nodes
store them as top-level properties, null when unset. `Feedback`, `Job`,
`Idempotency`, `Schema` and `Migration` nodes and tombstones carry none.
`Pattern` and `Summary` nodes also store `scopeKey`, the four values joined
by `\x1f`, and a job only reuses stored nodes whose `scopeKey` equals its own.

A node matches a scope when, for every field the scope sets, the node has
that property as a string equal to it (`Scope.matchesNode`). A field the
scope leaves unset matches any value, null included. A node whose field is
null or missing does not match a scope that sets it. `scopeWhere` turns the
same rule into `findNodes` property matches; there, a field set to the empty
string matches nothing.

Supersession uses the same rule: a new slot memory supersedes the current
memories of its slot in every scope that agrees on the fields the request
sets.

## Lifecycle

**State.** `state` is written on `Fact`, `Preference`, `Procedure`,
`MemoryCard`, `Episode`, `Entity`, `Assertion`, `Update`, `SentenceIndex`,
`Pattern` and `Summary` nodes as `current`. These values change it:

| Value | Set on | By |
| --- | --- | --- |
| `superseded` | `Fact`, `Preference`, `Procedure`, `MemoryCard` | a newer memory of the same slot (`supersedeCurrentSlot`) |
| `superseded` | `Pattern` | its group merged into another or came to cover most occasions (`supersedePattern`) |
| `superseded` | `Summary` | nothing stands behind it (`retireSummary`) |
| `deleted`, `redacted` | any forgotten node | `tombstoneNode` |

`Schema` has `state: "active"`; `Job` uses `status` instead. The verifiers
and the retrieval renderer also accept `historical`, which nothing writes.

**Validity.** Only `Fact`, `Preference`, `Procedure` and `MemoryCard` nodes
store `validFrom` and `validTo`, and only they store `slotKey`, `value` and
the other slot fields. When a new candidate's slot is `single_value` (every
slot today), `supersedeCurrentSlot` finds every live `current` node of those
labels with the same `slotKey` in scope and rewrites it with `state:
"superseded"` and `validTo` set to the new message's `createdAt` (null when
the message has none). The rewrite keeps every other property
(`rewriteDerivedState`). With `time.validAt`, retrieval keeps a node when
`validFrom <= validAt < validTo` (`derivedActiveAt`); a null bound is open,
and the timestamps compare as strings. Other labels carry
their time in other properties: `createdAt` on `Message`, `Chunk`,
`Observation` and `Assertion`, `eventTime` on `Episode`, `firstSaid` and
`lastSaid` on `Pattern` and `Summary`. An `Assertion` is superseded only as
read, through `Update` nodes (see `Assertion` above).

**Forgetting.** `memory.forget` (see
[algorithms.md](algorithms.md#forgetting-v0)) replaces a forgotten node's
property object with a tombstone (`tombstoneNode`):

- `kind`: `"tombstone"`. `deleted`: true.
- `state`: `"redacted"` in mode `redact`, otherwise `"deleted"`.
- `mode`, `reason`: from the request.
- `previousLabel`: the label.
- `leakFingerprints`: hashes of windows of the text of a `Message`, `Chunk`,
  `Observation` or `ToolCall` (`forgetting.fingerprintNode`); empty for any
  other label.

The node keeps its qid, its label and its edges; only its properties change.
It loses its text, its slot and scope fields and everything else. In
LatticeDB it also keeps its node id, so its place in creation order, and it
leaves the full-text and vector indexes. A node that is already a tombstone
is left as it is.

The roots of a request and their chunks are tombstoned in the request's mode.
With `propagate` (the default), every live node with an `EVIDENCED_BY` or
`DERIVED_FROM` edge, or an `evidenceQid`, to a forgotten node is tombstoned
too, transitively and whatever its label, in mode `hard_delete`. Core blocks
with a `COMPILED_FROM` edge to a forgotten node, and whose `evidenceQids`
still list it (or that have none), are tombstoned in the request's mode. An
entity that only forgotten nodes mention is tombstoned in mode `hard_delete`.
When propagation tombstones a `Pattern` or `Summary` node, a job is queued
for its scope, which rebuilds the scope's nodes from what remains.

## How the labels connect

Arrows run from the node that holds the edge. `EVID` is `EVIDENCED_BY` and
`DERIV` is `DERIVED_FROM`.

```
Raw spine, written by memory.remember:

  Session --HAS_TURN--> Turn --HAS_MESSAGE--> Message --HAS_CHUNK--> Chunk
                        |                      |  ^                    |
                        |            MENTIONS  |  +------EVID----------+
                        |                      v
                        |                   Entity
                        +--HAS_TOOL_CALL----> ToolCall
                        +--HAS_OBSERVATION--> Observation

Derived memory, pointing into the spine:

  Fact | Preference | Procedure --EVID--> Message
  MemoryCard --EVID--> Message
  MemoryCard --RELATED_TO--> MemoryCard
  Episode --DERIV--> Turn, Message
  Core --COMPILED_FROM--> Fact | Preference | Procedure | MemoryCard | Episode

Model-derived memory, written by background jobs:

  Assertion --EVID--> Message, Chunk
  Update --DERIV--> Assertion (new), Assertion (replaced)
  Update --EVID--> Message (of each claim)
  SentenceIndex --EVID--> Message
  Pattern --EVID--> Message (every message of every occasion)
  Summary (session) --SUMMARIZES--> Session
  Summary (topic) --DERIV--> Assertion (each member)
  Summary --EVID--> Message (every message it rests on)
```

Bookkeeping nodes (`Job`, `Idempotency`, `Schema`, `Migration`) and
`Feedback` have no edges. An `Idempotency` node names its session, turn and
message only in its properties.
