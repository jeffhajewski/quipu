from __future__ import annotations

from dataclasses import asdict, dataclass
import argparse
import json
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
from typing import Any, Mapping

from .artifacts import build_manifest, write_json
from .core_client import CoreStdioClient
from .graders import (
    GradeResult,
    grade_deletion_leakage,
    grade_evidence_ids,
    grade_exact_answer,
    grade_forbidden_evidence,
)
from .metrics import grade_counts, metric_groups
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
    trace: Mapping[str, Any] | None = None

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
    baseline: str
    query_runs: list[CoreQueryRun]
    forget_runs: list[CoreForgetRun]
    verification_runs: list[Mapping[str, Any]]

    @property
    def passed(self) -> bool:
        return all(run.passed for run in self.query_runs) and all(run.passed for run in self.forget_runs)

    def to_json(self) -> dict[str, object]:
        grades = list(_all_grades(self))
        return {
            "suiteName": self.suite_name,
            "suiteVersion": self.suite_version,
            "baseline": self.baseline,
            "passed": self.passed,
            "queries": [query_run_to_json(run) for run in self.query_runs],
            "forgetOps": [forget_run_to_json(run) for run in self.forget_runs],
            "verification": summarize_verification(self.verification_runs),
            "metrics": {
                "queriesPassed": sum(1 for run in self.query_runs if run.passed),
                "queriesTotal": len(self.query_runs),
                "forgetOpsPassed": sum(1 for run in self.forget_runs if run.passed),
                "forgetOpsTotal": len(self.forget_runs),
                "grades": grade_counts(grades),
                **metric_groups(grades),
            },
        }


def _all_grades(run: CoreSuiteRun):
    for query in run.query_runs:
        yield from query.grades
    for forget in run.forget_runs:
        yield forget.grade


def summarize_verification(verification_runs: list[Mapping[str, Any]]) -> dict[str, object]:
    if not verification_runs:
        return {"status": "not_run", "runs": []}
    passed = all(run.get("status") == "ok" for run in verification_runs)
    return {"status": "passed" if passed else "failed", "runs": verification_runs}


def run_core_suite(
    path: str | Path,
    *,
    storage: str = "memory",
    db_dir: Path | None = None,
    lattice_include: str | None = None,
    lattice_lib: str | None = None,
    scenario_artifact_dir: Path | None = None,
    reuse_existing: bool = False,
    skip_verification: bool = False,
    log_retrieval: bool = True,
    extract: bool = True,
    retrieval_mode: str | None = None,
    answer_method: str = "retrieve",
    answer_provider: str | None = None,
    answer_model: str | None = None,
    answer_url: str | None = None,
    entity_provider: str | None = None,
    entity_model: str | None = None,
    entity_url: str | None = None,
    embedding_provider: str | None = None,
    embedding_model: str | None = None,
    embedding_url: str | None = None,
    vector_dimensions: int | None = None,
    page_size: int | None = None,
) -> CoreSuiteRun:
    ensure_core_binary(storage=storage, lattice_include=lattice_include, lattice_lib=lattice_lib)
    suite = load_suite(path)
    query_runs: list[CoreQueryRun] = []
    forget_runs: list[CoreForgetRun] = []
    verification_runs: list[Mapping[str, Any]] = []
    for scenario in suite.scenarios:
        scenario_artifact = scenario_artifact_path(scenario_artifact_dir, scenario.scenario_id) if scenario_artifact_dir is not None else None
        if reuse_existing and scenario_artifact is not None and scenario_artifact.exists():
            scenario_payload = json.loads(scenario_artifact.read_text())
            scenario_query_runs, scenario_forget_runs, scenario_verification = scenario_run_from_json(scenario_payload)
            query_runs.extend(scenario_query_runs)
            forget_runs.extend(scenario_forget_runs)
            if scenario_verification is not None:
                verification_runs.append(scenario_verification)
            continue

        db_path = None
        if storage == "lattice":
            if db_dir is None:
                raise ValueError("db_dir is required for lattice storage")
            db_path = db_dir / f"{scenario.scenario_id}.lattice"
        retrieval_needs = ["raw"] if suite.metadata.get("benchmark") == "locomo" else None
        scenario_query_runs, scenario_forget_runs, scenario_verification = run_core_scenario(
            scenario,
            db_path=db_path,
            retrieval_needs=retrieval_needs,
            skip_verification=skip_verification,
            log_retrieval=log_retrieval,
            extract=extract,
            retrieval_mode=retrieval_mode,
            answer_method=answer_method,
            answer_provider=answer_provider,
            answer_model=answer_model,
            answer_url=answer_url,
            entity_provider=entity_provider,
            entity_model=entity_model,
            entity_url=entity_url,
            embedding_provider=embedding_provider,
            embedding_model=embedding_model,
            embedding_url=embedding_url,
            vector_dimensions=vector_dimensions,
            page_size=page_size,
        )
        query_runs.extend(scenario_query_runs)
        forget_runs.extend(scenario_forget_runs)
        if scenario_verification is not None:
            verification_runs.append(scenario_verification)
        if scenario_artifact is not None:
            scenario_artifact.parent.mkdir(parents=True, exist_ok=True)
            write_json(
                scenario_artifact,
                scenario_run_to_json(scenario.scenario_id, scenario_query_runs, scenario_forget_runs, scenario_verification),
            )
    baseline = "core_lattice" if storage == "lattice" else "core_in_memory"
    return CoreSuiteRun(suite.name, suite.version, baseline, query_runs, forget_runs, verification_runs)


