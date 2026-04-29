from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any


@dataclass(frozen=True)
class PublishedResult:
    system: str
    benchmark: str
    score: float
    metric: str
    dataset: str
    source: str
    source_url: str
    notes: str
    categories: dict[str, float] = field(default_factory=dict)


LOCOMO_RESULTS = [
    PublishedResult(
        system="Mem0 Platform v3 top-200",
        benchmark="locomo",
        score=91.6,
        metric="pass_rate_percent",
        dataset="LoCoMo 1540 questions",
        source="mem0ai/memory-benchmarks README",
        source_url="https://github.com/mem0ai/memory-benchmarks",
        notes="Managed Mem0 platform result; uses top-200 retrieved memories and answer/judge LLM pipeline.",
        categories={"single_hop": 92.3, "multi_hop": 93.3, "open_domain": 76.0, "temporal": 92.8},
    ),
    PublishedResult(
        system="Mem0 Platform v3 top-50",
        benchmark="locomo",
        score=82.7,
        metric="pass_rate_percent",
        dataset="LoCoMo 1540 questions",
        source="mem0ai/memory-benchmarks README",
        source_url="https://github.com/mem0ai/memory-benchmarks",
        notes="Managed Mem0 platform result with a smaller top-50 retrieval cutoff.",
        categories={"single_hop": 82.8, "multi_hop": 82.3, "open_domain": 70.8, "temporal": 86.3},
    ),
    PublishedResult(
        system="Memvid",
        benchmark="locomo",
        score=85.65,
        metric="llm_judge_percent_cat1_4",
        dataset="LoCoMo 1986 questions; primary metric excludes adversarial category",
        source="Memvid benchmark page",
        source_url="https://memvid.com/benchmarks",
        notes="Vendor-published result using GPT-4o answer model, GPT-4o-mini judge, hybrid search, top-k 60.",
        categories={"single_hop": 80.1, "multi_hop": 80.4, "open_domain": 91.1, "temporal": 71.9},
    ),
    PublishedResult(
        system="Memobase v0.0.37",
        benchmark="locomo",
        score=75.78,
        metric="llm_judge_percent",
        dataset="LoCoMo categories 1-4",
        source="memodb-io/memobase LoCoMo benchmark README",
        source_url="https://github.com/memodb-io/memobase/blob/main/docs/experiments/locomo-benchmark/README.md",
        notes="Memobase-maintained benchmark artifacts; reports LLM judge score.",
        categories={"single_hop": 70.92, "multi_hop": 46.88, "open_domain": 77.17, "temporal": 85.05},
    ),
    PublishedResult(
        system="Zep updated",
        benchmark="locomo",
        score=75.14,
        metric="llm_judge_percent",
        dataset="LoCoMo categories 1-4",
        source="memodb-io/memobase LoCoMo benchmark README",
        source_url="https://github.com/memodb-io/memobase/blob/main/docs/experiments/locomo-benchmark/README.md",
        notes="Memobase README labels this as an updated Zep-team result.",
        categories={"single_hop": 74.11, "multi_hop": 66.04, "open_domain": 67.71, "temporal": 79.79},
    ),
    PublishedResult(
        system="Letta Filesystem",
        benchmark="locomo",
        score=74.0,
        metric="accuracy_percent",
        dataset="LoCoMo",
        source="Letta blog",
        source_url="https://www.letta.com/blog/benchmarking-ai-agent-memory",
        notes="Agentic filesystem/search setup using GPT-4o mini and LoCoMo history as attached files.",
    ),
    PublishedResult(
        system="Full-context",
        benchmark="locomo",
        score=72.90,
        metric="llm_judge_percent_cat1_4",
        dataset="LoCoMo categories 1-4",
        source="Memvid benchmark page",
        source_url="https://memvid.com/benchmarks",
        notes="Full-context reference reported on Memvid benchmark page from arXiv baseline figures.",
    ),
    PublishedResult(
        system="Memobase v0.0.32",
        benchmark="locomo",
        score=70.91,
        metric="llm_judge_percent",
        dataset="LoCoMo categories 1-4",
        source="memodb-io/memobase LoCoMo benchmark README",
        source_url="https://github.com/memodb-io/memobase/blob/main/docs/experiments/locomo-benchmark/README.md",
        notes="Older Memobase artifact result.",
        categories={"single_hop": 63.83, "multi_hop": 52.08, "open_domain": 71.82, "temporal": 80.37},
    ),
    PublishedResult(
        system="Mem0 paper baseline",
        benchmark="locomo",
        score=66.88,
        metric="llm_judge_percent",
        dataset="LoCoMo categories 1-4",
        source="memodb-io/memobase LoCoMo benchmark README",
        source_url="https://github.com/memodb-io/memobase/blob/main/docs/experiments/locomo-benchmark/README.md",
        notes="Memobase README says these non-Memobase rows were pasted from the Mem0 paper; some vendors dispute methodology.",
        categories={"single_hop": 67.13, "multi_hop": 51.15, "open_domain": 72.93, "temporal": 55.51},
    ),
    PublishedResult(
        system="Zep paper baseline",
        benchmark="locomo",
        score=65.99,
        metric="llm_judge_percent",
        dataset="LoCoMo categories 1-4",
        source="memodb-io/memobase LoCoMo benchmark README",
        source_url="https://github.com/memodb-io/memobase/blob/main/docs/experiments/locomo-benchmark/README.md",
        notes="Older Zep baseline copied from Mem0 paper according to Memobase README.",
        categories={"single_hop": 61.70, "multi_hop": 41.35, "open_domain": 76.60, "temporal": 49.31},
    ),
    PublishedResult(
        system="LangMem paper baseline",
        benchmark="locomo",
        score=58.10,
        metric="llm_judge_percent",
        dataset="LoCoMo categories 1-4",
        source="memodb-io/memobase LoCoMo benchmark README",
        source_url="https://github.com/memodb-io/memobase/blob/main/docs/experiments/locomo-benchmark/README.md",
        notes="Baseline copied from Mem0 paper according to Memobase README.",
        categories={"single_hop": 62.23, "multi_hop": 47.92, "open_domain": 71.12, "temporal": 23.43},
    ),
    PublishedResult(
        system="OpenAI Memory paper baseline",
        benchmark="locomo",
        score=52.90,
        metric="llm_judge_percent",
        dataset="LoCoMo categories 1-4",
        source="memodb-io/memobase LoCoMo benchmark README",
        source_url="https://github.com/memodb-io/memobase/blob/main/docs/experiments/locomo-benchmark/README.md",
        notes="Baseline copied from Mem0 paper according to Memobase README.",
        categories={"single_hop": 63.79, "multi_hop": 42.92, "open_domain": 62.29, "temporal": 21.71},
    ),
]

