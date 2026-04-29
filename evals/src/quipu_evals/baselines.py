from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class BaselineSpec:
    id: str
    name: str
    status: str
    description: str


REQUIRED_BASELINES = [
    BaselineSpec("full_context", "Full context", "planned", "Replay all eligible raw context within the answer budget."),
    BaselineSpec("recent_only", "Recent only", "planned", "Use the most recent scoped messages only."),
    BaselineSpec("bm25", "BM25", "planned", "Lexical search baseline over scoped raw messages."),
    BaselineSpec("vector_rag", "Vector RAG", "planned", "Vector-only retrieval over scoped raw messages."),
    BaselineSpec("hybrid_bm25_vector", "Hybrid BM25/vector", "planned", "Combine lexical and vector scores."),
    BaselineSpec("summary_only", "Summary only", "planned", "Answer from generated summaries without raw evidence retrieval."),
    BaselineSpec("memory_cards_only", "Memory cards only", "planned", "Use memory cards without raw-message fallback."),
    BaselineSpec("graph_only", "Graph only", "planned", "Use graph expansion without lexical/vector ranking."),
    BaselineSpec("q0_raw_only_fake", "Q0 raw-only fake", "implemented", "Deterministic raw-only smoke baseline."),
    BaselineSpec("core_in_memory", "Core in-memory", "implemented", "Zig core runtime over in-memory storage."),
    BaselineSpec("core_lattice", "Core LatticeDB", "implemented_optional", "Zig core runtime over LatticeDB when configured."),
]


QUIPU_ABLATIONS = [
    BaselineSpec("Q0", "Raw-only no extraction", "implemented_smoke", "Raw scenario replay with scoped lexical retrieval."),
    BaselineSpec("Q1", "Memory cards only", "planned", "Retrieve only memory-card nodes."),
    BaselineSpec("Q2", "Facts only", "planned", "Retrieve only fact/preference nodes."),
    BaselineSpec("Q3", "Vector only", "planned", "Use vector retrieval only."),
    BaselineSpec("Q4", "BM25 only", "planned", "Use lexical retrieval only."),
    BaselineSpec("Q5", "Vector + BM25", "planned", "Hybrid lexical/vector retrieval."),
    BaselineSpec("Q6", "+ graph expansion", "planned", "Add graph neighborhood expansion."),
    BaselineSpec("Q7", "+ graph activation", "planned", "Add activation scoring over graph neighborhoods."),
    BaselineSpec("Q8", "+ temporal validity", "partial", "Use valid-at filtering for current and historical facts."),
    BaselineSpec("Q9", "+ contradiction suppression", "planned", "Suppress stale or contradicted active answers."),
    BaselineSpec("Q10", "+ evidence reranking", "planned", "Rerank retrieved evidence before budget assembly."),
    BaselineSpec("Q11", "+ utility learning", "planned", "Update utility scores from feedback and traces."),
    BaselineSpec("Q12", "+ summaries/core memory", "partial", "Include user-managed core memory blocks and summaries."),
    BaselineSpec("Q13", "+ forgetting propagation", "partial", "Propagate forget operations through derived memories."),
    BaselineSpec("full_quipu", "Full Quipu", "planned", "All retrieval, consolidation, provider, and verification stages enabled."),
]


def registry_json() -> dict[str, list[dict[str, str]]]:
    return {
        "baselines": [asdict(item) for item in REQUIRED_BASELINES],
        "ablations": [asdict(item) for item in QUIPU_ABLATIONS],
    }
