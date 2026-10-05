# Changelog

## Unreleased

- LLM fact extraction: `quipu jobs run extract` (and the operational
  `memory.extract.run` RPC) runs the queued `extract` jobs through a chat model
  configured with `--extract-provider`, `--extract-url` and `--extract-model`
  (falling back to `--llm-*`). It uses E1's prompt with an optional event date,
  exact-quote grounding with unique-quote index repair, and bounded retries
  after malformed JSON. Accepted claims become `Assertion` nodes linked
  `EVIDENCED_BY` to their message and chunk. Quarantined claims are counted on
  the job, never stored. Forgetting a message tombstones its assertions.
- `options.factKeys` on `memory.retrieve` and `memory.answer` (default `false`):
  assertion hits return their source chunk or message, never the claim, and
  raw lines show claim event dates as `[event YYYY-MM-DD]`. With it off,
  assertions take no part in retrieval. `trace.factKeys` reports how claims
  shaped the candidates, and `system.health` reports the extractor.
- Memory items may have type `assertion`, but only from `memory.search` with
  `labels: ["Assertion"]`.

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
  vector.
- With the `openrouter` or `openai` embedding provider, vectors default to the
  model's native 1536 dimensions and the `dimensions` request parameter is sent
  only when a width is configured.

## 0.1.0

- Initial specification and repository skeleton.