LONGMEMEVAL_RESULTS = [
    PublishedResult(
        system="Mem0 Platform v3 top-200",
        benchmark="longmemeval",
        score=93.4,
        metric="pass_rate_percent",
        dataset="LongMemEval 500 questions",
        source="mem0ai/memory-benchmarks README",
        source_url="https://github.com/mem0ai/memory-benchmarks",
        notes="Managed Mem0 platform result; top-200 retrieval cutoff.",
        categories={
            "knowledge_update": 96.2,
            "multi_session": 86.5,
            "single_session_assistant": 100.0,
            "single_session_preference": 96.7,
            "single_session_user": 97.1,
            "temporal_reasoning": 93.2,
        },
    ),
    PublishedResult(
        system="Mem0 Platform v3 top-50",
        benchmark="longmemeval",
        score=90.4,
        metric="pass_rate_percent",
        dataset="LongMemEval 500 questions",
        source="mem0ai/memory-benchmarks README",
        source_url="https://github.com/mem0ai/memory-benchmarks",
        notes="Managed Mem0 platform result; top-50 retrieval cutoff.",
        categories={
            "knowledge_update": 96.2,
            "multi_session": 82.0,
            "single_session_assistant": 92.9,
            "single_session_preference": 86.7,
            "single_session_user": 95.7,
            "temporal_reasoning": 92.5,
        },
    ),
]


def published_results(benchmark: str | None) -> list[dict[str, Any]]:
    if benchmark == "locomo":
        return [asdict(item) for item in LOCOMO_RESULTS]
    if benchmark == "longmemeval":
        return [asdict(item) for item in LONGMEMEVAL_RESULTS]
    return []