def run_core_scenario(
    scenario: Scenario,
    *,
    db_path: Path | None = None,
    retrieval_needs: list[str] | None = None,
    skip_verification: bool = False,
    log_retrieval: bool = True,
    extract: bool = True,
    retrieval_mode: str | None = None,
    answer_method: str = "retrieve",
    answer_provider: str | None = None,
    answer_model: str | None = None,
    answer_url: str | None = None,
    entity_provider: str | None = None,
    entity_model: str | None = None,
    entity_url: str | None = None,
    embedding_provider: str | None = None,
    embedding_model: str | None = None,
    embedding_url: str | None = None,
    vector_dimensions: int | None = None,
    page_size: int | None = None,
) -> tuple[list[CoreQueryRun], list[CoreForgetRun], Mapping[str, Any] | None]:
    if answer_method not in {"retrieve", "answer"}:
        raise ValueError("answer_method must be 'retrieve' or 'answer'")
    if entity_provider is not None and db_path is None:
        raise ValueError("entity_provider requires persistent core storage")

    extra_args = core_process_args(
        db_path=db_path,
        answer_provider=answer_provider,
        answer_model=answer_model,
        answer_url=answer_url,
        entity_provider=entity_provider,
        entity_model=entity_model,
        entity_url=entity_url,
        embedding_provider=embedding_provider,
        embedding_model=embedding_model,
        embedding_url=embedding_url,
        vector_dimensions=vector_dimensions,
        page_size=page_size,
    )
    event_to_message_qids: dict[str, list[str]] = {}
    query_runs: list[CoreQueryRun] | None = None
    forget_runs: list[CoreForgetRun] | None = None
    with CoreStdioClient(CORE_BINARY, extra_args=extra_args) as client:
        for event in sorted(scenario.events, key=lambda item: item.time):
            remembered = remember_event(client, event, extract=extract)
            event_to_message_qids[event.event_id] = list(remembered["messageQids"])

        if entity_provider is None:
            query_runs, forget_runs = run_core_queries_and_forgets(
                client,
                scenario,
                event_to_message_qids,
                retrieval_needs=retrieval_needs,
                log_retrieval=log_retrieval,
                retrieval_mode=retrieval_mode,
                answer_method=answer_method,
            )

    if entity_provider is None:
        verification = verify_db(db_path, scenario.scenario_id, extra_args=extra_args) if db_path is not None and not skip_verification else None
        return query_runs or [], forget_runs or [], verification

    if db_path is not None:
        run_entity_resolve_jobs(
            db_path,
            answer_provider=answer_provider,
            answer_model=answer_model,
            answer_url=answer_url,
            entity_provider=entity_provider,
            entity_model=entity_model,
            entity_url=entity_url,
            embedding_provider=embedding_provider,
            embedding_model=embedding_model,
            embedding_url=embedding_url,
            vector_dimensions=vector_dimensions,
            page_size=page_size,
        )

    with CoreStdioClient(CORE_BINARY, extra_args=extra_args) as client:
        query_runs, forget_runs = run_core_queries_and_forgets(
            client,
            scenario,
            event_to_message_qids,
            retrieval_needs=retrieval_needs,
            log_retrieval=log_retrieval,
            retrieval_mode=retrieval_mode,
            answer_method=answer_method,
        )

    verification = verify_db(db_path, scenario.scenario_id, extra_args=extra_args) if db_path is not None and not skip_verification else None
    return query_runs, forget_runs, verification


