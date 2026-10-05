# Changelog

## Unreleased

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
- Forgetting, supersession, core blocks, related cards, job leasing and the
  inspect audit trail no longer enumerate the first 1,000 (or 100,000) nodes or
  audit events. On stores past that size they used to miss newer memories:
  forgetting could leave derived facts, cards, episodes or core blocks that
  still carried the deleted text, and supersession could leave two current
  values for a slot.
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
