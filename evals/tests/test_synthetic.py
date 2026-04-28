from __future__ import annotations

import sys
import unittest
from pathlib import Path
import os
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "evals" / "src"))

from quipu_evals.core_client import CoreStdioClient  # noqa: E402
from quipu_evals.core_runner import run_core_suite  # noqa: E402
from quipu_evals import load_suite, run_suite  # noqa: E402


SUITE_PATH = ROOT / "evals" / "suites" / "quipu_synthetic.yaml"
CORE_DIR = ROOT / "core"
CORE_BINARY = CORE_DIR / "zig-out" / "bin" / "quipu"


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

    @unittest.skipUnless(shutil.which("zig"), "zig is not installed")
    def test_core_stdio_remember_retrieve_forget_smoke(self):
        env = os.environ.copy()
        env["ZIG_GLOBAL_CACHE_DIR"] = "/tmp/quipu-zig-cache"
        subprocess.run(["zig", "build"], cwd=str(CORE_DIR), check=True, env=env)

        with CoreStdioClient(CORE_BINARY) as client:
            remembered = client.call(
                "memory.remember",
                {
                    "scope": {"projectId": "repo:test"},
                    "messages": [{"role": "user", "content": "Use pnpm for this repo."}],
                },
            )
            retrieved = client.call(
                "memory.retrieve",
                {"query": "pnpm", "scope": {"projectId": "repo:test"}},
            )

            self.assertEqual(remembered["status"], "stored")
            self.assertIn("The repo uses pnpm as its package manager.", retrieved["prompt"])

            forgotten = client.call(
                "memory.forget",
                {
                    "mode": "hard_delete",
                    "selector": {"qids": remembered["messageQids"]},
                    "dryRun": False,
                    "reason": "test",
                },
            )
            retrieved_after_forget = client.call(
                "memory.retrieve",
                {"query": "pnpm", "scope": {"projectId": "repo:test"}},
            )

            self.assertEqual(forgotten["nodesDeleted"], 1)
            self.assertNotIn("Use pnpm for this repo.", retrieved_after_forget["prompt"])

    @unittest.skipUnless(shutil.which("zig"), "zig is not installed")
    def test_core_synthetic_eval_marks_current_capabilities(self):
        run = run_core_suite(SUITE_PATH)
        by_query = {query.query_id: query for query in run.query_runs}

        self.assertTrue(run.passed)
        self.assertTrue(by_query["q_pkg_current"].passed)
        self.assertTrue(by_query["q_pkg_historical"].passed)
        self.assertTrue(by_query["q_scope_alpha"].passed)
        self.assertEqual(run.forget_runs[0].deleted_roots, 1)
        self.assertTrue(run.forget_runs[0].passed)


if __name__ == "__main__":
    unittest.main()
