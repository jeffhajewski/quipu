from __future__ import annotations

from dataclasses import asdict, dataclass
import argparse
import json
from pathlib import Path
import os
import re
import shutil
import subprocess
from typing import Mapping

from .core_client import CoreStdioClient
from .graders import (
    GradeResult,
    grade_deletion_leakage,
    grade_evidence_ids,
    grade_exact_answer,
    grade_forbidden_evidence,
)
from .scenarios import Event, Query, Scenario, load_suite


ROOT = Path(__file__).resolve().parents[3]
CORE_DIR = ROOT / "core"
CORE_BINARY = CORE_DIR / "zig-out" / "bin" / "quipu"


@dataclass(frozen=True)
class CoreQueryRun:
    scenario_id: str
    query_id: str
    category: str
    prompt: str
    actual_answer: str
    evidence_event_ids: list[str]
    grades: list[GradeResult]

    @property
    def passed(self) -> bool:
        return all(grade.passed for grade in self.grades)


@dataclass(frozen=True)
class CoreForgetRun:
    scenario_id: str
    forget_id: str
    deleted_roots: int
    invalidated_facts: int
    grade: GradeResult

    @property
    def passed(self) -> bool:
        return self.grade.passed


@dataclass(frozen=True)
class CoreSuiteRun:
    suite_name: str
    suite_version: str
    query_runs: list[CoreQueryRun]
    forget_runs: list[CoreForgetRun]

    @property
    def passed(self) -> bool:
        return all(run.passed for run in self.query_runs) and all(run.passed for run in self.forget_runs)

    def to_json(self) -> dict[str, object]:
        return {
            "suiteName": self.suite_name,
            "suiteVersion": self.suite_version,
            "baseline": "core_in_memory",
            "passed": self.passed,
            "queries": [query_run_to_json(run) for run in self.query_runs],
            "forgetOps": [forget_run_to_json(run) for run in self.forget_runs],
            "metrics": {
                "queriesPassed": sum(1 for run in self.query_runs if run.passed),
                "queriesTotal": len(self.query_runs),
                "forgetOpsPassed": sum(1 for run in self.forget_runs if run.passed),
                "forgetOpsTotal": len(self.forget_runs),
            },
        }


def run_core_suite(path: str | Path) -> CoreSuiteRun:
    ensure_core_binary()
    suite = load_suite(path)
    query_runs: list[CoreQueryRun] = []
    forget_runs: list[CoreForgetRun] = []
    for scenario in suite.scenarios:
        scenario_query_runs, scenario_forget_runs = run_core_scenario(scenario)
        query_runs.extend(scenario_query_runs)
        forget_runs.extend(scenario_forget_runs)
    return CoreSuiteRun(suite.name, suite.version, query_runs, forget_runs)


def run_core_scenario(scenario: Scenario) -> tuple[list[CoreQueryRun], list[CoreForgetRun]]:
    with CoreStdioClient(CORE_BINARY) as client:
        event_to_message_qids: dict[str, list[str]] = {}
        for event in sorted(scenario.events, key=lambda item: item.time):
            remembered = remember_event(client, event)
            event_to_message_qids[event.event_id] = list(remembered["messageQids"])

        query_runs = [run_query(client, scenario.scenario_id, query, event_to_message_qids) for query in scenario.queries]

        forget_runs = []
        for op in scenario.forget_ops:
            qids = []
            for event_id in op.selector.get("eventIds", []):
                qids.extend(event_to_message_qids.get(event_id, []))
            result = client.call(
                "memory.forget",
                {
                    "mode": op.mode,
                    "selector": {"qids": qids},
                    "dryRun": False,
                    "reason": "eval",
                },
            )
            visible_texts = []
            for text in op.expected_not_retrievable_text:
                retrieved = client.call("memory.retrieve", {"query": text, "scope": {}})
                visible_texts.append(str(retrieved["prompt"]))
            grade = grade_deletion_leakage(visible_texts, op.expected_not_retrievable_text)
            forget_runs.append(
                CoreForgetRun(
                    scenario_id=scenario.scenario_id,
                    forget_id=op.forget_id,
                    deleted_roots=int(result["nodesDeleted"]),
                    invalidated_facts=int(result["factsInvalidated"]),
                    grade=grade,
                )
            )

        return query_runs, forget_runs


