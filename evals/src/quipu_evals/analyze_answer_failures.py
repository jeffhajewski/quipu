from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
from typing import Any, Mapping

from .artifacts import write_json
from .scenarios import Query, load_suite


BUCKETS = {
    "retrieval_miss",
    "provider_error",
    "synthesis_with_evidence",
    "abstention_miss",
    "preference_miss",
    "wrong_temporal_choice",
    "wrong_aggregation",
    "verbose_format_mismatch",
    "unsupported_answer",
    "numeric_date_mismatch",
}


def analyze(input_path: str | Path, *, suite_path: str | Path | None = None) -> dict[str, Any]:
    path = Path(input_path)
    payloads, inferred_suite = load_result_payloads(path)
    suite = load_query_index(Path(suite_path or inferred_suite)) if suite_path or inferred_suite else {}

    rows: list[dict[str, Any]] = []
    for run_name, payload in payloads:
        for query in payload.get("queries", []):
            if not isinstance(query, Mapping) or query.get("passed") is True:
                continue
            grades = [grade for grade in query.get("grades", []) if isinstance(grade, Mapping)]
            query_id = str(query.get("queryId") or "")
            expected = exact_grade_value(grades, "expected")
            actual = str(query.get("actualAnswer") or exact_grade_value(grades, "actual"))
            suite_query = suite.get(query_id)
            category = str(query.get("category") or (suite_query.category if suite_query else ""))
            expected_evidence = suite_query.expected_evidence_event_ids if suite_query else expected_evidence_from_grade(grades)
            evidence_ids = [str(item) for item in query.get("evidenceEventIds", []) if isinstance(item, str)]
            trace = query.get("trace") if isinstance(query.get("trace"), Mapping) else {}
            answer_trace = query.get("answerTrace") if isinstance(query.get("answerTrace"), Mapping) else {}
            row = {
                "run": run_name,
                "scenarioId": str(query.get("scenarioId") or ""),
                "queryId": query_id,
                "category": category,
                "query": suite_query.query if suite_query else "",
                "expected": expected,
                "actual": actual,
                "bucket": bucket_failure(
                    category=category,
                    expected=expected,
                    actual=actual,
                    grades=grades,
                    expected_evidence=expected_evidence,
                    evidence_ids=evidence_ids,
                    answer_trace=answer_trace,
                ),
                "evidenceEventIds": evidence_ids,
                "expectedEvidenceEventIds": expected_evidence,
                "topItemTexts": [str(item) for item in query.get("topItemTexts", []) if isinstance(item, str)],
                "traceCounts": trace_counts(trace),
                "answerTrace": compact_answer_trace(answer_trace),
                "failedGrades": [str(grade.get("name") or "unknown") for grade in grades if not grade.get("passed")],
            }
            rows.append(row)

    counts = Counter(row["bucket"] for row in rows)
    return {
        "schemaVersion": "quipu.answer_failure_report.v1",
        "input": str(path),
        "suite": str(suite_path or inferred_suite or ""),
        "failureCount": len(rows),
        "buckets": {bucket: counts.get(bucket, 0) for bucket in sorted(BUCKETS)},
        "rows": rows,
    }


def load_result_payloads(path: Path) -> tuple[list[tuple[str, Mapping[str, Any]]], str | None]:
    if path.is_dir():
        report = path / "report.json"
        if report.exists():
            return payloads_from_report(json.loads(report.read_text()), path)
        payloads = []
        for result_path in sorted(path.glob("*-results.json")):
            payloads.append((result_path.stem.removesuffix("-results"), json.loads(result_path.read_text())))
        return payloads, None

    payload = json.loads(path.read_text())
    if isinstance(payload, Mapping) and "runs" in payload:
        return payloads_from_report(payload, path.parent)
    return [(path.stem.removesuffix("-results"), payload)], None


def payloads_from_report(report: Mapping[str, Any], base_dir: Path) -> tuple[list[tuple[str, Mapping[str, Any]]], str | None]:
    payloads = []
    for run in report.get("runs", []):
        if not isinstance(run, Mapping):
            continue
        artifacts = run.get("artifacts")
        if not isinstance(artifacts, Mapping):
            continue
        result_ref = artifacts.get("results")
        if not isinstance(result_ref, str):
            continue
        result_path = resolve_path(result_ref, base_dir)
        if result_path.exists():
            payloads.append((str(run.get("name") or run.get("baseline") or result_path.stem), json.loads(result_path.read_text())))
    suite_ref = report.get("suite")
    suite = str(suite_ref) if isinstance(suite_ref, str) else None
    return payloads, suite


def resolve_path(value: str, base_dir: Path) -> Path:
    path = Path(value)
    if path.is_absolute() or path.exists():
        return path
    root_path = Path(__file__).resolve().parents[3] / path
    if root_path.exists():
        return root_path
    return base_dir / path.name


def load_query_index(path: Path) -> dict[str, Query]:
    suite = load_suite(path)
    return {query.query_id: query for scenario in suite.scenarios for query in scenario.queries}


