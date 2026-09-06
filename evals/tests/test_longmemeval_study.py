from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "evals" / "src"))

from quipu_evals.longmemeval_study import extraction_key, grounded_extraction, paired, parse_extraction  # noqa: E402
from quipu_evals.scenarios import Event, Message  # noqa: E402


class StudyTests(unittest.TestCase):
    def setUp(self):
        self.event = Event("answer_secret", "2026-01-01T00:00:00Z", "message",
                           [Message("user", "My workshop is on Tuesday."), Message("assistant", "Noted.")],
                           {"secret_scope": "secret"}, ["secret_answer"])

    def test_extraction_ignores_scope_ids_and_gold_labels(self):
        altered = replace(self.event, event_id="other", scope={}, ground_truth_memories=[])
        self.assertEqual(extraction_key(self.event), extraction_key(altered))
        self.assertNotIn("secret", str(extraction_key(self.event)[1]))

    def test_citation_index_repair_requires_unique_verbatim_quote(self):
        claim = {"text": "The user's workshop is on Tuesday.", "messageIndex": 1, "quote": "My workshop is on Tuesday."}
        record = {"assertions": [], "invalid": [{"assertion": claim}]}
        fixed = grounded_extraction(self.event, record)
        self.assertEqual(fixed["assertions"][0]["messageIndex"], 0)
        self.assertEqual(fixed["repairedCitationIndices"], 1)
        ambiguous = replace(self.event, messages=[*self.event.messages, self.event.messages[0]])
        self.assertEqual(grounded_extraction(ambiguous, record)["assertions"], [])

    def test_paraphrased_quote_stays_quarantined(self):
        record = {"assertions": [], "invalid": [{"assertion": {
            "text": "workshop Tuesday", "messageIndex": 0, "quote": "The workshop is Tuesday",
        }}]}
        self.assertEqual(len(grounded_extraction(self.event, record)["rejected"]), 1)

    def test_paired_statistics_use_same_questions(self):
        rows = [
            {"queryId": "a", "arm": "raw", "budget": 1024, "judgment": {"correct": False}},
            {"queryId": "a", "arm": "assertions", "budget": 1024, "judgment": {"correct": True}},
            {"queryId": "unpaired", "arm": "assertions", "budget": 1024, "judgment": {"correct": True}},
        ]
        result = paired(rows, repeats=100)[0]
        self.assertEqual(result["n"], 1)
        self.assertEqual(result["wins"], 1)
        self.assertEqual(result["bootstrap95"], [1, 1])

    def test_invalid_latex_escape_is_preserved_literally(self):
        decoded, repaired = parse_extraction(r'{"text":"\usepackage{math}\quad"}')
        self.assertEqual(decoded["text"], r"\usepackage{math}\quad")
        self.assertTrue(repaired)
        decoded, repaired = parse_extraction(r'{"text":"\u0041\\usepackage"}')
        self.assertEqual(decoded["text"], "A\\usepackage")
        self.assertFalse(repaired)


if __name__ == "__main__":
    unittest.main()
