# Algorithms

See [../SPEC.md](../SPEC.md) for the full design.

## Retrieval V0

The current in-memory retrieval path is deterministic and deliberately simple:

1. Search the adapter with lexical full-text matching.
2. Apply scope, deleted-state, temporal validity, and event-window filters.
3. Optionally add scoped core blocks when `needs` includes `core`.
4. Filter candidates by requested memory needs.
5. Suppress raw evidence when derived facts/procedures are available, unless `needs` explicitly includes `raw`.
6. Drop items that exceed `budgetTokens`, preserving warning and trace counts.
7. Split kept items into context sections and render the prompt from those sections.

This gives later vector/BM25/reranking work a stable behavioral surface: retrieval must return scoped, evidence-backed, budgeted context packets rather than arbitrary top-k chunks.