def bucket_failure(
    *,
    category: str,
    expected: str,
    actual: str,
    grades: list[Mapping[str, Any]],
    expected_evidence: list[str],
    evidence_ids: list[str],
    answer_trace: Mapping[str, Any],
) -> str:
    failed_grade_names = {str(grade.get("name") or "") for grade in grades if not grade.get("passed")}
    if "runtime_error" in failed_grade_names or any("provider" in str(grade.get("details", {})).lower() for grade in grades):
        return "provider_error"
    if missing_evidence(expected_evidence, evidence_ids):
        return "retrieval_miss"
    if expected == "[abstain]" and actual != "[abstain]":
        return "abstention_miss"
    if category == "single-session-preference":
        return "preference_miss"
    if category == "temporal-reasoning":
        return "wrong_temporal_choice"
    if category == "multi-session":
        return "wrong_aggregation"
    if numeric_or_date(expected) and numeric_or_date(actual):
        return "numeric_date_mismatch"
    validation = answer_trace.get("validation") if isinstance(answer_trace, Mapping) else None
    if isinstance(validation, Mapping) and validation.get("status") in {"fallback", "invalid_support", "parse_error"}:
        return "synthesis_with_evidence"
    if expected and expected.lower() in actual.lower():
        return "verbose_format_mismatch"
    if actual in {"", "I don't know.", "I don't know", "[abstain]"}:
        return "unsupported_answer"
    return "synthesis_with_evidence"


def missing_evidence(expected: list[str], actual: list[str]) -> bool:
    return bool(set(expected) - set(actual))


def exact_grade_value(grades: list[Mapping[str, Any]], key: str) -> str:
    for grade in grades:
        if grade.get("name") != "exact_answer":
            continue
        details = grade.get("details")
        if isinstance(details, Mapping):
            value = details.get(key)
            if isinstance(value, str):
                return value
    return ""


def expected_evidence_from_grade(grades: list[Mapping[str, Any]]) -> list[str]:
    for grade in grades:
        if grade.get("name") != "evidence_ids":
            continue
        details = grade.get("details")
        if isinstance(details, Mapping):
            expected = details.get("expected")
            if isinstance(expected, list):
                return [str(item) for item in expected if isinstance(item, str)]
    return []


def trace_counts(trace: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "candidateCount": int(trace.get("candidateCount") or 0),
        "keptCount": int(trace.get("keptCount") or 0),
        "droppedForNeeds": int(trace.get("droppedForNeeds") or 0),
        "droppedForBudget": int(trace.get("droppedForBudget") or 0),
        "candidateSources": dict(trace.get("candidateSources") or {}) if isinstance(trace.get("candidateSources"), Mapping) else {},
    }


def compact_answer_trace(trace: Mapping[str, Any]) -> dict[str, Any]:
    if not trace:
        return {}
    validation = trace.get("validation")
    evidence_gate = trace.get("evidenceGate") if isinstance(trace.get("evidenceGate"), Mapping) else {}
    return {
        "strategy": trace.get("strategy"),
        "answerable": trace.get("answerable"),
        "supportQids": trace.get("supportQids", []),
        "candidateCount": len(trace.get("candidateAnswers", [])) if isinstance(trace.get("candidateAnswers"), list) else 0,
        "validationStatus": validation.get("status") if isinstance(validation, Mapping) else None,
        "validationWarnings": validation.get("warnings", []) if isinstance(validation, Mapping) else [],
        "evidenceGate": {
            "querySlots": evidence_gate.get("querySlots", []) if isinstance(evidence_gate, Mapping) else [],
            "warnings": evidence_gate.get("warnings", []) if isinstance(evidence_gate, Mapping) else [],
            "keptCount": len(evidence_gate.get("keptQids", [])) if isinstance(evidence_gate.get("keptQids"), list) else 0,
            "rejectedCount": len(evidence_gate.get("rejectedQids", [])) if isinstance(evidence_gate.get("rejectedQids"), list) else 0,
        },
    }


def numeric_or_date(value: str) -> bool:
    return bool(re.search(r"\d", value))


def render_markdown(report: Mapping[str, Any]) -> str:
    lines = [
        "# Answer Failure Report",
        "",
        f"- Input: `{report.get('input')}`",
        f"- Suite: `{report.get('suite') or '-'}`",
        f"- Failures: `{report.get('failureCount', 0)}`",
        "",
        "## Buckets",
        "",
        "| Bucket | Count |",
        "| --- | ---: |",
    ]
    for bucket, count in report.get("buckets", {}).items():
        lines.append(f"| `{bucket}` | {count} |")
    lines.extend(["", "## Failed Queries", "", "| Run | Query | Category | Bucket | Expected | Actual | Evidence |", "| --- | --- | --- | --- | --- | --- | --- |"])
    for row in report.get("rows", []):
        if not isinstance(row, Mapping):
            continue
        evidence = ",".join(row.get("evidenceEventIds", []))
        lines.append(
            "| `{run}` | `{query_id}` | `{category}` | `{bucket}` | {expected} | {actual} | `{evidence}` |".format(
                run=row.get("run", ""),
                query_id=row.get("queryId", ""),
                category=row.get("category", ""),
                bucket=row.get("bucket", ""),
                expected=escape_cell(str(row.get("expected", ""))),
                actual=escape_cell(str(row.get("actual", ""))),
                evidence=evidence,
            )
        )
    return "\n".join(lines) + "\n"


def escape_cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", help="Benchmark output directory, report JSON, or run result JSON")
    parser.add_argument("--suite", type=Path, help="Suite file used to recover query text")
    parser.add_argument("--json-output", type=Path, help="Write JSON report")
    parser.add_argument("--markdown-output", type=Path, help="Write Markdown report")
    args = parser.parse_args()

    report = analyze(args.input, suite_path=args.suite)
    if args.json_output:
        write_json(args.json_output, report)
    if args.markdown_output:
        args.markdown_output.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_output.write_text(render_markdown(report))
    if not args.json_output and not args.markdown_output:
        print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
