from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "evals" / "src"))

from quipu_evals.rerank_server import RerankServer, RerankService, ScoreCache  # noqa: E402
from quipu_evals.sota_longmemeval import (  # noqa: E402
    answer_valid_at, build_case, coverage, daemon_command, item_turns, linked_message_qids, paired_comparison, parse_answer_options,
    percentile, reader_context, render_context, rerank_summary, reranker_health, select_dev, summarize_rows,
)


def item(question_id, question_type="single-session-user"):
    return {"question_id": question_id, "question_type": question_type}


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.items = [item(f"u{i}") for i in range(6)] + [item(f"u{i}_abs") for i in range(6)]
        self.categories = ("abstention", "single-session-user")

    def test_excluded_questions_block_their_families(self):
        chosen = select_dev(self.items, ["u0", "u1_abs"], seed="s", per_category=2, categories=self.categories)
        families = [entry["id"].removesuffix("_abs") for entry in chosen]
        self.assertNotIn("u0", families)
        self.assertNotIn("u1", families)
        self.assertEqual(len(families), len(set(families)), "one question per family")
        self.assertEqual(sum(entry["category"] == "abstention" for entry in chosen), 2)

    def test_selection_is_deterministic_and_seed_dependent(self):
        first = select_dev(self.items, [], seed="a", per_category=2, categories=self.categories)
        self.assertEqual(first, select_dev(list(reversed(self.items)), [], seed="a", per_category=2,
                                           categories=self.categories))
        seeds = {json.dumps(select_dev(self.items, [], seed=s, per_category=2, categories=self.categories))
                 for s in "abcdefgh"}
        self.assertGreater(len(seeds), 1)

    def test_insufficient_candidates_raise(self):
        with self.assertRaises(ValueError):
            select_dev(self.items, [f"u{i}" for i in range(5)], seed="s", per_category=2, categories=self.categories)

    def test_frozen_dev_selection_is_balanced_and_disjoint_from_e1(self):
        payload = json.loads((ROOT / "evals/experiments/sota-dev-selection.json").read_text())
        ids = payload["questionIds"]
        self.assertEqual(len(ids), 70)
        self.assertEqual(len({value.removesuffix("_abs") for value in ids}), 70)
        self.assertEqual(sum(value.endswith("_abs") for value in ids), 10)
        self.assertEqual(payload["seed"], "quipu-sota-dev-20261001")
        e1 = json.loads((ROOT / "evals/experiments/e1-directional-results.json").read_text())
        e1_ids = {value for value in json.dumps(e1).split('"') if value in set(ids)}
        self.assertEqual(e1_ids, set(), "dev slice must not reuse E1 questions")


class CaseTests(unittest.TestCase):
    def setUp(self):
        self.item = {
            "question_id": "q1", "question_type": "multi-session", "question": "Where?", "answer": "Paris",
            "question_date": "2023/05/30 (Tue) 23:40",
            "haystack_session_ids": ["answer_late", "noise", "answer_early"],
            "haystack_dates": ["2023/05/20 (Sat) 10:00", "2023/05/01 (Mon) 09:00", "2023/05/10 (Wed) 08:00"],
            "answer_session_ids": ["answer_late", "answer_early"],
            "haystack_sessions": [
                [{"role": "user", "content": "  ", "has_answer": False},
                 {"role": "user", "content": "I moved to Paris.", "has_answer": True}],
                [{"role": "user", "content": "Hello"}, {"role": "assistant", "content": "Hi"}],
                [{"role": "user", "content": "I lived in Rome.", "has_answer": True}],
            ],
        }

    def test_sessions_are_date_ordered_and_anonymized(self):
        case = build_case(self.item)
        self.assertEqual([s["sessionId"] for s in case["sessions"]], ["s01", "s02", "s03"])
        self.assertEqual([s["time"] for s in case["sessions"]],
                         ["2023-05-01T09:00:00Z", "2023-05-10T08:00:00Z", "2023-05-20T10:00:00Z"])
        self.assertNotIn("answer", json.dumps(case["sessions"]))
        self.assertEqual(case["evidenceSessions"], ["s02", "s03"])
        self.assertEqual(case["questionTime"], "2023-05-30T23:40:00Z")
        self.assertTrue(all(m["createdAt"] == case["sessions"][2]["time"] for m in case["sessions"][2]["messages"]))

    def test_empty_turns_are_dropped_and_gold_indices_follow_filtered_messages(self):
        case = build_case(self.item)
        self.assertEqual(case["sessions"][2]["messages"][0]["content"], "I moved to Paris.")
        self.assertEqual(sorted(map(tuple, case["goldTurns"])), [("s02", 0), ("s03", 0)])