def core_process_args(
    *,
    db_path: Path | None = None,
    answer_provider: str | None = None,
    answer_model: str | None = None,
    answer_url: str | None = None,
    entity_provider: str | None = None,
    entity_model: str | None = None,
    entity_url: str | None = None,
    embedding_provider: str | None = None,
    embedding_model: str | None = None,
    embedding_url: str | None = None,
    vector_dimensions: int | None = None,
    page_size: int | None = None,
) -> list[str]:
    args: list[str] = []
    if db_path is not None:
        args.extend(["--db", str(db_path)])
    if vector_dimensions is not None:
        args.extend(["--vector-dimensions", str(vector_dimensions)])
    if page_size is not None:
        args.extend(["--page-size", str(page_size)])
    if embedding_provider is not None:
        args.extend(["--embedding-provider", embedding_provider])
    if embedding_url is not None:
        args.extend(["--embedding-url", embedding_url])
    if embedding_model is not None:
        args.extend(["--embedding-model", embedding_model])
    if answer_provider is not None:
        args.extend(["--answer-provider", answer_provider])
    if answer_url is not None:
        args.extend(["--answer-url", answer_url])
    if answer_model is not None:
        args.extend(["--answer-model", answer_model])
    if entity_provider is not None:
        args.extend(["--entity-provider", entity_provider])
    if entity_url is not None:
        args.extend(["--entity-url", entity_url])
    if entity_model is not None:
        args.extend(["--entity-model", entity_model])
    return args


def run_entity_resolve_jobs(
    db_path: Path,
    *,
    answer_provider: str | None = None,
    answer_model: str | None = None,
    answer_url: str | None = None,
    entity_provider: str | None = None,
    entity_model: str | None = None,
    entity_url: str | None = None,
    embedding_provider: str | None = None,
    embedding_model: str | None = None,
    embedding_url: str | None = None,
    vector_dimensions: int | None = None,
    page_size: int | None = None,
    limit: int = 100_000,
) -> Mapping[str, Any]:
    extra_args = core_process_args(
        db_path=db_path,
        answer_provider=answer_provider,
        answer_model=answer_model,
        answer_url=answer_url,
        entity_provider=entity_provider,
        entity_model=entity_model,
        entity_url=entity_url,
        embedding_provider=embedding_provider,
        embedding_model=embedding_model,
        embedding_url=embedding_url,
        vector_dimensions=vector_dimensions,
        page_size=page_size,
    )
    completed = subprocess.run(
        [str(CORE_BINARY), *extra_args, "jobs", "run", "entity-resolve", "--limit", str(limit)],
        cwd=str(ROOT),
        check=False,
        env=core_command_env(skip_lattice_close=True),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"entity resolver job failed: {completed.stderr.strip()}") from exc
    if completed.returncode != 0 or payload.get("status") != "ok" or int(payload.get("failedCount") or 0) > 0:
        raise RuntimeError(f"entity resolver job failed: {json.dumps(payload, sort_keys=True)}")
    return payload


