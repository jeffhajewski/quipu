# Algorithms

See [../SPEC.md](../SPEC.md) for the full design.

## Search V0

`memory.search` accepts `mode` values of `fts`, `vector`, `hybrid`, and `graph`.
The in-memory adapter currently serves lexical search only; vector mode returns
no hits when the active backend does not advertise vector capability. The
Lattice adapter indexes deterministic `lattice_hash_embed` vectors by default,
or OpenAI-compatible provider embeddings when configured, as nodes are written.
It embeds vector queries through the same provider and uses Lattice vector
search for `vector` and `hybrid` modes. `hybrid` fuses lexical and vector ranks
with reciprocal-rank fusion before the runtime applies scope, deleted-state,
label, and temporal filters.

`graph` mode starts from the same lexical or hybrid seed set, expands through
stored `Entity` nodes connected by `MENTIONS` / `MENTIONED_IN` edges, then
applies the normal runtime filters. Entity nodes are hidden from retrieval
results unless callers explicitly request the `Entity` label.

## Retrieval V0

The current retrieval path is deterministic around filtering and context
construction. Candidate generation uses lexical search by default for in-memory
and hash-vector stores, and hybrid search by default when the active backend
advertises a non-hash embedding model. Callers can override this with
`mode: "fts"`, `"vector"`, `"hybrid"`, or `"graph"`.

1. Search the adapter with the selected candidate mode.
2. Apply scope, deleted-state, temporal validity, and event-window filters.
3. Optionally add scoped core blocks when `needs` includes `core`.
4. Filter candidates by requested memory needs.
5. Suppress raw evidence when derived facts/procedures are available, unless `needs` explicitly includes `raw`.
6. Drop items that exceed `budgetTokens`, preserving warning and trace counts.
7. Split kept items into context sections and render the prompt from those sections.

This gives later provider-embedding, BM25, and reranking work a stable behavioral surface: retrieval must return scoped, evidence-backed, budgeted context packets rather than arbitrary top-k chunks.

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
[q_chunk_11] assistant (1/2): first 1,200-character chunk
[q_chunk_12] assistant (2/2): second chunk
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
- Session, role, and index metadata is read from node properties
  (`sessionQid`, `sessionId`, `messageIndex`, `chunkIndex`, `chunkCount`). For
  older nodes it is recovered through the owning Turn's `HAS_*` edge.
  Session and Turn nodes never render as items.
- Text is written on one line with whitespace collapsed. Context section tags
  inside stored text are defanged (`</memory>` becomes `[/memory]`), so memory
  cannot close or forge a section.
- Fixed overhead per item is the bracketed qid, the speaker, and an optional
  date or chunk marker, plus a share of its session header. This fits inside the
  per-item allowance of the budget estimator.

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

`answerTrace.strategy` only describes which path ran: `llm_reader`,
`deterministic_fallback`, or `abstain`. With `options.includeDebug`, the
response also carries `prompt`, the exact memory context string the reader
received.

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
3. Supersede only the current memory with the same scoped slot key.
4. Store the accepted derived node with temporal validity and raw evidence.
5. Link the derived node to its message evidence with `EVIDENCED_BY`.

This mirrors the future plugin contract: extractor output can propose memories, but deterministic runtime validation owns all mutation.
