from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
from pathlib import Path
from typing import Iterable, Union

from .fake_client import Q0RawOnlyBaseline
from .graders import (
    GradeResult,
    grade_deletion_leakage,
    grade_evidence_ids,
    grade_exact_answer,
    grade_forbidden_evidence,
    grade_scope_leakage,
)
from .scenarios import Scenario, load_suite


@dataclass(frozen=True)
class QueryRun:
    scenario_id: str
    query_id: str
    grades: list[GradeResult]

    @property
    def passed(self) -> bool:
        return all(grade.passed for grade in self.grades)


@dataclass(frozen=True)
class ForgetRun:
    scenario_id: str
    forget_id: str
    deleted_roots: int
    grade: GradeResult

    @property
    def passed(self) -> bool:
        return self.grade.passed


@dataclass(frozen=True)
class SuiteRun:
    suite_name: str
    suite_version: str
    baseline: str
    query_runs: list[QueryRun]
    forget_runs: list[ForgetRun]

    @property
    def passed(self) -> bool:
        return all(run.passed for run in self.query_runs) and all(run.passed for run in self.forget_runs)

    def to_json(self) -> dict[str, object]:
        return {
            "suiteName": self.suite_name,
            "suiteVersion": self.suite_version,
            "baseline": self.baseline,
            "passed": self.passed,
            "queries": [query_run_to_json(run) for run in self.query_runs],
            "forgetOps": [forget_run_to_json(run) for run in self.forget_runs],
            "metrics": summarize(self),
        }


def run_suite(path: Union[str, Path]) -> SuiteRun:
    suite = load_suite(path)
    query_runs: list[QueryRun] = []
    forget_runs: list[ForgetRun] = []
    for scenario in suite.scenarios:
        scenario_query_runs, scenario_forget_runs = run_scenario(scenario)
        query_runs.extend(scenario_query_runs)
        forget_runs.extend(scenario_forget_runs)
    return SuiteRun(
        suite_name=suite.name,
        suite_version=suite.version,
        baseline="q0_raw_only_fake",
        query_runs=query_runs,
        forget_runs=forget_runs,
    )


def run_scenario(scenario: Scenario) -> tuple[list[QueryRun], list[ForgetRun]]:
    client = Q0RawOnlyBaseline()
    for event in sorted(scenario.events, key=lambda item: item.time):
        client.remember_event(event)

    query_runs = []
    for query in scenario.queries:
        retrieval = client.retrieve(query)
        grades = [
            grade_exact_answer(retrieval.answer, query.expected_answer),
            grade_evidence_ids(retrieval.evidence_event_ids, query.expected_evidence_event_ids),
            grade_forbidden_evidence(retrieval.evidence_event_ids, query.must_not_use_event_ids),
            grade_scope_leakage(retrieval.item_scopes, query.scope),
        ]
        query_runs.append(QueryRun(scenario.scenario_id, query.query_id, grades))

    forget_runs = []
    for op in scenario.forget_ops:
        deleted = client.forget(op)
        grade = grade_deletion_leakage(client.visible_texts(), op.expected_not_retrievable_text)
        forget_runs.append(ForgetRun(scenario.scenario_id, op.forget_id, deleted, grade))

    return query_runs, forget_runs


def summarize(run: SuiteRun) -> dict[str, object]:
    grade_counts: dict[str, dict[str, int]] = {}
    for grade in _all_grades(run):
        counts = grade_counts.setdefault(grade.name, {"passed": 0, "total": 0})
        counts["total"] += 1
        if grade.passed:
            counts["passed"] += 1
    return {
        "queriesPassed": sum(1 for query in run.query_runs if query.passed),
        "queriesTotal": len(run.query_runs),
        "forgetOpsPassed": sum(1 for op in run.forget_runs if op.passed),
        "forgetOpsTotal": len(run.forget_runs),
        "grades": grade_counts,
    }


def _all_grades(run: SuiteRun) -> Iterable[GradeResult]:
    for query in run.query_runs:
        yield from query.grades
    for forget in run.forget_runs:
        yield forget.grade


def query_run_to_json(run: QueryRun) -> dict[str, object]:
    return {
        "scenarioId": run.scenario_id,
        "queryId": run.query_id,
        "passed": run.passed,
        "grades": [asdict(grade) for grade in run.grades],
    }


def forget_run_to_json(run: ForgetRun) -> dict[str, object]:
    return {
        "scenarioId": run.scenario_id,
        "forgetId": run.forget_id,
        "deletedRoots": run.deleted_roots,
        "passed": run.passed,
        "grade": asdict(run.grade),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("suite", nargs="?", default="evals/suites/quipu_synthetic.yaml")
    args = parser.parse_args()
    run = run_suite(args.suite)
    print(json.dumps(run.to_json(), indent=2, sort_keys=True))
    return 0 if run.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
