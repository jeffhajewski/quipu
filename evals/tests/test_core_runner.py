from __future__ import annotations

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "evals" / "src"))


class CoreRunnerFixTests(unittest.TestCase):
    def test_old_runner_logs_array_shaped_context(self):
        from quipu_evals.core_runner import context_prompt
        context = {"core": [{"qid": "q_core", "text": "Project uses Zig"}], "currentFacts": [],
                   "preferences": [], "procedural": [], "episodes": []}
        self.assertIn("Project uses Zig", context_prompt(context))
        self.assertEqual(context_prompt(context, "daemon prompt"), "daemon prompt")

    def test_in_memory_runs_build_without_lattice(self):
        from unittest import mock
        from quipu_evals import core_runner
        with mock.patch.object(core_runner.shutil, "which", return_value="/usr/bin/zig"), \
                mock.patch.object(core_runner.subprocess, "run") as run:
            core_runner.ensure_core_binary(storage="memory")
        self.assertIn("-Denable-lattice=false", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
