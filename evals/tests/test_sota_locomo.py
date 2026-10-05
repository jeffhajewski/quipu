from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "evals" / "src"))

from quipu_evals.sota_locomo import (  # noqa: E402
    ACCURACY_PROMPT, ACCURACY_PROMPT_SHA256, ADVERSARIAL_GOLD, CATEGORY_NAMES, JUDGE_MODEL, aggregate,
    answer_params, build_conversation, build_questions, evidence_coverage, judge_answer, judge_request,
    load_audit, parse_evidence, parse_judge_label, plan_parallelism, resolve_evidence, turn_message,
)
from quipu_evals.sota_longmemeval import item_turns  # noqa: E402


def sample():
    return {
        "sample_id": "conv-x",
        "conversation": {
            "speaker_a": "Caroline", "speaker_b": "Melanie",
            # Session 2 is numbered first but happened later; session 3 has a date only.
            "session_2_date_time": "1:14 pm on 25 May, 2023",
            "session_2": [
                {"speaker": "Melanie", "dia_id": "D2:1", "text": "I ran a charity race last Saturday."},
                {"speaker": "Caroline", "dia_id": "D2:2", "text": "  ", "blip_caption": "a photo of a medal",
                 "img_url": ["http://x"], "query": "gold medal race"},
                {"speaker": "Melanie", "dia_id": "D2:3", "text": ""},
                {"speaker": "Melanie", "dia_id": "D2:4", "text": "Thanks!"},
            ],
            "session_1_date_time": "1:56 pm on 8 May, 2023",
            "session_1": [
                {"speaker": "Caroline", "dia_id": "D1:1", "text": "Hey Mel!"},
                {"speaker": "Melanie", "dia_id": "D1:2", "text": "Look at this", "blip_caption": "a lake at sunrise"},
            ],
            "session_3_date_time": "9:00 am on 1 June, 2023",
        },
        "qa": [
            {"question": "When did Melanie run a charity race?", "answer": "The sunday before 25 May 2023",
             "evidence": ["D2:1"], "category": 2},
            {"question": "What did Melanie paint?", "answer": "a sunrise", "evidence": ["D1:2; D2:1"], "category": 4},
            {"question": "What did Caroline say about her race?", "adversarial_answer": "it went well",
             "evidence": ["D2:1"], "category": 5},
            {"question": "Where did they meet?", "answer": 2022, "evidence": ["D", "D:9:9"], "category": 1},
        ],
    }


class ConversationTests(unittest.TestCase):
    def setUp(self):
        self.conversation = build_conversation(sample(), 3)

    def test_sessions_are_date_ordered_and_date_only_sessions_ignored(self):
        self.assertEqual([s["sessionId"] for s in self.conversation["sessions"]], ["s01", "s02"])
        self.assertEqual(self.conversation["sessions"][1]["time"], "2023-05-25T13:14:00Z")

    def test_speaker_name_is_the_role_and_nobody_is_the_assistant(self):
        messages = [m for s in self.conversation["sessions"] for m in s["messages"]]
        self.assertEqual([m["role"] for m in messages], ["Caroline", "Melanie", "Melanie", "Caroline", "Melanie"])
        self.assertEqual(messages[0]["content"], "Hey Mel!")
        prefixed = build_conversation(sample(), 3, speaker_mode="prefix")["sessions"][0]["messages"]
        self.assertEqual(prefixed[0], {"role": "user", "content": "Caroline: Hey Mel!",
                                       "createdAt": "2023-05-08T13:56:00Z"})
        self.assertNotIn("assistant", json.dumps(self.conversation["sessions"]))

    def test_messages_carry_session_time_plus_turn_offsets(self):
        times = [m["createdAt"] for m in self.conversation["sessions"][1]["messages"]]
        # D2:3 is empty and dropped; offsets follow the original turn position.
        self.assertEqual(times, ["2023-05-25T13:14:00Z", "2023-05-25T13:14:01Z", "2023-05-25T13:14:03Z"])
        self.assertEqual(self.conversation["droppedTurns"], ["D2:3"])
        self.assertEqual(self.conversation["questionTime"], "2023-05-25T13:15:03Z")

    def test_captions_are_appended_and_the_crawler_query_is_never_used(self):
        session = self.conversation["sessions"][1]["messages"]
        self.assertEqual(session[1]["content"], "[shares image: a photo of a medal]")
        self.assertEqual(self.conversation["sessions"][0]["messages"][1]["content"],
                         "Look at this [shares image: a lake at sunrise]")
        self.assertNotIn("gold medal race", json.dumps(self.conversation))
        no_captions = build_conversation(sample(), 3, captions=False)
        self.assertNotIn("D2:2", no_captions["diaToTurn"])
        self.assertIsNone(turn_message({"speaker": "A", "text": " "}))
        with self.assertRaises(ValueError):
            turn_message({"speaker": "A", "text": "x"}, speaker_mode="assistant")

    def test_dia_ids_map_to_post_filter_message_indices(self):
        self.assertEqual(self.conversation["diaToTurn"]["D2:4"], ["s02", 2])
        self.assertEqual(self.conversation["diaToTurn"]["D1:2"], ["s01", 1])


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.conversation = build_conversation(sample(), 3)

    def test_evidence_strings_are_normalized(self):
        self.assertEqual(parse_evidence(["D1:3"]), (["D1:3"], []))
        self.assertEqual(parse_evidence(["D8:6; D9:17", "D9:1 D4:4 D8:6"]), (["D8:6", "D9:17", "D9:1", "D4:4"], []))
        self.assertEqual(parse_evidence(["D:11:26", "D"]), (["D11:26"], ["D"]))

    def test_unresolvable_ids_are_kept_apart(self):
        turns, unresolved = resolve_evidence(["D2:1", "D2:3", "D9:9"], self.conversation["diaToTurn"])
        self.assertEqual(turns, [["s02", 0]])
        self.assertEqual(unresolved, ["D2:3", "D9:9"])

    def test_chunk_and_message_items_map_to_gold_turns(self):
        qid_to_turn = {"q_msg_1": ("s01", 0), "q_msg_2": ("s01", 1), "q_msg_3": ("s02", 0)}
        chunk = {"qid": "q_chunk_7", "type": "message", "evidence": [{"qid": "q_msg_3"}]}
        fact = {"qid": "q_fact_1", "type": "fact", "evidence": [{"qid": "q_msg_2"}]}
        turns = item_turns([chunk, fact], qid_to_turn)
        result = evidence_coverage([["s01", 1], ["s02", 0]], turns)
        self.assertEqual((result["goldTurnCoverage"], result["allGoldTurns"]), (1.0, True))
        raw = evidence_coverage([["s01", 1], ["s02", 0]], item_turns([chunk, fact], qid_to_turn, raw_only=True))
        self.assertEqual((raw["goldTurnCoverage"], raw["goldSessionCoverage"]), (0.5, 0.5))
        self.assertEqual(raw["missingGoldTurns"], [("s01", 1)])
        self.assertIsNone(evidence_coverage([], turns)["goldTurnCoverage"])