class MappingTests(unittest.TestCase):
    def setUp(self):
        self.qid_to_turn = {"q_msg_1": ("s01", 0), "q_msg_2": ("s01", 1), "q_msg_3": ("s02", 0)}
        self.case = {"goldTurns": [["s01", 1], ["s02", 0]], "evidenceSessions": ["s01", "s02"], "abstention": False}

    def test_message_items_map_directly(self):
        turns = item_turns([{"qid": "q_msg_2", "type": "message", "evidence": []}], self.qid_to_turn)
        self.assertEqual(turns, {("s01", 1)})

    def test_chunk_items_map_through_evidence_to_parent_message(self):
        chunk = {"qid": "q_chunk_9", "type": "message", "evidence": [{"qid": "q_msg_3", "quote": "..."}]}
        self.assertEqual(linked_message_qids(chunk), ["q_chunk_9", "q_msg_3"])
        self.assertEqual(item_turns([chunk], self.qid_to_turn), {("s02", 0)})

    def test_derived_items_count_only_when_not_raw_only(self):
        fact = {"qid": "q_fact_1", "type": "fact", "evidence": [{"qid": "q_msg_2"}]}
        self.assertEqual(item_turns([fact], self.qid_to_turn), {("s01", 1)})
        self.assertEqual(item_turns([fact], self.qid_to_turn, raw_only=True), set())

    def test_coverage_and_abstention(self):
        turns = item_turns([{"qid": "q_msg_2", "type": "message"}, {"qid": "q_msg_1", "type": "message"}], self.qid_to_turn)
        result = coverage(self.case, turns)
        self.assertEqual(result["goldTurnCoverage"], 0.5)
        self.assertEqual(result["goldSessionCoverage"], 0.5)
        self.assertFalse(result["allGoldTurns"])
        self.assertEqual(result["missingGoldTurns"], [("s02", 0)])
        self.assertIsNone(coverage({**self.case, "abstention": True}, turns)["goldTurnCoverage"])

    def test_context_render_matches_daemon_prompt_format(self):
        context = {"core": [], "currentFacts": [{"qid": "q_f", "text": "Lives in Paris"}],
                   "preferences": [], "procedural": [], "episodes": [{"qid": "q_msg_1", "text": "hello"}],
                   "warnings": []}
        self.assertEqual(render_context(context),
                         "<memory>\n<facts>\n- (q_f) Lives in Paris\n</facts>\n<episodes>\n- (q_msg_1) hello\n</episodes>\n</memory>")
        self.assertEqual(reader_context({"context": context})[1], "context_render")
        self.assertEqual(reader_context({"prompt": "exact", "context": context}), ("exact", "prompt"))


class StatisticsTests(unittest.TestCase):
    def test_paired_comparison_excludes_errors_and_counts_wins(self):
        a = [{"questionId": q, "category": "c", "budget": 1024, "status": "ok", "correct": c}
             for q, c in (("x", False), ("y", True), ("z", True))]
        b = [{"questionId": "x", "category": "c", "budget": 1024, "status": "ok", "correct": True},
             {"questionId": "y", "category": "c", "budget": 1024, "status": "ok", "correct": True},
             {"questionId": "z", "category": "c", "budget": 1024, "status": "error", "correct": None}]
        result = paired_comparison(a, b, repeats=50)[0]
        self.assertEqual((result["n"], result["wins"], result["losses"], result["excludedForErrors"]), (2, 1, 0, 1))
        self.assertEqual(result["winQuestions"], ["x"])
        self.assertEqual(result["exactMcNemarPUnadjusted"], 1.0)

    def test_percentile_is_nearest_rank(self):
        self.assertEqual(percentile([1, 2, 3, 4], 0.5), 2)
        self.assertEqual(percentile(range(1, 101), 0.95), 95)
        self.assertIsNone(percentile([], 0.5))


