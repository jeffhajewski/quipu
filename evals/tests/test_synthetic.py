from __future__ import annotations

import sys
import unittest
import json
from pathlib import Path
import os
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "evals" / "src"))

from quipu_evals.core_client import CoreStdioClient  # noqa: E402
from quipu_evals.core_runner import run_core_suite  # noqa: E402
from quipu_evals.artifacts import build_manifest  # noqa: E402
from quipu_evals.benchmarks import collect_benchmarks, render_markdown  # noqa: E402
from quipu_evals.comparisons import published_results  # noqa: E402
from quipu_evals.external import load_external_suite  # noqa: E402
from quipu_evals.locomo import load_locomo_suite, write_suite  # noqa: E402
from quipu_evals.provider_clients import CachedEmbeddingProvider, LlmJudgeResult  # noqa: E402
from quipu_evals.readiness import evaluate_readiness  # noqa: E402
from quipu_evals.baselines import DETERMINISTIC_ABLATIONS, DETERMINISTIC_REQUIRED_BASELINES  # noqa: E402
from quipu_evals import load_suite, run_suite  # noqa: E402


SUITE_PATH = ROOT / "evals" / "suites" / "quipu_synthetic.yaml"
LOCOMO_MINI_PATH = ROOT / "evals" / "suites" / "external" / "locomo_mini.yaml"
CORE_DIR = ROOT / "core"
CORE_BINARY = CORE_DIR / "zig-out" / "bin" / "quipu"
LATTICE_INCLUDE = os.environ.get("LATTICE_INCLUDE")
LATTICE_LIB = os.environ.get("LATTICE_LIB_DIR") or (
    str(Path(os.environ["LATTICE_LIB_PATH"]).parent) if os.environ.get("LATTICE_LIB_PATH") else None
)


