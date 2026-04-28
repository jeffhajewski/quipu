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

## Extraction V0

The current extractor is deterministic and intentionally narrow. It emits candidate facts, preferences, and procedures for package manager, response style, and test-command memories. Runtime treats those candidates as untrusted:

1. Validate that slot, label, value, and text are well formed.
2. Reject label/slot mismatches before any graph write.
3. Supersede only the current memory with the same scoped slot key.
4. Store the accepted derived node with temporal validity and raw evidence.
5. Link the derived node to its message evidence with `EVIDENCED_BY`.

This mirrors the future plugin contract: extractor output can propose memories, but deterministic runtime validation owns all mutation.
