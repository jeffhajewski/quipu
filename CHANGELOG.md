# Changelog

## Unreleased

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
  vector.
- With the `openrouter` or `openai` embedding provider, vectors default to the
  model's native 1536 dimensions and the `dimensions` request parameter is sent
  only when a width is configured.

## 0.1.0

- Initial specification and repository skeleton.