def remember_event(client: CoreStdioClient, event: Event) -> Mapping[str, object]:
    return client.call(
        "memory.remember",
        {
            "scope": event.scope,
            "messages": [
                {
                    "role": message.role,
                    "content": message.content,
                    "createdAt": event.time,
                }
                for message in event.messages
            ],
        },
    )


def run_query(
    client: CoreStdioClient,
    scenario_id: str,
    query: Query,
    event_to_message_qids: Mapping[str, list[str]],
) -> CoreQueryRun:
    retrieved = client.call(
        "memory.retrieve",
        {
            "query": query.query,
            "scope": query.scope,
            "time": {"validAt": query.time},
            "options": {"includeEvidence": True},
        },
    )
    prompt = str(retrieved["prompt"])
    actual_answer = answer_from_prompt(prompt, query.expected_answer)
    evidence_event_ids = event_ids_from_items(retrieved.get("items", []), event_to_message_qids)
    grades = [
        grade_exact_answer(actual_answer, query.expected_answer),
        grade_evidence_ids(evidence_event_ids, query.expected_evidence_event_ids),
        grade_forbidden_evidence(evidence_event_ids, query.must_not_use_event_ids),
    ]
    return CoreQueryRun(
        scenario_id=scenario_id,
        query_id=query.query_id,
        category=query.category,
        prompt=prompt,
        actual_answer=actual_answer,
        evidence_event_ids=evidence_event_ids,
        grades=grades,
    )


def event_ids_from_items(items: object, event_to_message_qids: Mapping[str, list[str]]) -> list[str]:
    qid_to_event = {
        message_qid: event_id
        for event_id, message_qids in event_to_message_qids.items()
        for message_qid in message_qids
    }
    found: list[str] = []
    if not isinstance(items, list):
        return found
    for item in items:
        if not isinstance(item, Mapping):
            continue
        qid = item.get("qid")
        if isinstance(qid, str) and qid in qid_to_event:
            found.append(qid_to_event[qid])
        evidence = item.get("evidence")
        if isinstance(evidence, list):
            for evidence_item in evidence:
                if isinstance(evidence_item, Mapping):
                    evidence_qid = evidence_item.get("qid")
                    if isinstance(evidence_qid, str) and evidence_qid in qid_to_event:
                        found.append(qid_to_event[evidence_qid])
    return sorted(set(found))


def answer_from_prompt(prompt: str, expected_answer: str) -> str:
    pattern = r"(?<![a-z0-9])" + re.escape(expected_answer.lower()) + r"(?![a-z0-9])"
    return expected_answer if re.search(pattern, prompt.lower()) else ""


def ensure_core_binary() -> None:
    if not shutil.which("zig"):
        raise RuntimeError("zig is required to run core eval smoke")
    env = os.environ.copy()
    env["ZIG_GLOBAL_CACHE_DIR"] = "/tmp/quipu-zig-cache"
    subprocess.run(["zig", "build"], cwd=str(CORE_DIR), check=True, env=env)


def query_run_to_json(run: CoreQueryRun) -> dict[str, object]:
    return {
        "scenarioId": run.scenario_id,
        "queryId": run.query_id,
        "category": run.category,
        "passed": run.passed,
        "actualAnswer": run.actual_answer,
        "evidenceEventIds": run.evidence_event_ids,
        "grades": [asdict(grade) for grade in run.grades],
    }


def forget_run_to_json(run: CoreForgetRun) -> dict[str, object]:
    return {
        "scenarioId": run.scenario_id,
        "forgetId": run.forget_id,
        "passed": run.passed,
        "deletedRoots": run.deleted_roots,
        "invalidatedFacts": run.invalidated_facts,
        "grade": asdict(run.grade),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("suite", nargs="?", default=str(ROOT / "evals" / "suites" / "quipu_synthetic.yaml"))
    parser.add_argument("--strict", action="store_true", help="Return non-zero when any scenario fails")
    args = parser.parse_args()
    run = run_core_suite(args.suite)
    print(json.dumps(run.to_json(), indent=2, sort_keys=True))
    return 0 if run.passed or not args.strict else 1


if __name__ == "__main__":
    raise SystemExit(main())