def verify_db(db_path: Path, scenario_id: str, *, extra_args: list[str] | None = None) -> Mapping[str, Any]:
    verify_args = extra_args if extra_args is not None else ["--db", str(db_path)]
    completed = subprocess.run(
        [str(CORE_BINARY), *verify_args, "verify", "all"],
        cwd=str(ROOT),
        check=False,
        env=core_command_env(skip_lattice_close=True),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        payload = {
            "status": "failed",
            "checks": ["all"],
            "issueCount": 1,
            "issues": [{"code": "verify_command_failed", "message": completed.stderr.strip()}],
        }
    return {
        "scenarioId": scenario_id,
        "exitCode": completed.returncode,
        **payload,
    }


def core_command_env(*, skip_lattice_close: bool = False) -> dict[str, str]:
    env = os.environ.copy()
    if skip_lattice_close:
        env["QUIPU_LATTICE_SKIP_CLOSE"] = "1"
    return env


def scenario_artifact_path(directory: Path, scenario_id: str) -> Path:
    safe_id = "".join(char if char.isalnum() or char in "-_" else "_" for char in scenario_id)
    return directory / f"{safe_id}.json"


def scenario_run_to_json(
    scenario_id: str,
    query_runs: list[CoreQueryRun],
    forget_runs: list[CoreForgetRun],
    verification: Mapping[str, Any] | None,
) -> dict[str, Any]:
    return {
        "scenarioId": scenario_id,
        "queries": [query_run_to_json(run) for run in query_runs],
        "forgetOps": [forget_run_to_json(run) for run in forget_runs],
        "verification": dict(verification) if verification is not None else None,
    }


def scenario_run_from_json(payload: Mapping[str, Any]) -> tuple[list[CoreQueryRun], list[CoreForgetRun], Mapping[str, Any] | None]:
    query_runs = [core_query_run_from_json(item) for item in payload.get("queries", []) if isinstance(item, Mapping)]
    forget_runs = [core_forget_run_from_json(item) for item in payload.get("forgetOps", []) if isinstance(item, Mapping)]
    verification = payload.get("verification")
    return query_runs, forget_runs, verification if isinstance(verification, Mapping) else None


def core_query_run_from_json(payload: Mapping[str, Any]) -> CoreQueryRun:
    return CoreQueryRun(
        scenario_id=str(payload.get("scenarioId") or ""),
        query_id=str(payload.get("queryId") or ""),
        category=str(payload.get("category") or ""),
        prompt="",
        actual_answer=str(payload.get("actualAnswer") or ""),
        evidence_event_ids=[str(item) for item in payload.get("evidenceEventIds", []) if isinstance(item, str)],
        grades=[grade_from_json(item) for item in payload.get("grades", []) if isinstance(item, Mapping)],
        trace=payload.get("trace") if isinstance(payload.get("trace"), Mapping) else None,
    )


def core_forget_run_from_json(payload: Mapping[str, Any]) -> CoreForgetRun:
    grade_payload = payload.get("grade")
    return CoreForgetRun(
        scenario_id=str(payload.get("scenarioId") or ""),
        forget_id=str(payload.get("forgetId") or ""),
        deleted_roots=int(payload.get("deletedRoots") or 0),
        invalidated_facts=int(payload.get("invalidatedFacts") or 0),
        grade=grade_from_json(grade_payload if isinstance(grade_payload, Mapping) else {}),
    )


def grade_from_json(payload: Mapping[str, Any]) -> GradeResult:
    details = payload.get("details")
    return GradeResult(
        name=str(payload.get("name") or "unknown"),
        passed=bool(payload.get("passed")),
        details=dict(details) if isinstance(details, Mapping) else {},
    )


def remember_event(client: CoreStdioClient, event: Event, *, extract: bool = True) -> Mapping[str, object]:
    return client.call(
        "memory.remember",
        {
            "scope": event.scope,
            "extract": extract,
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


def run_core_queries_and_forgets(
    client: CoreStdioClient,
    scenario: Scenario,
    event_to_message_qids: Mapping[str, list[str]],
    *,
    retrieval_needs: list[str] | None = None,
    log_retrieval: bool = True,
    retrieval_mode: str | None = None,
    answer_method: str = "retrieve",
) -> tuple[list[CoreQueryRun], list[CoreForgetRun]]:
    query_runs = [
        run_query(
            client,
            scenario.scenario_id,
            query,
            event_to_message_qids,
            retrieval_needs=retrieval_needs,
            log_retrieval=log_retrieval,
            retrieval_mode=retrieval_mode,
            answer_method=answer_method,
        )
        for query in scenario.queries
    ]

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
            params: dict[str, Any] = {"query": text, "scope": {}}
            if retrieval_mode is not None:
                params["mode"] = retrieval_mode
            retrieved = client.call("memory.retrieve", params)
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


def run_query(
    client: CoreStdioClient,
    scenario_id: str,
    query: Query,
    event_to_message_qids: Mapping[str, list[str]],
    *,
    retrieval_needs: list[str] | None = None,
    log_retrieval: bool = True,
    retrieval_mode: str | None = None,
    answer_method: str = "retrieve",
) -> CoreQueryRun:
    params = {
        "query": query.query,
        "scope": query.scope,
        "time": {"validAt": query.time},
        "options": {"includeEvidence": True, "includeDebug": True, "logTrace": log_retrieval, "logAudit": log_retrieval},
    }
    if retrieval_needs is not None:
        params["needs"] = retrieval_needs
    if retrieval_mode is not None:
        params["mode"] = retrieval_mode
    if answer_method == "answer":
        retrieved = client.call("memory.answer", params)
        context = retrieved.get("context")
        prompt = context_prompt(context)
        actual_answer = str(retrieved.get("answer") or "")
    else:
        retrieved = client.call("memory.retrieve", params)
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
        trace=retrieved.get("trace") if isinstance(retrieved.get("trace"), Mapping) else None,
    )


def context_prompt(context: object) -> str:
    if not isinstance(context, Mapping):
        return ""
    core = context.get("core")
    if not isinstance(core, Mapping):
        return ""
    items = core.get("items")
    if not isinstance(items, list):
        return ""
    lines = []
    for item in items:
        if not isinstance(item, Mapping):
            continue
        text = item.get("text")
        if isinstance(text, str):
            lines.append(text)
    return "\n".join(lines)


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


def ensure_core_binary(*, storage: str = "memory", lattice_include: str | None = None, lattice_lib: str | None = None) -> None:
    if not shutil.which("zig"):
        raise RuntimeError("zig is required to run core eval smoke")
    env = os.environ.copy()
    env["ZIG_GLOBAL_CACHE_DIR"] = "/tmp/quipu-zig-cache"
    command = ["zig", "build"]
    if storage == "lattice":
        command.append("-Denable-lattice=true")
        if lattice_include:
            command.append(f"-Dlattice-include={lattice_include}")
        if lattice_lib:
            command.append(f"-Dlattice-lib={lattice_lib}")
    subprocess.run(command, cwd=str(CORE_DIR), check=True, env=env)


def lattice_lib_from_env() -> str | None:
    if value := os.environ.get("LATTICE_LIB_DIR"):
        return value
    if value := os.environ.get("LATTICE_LIB_PATH"):
        return str(Path(value).parent)
    if value := os.environ.get("LATTICE_PREFIX"):
        return str(Path(value) / "lib")
    return None


def query_run_to_json(run: CoreQueryRun) -> dict[str, object]:
    return {
        "scenarioId": run.scenario_id,
        "queryId": run.query_id,
        "category": run.category,
        "passed": run.passed,
        "actualAnswer": run.actual_answer,
        "evidenceEventIds": run.evidence_event_ids,
        "grades": [asdict(grade) for grade in run.grades],
        "trace": dict(run.trace) if run.trace is not None else None,
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
    parser.add_argument("--storage", choices=["memory", "lattice"], default="memory")
    parser.add_argument("--db-dir", type=Path, help="Directory for per-scenario LatticeDB files")
    parser.add_argument("--lattice-include", default=os.environ.get("LATTICE_INCLUDE"))
    parser.add_argument("--lattice-lib", default=lattice_lib_from_env())
    parser.add_argument("--strict", action="store_true", help="Return non-zero when any scenario fails")
    parser.add_argument("--output", type=Path, help="Write the full run result JSON to this path")
    parser.add_argument("--manifest", type=Path, help="Write a compact eval run manifest to this path")
    parser.add_argument("--skip-verification", action="store_true", help="Skip per-scenario core DB verification")
    parser.add_argument("--no-retrieval-log", action="store_true", help="Do not write retrieval/audit stream entries during queries")
    parser.add_argument("--no-extract", action="store_true", help="Replay raw messages without synchronous extraction")
    parser.add_argument("--retrieval-mode", choices=["fts", "vector", "hybrid", "graph"], default=os.environ.get("QUIPU_CORE_RETRIEVAL_MODE"))
    parser.add_argument("--answer-method", choices=["retrieve", "answer"], default=os.environ.get("QUIPU_CORE_ANSWER_METHOD", "retrieve"))
    parser.add_argument("--answer-provider", choices=["deterministic", "openrouter"], default=os.environ.get("QUIPU_ANSWER_PROVIDER"))
    parser.add_argument("--answer-model", default=os.environ.get("QUIPU_ANSWER_MODEL") or os.environ.get("OPENROUTER_ANSWER_MODEL"))
    parser.add_argument("--answer-url", default=os.environ.get("QUIPU_ANSWER_URL") or os.environ.get("OPENROUTER_ANSWER_URL"))
    parser.add_argument("--entity-provider", choices=["deterministic", "openrouter"], default=os.environ.get("QUIPU_ENTITY_PROVIDER"))
    parser.add_argument("--entity-model", default=os.environ.get("QUIPU_ENTITY_MODEL") or os.environ.get("OPENROUTER_ENTITY_MODEL"))
    parser.add_argument("--entity-url", default=os.environ.get("QUIPU_ENTITY_URL") or os.environ.get("OPENROUTER_ENTITY_URL"))
    parser.add_argument("--embedding-provider", choices=["hash", "openrouter"], default=os.environ.get("QUIPU_EMBEDDING_PROVIDER"))
    parser.add_argument("--embedding-model", default=os.environ.get("QUIPU_EMBEDDING_MODEL") or os.environ.get("OPENROUTER_EMBEDDING_MODEL"))
    parser.add_argument("--embedding-url", default=os.environ.get("QUIPU_EMBEDDING_URL") or os.environ.get("OPENROUTER_EMBEDDING_URL"))
    parser.add_argument("--vector-dimensions", type=int, default=int(os.environ["QUIPU_VECTOR_DIMENSIONS"]) if os.environ.get("QUIPU_VECTOR_DIMENSIONS") else None)
    parser.add_argument("--page-size", type=int, default=int(os.environ["QUIPU_LATTICE_PAGE_SIZE"]) if os.environ.get("QUIPU_LATTICE_PAGE_SIZE") else None)
    args = parser.parse_args()
    if args.storage != "lattice" and args.entity_provider:
        parser.error("--entity-provider requires --storage lattice")

    if args.storage == "lattice":
        if args.db_dir is not None:
            args.db_dir.mkdir(parents=True, exist_ok=True)
            run = run_core_suite(
                args.suite,
                storage=args.storage,
                db_dir=args.db_dir,
                lattice_include=args.lattice_include,
                lattice_lib=args.lattice_lib,
                skip_verification=args.skip_verification,
                log_retrieval=not args.no_retrieval_log,
                extract=not args.no_extract,
                retrieval_mode=args.retrieval_mode,
                answer_method=args.answer_method,
                answer_provider=args.answer_provider,
                answer_model=args.answer_model,
                answer_url=args.answer_url,
                entity_provider=args.entity_provider,
                entity_model=args.entity_model,
                entity_url=args.entity_url,
                embedding_provider=args.embedding_provider,
                embedding_model=args.embedding_model,
                embedding_url=args.embedding_url,
                vector_dimensions=args.vector_dimensions,
                page_size=args.page_size,
            )
        else:
            with tempfile.TemporaryDirectory(prefix="quipu-lattice-eval-") as directory:
                run = run_core_suite(
                    args.suite,
                    storage=args.storage,
                    db_dir=Path(directory),
                    lattice_include=args.lattice_include,
                    lattice_lib=args.lattice_lib,
                    skip_verification=args.skip_verification,
                    log_retrieval=not args.no_retrieval_log,
                    extract=not args.no_extract,
                    retrieval_mode=args.retrieval_mode,
                    answer_method=args.answer_method,
                    answer_provider=args.answer_provider,
                    answer_model=args.answer_model,
                    answer_url=args.answer_url,
                    entity_provider=args.entity_provider,
                    entity_model=args.entity_model,
                    entity_url=args.entity_url,
                    embedding_provider=args.embedding_provider,
                    embedding_model=args.embedding_model,
                    embedding_url=args.embedding_url,
                    vector_dimensions=args.vector_dimensions,
                    page_size=args.page_size,
                )
    else:
        run = run_core_suite(
            args.suite,
            retrieval_mode=args.retrieval_mode,
            answer_method=args.answer_method,
            answer_provider=args.answer_provider,
            answer_model=args.answer_model,
            answer_url=args.answer_url,
            entity_provider=args.entity_provider,
            entity_model=args.entity_model,
            entity_url=args.entity_url,
            embedding_provider=args.embedding_provider,
            embedding_model=args.embedding_model,
            embedding_url=args.embedding_url,
            vector_dimensions=args.vector_dimensions,
            page_size=args.page_size,
        )
    run_json = run.to_json()
    run_config = {
        "retrievalMode": args.retrieval_mode,
        "answerMethod": args.answer_method,
        "answerProvider": args.answer_provider,
        "answerModel": args.answer_model,
        "entityProvider": args.entity_provider,
        "entityModel": args.entity_model,
        "embeddingProvider": args.embedding_provider,
        "embeddingModel": args.embedding_model,
        "vectorDimensions": args.vector_dimensions,
        "pageSize": args.page_size,
    }
    providers = {
        "extractor": "deterministic_fixture",
        "embedder": provider_label(args.embedding_provider, args.embedding_model, default="deterministic_fixture"),
        "reranker": "none",
        "answer": provider_label(args.answer_provider, args.answer_model, default="deterministic_prompt_match"),
        "judge": "rule_based",
        "entityResolver": provider_label(args.entity_provider, args.entity_model, default="none"),
    }
    if args.output:
        write_json(args.output, run_json)
    if args.manifest:
        write_json(
            args.manifest,
            build_manifest(
                run_json,
                suite_path=args.suite,
                runner="quipu_evals.core_runner",
                storage=args.storage,
                results_path=args.output,
                config=run_config,
                providers=providers,
            ),
        )
    print(json.dumps(run_json, indent=2, sort_keys=True))
    return 0 if run.passed or not args.strict else 1


def provider_label(provider: str | None, model: str | None, *, default: str) -> str:
    if not provider:
        return default
    if model:
        return f"{provider}:{model}"
    return provider


if __name__ == "__main__":
    raise SystemExit(main())