class QuestionTests(unittest.TestCase):
    def setUp(self):
        self.sample = sample()
        self.conversation = build_conversation(self.sample, 3)
        self.audit_entries = [
            {"question_id": "locomo_3_qa0", "question": "When did Melanie run a charity race?",
             "golden_answer": "The sunday before 25 May 2023", "category": 2, "error_type": "TEMPORAL_ERROR",
             "cited_evidence": ["D2:1"], "correct_evidence": ["D2:1"], "correct_answer": "The Saturday before 25 May 2023"},
            {"question_id": "locomo_3_qa1", "question": "What did Melanie paint?", "golden_answer": "a sunrise",
             "category": 4, "error_type": "WRONG_CITATION", "cited_evidence": ["D1:2"], "correct_evidence": ["D1:1"],
             "correct_answer": "a lake sunrise"},
        ]

    def audit(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "errors.json"
            path.write_text(json.dumps(self.audit_entries))
            return load_audit(path)

    def test_ids_follow_the_audit_scheme_and_category_names_the_data(self):
        questions = build_questions(self.sample, self.conversation)
        self.assertEqual([q["questionId"] for q in questions], [f"locomo_3_qa{i}" for i in range(4)])
        self.assertEqual(CATEGORY_NAMES, {1: "multi-hop", 2: "temporal", 3: "open-domain", 4: "single-hop",
                                          5: "adversarial"})
        self.assertEqual(questions[3]["reference"], "2022")

    def test_category_filter_then_limit(self):
        questions = build_questions(self.sample, self.conversation, categories=[1, 2, 4], limit=2)
        self.assertEqual([q["category"] for q in questions], [2, 4])
        self.assertEqual([q["qaIndex"] for q in build_questions(self.sample, self.conversation, categories=[5])], [2])

    def test_adversarial_questions_are_judged_against_not_mentioned(self):
        question = build_questions(self.sample, self.conversation, categories=[5])[0]
        self.assertEqual(question["reference"], ADVERSARIAL_GOLD)
        self.assertEqual(question["adversarialAnswer"], "it went well")
        self.assertIsNone(question["auditReference"])

    def test_audit_changes_only_score_corrupting_answers(self):
        questions = build_questions(self.sample, self.conversation, audit=self.audit())
        self.assertEqual(questions[0]["auditReference"], "The Saturday before 25 May 2023")
        self.assertEqual(questions[0]["reference"], "The sunday before 25 May 2023")
        self.assertIsNone(questions[1]["auditReference"])
        self.assertEqual(questions[1]["auditGoldTurns"], [["s01", 0]])
        self.assertEqual(questions[1]["goldTurns"], [["s01", 1], ["s02", 0]])

    def test_audit_entries_must_match_the_dataset(self):
        self.audit_entries[0]["question"] = "Something else?"
        with self.assertRaises(ValueError):
            build_questions(self.sample, self.conversation, audit=self.audit())

    def test_answer_params_pin_time_budget_and_disable_retrieval_logging(self):
        question = build_questions(self.sample, self.conversation)[0]
        params = answer_params(question, self.conversation, {"answerOptions": {"rerank": False}}, 1024)
        self.assertEqual(params["time"], {"validAt": self.conversation["questionTime"]})
        self.assertEqual(params["budgetTokens"], 1024)
        self.assertEqual(params["options"], {"logRetrieval": False, "rerank": False, "includeDebug": True,
                                             "includeEvidence": True})


class FakePoster:
    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = []

    def __call__(self, tag, body):
        self.calls.append((tag, body))
        return {"model": body["model"], "choices": [{"message": {"content": self.replies.pop(0)}}]}


class JudgeTests(unittest.TestCase):
    def test_prompt_is_the_pinned_mem0_prompt(self):
        self.assertEqual(hashlib.sha256(ACCURACY_PROMPT.encode()).hexdigest(), ACCURACY_PROMPT_SHA256)
        self.assertIn("’CORRECT’ or ’WRONG’", ACCURACY_PROMPT)

    def test_request_shape_matches_mem0(self):
        body = judge_request("When?", "7 May 2023", "May 7th {braces}")
        self.assertEqual(set(body), {"model", "messages", "response_format", "temperature"})
        self.assertEqual((body["model"], body["temperature"]), (JUDGE_MODEL, 0.0))
        self.assertEqual(body["response_format"], {"type": "json_object"})
        self.assertEqual(len(body["messages"]), 1)
        self.assertEqual(body["messages"][0]["role"], "user")
        content = body["messages"][0]["content"]
        self.assertIn("Question: When?\nGold answer: 7 May 2023\nGenerated answer: May 7th {braces}\n", content)

    def test_labels_parse_from_json_fences_and_bare_text(self):
        self.assertEqual(parse_judge_label('{"label": "CORRECT"}'), "CORRECT")
        self.assertEqual(parse_judge_label('```json\n{"label": "WRONG"}\n```'), "WRONG")
        self.assertEqual(parse_judge_label('Reasoning... {"label": "correct"'), "CORRECT")
        self.assertEqual(parse_judge_label("WRONG"), "WRONG")
        with self.assertRaises(ValueError):
            parse_judge_label('{"label": "MAYBE"}')
        with self.assertRaises(ValueError):
            parse_judge_label("The answer is correct, not wrong.")

    def test_judge_answer_uses_the_poster_and_tag(self):
        poster = FakePoster(['{"label": "CORRECT"}'])
        result = judge_answer(poster, "q.b1024.judge", "When?", "7 May 2023", "May 7")
        self.assertTrue(result["correct"])
        self.assertEqual(poster.calls[0][0], "q.b1024.judge")
        self.assertEqual(result["gold"], "7 May 2023")


class AggregateTests(unittest.TestCase):
    def row(self, qid, category, correct, audit=None, budget=1024, status="ok"):
        row = {"questionId": qid, "category": category, "budget": budget, "status": status, "correct": correct,
               "correctAudit": correct if audit is None else audit, "goldTurnCoverage": 1.0, "llmAnswered": True,
               "auditEvidence": {"goldTurnCoverage": 1.0, "allGoldTurns": True}, "answerable": True,
               "calls": {"chatCalls": 1, "costUsd": 0.001, "nominalCostUsd": 0.002}}
        if audit is not None:
            row["judgmentAudit"] = {"correct": audit}
        return row

    def test_category_five_is_reported_apart_from_the_headline(self):
        rows = [self.row("a", 1, True), self.row("b", 4, False, audit=True), self.row("c", 5, True),
                self.row("d", 5, False), self.row("e", 2, None, status="error")]
        report = aggregate(rows, [1024])
        official, audit = report["summary"]["1024"]["official"], report["summary"]["1024"]["audit"]
        self.assertEqual((official["n"], official["correct"], official["completed"]), (3, 1, 2))
        self.assertEqual(audit["correct"], 2)
        self.assertEqual(report["summary"]["1024"]["auditCorrectedQuestions"],
                         {"n": 1, "officialCorrect": 0, "auditCorrect": 1})
        self.assertEqual((report["adversarial"]["1024"]["n"], report["adversarial"]["1024"]["correct"]), (2, 1))
        self.assertEqual(sorted(report["byCategory"]["1024"]), ["multi-hop", "single-hop", "temporal"])
        self.assertEqual(report["failures"]["1024"]["wrongByCause"], {"full_coverage_reader_wrong": 1})
        self.assertEqual(official["answerNominalCostPerQuestionUsd"], 0.002)

    def test_parallelism_splits_workers_between_conversations_and_replicas(self):
        self.assertEqual(plan_parallelism(10, 10, None, True), (10, 1))
        self.assertEqual(plan_parallelism(20, 10, None, True), (10, 2))
        self.assertEqual(plan_parallelism(8, 1, None, True), (1, 8))
        self.assertEqual(plan_parallelism(8, 1, 2, True), (1, 2))
        self.assertEqual(plan_parallelism(8, 1, None, False), (1, 1))


if __name__ == "__main__":
    unittest.main()