class ValidAtTests(unittest.TestCase):
    def test_end_of_day_keeps_the_date_and_admits_later_same_day_evidence(self):
        self.assertEqual(answer_valid_at("2023-05-30T07:03:00Z"), "2023-05-30T23:59:59Z")
        self.assertEqual(answer_valid_at("2023-05-30T07:03:00Z", "question"), "2023-05-30T07:03:00Z")
        with self.assertRaises(ValueError):
            answer_valid_at("2023-05-30T07:03:00Z", "none")


class AnswerOptionTests(unittest.TestCase):
    def test_values_parse_as_json_with_string_fallback(self):
        self.assertEqual(
            parse_answer_options(["rerank=false", "topK=40", "label=plain"]),
            {"rerank": False, "topK": 40, "label": "plain"},
        )
        self.assertEqual(parse_answer_options(None), {})

    def test_rejects_pairs_without_equals(self):
        with self.assertRaises(SystemExit):
            parse_answer_options(["rerank"])


class RerankerTests(unittest.TestCase):
    CONFIG = {"daemonBinary": "/bin/quipu", "readerModel": "reader", "embeddingModel": "embed",
              "daemonArgs": ["--page-size", "8192"]}

    def test_daemon_gets_reranker_flags_only_when_configured(self):
        plain = daemon_command(self.CONFIG, answer_url="http://proxy/chat", embedding_url=None, db_path=None)
        self.assertNotIn("--reranker-url", plain)
        command = daemon_command({**self.CONFIG, "rerankerUrl": "http://127.0.0.1:7341/v1/rerank",
                                  "rerankerModel": "BAAI/bge-reranker-v2-m3"},
                                 answer_url="http://proxy/chat", embedding_url=None, db_path=None)
        self.assertEqual(command[-7:], ["--reranker-url", "http://127.0.0.1:7341/v1/rerank",
                                        "--reranker-model", "BAAI/bge-reranker-v2-m3",
                                        "--page-size", "8192", "serve-stdio"])

    def test_rows_summarize_rerank_outcomes(self):
        trace = {"rerank": {"model": "m", "status": "applied", "windowSize": 50, "rerankedCount": 50,
                            "latencyMs": 812.5, "topScores": [{"qid": "q_msg_1", "score": 0.97}], "error": None}}
        summary = rerank_summary(trace)
        self.assertEqual(summary["topScore"], 0.97)
        self.assertNotIn("topScores", summary)
        self.assertIsNone(rerank_summary({"query": "q"}))
        rows = [{"status": "ok", "correct": True, "rerank": summary},
                {"status": "ok", "correct": False, "rerank": {**summary, "status": "failed", "latencyMs": 30000}}]
        stats = summarize_rows(rows)
        self.assertEqual(stats["rerankStatuses"], {"applied": 1, "failed": 1})
        self.assertEqual(stats["rerankLatencyMsP50"], 812.5)
        self.assertNotIn("rerankStatuses", summarize_rows([{"status": "ok", "correct": True}]))

    def test_reranker_health_reads_the_rerank_server(self):
        service = RerankService("fake-model", lambda pairs: [0.0] * len(pairs), ScoreCache(None), max_length=256)
        with RerankServer(service) as server:
            info = reranker_health(server.url)
        self.assertEqual((info["model"], info["maxLength"]), ("fake-model", 256))
        self.assertIsNone(reranker_health(None))


