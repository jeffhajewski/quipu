"""Audit stored evidence coverage, paired answers, and observed provider usage."""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
from math import comb
from pathlib import Path

from .longmemeval_study import aggregate, extraction_key, grounded_extraction, paired, mean
from .representation_experiment import validate_assertions, write_json
from .scenarios import load_suite


def audit_extractions(suite, cache):
    cases = []
    for scenario in suite.scenarios:
        available = set()
        emitted, rejected, repaired, failed = 0, 0, 0, 0
        raw_claims = 0
        for event in scenario.events:
            key, _ = extraction_key(event)
            path = cache / "extractions" / f"{key}.json"
            if not path.exists():
                failed += 1
                continue
            original = json.loads(path.read_text())
            record = grounded_extraction(event, original)
            claims = validate_assertions(event, record)
            raw_claims += len(original["assertions"]) + len(original["invalid"])
            emitted += len(claims)
            rejected += len(record["rejected"])
            repaired += record["repairedCitationIndices"]
            available.update((p.event_id, p.message_index) for p in claims)
        gold = {tuple(turn) for turn in scenario.metadata["goldTurns"]}
        query = scenario.queries[0]
        cases.append({"queryId": query.query_id, "category": query.category,
                      "emitted": emitted, "quarantined": rejected, "repaired": repaired,
                      "rawClaims": raw_claims, "failedEpisodes": failed,
                      "storedGoldTurnCoverage": len(available & gold) / len(gold) if gold and not query.should_abstain else None,
                      "missingGoldTurns": sorted(gold - available)})
    return {"cases": cases, "meanStoredGoldTurnCoverage": mean([c["storedGoldTurnCoverage"] for c in cases]),
            "emitted": sum(c["emitted"] for c in cases),
            "quarantined": sum(c["quarantined"] for c in cases),
            "repaired": sum(c["repaired"] for c in cases),
            "rawClaims": sum(c["rawClaims"] for c in cases),
            "failedEpisodes": sum(c["failedEpisodes"] for c in cases)}


def cache_usage(cache):
    by_model = defaultdict(lambda: {"requests": 0, "promptTokens": 0, "completionTokens": 0,
                                    "observedCostUsd": 0, "missingCostRequests": 0})
    for path in cache.glob("*.json"):
        response = json.loads(path.read_text())["response"]
        usage = response.get("usage") or {}
        group = by_model[response.get("model", "embedding_or_unspecified")]
        group["requests"] += 1
        group["promptTokens"] += usage.get("prompt_tokens", 0)
        group["completionTokens"] += usage.get("completion_tokens", 0)
        cost = usage.get("cost")
        if isinstance(cost, (int, float)):
            group["observedCostUsd"] += cost
        else:
            group["missingCostRequests"] += 1
    return dict(by_model)


def merged_reports(paths):
    rows = {}
    reports = [json.loads(path.read_text()) for path in paths]
    identity_fields = ("suiteHash", "graderHash", "readerPrompt", "representationCodeHash", "models", "tokenizer", "plannedQuestions")
    for report in reports:
        if report.get("errors"):
            raise ValueError(f"cannot use incomplete report: {report['errors']}")
        if any(field not in report or report[field] != reports[0].get(field) for field in identity_fields):
            raise ValueError("cannot merge different or missing study identities")
        expected = {(arm, budget) for arm in report["config"]["arms"] for budget in report["config"]["budgets"]}
        observed = defaultdict(set)
        for row in report["rows"]:
            key = (row["queryId"], row["arm"], row["budget"])
            if key in rows:
                raise ValueError(f"duplicate observation {key}")
            rows[key] = row
            observed[(row["arm"], row["budget"])].add(row["queryId"])
        if set(observed) != expected or any(len(ids) != report["plannedQuestions"] for ids in observed.values()):
            raise ValueError("incomplete treatment cells")
        if any(ids != next(iter(observed.values())) for ids in observed.values()):
            raise ValueError("treatments do not contain the same questions")
    return list(rows.values())


def paired_with_exact_test(rows):
    results = paired(rows)
    for result in results:
        discordant = result["wins"] + result["losses"]
        tail = min(result["wins"], result["losses"])
        result["exactMcNemarPUnadjusted"] = min(1.0, 2 * sum(comb(discordant, k) for k in range(tail + 1)) / 2 ** discordant)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--reports", type=Path, nargs="+", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    suite = load_suite(args.suite)
    rows = merged_reports(args.reports)
    by_query = defaultdict(dict)
    for row in rows:
        by_query[(row["queryId"], row["budget"])][row["arm"]] = row
    disagreements = []
    for (query_id, budget), treatments in sorted(by_query.items()):
        if "raw" not in treatments:
            continue
        raw = treatments["raw"]
        for arm, row in treatments.items():
            if row["judgment"]["correct"] == raw["judgment"]["correct"]:
                continue
            disagreements.append({"queryId": query_id, "budget": budget, "arm": arm,
                                  "question": row["question"], "reference": row["reference"],
                                  "rawAnswer": raw["reader"]["answer"], "armAnswer": row["reader"]["answer"],
                                  "armCorrect": row["judgment"]["correct"],
                                  "rawGoldTurnRecall": raw["goldTurnRecall"], "armGoldTurnRecall": row["goldTurnRecall"]})
    report = {"summary": aggregate(rows), "paired": paired_with_exact_test(rows),
              "byCategory": {category: aggregate([row for row in rows if row["category"] == category])
                             for category in sorted({row["category"] for row in rows})},
              "extractionAudit": audit_extractions(suite, args.cache),
              "observedCacheUsage": cache_usage(args.cache), "disagreements": disagreements,
              "reports": [str(path) for path in args.reports]}
    write_json(args.output, report)
    print(json.dumps({key: value for key, value in report.items() if key not in ("byCategory", "disagreements", "extractionAudit")}, indent=2))


if __name__ == "__main__":
    main()
