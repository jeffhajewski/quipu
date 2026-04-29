from __future__ import annotations

from typing import Any, Mapping


REAL_BENCHMARK_READY_REQUIREMENTS = [
    ("external_dataset_adapter", "External dataset adapter"),
    ("full_dataset", "Full external dataset"),
    ("replay_into_daemon", "Replay into daemon"),
    ("lattice_storage", "Lattice-backed storage"),
    ("retrieval_traces", "Retrieval traces"),
    ("answer_generation", "Answer generation"),
    ("grading", "Grading"),
    ("baselines", "Required baselines"),
    ("ablations", "Quipu ablations"),
    ("verification", "Verification pass"),
    ("reproducible_report", "Reproducible report and manifests"),
]


def evaluate_readiness(report: Mapping[str, Any]) -> dict[str, Any]:
    runs = [run for run in report.get("runs", []) if isinstance(run, Mapping)]
    implemented_baselines = {str(run.get("baseline")) for run in runs}
    artifacts = [run.get("artifacts", {}) for run in runs]
    manifests = [artifact.get("manifest") for artifact in artifacts if isinstance(artifact, Mapping)]

    checks = {
        "external_dataset_adapter": bool(report.get("externalBenchmark")),
        "full_dataset": bool(report.get("dataset", {}).get("fullDataset")),
        "replay_into_daemon": any(run.get("storage") in {"memory", "lattice"} for run in runs),
        "lattice_storage": any(
            run.get("storage") == "lattice"
            and "error" not in run
            and isinstance(run.get("metrics"), Mapping)
            for run in runs
        ),
        "retrieval_traces": bool(report.get("traceArtifacts")),
        "answer_generation": any(_has_answer_metrics(run) for run in runs),
        "grading": any(_has_grade_metrics(run) for run in runs),
        "baselines": _has_publishable_baselines(implemented_baselines),
        "ablations": _has_publishable_ablations(report),
        "verification": report.get("verification", {}).get("status") == "passed",
        "reproducible_report": bool(report.get("gitCommit")) and len(manifests) == len(runs),
    }

    requirement_results = [
        {
            "id": requirement_id,
            "name": name,
            "passed": checks.get(requirement_id, False),
        }
        for requirement_id, name in REAL_BENCHMARK_READY_REQUIREMENTS
    ]
    missing = [item["id"] for item in requirement_results if not item["passed"]]
    return {
        "status": "ready" if not missing else "not_ready",
        "missing": missing,
        "requirements": requirement_results,
    }


def _has_answer_metrics(run: Mapping[str, Any]) -> bool:
    answer = run.get("metrics", {}).get("answer", {})
    return isinstance(answer, Mapping) and "exactMatch" in answer


def _has_grade_metrics(run: Mapping[str, Any]) -> bool:
    grades = run.get("metrics", {}).get("grades", {})
    return isinstance(grades, Mapping) and bool(grades)


def _has_publishable_baselines(implemented_baselines: set[str]) -> bool:
    required = {
        "full_context",
        "recent_only",
        "bm25",
        "vector_rag",
        "hybrid_bm25_vector",
        "summary_only",
        "memory_cards_only",
        "graph_only",
    }
    return required.issubset(implemented_baselines)


def _has_publishable_ablations(report: Mapping[str, Any]) -> bool:
    ablations = report.get("ablations", [])
    if not isinstance(ablations, list):
        return False
    required = {f"Q{index}" for index in range(14)} | {"full_quipu"}
    present = {str(item.get("id")) for item in ablations if isinstance(item, Mapping)}
    return required.issubset(present)
