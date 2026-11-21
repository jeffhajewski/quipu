# How Quipu works

This is the map. It follows one message through the daemon, lists the
retrieval pipeline in the order the code runs it, and names the jobs, streams
and words the other documents use. [algorithms.md](algorithms.md) holds the
detail of each mechanism and [data-model.md](data-model.md) every label, edge
and property; this page links to them instead of repeating them.

## Orientation

Quipu is one Zig process that owns every memory semantic. The SDKs, the CLI
and the MCP adapter send JSON-RPC 2.0 requests to it: the SDKs and the MCP
adapter start `quipu serve-stdio` and write one request per line, and the CLI
commands (`quipu remember`, `quipu retrieve`, ...) build the same requests and
hand them to the same dispatcher (`Runtime.dispatch` in
`core/src/runtime.zig`). The work splits in two halves. `memory.remember`
stores and indexes raw text and queues jobs; it makes no model call. Jobs
make the model calls later, either between requests in a daemon started with
`--background on`, or when a caller runs them (`quipu jobs run ...`,
`memory.extract.run` and the other `*.run` methods). All storage goes through
the `storage.Adapter` vtable in `core/src/storage.zig`: nodes, edges,
full-text search, embeddings, vector search, append-only streams and
verification. Two adapters implement it: `InMemoryAdapter` (no vectors) and
`LatticeAdapter` (durable, compiled only with `-Denable-lattice=true`).

```
SDK / MCP / CLI  ->  JSON-RPC line  ->  Runtime.dispatch (runtime.zig)
                                          |  memory.remember: write, index, queue
                                          |  memory.retrieve / answer: read
                                          |  background batches between requests
                                          v
                                    storage.Adapter (storage.zig)
                                    InMemoryAdapter | LatticeAdapter
```

`system.health` reports the backend, whether it has vectors, and which
workers can run (`extractor`, `consolidator`, `summaries`, `patterns`,
`entityResolver`, `answerer`). Most of the background layer needs vectors:
summary and pattern jobs are not queued, and the threads and patterns
sections are not built, on a store whose adapter reports `vector: false`.

## One message, end to end

### `memory.remember` (synchronous)

Everything below happens inside the request. Each node or edge write commits
on its own; the call is not wrapped in one transaction.

1. **Validate.** `messages` must be a non-empty array. If `idempotencyKey` is
   given and an `Idempotency` node `q_idem_<key>` exists, the call returns
   the stored session, turn and first message qids with
   `status: "duplicate"` and writes nothing. Each message's `role` and
   non-empty `content` are checked as it is written, so a bad message later
   in the array fails the call after the earlier ones were stored.
