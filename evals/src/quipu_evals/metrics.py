from __future__ import annotations

from collections import defaultdict
from typing import Iterable

from .graders import GradeResult


def grade_counts(grades: Iterable[GradeResult]) -> dict[str, dict[str, int]]:
    counts: dict[str, dict[str, int]] = {}
    for grade in grades:
        bucket = counts.setdefault(grade.name, {"passed": 0, "total": 0})
        bucket["total"] += 1
        if grade.passed:
            bucket["passed"] += 1
    return counts


def metric_groups(grades: Iterable[GradeResult]) -> dict[str, dict[str, float]]:
    by_name: dict[str, list[GradeResult]] = defaultdict(list)
    for grade in grades:
        by_name[grade.name].append(grade)

    retrieval: dict[str, float] = {}
    if by_name["evidence_ids"]:
        retrieval["evidenceRecall"] = _mean_evidence_recall(by_name["evidence_ids"])
        retrieval["recallAtK"] = retrieval["evidenceRecall"]
    if by_name["forbidden_evidence"]:
        retrieval["evidencePrecision"] = _mean_evidence_precision(by_name["evidence_ids"])
        retrieval["staleMemoryRate"] = _fail_rate(by_name["forbidden_evidence"])
    if by_name["scope_leakage"]:
        retrieval["scopePrecision"] = _pass_rate(by_name["scope_leakage"])

    answer: dict[str, float] = {}
    if by_name["exact_answer"]:
        answer["exactMatch"] = _pass_rate(by_name["exact_answer"])
    if by_name["abstention"]:
        answer["abstentionAccuracy"] = _pass_rate(by_name["abstention"])

    forgetting: dict[str, float] = {}
    if by_name["deletion_leakage"]:
        forgetting["deletedStringLeakRate"] = _fail_rate(by_name["deletion_leakage"])

    return {
        "retrieval": retrieval,
        "answer": answer,
        "forgetting": forgetting,
        "runtime": {},
    }


def _pass_rate(grades: list[GradeResult]) -> float:
    if not grades:
        return 0.0
    return sum(1 for grade in grades if grade.passed) / len(grades)


def _fail_rate(grades: list[GradeResult]) -> float:
    if not grades:
        return 0.0
    return sum(1 for grade in grades if not grade.passed) / len(grades)


def _mean_evidence_recall(grades: list[GradeResult]) -> float:
    values = []
    for grade in grades:
        expected = set(_string_list(grade.details.get("expected")))
        actual = set(_string_list(grade.details.get("actual")))
        if not expected:
            continue
        values.append(len(expected & actual) / len(expected))
    return sum(values) / len(values) if values else 0.0


def _mean_evidence_precision(grades: list[GradeResult]) -> float:
    values = []
    for grade in grades:
        expected = set(_string_list(grade.details.get("expected")))
        actual = set(_string_list(grade.details.get("actual")))
        if not actual:
            values.append(0.0 if expected else 1.0)
            continue
        values.append(len(expected & actual) / len(actual))
    return sum(values) / len(values) if values else 0.0


def _string_list(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, str)]
