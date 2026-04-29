from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Iterable, Mapping


@dataclass(frozen=True)
class GradeResult:
    name: str
    passed: bool
    details: Mapping[str, object]


def normalize_text(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower())


def grade_exact_answer(actual: str, expected: str) -> GradeResult:
    actual_normalized = normalize_text(actual)
    expected_normalized = normalize_text(expected)
    passed = actual_normalized == expected_normalized or (
        bool(expected_normalized) and expected_normalized in actual_normalized
    )
    return GradeResult(
        name="exact_answer",
        passed=passed,
        details={"actual": actual, "expected": expected},
    )


def grade_evidence_ids(actual_event_ids: Iterable[str], expected_event_ids: Iterable[str]) -> GradeResult:
    actual = set(actual_event_ids)
    expected = set(expected_event_ids)
    missing = sorted(expected - actual)
    return GradeResult(
        name="evidence_ids",
        passed=not missing,
        details={"actual": sorted(actual), "expected": sorted(expected), "missing": missing},
    )


def grade_forbidden_evidence(actual_event_ids: Iterable[str], forbidden_event_ids: Iterable[str]) -> GradeResult:
    actual = set(actual_event_ids)
    forbidden = set(forbidden_event_ids)
    used_forbidden = sorted(actual & forbidden)
    return GradeResult(
        name="forbidden_evidence",
        passed=not used_forbidden,
        details={"actual": sorted(actual), "forbidden": sorted(forbidden), "usedForbidden": used_forbidden},
    )


def grade_scope_leakage(actual_scopes: Iterable[Mapping[str, str]], expected_scope: Mapping[str, str]) -> GradeResult:
    leaked = []
    for scope in actual_scopes:
        for key, expected_value in expected_scope.items():
            if scope.get(key) != expected_value:
                leaked.append(dict(scope))
                break
    return GradeResult(
        name="scope_leakage",
        passed=not leaked,
        details={"expectedScope": dict(expected_scope), "leakedScopes": leaked},
    )


def grade_deletion_leakage(visible_texts: Iterable[str], forbidden_texts: Iterable[str]) -> GradeResult:
    normalized_visible = [normalize_text(text) for text in visible_texts]
    leaks = []
    for forbidden in forbidden_texts:
        needle = normalize_text(forbidden)
        if any(needle in visible for visible in normalized_visible):
            leaks.append(forbidden)
    return GradeResult(
        name="deletion_leakage",
        passed=not leaks,
        details={"leaks": leaks},
    )


def grade_llm_judge(passed: bool, score: float, reason: str, model: str) -> GradeResult:
    return GradeResult(
        name="llm_judge",
        passed=passed,
        details={"score": score, "reason": reason, "model": model},
    )