2. **Containers.** The `Session` node the call belongs to and a new `Turn`
   node (`q_turn_<n>`), joined by `Session -[HAS_TURN]-> Turn`. A call with
   a `sessionId` joins the session of that id in its scope, or starts it
   (`q_sess_<hash of scope and id>`); a call with none is a session of its
   own (`q_sess_<n>`). See [Sessions and scope](#sessions-and-scope).
3. **Embedding prefetch.** On a Lattice store with an OpenAI-compatible
   embedding provider, the texts that will be vector-indexed (unchunked
   messages, chunks, deterministic extractions) are embedded in batched
   requests before any write. See
   [architecture.md](architecture.md#storage-adapters).
4. **Messages.** One `Message` node per element (`q_msg_<n>`) with `role`,
   `content` (clamped to 64 KiB), `createdAt`, `sessionQid`, `sessionId`,
   `turnQid`, `messageIndex`, scope and `privacyClass`;
   `Turn -[HAS_MESSAGE]-> Message`.
5. **Chunks.** A message over 1,200 bytes also gets `Chunk` nodes
   (`q_chunk_<n>_<i>`), `Message -[HAS_CHUNK]-> Chunk` and
   `Chunk -[EVIDENCED_BY]-> Message`, and the message itself is marked
   `searchable: false`. See
   [Index units](algorithms.md#index-units-messages-and-chunks).
6. **Indexing.** The adapter indexes each node as it is written. The text is
   the first non-blank of `searchText`, `content`, `text`, `name`; a role that
   names a speaker (not `user`, `assistant`, `system`, `tool`, `developer`,
   `function`) adds `searchText = "<role>: <text>"`. `Session`, `Turn`,
   internal labels (`Job`, `Idempotency`, `Schema`, `Migration`) and nodes
   marked `searchable: false` or `deleted: true` are not indexed. Vectors are
   kept only for `Message`, `Chunk`, `MemoryCard`, `Fact`, `Preference`,
   `Procedure`, `Assertion` and `Core` on the Lattice adapter. See
   [Search V0](algorithms.md#search-v0).
7. **Deterministic extraction** (unless `extract: false`). For each message
   the built-in extractor looks for five slots: package manager, test
   command, repo style, project constraint, response style. Each valid
   candidate first marks every current memory with the same `slotKey` in the
   scope `superseded`, then writes a `Fact`, `Preference` or `Procedure` node
   (`q_fact_<n>`, `q_pref_<n>`, `q_proc_<n>`) with
   `-[EVIDENCED_BY]-> Message`, and a `MemoryCard` (`q_card_<hash>`) with
   `-[EVIDENCED_BY]-> Message` and up to eight `-[RELATED_TO]->` edges to
   live cards of the same slot or kind. See
   [Extraction V0](algorithms.md#extraction-v0).
8. **Episode** (unless `extract: false`). One `Episode` node per call
   (`q_ep_<hash of turn>`), a copy of the first message's first 1,024 bytes,
   `searchable: false`, with `-[DERIVED_FROM]->` the turn and every message.
9. **Tool calls and observations**, when given: `ToolCall` and `Observation`
   nodes with `Turn -[HAS_TOOL_CALL]->` / `-[HAS_OBSERVATION]->` edges.
10. **Idempotency node**, when a key was given.
11. **Queue.** Unless `extract: false`, append to `quipu.extract.requested`
    (session, turn, message qids, scope) and materialize that one entry into
    a pending `extract` job. With an entity provider configured, do the same
    on `quipu.entity.resolve.requested`. Then append the call's summary to
    `quipu.raw_event` and `quipu.audit`, and return the qids and
    `queuedJobs`.

```
Session -[HAS_TURN]-> Turn -[HAS_MESSAGE]-> Message -[HAS_CHUNK]-> Chunk
                                              ^  ^  ^                |
                         Fact/Preference/ ----+  |  +--- EVIDENCED_BY+
                         Procedure, MemoryCard   |
                         (EVIDENCED_BY)        Episode (DERIVED_FROM)
```

Until its jobs run, a message is found only as raw text and through the
deterministic slots.

### The background work, in the order the worker runs it

`Runtime.startBackgroundWork` leases one kind of job per batch and prefers
them in this order: `extract`; then, only when none is pending, `consolidate`
(only with `--consolidate on`); then `summary`; then `pattern`. Each job
kind below says what queues it, what it reads, which model calls it makes,
what it writes and what it queues next.

**1. Extract.** Queued by `memory.remember`. It reads the turn's messages
written by a person (every role but `assistant`, `system`, `tool`,
`function`, `developer`), reassembling chunked ones, and skips forgotten
ones; a job with none left succeeds without a call. Model calls, all to the
extract provider in JSON mode: the first reading of the turn (up to three
attempts for a malformed reply), grounding of its claims against the
messages, then a second reading of the messages of 60 bytes or more that
yielded no claim (again up to three attempts). Both readings must answer or
the job fails and nothing is written. It writes one `Assertion` node per
accepted claim (`q_asrt_<hash>`, so a rerun rewrites the same nodes) with
`-[EVIDENCED_BY]->` the source message and every chunk the quote overlaps,
completes the job and appends `quipu.extract.completed`. A claim whose
message was forgotten while the calls ran is not written. It queues a
`consolidate` job when `--consolidate on` is set and it wrote a claim, and a
`pattern` job and a `summary` job for the scope when it read at least one
message (on a store with vectors). See
[LLM fact extraction](algorithms.md#llm-fact-extraction).

**2. Consolidate.** Queued by a finished extract job. It loads the job's
live claims (at most 32) and, for each, the best three earlier claims by the
same role from a different `Session` node, found by hybrid search (full-text
on a store without vectors). Model calls, to the extract provider: one
propose call (one retry), then one verify call per surviving pair (one
retry each). It writes one `Update` node per accepted pair
(`q_upd_<hash>`, `searchable: false`) with `-[DERIVED_FROM]->` both claims
and `-[EVIDENCED_BY]->` both messages, and appends
`quipu.consolidate.completed`. It queues nothing. See
[Consolidation](algorithms.md#consolidation-knowledge-updates).

**3. Summary.** Queued by a finished extract job, by a forget that removed a
`Summary`, and by a pass that left claims unembedded. Jobs of one scope are
settled by one pass. The pass reads every `Message` and every `Assertion`
of the scope. Session summaries come first in the plan: one per `Session`
node whose set of messages changed. Then topics: claims without a stored
vector are embedded (at most 2,048 a pass) and stored on their `Assertion`
node, the claims are grouped, and each new or changed group of two or more
asks for a topic summary. Model calls, to the extract provider: one per
session or topic asked about (one retry), up to eight at once, plus one
batched embedding request for the summary texts. It writes `Summary` nodes
(`q_sum_<n>`, `searchable: false`): a session summary with
`-[SUMMARIZES]-> Session`, a topic with `-[DERIVED_FROM]->` each claim, both
with `-[EVIDENCED_BY]->` each message. Nodes nothing stands behind are
marked `superseded`. It appends `quipu.summary.completed` and queues
another summary job when claims are left to embed. See
[Summary nodes](algorithms.md#summary-nodes).

**4. Pattern.** Queued like the summary job (extract, forget of a `Pattern`,
backlog). The pass reads every message a person wrote in the scope, embeds
the sentences of up to 64 not yet indexed and stores one `SentenceIndex`
node per message (`q_sidx_<n>`, `-[EVIDENCED_BY]-> Message`), groups alike
sentences across occasions, and works on each group worth a node. Model
calls, to the pattern provider (the extract provider unless `--pattern-*` is
set): a gate call, a propose call and check calls, as the group needs them.
It writes `Pattern` nodes (`q_pat_<n>`, `searchable: false`) with
`-[EVIDENCED_BY]->` every message of every occasion, marks orphaned ones
`superseded`, appends `quipu.pattern.completed` and queues another pattern
job when messages are left to index. See
[Pattern nodes](algorithms.md#pattern-nodes).

Entity resolution (`entity_resolve` jobs) is not run by the worker; it runs
only through `quipu jobs run entity-resolve` or `memory.entityResolve.run`.
It writes `Entity` nodes and `Message -[MENTIONS]-> Entity` edges.

```
memory.remember --> extract --+--> consolidate   (--consolidate on)
                              +--> summary  --+
                              +--> pattern  --+  (each re-queues itself
memory.forget ------------------> summary / pattern   for a backlog)
```

### Reading it back

`memory.retrieve` returns the rendered `prompt` and the structured `context`.
`memory.answer` runs the same pipeline, then sends the prompt to the answer
provider (or a deterministic fallback) and validates the reply; see
[Answering](algorithms.md#answering). The next section is that pipeline.

## The retrieval pipeline, in order

`memory.retrieve` and `memory.answer` run the same steps
(`Runtime.memoryRetrieve`, `Runtime.memoryAnswer`):

1. **Validate.** `query` must be non-empty and `budgetTokens` (default 4,096)
   positive; `mode`, `options.rerankCandidates` and `options.queryExpansion`
   must parse. With no `mode`, search is `hybrid` when the store has vectors
   from an embedding model other than `lattice_hash_embed`, else `fts`.
2. **Embed the question** once, in `vector` and `hybrid` modes.
3. **Expand.** `options.queryExpansion` (`off`, `rules`, `llm`) adds
   sub-queries to the original. See
   [Query expansion](algorithms.md#query-expansion).
4. **Candidates.** Each query asks for 320 hits (four times the 80-item
   candidate limit): BM25 for `fts`; BM25 and vector lists fused by
   reciprocal rank (k = 60) for `hybrid`; and for `graph`, that seed set
   plus the nodes that share an `Entity` with a hit through `MENTIONS`.
   `Assertion` hits are dropped unless `options.factKeys` is on or the
   request names the `Assertion` label. Hits become
   items only if they pass scope, deleted-state, label, `time.validAt` and
   event-window filters. Several queries' lists are fused. See
   [Retrieval V0](algorithms.md#retrieval-v0) and
   [Fact keys](algorithms.md#fact-keys).
5. **Time anchors.** When `time.validAt` parses and the question names a
   time, speakers' messages from inside that window are moved ahead of the
   other candidates. See [Time anchors](algorithms.md#time-anchors).
6. **Core.** When `needs` includes `core`, every live `Core` block in scope
   is added.
7. **Needs filter.** With `needs` given, items of other types are dropped.
8. **Raw-evidence policy.** Raw items whose message evidences a stale slot
   memory are dropped when the current one is in the packet, and memory
   cards that restate a slot already present are dropped.
9. **Rerank**, only with a configured reranker. See
   [Retrieval V0](algorithms.md#retrieval-v0) step 7.
10. **Facts section**, only with `options.facts`: claims that an `Update`
    links to another, both sides. See
    [The facts section](algorithms.md#the-facts-section).
11. **Patterns section**: at most one `Pattern` node that owns the question.
    See [Pattern nodes](algorithms.md#pattern-nodes).
12. **Threads section**: built when the scope has a current `Summary`. It
    leads with facts from a time the question names, then the topics and
    facts nearest the question. It also decides which sessions raw evidence
    may come from and adds the messages behind the facts it shows to the
    raw candidates. See
    [Reading the summaries first](algorithms.md#reading-the-summaries-first).
13. **Session token budget.** The remaining candidates (raw evidence, core,
    deterministic facts, memory cards) are packed in order into what is
    left; the first item kept from a summarised session also pays for its
    header summary. Items that do not fit are dropped and counted.
14. **Adopt.** The facts, pattern and thread items are appended to the kept
    candidates.
15. **Render.** The items are split into sections and the prompt is written.
    The call appends to `quipu.retrieval.logged` (both methods) and
    `quipu.audit` (`memory.retrieve` only), unless the options turn them off.

Steps 10 to 12 return nothing when `needs` is given without
`current_facts`, and steps 11 and 12 need a store with vectors.

### Token budget

`B` is `budgetTokens`. `E` is the evidence budget,
`B - facts tokens - pattern tokens`, using what those two sections actually
took.

| Section | Constant | Value | Share of |
| --- | --- | --- | --- |
| core | none | none | no cap of its own; packed with the raw evidence in step 13 |
| facts | `facts_budget_percent` (runtime.zig) | 30% | `B` |
| patterns | `pattern_budget_percent` (runtime.zig) | 40% | `B`; one node, shown whole or not at all |
| threads | `threads_budget_percent` (summaries.zig) | 45% | `E` |
| session-header summaries | `session_summary_percent` (summaries.zig) | 15% | `E`; charged inside the raw-evidence share, a header past the cap shows its title only |
| raw evidence | none | remainder | `E - threads tokens` |
| time anchors (not a section) | `time_anchor_budget_percent` (runtime.zig) | 50% | `B`; caps the anchored candidates, which are then packed with the rest |

Items are sized by `estimateItemTokens`: `ceil(bytes / 4.2) + 16`, plus the
event tag under `options.factKeys`.

### The rendered prompt

`renderPrompt` writes, in this order, skipping empty sections:

```
Current date: 2023-05-30 (Tuesday)    <- memory.retrieve only, with time.validAt
Time references: ...                  <- when words in the question resolve to dates
<memory>
<core> <facts> <preferences> <procedures> <patterns>
<threads>
<sessions>
</memory>
```

Each derived line is `[qid] (state, from A) text`, or `(state, A to B)`
when it has an end, oldest `validFrom` first. `<facts>` holds deterministic
`Fact` items and, with `options.facts`, claims listed under their message's
qid. Everything that is not core, fact, preference, procedure, pattern or a
thread item (messages, chunks, memory cards, episodes) goes to `<sessions>`,
grouped by `sessionId`, or by session qid when there is none:

```
## session <sessionId or session qid> 2023-05-20 (Sat), 10 days ago: this is the question's "last Saturday" | Title: summary
[q_msg_3] user: text
[q_msg_4] 2023-05-21 user: text
[q_chunk_10_0] assistant (1/2): text
[q_msg_9] user [event 2023-03-03]: text
## other
[q_obs_7] 2023-05-21 observation: text
```

The header's `, 10 days ago` comes only with `options.temporalHints`, the
`: this is ...` mark only for a session inside a time the question names,
and ` | Title: summary` only for a summarised session. A line shows its date
only when it differs from the header's (always under `## other`), then the
role, then `(i/n)` for a chunk of a split message, then the event dates
under `options.factKeys`. Groups are in date order; `## other`, for items
with no session, is last. See
[Context rendering](algorithms.md#context-rendering).

## Jobs and streams

### Job states

A job is a `Job` node `q_job_<hash of stream:sequence:kind>`, so
materializing the same stream entry twice makes one job. It holds the
stream name and sequence, not the payload: the worker reads the payload back
from the stream (`payloadJsonForLease`).

```
stream entry --materialize--> pending --lease--> leased --complete--> succeeded
                               ^   ^               |
                               |   +-- release ----+   attempts unchanged
                               +------ fail -------+   attempts + 1
                                                   |
                       fail with attempts = max ---+--> deadlettered
                                                         + quipu.deadletter
```

- `maxAttempts` is 3 (`MaterializeOptions`).
- A lease records an owner and `leaseUntilMs`. The default TTL is five
  minutes; summary and pattern passes lease for 30 minutes.
- `reclaimExpiredLeases` fails every lease that has ended, with
  `{"error":"lease_expired"}`: it uses an attempt and can deadletter.
- `releaseLease` returns a leased job to pending without using an attempt
  (shutdown, a batch nothing answered, a failed write).
- `releaseOwnedLeases` releases every lease held by an owner; the daemon
  does it once for `quipu-daemon` before its first batch.

### The worker loop

A daemon serves requests on one thread and reads stdin on another. After
every request, and when the last provider call of a batch returns, it calls
`advanceBackground`: if the batch in flight is ready, `finishBackgroundWork`
grounds the replies, writes the nodes and settles the jobs; then
`startBackgroundWork` starts the next batch. Provider calls run on other
threads; every storage read and write stays on the serving thread. One
batch is in flight at a time.

`startBackgroundWork` does nothing while a batch is in flight, while no job
may be pending (a flag set by every enqueue, cleared by a pass that finds
none), before the backoff time, or when the worker is not enabled. It
reclaims expired leases, then leases up to 8 `extract` jobs; if there are
none, up to 8 `consolidate` jobs (only with `--consolidate on`), then up to
256 `summary` jobs, then up to 256 `pattern` jobs.

When every call of a batch went unanswered, its jobs are released and the
worker waits 30 seconds, doubling to at most 10 minutes. A summary batch
whose chat calls answered but whose embedding call did not also backs off.
The wait is checked when the next request arrives. At end of input the
batch in flight is cancelled and its jobs released. See
[Background worker](algorithms.md#background-worker).

| Setting | Flag / variable | Effect |
| --- | --- | --- |
| background worker | `--background on`, `QUIPU_BACKGROUND` | only for `serve` and `serve-stdio`; needs an extract provider of kind `http` or `callback` |
| update consolidation | `--consolidate on`, `QUIPU_CONSOLIDATE` | extract jobs queue `consolidate` jobs |
| extract provider | `--extract-provider/-url/-model`, `QUIPU_EXTRACT_*`, else `--llm-*` | extract, consolidate and summary jobs |
| pattern provider | `--pattern-provider/-url/-model`, `QUIPU_PATTERN_*` | pattern jobs; unset means the extract provider |
| entity provider | `--entity-provider/-url/-model`, `QUIPU_ENTITY_*` | `memory.remember` queues `entity_resolve` jobs |

The switches accept `on`, `1`, `true` or `yes`, in any case. Without
`--background on` jobs run only when asked: `quipu jobs run
extract|consolidate|summaries|patterns|entity-resolve`, or the matching
`memory.*.run` method. Provider resolution is in
[providers.md](providers.md#configuration-precedence).

### Job kinds

| Kind | Stream | Queued by | Does | Queues next |
| --- | --- | --- | --- | --- |
| `extract` | `quipu.extract.requested` | `memory.remember` | two readings, grounding, `Assertion` nodes | `consolidate` (flag on, claims written); `summary` and `pattern` (a message read, store has vectors) |
| `consolidate` | `quipu.consolidate.requested` | finished `extract` | propose and verify, `Update` nodes | nothing |
| `summary` | `quipu.summary.requested` | finished `extract`; `memory.forget`; its own backlog | session and topic `Summary` nodes, claim vectors | itself, while claims wait to be embedded |
| `pattern` | `quipu.pattern.requested` | finished `extract`; `memory.forget`; its own backlog | `SentenceIndex` and `Pattern` nodes | itself, while messages wait to be indexed |
| `entity_resolve` | `quipu.entity.resolve.requested` | `memory.remember`, entity provider set | `Entity` nodes, `MENTIONS` edges | nothing; not run by the worker |

`quipu jobs materialize` turns entries of any stream in the table below into
jobs of its worker kind; only the five kinds above have a runner.

### Streams

Every stream is defined in `core/src/streams.zig`.

| Stream | Appended by | Payload | Read by |
| --- | --- | --- | --- |
| `quipu.raw_event` | `memory.remember` | session, turn, message qids, counts | nothing |
| `quipu.extract.requested` | `memory.remember` | session, turn, message qids, scope | `extract` jobs |
| `quipu.extract.completed` | extract job | job qid, result counts | nothing |
| `quipu.entity.resolve.requested` | `memory.remember` | message qids, scope, provider | `entity_resolve` jobs |
| `quipu.fact.upserted` | nothing | | |
| `quipu.card.created` | nothing | | |
| `quipu.consolidate.requested` | extract job | claim qids, session, scope | `consolidate` jobs |
| `quipu.consolidate.completed` | consolidate job; `memory.core.consolidate` | job result | nothing |
| `quipu.pattern.requested` | `queuePatternJob` | scope | `pattern` jobs |
| `quipu.pattern.completed` | pattern pass | job qid, scope, result | nothing |
| `quipu.summary.requested` | `queueSummaryJob` | scope | `summary` jobs |
| `quipu.summary.completed` | summary pass | job qid, scope, result | nothing |
| `quipu.forget.requested` | nothing | | |
| `quipu.forget.completed` | `memory.forget` | counts and the closure report | nothing |
| `quipu.retrieval.logged` | `memory.retrieve`, `memory.answer` | retrieval id, query, item qids | nothing |
| `quipu.feedback.received` | `memory.feedback` | feedback qid, retrieval id, rating | nothing |
| `quipu.audit` | remember, retrieve, forget, feedback, `memory.core.update`, `memory.core.consolidate` | the method's event | `memory.inspect` |
| `quipu.deadletter` | `jobs.failJob` | job qid, kind, stream, attempts, error | nothing |

"Nothing" means no code path in the daemon reads it; `quipu jobs
materialize` can still turn its entries into jobs.

## Sessions and scope

**Sessions.** A session is one conversation, and `sessionId` is the
caller's name for it. Every `memory.remember` call writes a new `Turn`.
The `Session` it hangs from depends on the id (`Runtime.openSession`):

- With a `sessionId`, the session's qid is a hash of the scope and the id,
  so the node is found without a search. The first call writes it and every
  later call with the same id and the same scope adds a turn to it. The
  node counts its messages (`messageCount`), and a later call's messages
  are numbered on from there, so `messageIndex` orders the whole session.
- The scope is part of the name: the same id under another scope, or with a
  scope field more or fewer, is another session.
- A forgotten session is not reopened. The next call with its id starts a
  new session, which the calls after that join.
- With no `sessionId` every call is a session of its own, and nothing can
  join it later.

Everything downstream keys on the `Session` node: a session summary covers
all of its turns and is written again when a call adds to it, consolidation
compares a claim only with claims from another session, a pattern occasion
is one session on one day, and the prompt gives the session one header. An
extract job still reads one turn, the messages of one call.

Stores written before sessions were joined keep one `Session` node per
call (`q_sess_<n>`). Those nodes are left as they are, and the prompt still
groups their lines by `sessionId`.

**Idempotency.** The key is global, not scoped, and a duplicate returns only
the first message qid of the original call.

**Scope.** A scope is four optional strings: `tenantId`, `userId`,
`agentId`, `projectId`. They are copied onto every node a call writes. A
filter compares only the fields it sets, by exact equality: an unset field
matches anything, so a request with no scope sees every scope, and a node
stored without `projectId` does not match a request that sets one
(`Scope.matchesNode`). This applies to writes too: supersession of a slot
and the messages a summary or pattern pass reads are selected the same way.

Scope fields are not indexed. `findNodes` indexes only `slotKey`, `state`,
`evidenceQid`, `blockKey`, `cardKind` and `status`; a scoped lookup on
another label (summaries, claims, messages, patterns) scans that label.
Search runs over the whole store and the scope is applied to the hits
afterwards (`appendNodeItem`), so a scoped retrieval sees only the in-scope
nodes among the top 320 hits of each query.

## Forgetting

`memory.forget` takes `selector.qids` or `selector.query` and a `mode`:
`hard_delete`, `redact` or `expire`. A query selects every full-text match;
a chunk resolves to its message; a `Session` or `Turn` root also selects its
messages; `selector.scope` and `selector.timeWindow` filter the roots. See
[Forgetting V0](algorithms.md#forgetting-v0) for the closure rules.

What each mode leaves behind is nearly the same. `tombstoneNode` replaces
the node's properties with `{kind: "tombstone", deleted: true, state, mode,
reason, previousLabel, leakFingerprints}` and keeps its qid, label and
edges. `state` is `redacted` for `redact` and `deleted` for `hard_delete`
and `expire`, which differ only in the recorded `mode`. The response counts
redacted roots as `nodesRedacted` and the others as `nodesDeleted`.

1. Each root and its chunks are tombstoned in the request's mode, whatever
   `propagate` says.
2. With `propagate` (default true), `dependentClosure` follows incoming
   `EVIDENCED_BY` and `DERIVED_FROM` edges, and `evidenceQid` properties,
   transitively from the forgotten nodes. That reaches facts, preferences,
   procedures, memory cards, episodes, claims, updates, summaries, sentence
   indexes and patterns. Each is tombstoned with mode `hard_delete`,
   whatever the request's mode.
3. An entity mentioned only by forgotten nodes is tombstoned the same way.
4. A `Core` block with `COMPILED_FROM` to a forgotten node is tombstoned in
   the request's mode.

Indexes follow from the write: a tombstone has `deleted: true` and no text
field, so the Lattice adapter drops the node from the full-text label,
clears its `searchText` and removes its vector, and the in-memory adapter
indexes nothing for it. Edges stay, so the closure can still be walked.

For each scope that lost a `Pattern` or a `Summary`, one `pattern` or
`summary` job is queued to rebuild from what remains, and the response lists
their qids in `jobsQueued`. The call appends `quipu.forget.completed` and
`quipu.audit`. A dry run writes no tombstone and queues nothing, but still
appends both events with `status: "planned"`. An extract job whose calls
were in flight does not write a claim whose message is now forgotten.

## Glossary

- **message**: a `Message` node, one element of `messages[]` in a remember
  call, with its role, text, date and position.
- **chunk**: a `Chunk` node, a slice of a message over 1,200 bytes. The
  chunks reassemble the message exactly; search sees chunks, not the long
  message.
- **turn**: the `Turn` node of one remember call; it holds the call's
  messages, tool calls and observations. One extract job reads one turn.
- **session**: a `Session` node: one conversation, with a turn for every
  remember call that named it.
- **sessionId**: the caller's name for a session. With the scope it
  identifies the `Session` node; a call without one is its own session.
- **conversation**: not a node. The code and the prompts use it for one
  `Session` node.
- **scope**: `tenantId`, `userId`, `agentId`, `projectId`; an unset field
  matches anything.
- **claim / assertion**: an `Assertion` node written by an extract job: one
  fact a person stated, with a quote grounded in its message.
- **fact**: three things. A `Fact` node is a deterministic slot memory
  (package manager, repo style, project constraint). An item of type `fact`
  in `<facts>` is a `Fact` node or, with `options.facts`, a claim that an
  `Update` links. A line in `<threads>` is a claim.
- **update**: an `Update` node from consolidation, saying one claim
  replaced an earlier one, with both values and dates.
- **topic**: a `Summary` with `summaryType: "topic"`, over a group of two or
  more claims clustered by their vectors.
- **thread**: what `<threads>` shows of a topic: its title and summary over
  its claims. Claims in no topic are listed apart.
- **summary**: a `Summary` node, of a session or of a topic. A session
  summary also heads that session's lines in `<sessions>`.
- **pattern**: a `Pattern` node, a conclusion counted across occasions,
  never stated by the person.
- **occasion**: in a pattern pass, the messages of one `Session` node on one
  day.
- **evidence**: what a node rests on, through `EVIDENCED_BY` (or
  `DERIVED_FROM`) edges and `evidenceQid`; in a response, an item's
  `evidence` list of qids and quotes.
- **said date / event date**: a claim's `createdAt` is its message's date,
  when it was said. `eventDate`, `eventStart` and `eventEnd` are when the
  thing happened, when the claim or its wording says so.
- **qid**: a node's public id, `q_<prefix>_<n>` from the runtime counter or
  `q_<prefix>_<hash>` from content, so rewrites land on the same node.
- **job**: a `Job` node materialized from one stream entry, run by its
  worker kind.
- **stream**: a named, append-only log in the store; entries have a
  sequence number.
- **budget**: `budgetTokens`, default 4,096, estimated, not counted by a
  tokenizer, and split as in [Token budget](#token-budget).
