# Algorithms

See [../SPEC.md](../SPEC.md) for the full design.

## Search V0

`memory.search` accepts `mode` values of `fts`, `vector`, `hybrid`, and `graph`.
Every adapter indexes one text per node: `searchText` ?? `content` ?? `text` ??
`name` from the node's properties, never the whole properties JSON. Nodes with
`searchable: false`, internal bookkeeping labels (`Job`, `Idempotency`,
`Schema`, `Migration`), and the `Session` / `Turn` containers are never search
hits. Full-text hits are returned sorted by descending score and truncated only
after sorting. An empty query enumerates every node, including unsearchable
ones; maintenance paths (forget closure, core blocks, job leasing) use that.

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
7. Pack items greedily in rank order into `budgetTokens` (default 4096),
   estimating each item as `ceil(text_bytes / 3.5) + 16` tokens; the overhead
   covers the rendered line prefix, date and speaker tags, and amortized session
   headers. Items that do not fit are skipped and counted in the trace.
8. Split kept items into context sections and render the prompt from those sections.

Retrieval must return scoped, evidence-backed, budgeted context packets rather
than arbitrary top-k chunks; reranking can slot in between steps 3 and 6.

Forgetting a message, whether selected by qid, by a query selector, or through
its `Session` / `Turn`, tombstones and redacts all of its chunks. A query
selector that matches a chunk resolves to the parent message, so the whole
message and every chunk are forgotten together.

`memory.answer` runs the same retrieval path, builds an evidence packet from
retrieved qids, and routes the query to a synthesis strategy:
`span_extract`, `preference`, `knowledge_update`, `temporal`,
`multi_session`, or `abstain`. The runtime first creates obvious heuristic
candidates from retrieved preferences, current facts, temporal items, direct
spans, and simple quantities.

When a configured answer provider is needed, the provider is prompted to return
strict JSON containing `answer`, `answerable`, `supportQids`, `strategy`, and
`confidence`. The runtime validates that every support qid exists in the
evidence packet, normalizes concise answers, and exposes the validation details
through optional `answerTrace`. If `options.abstainIfWeak` is true and the
answer is unsupported or invalidly supported, the public answer string is
exactly `[abstain]`.

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

The current extractor is deterministic and intentionally narrow. It emits candidate facts, preferences, and procedures for package manager, response style, and test-command memories. Runtime treats those candidates as untrusted:

1. Validate that slot, label, value, and text are well formed.
2. Reject label/slot mismatches before any graph write.
3. Supersede only the current memory with the same scoped slot key.
4. Store the accepted derived node with temporal validity and raw evidence.
5. Link the derived node to its message evidence with `EVIDENCED_BY`.

This mirrors the future plugin contract: extractor output can propose memories, but deterministic runtime validation owns all mutation.