class ExtractionTests(unittest.TestCase):
    CONFIG = {"daemonBinary": "/bin/quipu", "readerModel": "reader", "embeddingModel": "embed"}
    RESULT = {"leasedCount": 2, "succeededCount": 2, "failedCount": 0, "calls": 3, "jsonRetries": 1,
              "assertionsWritten": 9, "recallMessages": 4, "recallAssertions": 2, "counts": {"candidates": 12, "accepted": 9, "repaired": 2, "quarantined": 3,
                                                 "eventDates": 4}}

    class Proxy:
        def __init__(self, records):
            self.state = self
            self.records = records

        def mark(self):
            return 0

        def records_for(self, tag, mark):
            return [record for record in self.records if record["tag"] == tag]

    class Daemon:
        def __init__(self, result):
            self.result = result
            self.calls = []

        def call(self, method, params, timeout):
            self.calls.append((method, params, timeout))
            if isinstance(self.result, Exception):
                raise self.result
            return self.result

    class FlakyDaemon:
        """Fails some jobs on the first call and finishes them on the second."""

        def __init__(self):
            self.calls = []

        def call(self, method, params, timeout):
            self.calls.append(method)
            if len(self.calls) == 1:
                return {"leasedCount": 5, "succeededCount": 3, "failedCount": 2, "calls": 7,
                        "updatesWritten": 1, "counts": {"proposed": 4, "accepted": 1}, "lastError": "ConnectionReset"}
            return {"leasedCount": 2, "succeededCount": 2, "failedCount": 0, "calls": 3,
                    "updatesWritten": 2, "counts": {"proposed": 3, "accepted": 2}, "lastError": None}

    def test_failed_jobs_are_run_again_and_the_passes_add_up(self):
        from quipu_evals.sota_longmemeval import run_consolidation
        config = {"llmExtract": {"model": "m", "concurrency": 4, "timeout": 60}}
        daemon = self.FlakyDaemon()
        consolidation = run_consolidation(daemon, config, self.Proxy([]), "q1")
        self.assertEqual(daemon.calls, ["memory.consolidate.run", "memory.consolidate.run"])
        self.assertEqual(consolidation["passes"], 2)
        self.assertEqual(consolidation["result"], {
            "leasedCount": 5, "succeededCount": 5, "failedCount": 0, "calls": 10, "updatesWritten": 3,
            "counts": {"proposed": 7, "accepted": 3}, "lastError": None})

    def test_daemon_gets_extract_flags_only_with_extract(self):
        plain = daemon_command(self.CONFIG, answer_url="http://proxy/chat", embedding_url=None, db_path=None,
                               extract_url="http://proxy/chat")
        self.assertNotIn("--extract-provider", plain)
        command = daemon_command({**self.CONFIG, "llmExtract": {"model": "openai/gpt-4o-mini-2024-07-18"}},
                                 answer_url="http://proxy/chat", embedding_url=None, db_path=None,
                                 extract_url="http://proxy/q/x/v1/chat/completions")
        self.assertEqual(command[-7:], ["--extract-provider", "openrouter", "--extract-url",
                                        "http://proxy/q/x/v1/chat/completions", "--extract-model",
                                        "openai/gpt-4o-mini-2024-07-18", "serve-stdio"])

    def test_extraction_records_calls_cost_and_counts(self):
        from quipu_evals.sota_longmemeval import extraction_row, run_extraction, summarize_extraction
        records = [{"tag": "q1", "endpoint": "chat/completions", "status": 200, "costUsd": 0.01,
                    "nominalCostUsd": 0.02, "promptTokens": 100, "completionTokens": 50},
                   {"tag": "q1", "endpoint": "embeddings", "status": 200, "costUsd": 0.001, "nominalCostUsd": 0.001},
                   {"tag": "q2", "endpoint": "chat/completions", "status": 200, "costUsd": 5.0, "nominalCostUsd": 5.0}]
        config = {"llmExtract": {"model": "m", "concurrency": 4, "timeout": 60}}
        daemon = self.Daemon(self.RESULT)
        extraction = run_extraction(daemon, config, self.Proxy(records), "q1")
        self.assertEqual(daemon.calls, [("memory.extract.run", {"owner": "sota-harness", "concurrency": 4}, 60)])
        self.assertNotIn("error", extraction)
        self.assertEqual((extraction["calls"]["chatCalls"], extraction["calls"]["embeddingCalls"]), (1, 1))
        row = extraction_row(extraction)
        self.assertEqual((row["chatCalls"], row["accepted"], row["quarantined"]), (1, 9, 3))
        self.assertAlmostEqual(row["costUsd"], 0.011)

        from quipu_evals.sota_longmemeval import DaemonError
        failed = run_extraction(self.Daemon(DaemonError("memory.extract.run timed out")), config, self.Proxy([]), "q1")
        self.assertIn("timed out", failed["error"])
        self.assertIsNone(extraction_row(failed))

        summary = summarize_extraction([{"extraction": extraction}, {"extraction": failed}, {"extraction": None}])
        self.assertEqual((summary["questions"], summary["errors"], summary["failedJobs"]), (2, 1, 0))
        self.assertEqual(summary["counts"]["accepted"], 9)
        self.assertAlmostEqual(summary["acceptedRate"], 0.75)
        self.assertAlmostEqual(summary["quarantinedRate"], 0.25)
        self.assertEqual(summary["jsonRetries"], 1)
        self.assertEqual((summary["recallMessages"], summary["recallAssertions"]), (4, 2))
        self.assertIsNone(summarize_extraction([{"questionId": "q"}]))


if __name__ == "__main__":
    unittest.main()
