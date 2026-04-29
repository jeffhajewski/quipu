from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class BaselineSpec:
    id: str
    name: str
    status: str
    description: str


REQUIRED_BASELINES = [
    BaselineSpec("full_context", "Full context", "implemented_deterministic", "Replay all eligible raw context within the answer budget."),
    BaselineSpec("recent_only", "Recent only", "implemented_deterministic", "Use the most recent scoped messages only."),
    BaselineSpec("bm25", "BM25", "implemented_deterministic", "Lexical search baseline over scoped raw messages."),
    BaselineSpec("vector_rag", "Vector RAG", "implemented_deterministic", "Vector-only retrieval over scoped raw messages."),
    BaselineSpec("hybrid_bm25_vector", "Hybrid BM25/vector", "implemented_deterministic", "Combine lexical and vector scores."),
    BaselineSpec("summary_only", "Summary only", "implemented_deterministic", "Answer from generated summaries without raw evidence retrieval."),
    BaselineSpec("memory_cards_only", "Memory cards only", "implemented_deterministic", "Use memory cards without raw-message fallback."),
    BaselineSpec("graph_only", "Graph only", "implemented_deterministic", "Use graph expansion without lexical/vector ranking."),
    BaselineSpec("q0_raw_only_fake", "Q0 raw-only fake", "implemented", "Deterministic raw-only smoke baseline."),
    BaselineSpec("core_in_memory", "Core in-memory", "implemented", "Zig core runtime over in-memory storage."),
    BaselineSpec("core_lattice", "Core LatticeDB", "implemented_optional", "Zig core runtime over LatticeDB when configured."),
]


QUIPU_ABLATIONS = [
    BaselineSpec("Q0", "Raw-only no extraction", "implemented_deterministic", "Raw scenario replay with scoped lexical retrieval."),
    BaselineSpec("Q1", "Memory cards only", "implemented_deterministic", "Retrieve only memory-card nodes."),
    BaselineSpec("Q2", "Facts only", "implemented_deterministic", "Retrieve only fact/preference nodes."),
    BaselineSpec("Q3", "Vector only", "implemented_deterministic", "Use vector retrieval only."),
    BaselineSpec("Q4", "BM25 only", "implemented_deterministic", "Use lexical retrieval only."),
    BaselineSpec("Q5", "Vector + BM25", "implemented_deterministic", "Hybrid lexical/vector retrieval."),
    BaselineSpec("Q6", "+ graph expansion", "implemented_deterministic", "Add graph neighborhood expansion."),
    BaselineSpec("Q7", "+ graph activation", "implemented_deterministic", "Add activation scoring over graph neighborhoods."),
    BaselineSpec("Q8", "+ temporal validity", "implemented_deterministic", "Use valid-at filtering for current and historical facts."),
    BaselineSpec("Q9", "+ contradiction suppression", "implemented_deterministic", "Suppress stale or contradicted active answers."),
    BaselineSpec("Q10", "+ evidence reranking", "implemented_deterministic", "Rerank retrieved evidence before budget assembly."),
    BaselineSpec("Q11", "+ utility learning", "implemented_deterministic", "Update utility scores from feedback and traces."),
    BaselineSpec("Q12", "+ summaries/core memory", "implemented_deterministic", "Include user-managed core memory blocks and summaries."),
    BaselineSpec("Q13", "+ forgetting propagation", "implemented_deterministic", "Propagate forget operations through derived memories."),
    BaselineSpec("full_quipu", "Full Quipu", "implemented_deterministic", "All deterministic retrieval, consolidation, and verification stages enabled."),
]


DETERMINISTIC_REQUIRED_BASELINES = [
    "full_context",
    "recent_only",
    "bm25",
    "vector_rag",
    "hybrid_bm25_vector",
    "summary_only",
    "memory_cards_only",
    "graph_only",
]

DETERMINISTIC_ABLATIONS = [item.id for item in QUIPU_ABLATIONS]


def registry_json() -> dict[str, list[dict[str, str]]]:
    return {
        "baselines": [asdict(item) for item in REQUIRED_BASELINES],
        "ablations": [asdict(item) for item in QUIPU_ABLATIONS],
    }
