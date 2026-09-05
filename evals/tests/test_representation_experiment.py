from __future__ import annotations

from dataclasses import replace
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "evals" / "src"))

from quipu_evals.representation_experiment import (  # noqa: E402
    FrozenClient, answer, eligible, evidence_metrics, judge, pack, rank, raw_passages,
    run, source_episode, summarize, validate_assertions,
)
from quipu_evals.scenarios import load_suite  # noqa: E402
from quipu_evals.provider_clients import LlmClient, LlmSettings  # noqa: E402

SUITE = ROOT / "evals/suites/experiments/representation_smoke.json"
FIXTURE = ROOT / "evals/fixtures/representation_assertions.json"


class RecordingClient:
    def __init__(self, response):
        self.response = response
        self.requests = []

    def chat_completion(self, system, user, **kwargs):
        self.requests.append((system, user))
        return json.dumps(self.response)


class RepresentationExperimentTests(unittest.TestCase):
    def setUp(self):
        self.suite = load_suite(SUITE)
        self.fixture = json.loads(FIXTURE.read_text())
        self.event = self.suite.scenarios[0].events[0]

    def test_ingestion_has_no_gold_fields(self):
        event = replace(self.event, ground_truth_memories=["SECRET_GOLD_MARKER"])
        self.assertNotIn("SECRET_GOLD_MARKER", json.dumps(source_episode(event)))
        self.assertNotIn("ground_truth", json.dumps(source_episode(event)))

    def test_reader_never_receives_reference_answer(self):
        client = RecordingClient({"answer": "unknown", "abstained": True})
        answer(client, "question", "2026-01-01", "source only", "model")
        self.assertEqual(json.loads(client.requests[0][1]), {
            "question": "question", "questionTime": "2026-01-01", "memory": "source only",
        })

    def test_fabricated_quote_or_wrong_message_rejected(self):
        for index, quote in [(0, "fabricated"), (5, "I rejected"), (True, "I rejected")]:
            with self.subTest(index=index), self.assertRaises(ValueError):
                validate_assertions(self.event, {"assertions": [{"text": "claim", "messageIndex": index, "quote": quote}]})

    def test_repeated_assertion_does_not_duplicate_support(self):
        item = self.fixture["career"]["offer"]["assertions"][0]
        self.assertEqual(len(validate_assertions(self.event, {"assertions": [item, item]})), 1)

    def test_future_and_other_scope_evidence_never_enters_ranker(self):
        passages = [p for s in self.suite.scenarios for e in s.events for p in raw_passages(e)]
        selected = eligible(passages, "2026-03-01T00:00:00Z", {"project": "synthetic_cedar"})
        self.assertEqual({p.event_id for p in selected}, {"cedar"})
        selected = eligible(passages, "2026-03-01T00:00:00Z", {"user": "synthetic_nora"})
        self.assertEqual({p.event_id for p in selected}, {"offer", "residence"})

    def test_time_comparison_uses_instants_not_string_order(self):
        passage = replace(raw_passages(self.event)[0], time="2026-01-01T01:00:00+02:00")
        self.assertEqual(eligible([passage], "2026-01-01T00:00:00Z", {"user": "synthetic_nora"}), [passage])

    def test_budget_includes_wrappers_and_never_truncates_a_claim(self):
        passages = raw_passages(self.event)
        count = lambda text: len(text.encode())
        exact = count(passages[0].render())
        self.assertEqual(pack([(passages[0], 1)], exact, count)["selected"][0]["text"], passages[0].text)
        self.assertEqual(pack([(passages[0], 1)], exact - 1, count)["selected"], [])
        self.assertEqual(pack([(passages[0], 1)], exact - 1, count)["dropped"][0]["reason"], "context_budget")

    def test_gold_event_hit_can_still_omit_answer(self):
        query = self.suite.scenarios[0].queries[0]
        passage = validate_assertions(self.event, self.fixture["career"]["offer"])[0]
        packed = pack([(passage, 1)], 4096, len)
        self.assertEqual(evidence_metrics(packed["selected"], query)["sourceEventRecall"], 1)
        self.assertNotIn("orchestra", packed["context"])

    def test_unanswerable_has_no_positive_recall_denominator(self):
        query = self.suite.scenarios[0].queries[2]
        self.assertIsNone(evidence_metrics([], query)["sourceEventRecall"])

    def test_no_model_means_no_answer_score(self):
        report = run(self.suite, fixture=self.fixture, budget=4096, count=len)
        self.assertFalse(report["publishable"])
        self.assertEqual(len(report["queries"]), 20)
        for metrics in report["summary"].values():
            self.assertIsNone(metrics["answerAccuracyOnGraded"])
            self.assertEqual(metrics["graded"], 0)

    def test_gold_labels_do_not_change_extraction_or_retrieval(self):
        altered = replace(self.suite, scenarios=[replace(s, queries=[
            replace(q, expected_answer="SECRET", expected_evidence_event_ids=[]) for q in s.queries
        ]) for s in self.suite.scenarios])
        original = run(self.suite, fixture=self.fixture, budget=4096, count=len)
        changed = run(altered, fixture=self.fixture, budget=4096, count=len)
        self.assertEqual(original["projections"], changed["projections"])
        self.assertEqual([r["context"] for r in original["queries"] if r["arm"] != "oracle_source"],
                         [r["context"] for r in changed["queries"] if r["arm"] != "oracle_source"])

    def test_invalid_extraction_marks_dependent_arms_failed(self):
        self.fixture["career"]["offer"] = {"assertions": [{"text": "bad", "messageIndex": 0, "quote": "not in source"}]}
        report = run(self.suite, fixture=self.fixture, budget=4096, count=len)
        self.assertEqual(report["summary"]["assertions"]["errors"], 3)
        self.assertEqual(report["summary"]["raw"]["errors"], 0)

    def test_hybrid_requires_real_vectors(self):
        with self.assertRaises(ValueError):
            run(self.suite, fixture=self.fixture, budget=4096, count=len, hybrid=True)

    def test_hybrid_vector_shape_is_validated(self):
        class BrokenEmbedder:
            def embed_texts(self, texts):
                return [[1.0], [1.0, 2.0]]
        with self.assertRaises(ValueError):
            rank("offer", raw_passages(self.event), BrokenEmbedder())

    def test_judge_string_false_is_not_a_boolean(self):
        with self.assertRaises(ValueError):
            judge(RecordingClient({"correct": "false", "reason": "wrong"}),
                  self.suite.scenarios[0].queries[0], {"answer": "wrong"}, "judge")

    def test_errors_are_separate_from_graded_accuracy(self):
        result = summarize([
            {"arm": "raw", "status": "error"},
            {"arm": "raw", "status": "ok", "judgment": {"correct": True},
             "evidence": {"sourceEventRecall": 1, "allRequiredEvents": True}},
        ])["raw"]
        self.assertEqual(result["answerAccuracyOnGraded"], 1)
        self.assertEqual(result["answerSuccessOverAllQueries"], 0.5)
        self.assertEqual(result["errors"], 1)

    def test_frozen_requests_replay_without_network_and_keep_usage(self):
        settings = LlmSettings("openrouter", None, "https://example.invalid/v1", "extractor", "judge")
        with tempfile.TemporaryDirectory() as temporary:
            client = FrozenClient("openrouter", cache_dir=Path(temporary), settings=settings)
            response = {"choices": [{"message": {"content": "test"}}], "usage": {"total_tokens": 12}}
            with patch.object(LlmClient, "_post", return_value=response) as network:
                client.stage = "extraction"
                self.assertEqual(client.chat_completion("system", "episode"), "test")
                self.assertEqual(client.chat_completion("system", "episode"), "test")
                self.assertEqual(network.call_count, 1)
                self.assertEqual([call["cached"] for call in client.calls], [False, True])
                self.assertEqual(client.calls[1]["usage"]["total_tokens"], 12)
                client.chat_completion("system", "episode", model="different-model")
                self.assertEqual(network.call_count, 2)

    def test_unsupported_lifecycle_operations_fail_explicitly(self):
        scenario = replace(self.suite.scenarios[0], forget_ops=[object()])
        with self.assertRaisesRegex(ValueError, "forgetting"):
            run(replace(self.suite, scenarios=[scenario]), fixture=self.fixture, budget=4096, count=len)


if __name__ == "__main__":
    unittest.main()
