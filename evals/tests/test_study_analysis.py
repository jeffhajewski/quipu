from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from quipu_evals.study_analysis import merged_reports, paired_with_exact_test  # noqa: E402


class AnalysisTests(unittest.TestCase):
    def report(self, arm="raw"):
        return {"suiteHash": "s", "graderHash": "g", "readerPrompt": "r",
                "representationCodeHash": "c", "models": {}, "tokenizer": "t",
                "plannedQuestions": 1, "errors": [],
                "config": {"arms": [arm], "budgets": [1024]},
                "rows": [{"queryId": "q", "arm": arm, "budget": 1024}]}

    def merge(self, *reports):
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for index, report in enumerate(reports):
                path = Path(directory) / f"{index}.json"
                path.write_text(json.dumps(report))
                paths.append(path)
            return merged_reports(paths)

    def test_merge_matching_study(self):
        self.assertEqual(len(self.merge(self.report(), self.report("combined"))), 2)

    def test_reject_changed_reader_or_duplicate(self):
        changed = self.report("combined")
        changed["readerPrompt"] = "new"
        with self.assertRaises(ValueError):
            self.merge(self.report(), changed)
        with self.assertRaises(ValueError):
            self.merge(self.report(), self.report())

    def test_reject_incomplete_even_without_explicit_error(self):
        incomplete = self.report()
        incomplete["rows"] = []
        with self.assertRaises(ValueError):
            self.merge(incomplete)

    def test_four_discordant_wins_are_not_significant(self):
        rows = [{"queryId": str(i), "arm": arm, "budget": 1024,
                 "judgment": {"correct": arm == "combined"}}
                for i in range(4) for arm in ("raw", "combined")]
        self.assertEqual(paired_with_exact_test(rows)[0]["exactMcNemarPUnadjusted"], 0.125)


if __name__ == "__main__":
    unittest.main()
