from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
from pathlib import Path
from typing import Iterable, Union

from .artifacts import build_manifest, write_json
from .fake_client import FakeQuipuClient, supported_baseline_ids
from .graders import (
    GradeResult,
    grade_deletion_leakage,
    grade_evidence_ids,
    grade_exact_answer,
    grade_forbidden_evidence,
    grade_llm_judge,
    grade_scope_leakage,
)
from .metrics import grade_counts, metric_groups
from .provider_clients import OpenRouterClient, openrouter_providers_from_env
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


def run_suite(
    path: Union[str, Path],
    *,
    baseline_id: str = "q0_raw_only_fake",
    baseline_label: str | None = None,
    embedding_provider: object | None = None,
    answer_provider: object | None = None,
    judge_provider: object | None = None,
) -> SuiteRun:
    suite = load_suite(path)
    query_runs: list[QueryRun] = []
    forget_runs: list[ForgetRun] = []
    for scenario in suite.scenarios:
        scenario_query_runs, scenario_forget_runs = run_scenario(
            scenario,
            baseline_id=baseline_id,
            embedding_provider=embedding_provider,
            answer_provider=answer_provider,
            judge_provider=judge_provider,
        )
        query_runs.extend(scenario_query_runs)
        forget_runs.extend(scenario_forget_runs)
    return SuiteRun(
        suite_name=suite.name,
        suite_version=suite.version,
        baseline=baseline_label or baseline_id,
        query_runs=query_runs,
        forget_runs=forget_runs,
    )


def run_scenario(
    scenario: Scenario,
    *,
    baseline_id: str = "q0_raw_only_fake",
    embedding_provider: object | None = None,
    answer_provider: object | None = None,
    judge_provider: object | None = None,
) -> tuple[list[QueryRun], list[ForgetRun]]:
    client = FakeQuipuClient(
        baseline_id,
        embedding_provider=embedding_provider,
        answer_provider=answer_provider,
    )
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
        if judge_provider is not None:
            judgment = judge_provider.judge_answer(query.query, query.expected_answer, retrieval.answer)
            grades.append(grade_llm_judge(judgment.passed, judgment.score, judgment.reason, judgment.model))
        query_runs.append(QueryRun(scenario.scenario_id, query.query_id, grades))

    forget_runs = []
    for op in scenario.forget_ops:
        deleted = client.forget(op)
        grade = grade_deletion_leakage(client.visible_texts(), op.expected_not_retrievable_text)
        forget_runs.append(ForgetRun(scenario.scenario_id, op.forget_id, deleted, grade))

    return query_runs, forget_runs


def summarize(run: SuiteRun) -> dict[str, object]:
    grades = list(_all_grades(run))
    return {
        "queriesPassed": sum(1 for query in run.query_runs if query.passed),
        "queriesTotal": len(run.query_runs),
        "forgetOpsPassed": sum(1 for op in run.forget_runs if op.passed),
        "forgetOpsTotal": len(run.forget_runs),
        "grades": grade_counts(grades),
        **metric_groups(grades),
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
    parser.add_argument("--baseline", choices=supported_baseline_ids(), default="q0_raw_only_fake")
    parser.add_argument("--embedding-provider", choices=["deterministic", "openrouter"], default="deterministic")
    parser.add_argument("--answer-provider", choices=["deterministic", "openrouter"], default="deterministic")
    parser.add_argument("--judge-provider", choices=["none", "openrouter"], default="none")
    parser.add_argument("--embedding-cache", type=Path, help="JSONL cache for provider embedding vectors")
    parser.add_argument("--output", type=Path, help="Write the full run result JSON to this path")
    parser.add_argument("--manifest", type=Path, help="Write a compact eval run manifest to this path")
    args = parser.parse_args()
    embedding_provider = None
    answer_provider = None
    judge_provider = None
    openrouter_client: OpenRouterClient | None = None
    if args.embedding_provider == "openrouter":
        embedding_provider, openrouter_client = openrouter_providers_from_env(cache_path=args.embedding_cache)
    if args.answer_provider == "openrouter":
        openrouter_client = openrouter_client or OpenRouterClient()
        answer_provider = openrouter_client
    if args.judge_provider == "openrouter":
        openrouter_client = openrouter_client or OpenRouterClient()
        judge_provider = openrouter_client
    baseline_label = (
        f"openrouter_{args.baseline}"
        if args.embedding_provider == "openrouter" or args.answer_provider == "openrouter" or args.judge_provider == "openrouter"
        else args.baseline
    )
    run = run_suite(
        args.suite,
        baseline_id=args.baseline,
        baseline_label=baseline_label,
        embedding_provider=embedding_provider,
        answer_provider=answer_provider,
        judge_provider=judge_provider,
    )
    run_json = run.to_json()
    if args.output:
        write_json(args.output, run_json)
    if args.manifest:
        write_json(
            args.manifest,
            build_manifest(
                run_json,
                suite_path=args.suite,
                runner="quipu_evals.runner",
                storage="fake",
                results_path=args.output,
                config={
                    "suite": str(args.suite),
                    "baseline": args.baseline,
                    "embeddingProvider": args.embedding_provider,
                    "answerProvider": args.answer_provider,
                    "judgeProvider": args.judge_provider,
                },
                providers={
                    "extractor": "deterministic_fixture",
                    "embedder": args.embedding_provider,
                    "reranker": "none",
                    "answer": args.answer_provider,
                    "judge": args.judge_provider,
                },
            ),
        )
    print(json.dumps(run_json, indent=2, sort_keys=True))
    return 0 if run.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
