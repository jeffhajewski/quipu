from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "evals" / "src"))

from quipu_evals import load_suite, run_suite  # noqa: E402


SUITE_PATH = ROOT / "evals" / "suites" / "quipu_synthetic.yaml"


class SyntheticEvalTests(unittest.TestCase):
    def test_loads_unified_scenarios(self):
        suite = load_suite(SUITE_PATH)
        self.assertEqual(suite.name, "quipu_synthetic")
        self.assertGreaterEqual(len(suite.scenarios), 2)
        self.assertIn("temporal_truth", suite.suites)

    def test_q0_raw_only_smoke_run_passes(self):
        run = run_suite(SUITE_PATH)
        self.assertTrue(run.passed)
        self.assertEqual(len(run.query_runs), 3)
        self.assertEqual(len(run.forget_runs), 1)
        self.assertEqual(run.to_json()["metrics"]["queriesPassed"], 3)


if __name__ == "__main__":
    unittest.main()