class SyntheticEvalTests(unittest.TestCase):
    def test_loads_unified_scenarios(self):
        suite = load_suite(SUITE_PATH)
        self.assertEqual(suite.name, "quipu_synthetic")
        self.assertGreaterEqual(len(suite.scenarios), 2)
        self.assertIn("temporal_truth", suite.suites)

    def test_q0_raw_only_smoke_run_passes(self):
        run = run_suite(SUITE_PATH)
        self.assertTrue(run.passed)
        self.assertEqual(len(run.query_runs), 5)
        self.assertEqual(len(run.forget_runs), 1)
        self.assertEqual(run.to_json()["metrics"]["queriesPassed"], 5)

    def test_deterministic_required_baseline_runs(self):
        run = run_suite(SUITE_PATH, baseline_id="bm25")
        payload = run.to_json()

        self.assertEqual(payload["baseline"], "bm25")
        self.assertEqual(payload["metrics"]["queriesTotal"], 5)
        self.assertIn("retrieval", payload["metrics"])

    def test_provider_embedding_cache_reuses_vectors(self):
        class StubEmbeddingClient:
            class Settings:
                embedding_model = "stub-embedding"

            settings = Settings()

            def __init__(self):
                self.calls = 0

            def embed_texts(self, texts):
                self.calls += 1
                return [[float(len(text)), 1.0] for text in texts]

        with tempfile.TemporaryDirectory(prefix="quipu-provider-cache-") as directory:
            client = StubEmbeddingClient()
            cache = CachedEmbeddingProvider(client, cache_path=Path(directory) / "embeddings.jsonl")

            first = cache.embed_texts(["alpha", "beta", "alpha"])
            second = cache.embed_texts(["alpha"])

        self.assertEqual(first[0], second[0])
        self.assertEqual(client.calls, 1)

    def test_runner_can_use_provider_backed_vector_baseline(self):
        class StubEmbeddingProvider:
            def embed_texts(self, texts):
                vectors = []
                for text in texts:
                    lower = text.lower()
                    vectors.append([
                        1.0 if "pixel" in lower else 0.0,
                        1.0 if "appointment" in lower else 0.0,
                    ])
                return vectors

        run = run_suite(
            LOCOMO_MINI_PATH,
            baseline_id="vector_rag",
            baseline_label="openrouter_vector_rag",
            embedding_provider=StubEmbeddingProvider(),
        )

        self.assertEqual(run.to_json()["baseline"], "openrouter_vector_rag")
        self.assertEqual(run.to_json()["metrics"]["queriesTotal"], 5)

    def test_runner_can_add_llm_judge_grade(self):
        class StubJudgeProvider:
            def judge_answer(self, question, expected_answer, actual_answer):
                return LlmJudgeResult(
                    passed=actual_answer == expected_answer,
                    score=1.0 if actual_answer == expected_answer else 0.0,
                    reason=f"graded {question}",
                    model="stub-judge",
                )

        run = run_suite(SUITE_PATH, baseline_id="bm25", judge_provider=StubJudgeProvider())
        first_query = run.to_json()["queries"][0]
        grade_names = [grade["name"] for grade in first_query["grades"]]

        self.assertIn("llm_judge", grade_names)

    def test_eval_manifest_summarizes_run_artifacts(self):
        run = run_suite(SUITE_PATH)
        manifest = build_manifest(
            run.to_json(),
            suite_path=SUITE_PATH,
            runner="test",
            storage="fake",
            results_path="artifacts/results.json",
        )

        self.assertEqual(manifest["schemaVersion"], "quipu.eval.run.v1")
        self.assertEqual(manifest["suite"]["name"], "quipu_synthetic")
        self.assertEqual(manifest["baseline"], "q0_raw_only_fake")
        self.assertEqual(manifest["artifacts"]["results"], "artifacts/results.json")
        self.assertIn("configHash", manifest)
        self.assertEqual(manifest["providers"]["answer"], "deterministic_prompt_match")
        self.assertEqual(manifest["verification"]["status"], "not_run")

    def test_benchmark_markdown_renders_honest_scope(self):
        markdown = render_markdown(
            {
                "generatedAt": "2026-04-29T00:00:00Z",
                "gitCommit": "abc1234",
                "suite": "evals/suites/quipu_synthetic.yaml",
                "latticeIncluded": False,
                "runs": [
                    {
                        "baseline": "core_in_memory",
                        "storage": "memory",
                        "passed": True,
                        "metrics": {
                            "queriesPassed": 5,
                            "queriesTotal": 5,
                            "forgetOpsPassed": 1,
                            "forgetOpsTotal": 1,
                        },
                        "durationMs": 42.25,
                    }
                ],
            }
        )

        self.assertIn("synthetic smoke benchmark", markdown)
        self.assertIn("core_in_memory", markdown)
        self.assertIn("LoCoMo", markdown)

    def test_loads_locomo_external_smoke_suite(self):
        suite = load_external_suite(LOCOMO_MINI_PATH, benchmark="locomo")
        categories = {query.category for scenario in suite.scenarios for query in scenario.queries}

        self.assertEqual(suite.metadata["format"], "quipu.external.scenario.v1")
        self.assertEqual(suite.metadata["benchmark"], "locomo")
        self.assertEqual(len(suite.scenarios), 1)
        self.assertEqual(len(suite.scenarios[0].queries), 5)
        self.assertIn("single_hop", categories)
        self.assertIn("multi_hop", categories)
        self.assertIn("temporal", categories)
        self.assertIn("adversarial", categories)
        self.assertIn("event_summary", categories)

    def test_locomo_external_smoke_q0_passes(self):
        run = run_suite(LOCOMO_MINI_PATH)

        self.assertTrue(run.passed)
        self.assertEqual(len(run.query_runs), 5)
        self.assertEqual(len(run.forget_runs), 1)
        self.assertEqual(run.to_json()["metrics"]["answer"]["exactMatch"], 1.0)

    def test_converts_real_locomo_shape_to_external_suite(self):
        with tempfile.TemporaryDirectory(prefix="quipu-locomo-shape-") as directory:
            dataset = Path(directory) / "locomo10.json"
            dataset.write_text(
                json.dumps(
                    [
                        {
                            "sample_id": "conv-test",
                            "conversation": {
                                "speaker_a": "Avery",
                                "speaker_b": "Blake",
                                "session_1_date_time": "1:56 pm on 8 May, 2023",
                                "session_1": [
                                    {"speaker": "Avery", "dia_id": "D1:1", "text": "I adopted a cat named Pixel."},
                                    {"speaker": "Blake", "dia_id": "D1:2", "text": "Pixel sounds lovely."},
                                ],
                            },
                            "qa": [
                                {
                                    "question": "What is Avery's cat named?",
                                    "answer": "Pixel",
                                    "evidence": ["D1:1"],
                                    "category": 1,
                                }
                            ],
                            "event_summary": {
                                "events_session_1": {"Avery": ["Avery adopted Pixel."], "Blake": [], "date": "8 May, 2023"}
                            },
                        }
                    ]
                )
            )
            suite = load_locomo_suite(dataset, include_event_summaries=True)
            normalized = Path(directory) / "normalized.json"
            write_suite(normalized, suite)
            loaded = load_external_suite(normalized, benchmark="locomo")

        self.assertEqual(loaded.name, "locomo")
        self.assertEqual(len(loaded.scenarios), 1)
        self.assertEqual(len(loaded.scenarios[0].events), 2)
        self.assertEqual(loaded.scenarios[0].queries[0].expected_answer, "Pixel")
        self.assertEqual(loaded.scenarios[0].queries[1].category, "event_summary")
        self.assertTrue(loaded.metadata["fullDataset"])

    def test_external_smoke_report_marks_not_publishable(self):
        report = collect_benchmarks(
            LOCOMO_MINI_PATH,
            include_lattice=False,
            result_class="external_smoke",
            external_benchmark="locomo",
        )
        markdown = render_markdown(report)

        self.assertEqual(report["resultClass"], "external_smoke")
        self.assertEqual(report["dataset"]["benchmark"], "locomo")
        self.assertEqual(report["benchmarkReadiness"]["status"], "not_ready")
        self.assertGreater(len(report["publishedComparisons"]), 0)
        self.assertIn("External Smoke Benchmark Results", markdown)
        self.assertIn("Published External Reference Points", markdown)
        self.assertIn("not publishable", markdown)

    def test_published_comparisons_include_memory_system_references(self):
        systems = {row["system"] for row in published_results("locomo")}

        self.assertIn("Mem0 Platform v3 top-200", systems)
        self.assertIn("Memobase v0.0.37", systems)
        self.assertIn("Letta Filesystem", systems)
        self.assertIn("Memvid", systems)

    def test_report_can_execute_required_baselines_and_ablations(self):
        report = collect_benchmarks(
            LOCOMO_MINI_PATH,
            include_core=False,
            include_baselines=True,
            include_ablations=True,
            result_class="external_smoke",
            external_benchmark="locomo",
        )

        baselines = {run["baseline"] for run in report["runs"]}
        ablations = {item["id"] for item in report["ablations"]}
        self.assertTrue(set(DETERMINISTIC_REQUIRED_BASELINES).issubset(baselines))
        self.assertTrue(set(DETERMINISTIC_ABLATIONS).issubset(ablations))
        readiness = {item["id"]: item["passed"] for item in report["benchmarkReadiness"]["requirements"]}
        self.assertTrue(readiness["baselines"])
        self.assertTrue(readiness["ablations"])
        self.assertFalse(readiness["full_dataset"])

    def test_benchmark_collector_can_reuse_existing_run_artifacts(self):
        with tempfile.TemporaryDirectory(prefix="quipu-reuse-existing-") as directory:
            report = collect_benchmarks(
                LOCOMO_MINI_PATH,
                output_dir=directory,
                include_core=False,
                include_baselines=True,
                result_class="external_smoke",
                external_benchmark="locomo",
            )
            reused = collect_benchmarks(
                LOCOMO_MINI_PATH,
                output_dir=directory,
                include_core=False,
                include_baselines=True,
                result_class="external_smoke",
                external_benchmark="locomo",
                reuse_existing=True,
            )

        self.assertEqual(len(report["runs"]), len(reused["runs"]))
        self.assertTrue(all(run.get("reused") for run in reused["runs"]))
        self.assertEqual(report["runs"][0]["metrics"], reused["runs"][0]["metrics"])

    def test_readiness_counts_lattice_storage_runs_separately_from_accuracy(self):
        readiness = evaluate_readiness(
            {
                "externalBenchmark": "locomo",
                "gitCommit": "abc123",
                "traceArtifacts": ["core_lattice-traces.json"],
                "verification": {"status": "passed"},
                "runs": [
                    {
                        "baseline": "core_lattice",
                        "storage": "lattice",
                        "passed": False,
                        "metrics": {
                            "answer": {"exactMatch": 0.0},
                            "grades": {"exact_answer": {"passed": 0, "total": 1}},
                        },
                        "artifacts": {"manifest": "core_lattice-manifest.json"},
                    }
                ],
            }
        )
        lattice_requirement = next(
            item for item in readiness["requirements"] if item["id"] == "lattice_storage"
        )
        self.assertTrue(lattice_requirement["passed"])
        self.assertEqual(readiness["status"], "not_ready")

    def test_publishable_external_report_wording_is_not_synthetic(self):
        markdown = render_markdown(
            {
                "resultClass": "publishable",
                "externalBenchmark": "locomo",
                "generatedAt": "2026-04-29T00:00:00Z",
                "dataset": {"datasetName": "LoCoMo", "datasetVersion": "locomo10"},
                "suite": "normalized-locomo-suite.json",
                "latticeIncluded": True,
                "runs": [],
                "benchmarkReadiness": {"status": "not_ready", "requirements": []},
            }
        )
        self.assertIn("External Benchmark Results", markdown)
        self.assertIn("readiness gate", markdown)
        self.assertNotIn("synthetic smoke benchmark results", markdown)

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
        self.assertTrue(by_query["q_pref_current"].passed)
        self.assertTrue(by_query["q_pref_historical"].passed)
        self.assertEqual(run.forget_runs[0].deleted_roots, 1)
        self.assertTrue(run.forget_runs[0].passed)

    @unittest.skipUnless(
        shutil.which("zig") and LATTICE_INCLUDE and LATTICE_LIB,
        "zig, LATTICE_INCLUDE, and LATTICE_LIB_DIR or LATTICE_LIB_PATH are required",
    )
    def test_core_lattice_synthetic_eval_marks_current_capabilities(self):
        with tempfile.TemporaryDirectory(prefix="quipu-lattice-test-") as directory:
            run = run_core_suite(
                SUITE_PATH,
                storage="lattice",
                db_dir=Path(directory),
                lattice_include=LATTICE_INCLUDE,
                lattice_lib=LATTICE_LIB,
            )

        self.assertEqual(run.to_json()["baseline"], "core_lattice")
        self.assertTrue(run.passed)
        self.assertEqual(run.to_json()["metrics"]["queriesPassed"], 5)
        self.assertEqual(run.to_json()["metrics"]["forgetOpsPassed"], 1)

    @unittest.skipUnless(
        shutil.which("zig") and LATTICE_INCLUDE and LATTICE_LIB,
        "zig, LATTICE_INCLUDE, and LATTICE_LIB_DIR or LATTICE_LIB_PATH are required",
    )
    def test_core_lattice_vector_search_and_health(self):
        env = os.environ.copy()
        env["ZIG_GLOBAL_CACHE_DIR"] = "/tmp/quipu-zig-cache"
        subprocess.run(
            [
                "zig",
                "build",
                "-Denable-lattice=true",
                f"-Dlattice-include={LATTICE_INCLUDE}",
                f"-Dlattice-lib={LATTICE_LIB}",
            ],
            cwd=str(CORE_DIR),
            check=True,
            env=env,
        )

        with tempfile.TemporaryDirectory(prefix="quipu-lattice-vector-") as directory:
            db_path = Path(directory) / "quipu.lattice"
            with CoreStdioClient(CORE_BINARY, extra_args=["--db", str(db_path)]) as client:
                health = client.call("system.health", {})
                self.assertEqual(health["storage"]["backend"], "lattice")
                self.assertTrue(health["storage"]["vector"])
                self.assertEqual(health["storage"]["vectorDimensions"], 128)
                self.assertEqual(health["storage"]["embeddingModel"], "lattice_hash_embed")

                remembered = client.call(
                    "memory.remember",
                    {
                        "scope": {"projectId": "repo:vector"},
                        "messages": [
                            {
                                "role": "user",
                                "content": "The launch code is heliotrope.",
                            }
                        ],
                        "extract": False,
                    },
                )
                vector_results = client.call(
                    "memory.search",
                    {
                        "query": "heliotrope launch code",
                        "scope": {"projectId": "repo:vector"},
                        "labels": ["message"],
                        "mode": "vector",
                        "limit": 5,
                    },
                )
                hybrid_results = client.call(
                    "memory.search",
                    {
                        "query": "heliotrope",
                        "scope": {"projectId": "repo:vector"},
                        "labels": ["message"],
                        "mode": "hybrid",
                        "limit": 5,
                    },
                )

                self.assertEqual(remembered["status"], "stored")
                self.assertTrue(
                    any("heliotrope" in item["text"] for item in vector_results["results"])
                )
                self.assertTrue(
                    any("heliotrope" in item["text"] for item in hybrid_results["results"])
                )


if __name__ == "__main__":
    unittest.main()
