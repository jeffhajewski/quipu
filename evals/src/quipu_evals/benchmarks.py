from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from typing import Any, Callable, Mapping

from .artifacts import build_manifest, write_json
from .baselines import DETERMINISTIC_ABLATIONS, DETERMINISTIC_REQUIRED_BASELINES, registry_json
from .core_runner import CORE_BINARY, lattice_lib_from_env, run_core_suite
from .external import DEFAULT_EXTERNAL_SUITES, external_suite_metadata, is_normalized_external_suite, load_external_suite
from .locomo import download_locomo, load_locomo_suite, write_suite
from .readiness import evaluate_readiness
from .runner import run_suite
from .scenarios import load_suite


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_SUITE = ROOT / "evals" / "suites" / "quipu_synthetic.yaml"


def collect_benchmarks(
    suite_path: str | Path = DEFAULT_SUITE,
    *,
    output_dir: str | Path = ROOT / "artifacts" / "benchmarks",
    include_lattice: bool = False,
    lattice_include: str | None = None,
    lattice_lib: str | None = None,
    result_class: str = "synthetic_smoke",
    external_benchmark: str | None = None,
    seed: int = 0,
    verification_status: str = "not_run",
    include_core: bool = True,
    require_core: bool = False,
    locomo_options: Mapping[str, Any] | None = None,
    require_lattice: bool = False,
    include_baselines: bool = False,
    include_ablations: bool = False,
) -> dict[str, Any]:
    suite_path = Path(suite_path)
    suite_path, suite = prepare_suite(suite_path, output_dir, external_benchmark, locomo_options or {})
    dataset = external_suite_metadata(suite) if external_benchmark else {
        "format": "quipu.synthetic.scenario.v1",
        "benchmark": "synthetic",
        "datasetName": suite.name,
        "datasetVersion": suite.version,
        "source": "quipu",
        "license": "MIT",
        "tasks": list(suite.suites),
    }
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    if require_lattice and not include_lattice:
        raise RuntimeError("publishable LatticeDB run requires --include-lattice")
    lattice_available = include_lattice and bool(lattice_include) and bool(lattice_lib)
    if include_lattice and require_lattice and not lattice_available:
        raise RuntimeError("publishable LatticeDB run requires --lattice-include and --lattice-lib or LATTICE_* env vars")

    git_commit = current_git_commit()
    generated_at = now_iso()
    runs: list[dict[str, Any]] = []
    skipped_runs: list[dict[str, str]] = []

    runs.append(
        run_case(
            "q0_raw_only_fake",
            lambda: run_suite(suite_path, baseline_id="q0_raw_only_fake"),
            suite_path=suite_path,
            output_dir=output_dir,
            generated_at=generated_at,
            git_commit=git_commit,
            runner="quipu_evals.runner",
            storage="fake",
            config={
                "suite": str(suite_path),
                "baseline": "q0_raw_only_fake",
                "resultClass": result_class,
                "externalBenchmark": external_benchmark,
            },
            seed=seed,
            verification_status=verification_status,
        )
    )
    if include_baselines:
        for baseline_id in DETERMINISTIC_REQUIRED_BASELINES:
            runs.append(
                run_case(
                    baseline_id,
                    lambda baseline_id=baseline_id: run_suite(suite_path, baseline_id=baseline_id),
                    suite_path=suite_path,
                    output_dir=output_dir,
                    generated_at=generated_at,
                    git_commit=git_commit,
                    runner="quipu_evals.runner",
                    storage="deterministic",
                    config={
                        "suite": str(suite_path),
                        "baseline": baseline_id,
                        "resultClass": result_class,
                        "externalBenchmark": external_benchmark,
                    },
                    seed=seed,
                    verification_status=verification_status,
                )
            )
    if include_ablations:
        for ablation_id in DETERMINISTIC_ABLATIONS:
            runs.append(
                run_case(
                    f"ablation_{ablation_id}",
                    lambda ablation_id=ablation_id: run_suite(suite_path, baseline_id=ablation_id),
                    suite_path=suite_path,
                    output_dir=output_dir,
                    generated_at=generated_at,
                    git_commit=git_commit,
                    runner="quipu_evals.runner",
                    storage="deterministic",
                    config={
                        "suite": str(suite_path),
                        "ablation": ablation_id,
                        "resultClass": result_class,
                        "externalBenchmark": external_benchmark,
                    },
                    seed=seed,
                    verification_status=verification_status,
                )
            )
    core_available = shutil.which("zig") is not None
    if include_core and (core_available or require_core):
        runs.append(
            run_case(
                "core_in_memory",
                lambda: run_core_suite(suite_path, storage="memory"),
                suite_path=suite_path,
                output_dir=output_dir,
                generated_at=generated_at,
                git_commit=git_commit,
                runner="quipu_evals.core_runner",
                storage="memory",
                config={"suite": str(suite_path), "resultClass": result_class, "externalBenchmark": external_benchmark},
                seed=seed,
                verification_status=verification_status,
            )
        )
    elif include_core:
        skipped_runs.append({"name": "core_in_memory", "reason": "zig is not installed"})

    if lattice_available and (core_available or require_core):
        with tempfile.TemporaryDirectory(prefix="quipu-bench-lattice-") as db_dir:
            runs.append(
                run_case(
                    "core_lattice",
                    lambda: run_core_suite(
                        suite_path,
                        storage="lattice",
                        db_dir=Path(db_dir),
                        lattice_include=lattice_include,
                        lattice_lib=lattice_lib,
                    ),
                    suite_path=suite_path,
                    output_dir=output_dir,
                    generated_at=generated_at,
                    git_commit=git_commit,
                    runner="quipu_evals.core_runner",
                    storage="lattice",
                    config={
                        "suite": str(suite_path),
                        "resultClass": result_class,
                        "externalBenchmark": external_benchmark,
                        "latticeInclude": lattice_include,
                        "latticeLib": lattice_lib,
                    },
                    lattice_version=lattice_version(lattice_include, lattice_lib),
                    seed=seed,
                    verification_status=verification_status,
                )
            )
    elif include_lattice and not core_available:
        skipped_runs.append({"name": "core_lattice", "reason": "zig is not installed"})

    report_verification = aggregate_verification(runs, verification_status)
    report = {
        "schemaVersion": "quipu.benchmark.report.v1",
        "generatedAt": generated_at,
        "gitCommit": git_commit,
        "quipuVersion": "0.1.0",
        "resultClass": result_class,
        "externalBenchmark": external_benchmark,
        "dataset": dataset,
        "suite": str(suite_path),
        "latticeRequested": include_lattice,
        "latticeIncluded": any(run.get("storage") == "lattice" for run in runs),
        "verification": report_verification,
        "baselineRegistry": registry_json(),
        "ablations": ablation_summaries(runs),
        "traceArtifacts": [
            run.get("artifacts", {}).get("traces")
            for run in runs
            if isinstance(run.get("artifacts", {}), Mapping) and run.get("artifacts", {}).get("traces")
        ],
        "runs": runs,
        "skippedRuns": skipped_runs,
    }
    report["benchmarkReadiness"] = evaluate_readiness(report)
    return report


def ablation_summaries(runs: list[Mapping[str, Any]]) -> list[dict[str, Any]]:
    ablation_ids = set(DETERMINISTIC_ABLATIONS)
    summaries = []
    for run in runs:
        baseline = run.get("baseline")
        if baseline not in ablation_ids:
            continue
        summaries.append(
            {
                "id": baseline,
                "run": run.get("name"),
                "passed": run.get("passed"),
                "metrics": run.get("metrics", {}),
                "artifacts": run.get("artifacts", {}),
            }
        )
    return summaries


def prepare_suite(
    suite_path: Path,
    output_dir: str | Path,
    external_benchmark: str | None,
    locomo_options: Mapping[str, Any],
) -> tuple[Path, Any]:
    if external_benchmark != "locomo":
        return suite_path, load_suite(suite_path)
    if is_normalized_external_suite(suite_path):
        return suite_path, load_external_suite(suite_path, benchmark="locomo")

    suite = load_locomo_suite(
        suite_path,
        max_conversations=_optional_int(locomo_options.get("max_conversations")),
        max_questions_per_conversation=_optional_int(locomo_options.get("max_questions_per_conversation")),
        include_categories=locomo_options.get("include_categories"),
        include_event_summaries=bool(locomo_options.get("include_event_summaries", False)),
    )
    normalized_path = Path(output_dir) / "normalized-locomo-suite.json"
    write_suite(normalized_path, suite)
    return normalized_path, suite


def aggregate_verification(runs: list[Mapping[str, Any]], default: str) -> dict[str, Any]:
    verification_runs = [
        run.get("verification")
        for run in runs
        if isinstance(run.get("verification"), Mapping) and run.get("verification", {}).get("status") != "not_run"
    ]
    if verification_runs:
        passed = any(item.get("status") == "passed" for item in verification_runs if isinstance(item, Mapping))
        failed = any(item.get("status") == "failed" for item in verification_runs if isinstance(item, Mapping))
        if failed:
            status = "failed"
        elif passed:
            status = "passed"
        else:
            status = default
        return {"status": status, "runs": verification_runs}
    return {"status": default}


def run_case(
    slug: str,
    fn: Callable[[], Any],
    *,
    suite_path: Path,
    output_dir: Path,
    generated_at: str,
    git_commit: str | None,
    runner: str,
    storage: str,
    config: Mapping[str, Any],
    lattice_version: str | None = None,
    seed: int = 0,
    verification_status: str = "not_run",
) -> dict[str, Any]:
    started = time.perf_counter()
    run = fn()
    duration_ms = (time.perf_counter() - started) * 1000
    run_json = run.to_json()
    case_verification_status = _verification_status(run_json, verification_status)
    results_path = output_dir / f"{slug}-results.json"
    manifest_path = output_dir / f"{slug}-manifest.json"
    extra_artifacts: dict[str, str] = {}
    traces = trace_payload(run_json)
    if traces:
        trace_path = output_dir / f"{slug}-traces.json"
        write_json(trace_path, {"schemaVersion": "quipu.retrieval_traces.v1", "baseline": slug, "traces": traces})
        extra_artifacts["traces"] = str(trace_path)
    write_json(results_path, run_json)
    manifest = build_manifest(
        run_json,
        suite_path=suite_path,
        runner=runner,
        storage=storage,
        results_path=results_path,
        git_commit=git_commit,
        config=config,
        lattice_version=lattice_version,
        duration_ms=round(duration_ms, 3),
        seed=seed,
        verification_status=case_verification_status,
        extra_artifacts=extra_artifacts,
    )
    manifest["generatedAt"] = generated_at
    write_json(manifest_path, manifest)
    return {
        "name": slug,
        "baseline": run_json.get("baseline"),
        "storage": storage,
        "passed": run_json.get("passed"),
        "metrics": run_json.get("metrics", {}),
        "durationMs": round(duration_ms, 3),
        "latticeVersion": lattice_version,
        "verification": run_json.get("verification", {"status": case_verification_status}),
        "artifacts": {
            "results": str(results_path),
            "manifest": str(manifest_path),
            **extra_artifacts,
        },
    }


def trace_payload(run_json: Mapping[str, Any]) -> list[dict[str, Any]]:
    traces = []
    for query in run_json.get("queries", []):
        if not isinstance(query, Mapping):
            continue
        trace = query.get("trace")
        if isinstance(trace, Mapping):
            traces.append(
                {
                    "scenarioId": query.get("scenarioId"),
                    "queryId": query.get("queryId"),
                    "trace": trace,
                }
            )
    return traces


def _verification_status(run_json: Mapping[str, Any], default: str) -> str:
    verification = run_json.get("verification")
    if isinstance(verification, Mapping):
        status = verification.get("status")
        if isinstance(status, str):
            return status
    return default


def render_markdown(report: Mapping[str, Any]) -> str:
    result_class = str(report.get("resultClass") or "synthetic_smoke")
    external_benchmark = report.get("externalBenchmark")
    if result_class == "external_smoke":
        title = "External Smoke Benchmark Results"
        scope_description = [
            "These are Quipu external smoke benchmark results. They validate the",
            "dataset normalization, replay, retrieval, grading, and artifact path on",
            "a small fixture. They are not publishable external benchmark numbers.",
        ]
    elif external_benchmark:
        title = "External Benchmark Results"
        scope_description = [
            "These are Quipu external benchmark run artifacts. The readiness gate",
            "below determines whether the run is publishable; do not cite numbers as",
            "benchmark claims unless the gate status is ready.",
        ]
    else:
        title = "Benchmark Results"
        scope_description = [
            "These are Quipu synthetic smoke benchmark results. They are useful for",
            "tracking current correctness and basic runtime health, but they are not a",
            "claim of performance on external long-memory benchmarks yet.",
        ]
    dataset = report.get("dataset", {})
    lines = [
        f"# {title}",
        "",
        *scope_description,
        "",
        "Durations are local harness wall-clock timings, not optimized daemon latency.",
        "",
        f"- Generated: `{report.get('generatedAt')}`",
        f"- Git commit: `{report.get('gitCommit') or 'unknown'}`",
        f"- Result class: `{result_class}`",
        f"- External benchmark: `{report.get('externalBenchmark') or '-'}`",
        f"- Dataset: `{_mapping_get(dataset, 'datasetName', 'unknown')}` `{_mapping_get(dataset, 'datasetVersion', 'unknown')}`",
        f"- Suite: `{report.get('suite')}`",
        f"- Lattice included: `{str(report.get('latticeIncluded')).lower()}`",
        "",
        "| Baseline | Storage | Pass | Queries | Forget Ops | Duration | LatticeDB |",
        "| --- | --- | ---: | ---: | ---: | ---: | --- |",
    ]
    for run in report.get("runs", []):
        metrics = run.get("metrics", {})
        queries = f"{metrics.get('queriesPassed', 0)}/{metrics.get('queriesTotal', 0)}"
        forget = f"{metrics.get('forgetOpsPassed', 0)}/{metrics.get('forgetOpsTotal', 0)}"
        duration = f"{float(run.get('durationMs', 0.0)):.1f} ms"
        lattice = run.get("latticeVersion") or "-"
        passed = "yes" if run.get("passed") else "no"
        lines.append(
            f"| `{run.get('baseline')}` | `{run.get('storage')}` | {passed} | {queries} | {forget} | {duration} | `{lattice}` |"
        )
    skipped = report.get("skippedRuns", [])
    if skipped:
        lines.extend(["", "Skipped runs:"])
        for item in skipped:
            if isinstance(item, Mapping):
                lines.append(f"- `{item.get('name')}`: {item.get('reason')}")
    lines.extend(
        [
            "",
            "## Real Benchmark Readiness Gate",
            "",
            f"Status: `{report.get('benchmarkReadiness', {}).get('status', 'not_ready')}`",
            "",
            "| Requirement | Pass |",
            "| --- | ---: |",
        ]
    )
    for requirement in report.get("benchmarkReadiness", {}).get("requirements", []):
        passed = "yes" if requirement.get("passed") else "no"
        lines.append(f"| {requirement.get('name')} | {passed} |")
    lines.extend(
        [
            "",
            "## What This Covers",
            "",
            "- Temporal current and historical fact retrieval.",
            "- Cross-scope contamination checks.",
            "- Evidence ID faithfulness checks.",
            "- Preference supersession checks.",
            "- Forgetting leakage checks for deleted strings.",
            "",
            "## What This Does Not Cover Yet",
            "",
            "- Publishable LoCoMo, LongMemEval, or MemoryAgentBench results.",
            "- Real provider embeddings, reranking, or LLM extraction quality.",
            "- Long-running daemon transport latency.",
            "- Large-store retrieval latency or storage growth.",
            "",
        ]
    )
    return "\n".join(lines)


def _mapping_get(value: object, key: str, default: str) -> str:
    if isinstance(value, Mapping):
        result = value.get(key)
        if isinstance(result, str):
            return result
    return default


def _optional_int(value: object) -> int | None:
    if value is None:
        return None
    return int(value)


def current_git_commit() -> str | None:
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(ROOT),
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    commit = completed.stdout.strip()
    dirty = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=str(ROOT),
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return f"{commit}+dirty" if dirty.stdout.strip() else commit


def lattice_version(lattice_include: str | None, lattice_lib: str | None) -> str | None:
    if not lattice_include or not lattice_lib:
        return None
    env = os.environ.copy()
    env.setdefault("ZIG_GLOBAL_CACHE_DIR", "/tmp/quipu-zig-cache")
    subprocess.run(
        [
            "zig",
            "build",
            "-Denable-lattice=true",
            f"-Dlattice-include={lattice_include}",
            f"-Dlattice-lib={lattice_lib}",
        ],
        cwd=str(ROOT / "core"),
        check=True,
        env=env,
        stdout=subprocess.DEVNULL,
    )
    with tempfile.TemporaryDirectory(prefix="quipu-lattice-version-") as directory:
        db_path = Path(directory) / "version.lattice"
        completed = subprocess.run(
            [str(CORE_BINARY), "--db", str(db_path), "health"],
            cwd=str(ROOT),
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        )
    payload = json.loads(completed.stdout)
    result = payload.get("result", {})
    value = result.get("latticeVersion")
    return value if isinstance(value, str) else None


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("suite", nargs="?")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "artifacts" / "benchmarks")
    parser.add_argument("--report", type=Path, default=ROOT / "artifacts" / "benchmarks" / "report.json")
    parser.add_argument("--markdown", type=Path, help="Write a markdown summary report")
    parser.add_argument("--include-lattice", action="store_true")
    parser.add_argument("--lattice-include", default=os.environ.get("LATTICE_INCLUDE"))
    parser.add_argument("--lattice-lib", default=lattice_lib_from_env())
    parser.add_argument("--result-class", choices=["synthetic_smoke", "external_smoke", "publishable"])
    parser.add_argument("--external-benchmark", choices=sorted(DEFAULT_EXTERNAL_SUITES))
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--verification-status", default="not_run")
    parser.add_argument("--skip-core", action="store_true")
    parser.add_argument("--require-core", action="store_true")
    parser.add_argument("--require-lattice", action="store_true")
    parser.add_argument("--include-baselines", action="store_true")
    parser.add_argument("--include-ablations", action="store_true")
    parser.add_argument("--download-locomo", action="store_true")
    parser.add_argument("--dataset-cache", type=Path, default=Path(os.environ.get("QUIPU_DATASET_CACHE", ".quipu-datasets")))
    parser.add_argument("--locomo-max-conversations", type=int)
    parser.add_argument("--locomo-max-questions", type=int)
    parser.add_argument(
        "--locomo-categories",
        default="1,2,3,4,5",
        help="Comma-separated LoCoMo category numbers to include",
    )
    parser.add_argument("--locomo-event-summaries", action="store_true")
    parser.add_argument("--allow-failures", action="store_true")
    args = parser.parse_args()
    if args.download_locomo and args.external_benchmark != "locomo":
        parser.error("--download-locomo requires --external-benchmark locomo")
    result_class = args.result_class or ("external_smoke" if args.external_benchmark else "synthetic_smoke")
    downloaded_suite = download_locomo(args.dataset_cache) if args.download_locomo else None
    suite_path = (
        Path(args.suite)
        if args.suite
        else downloaded_suite
        if downloaded_suite is not None
        else DEFAULT_EXTERNAL_SUITES[args.external_benchmark]
        if args.external_benchmark
        else DEFAULT_SUITE
    )

    report = collect_benchmarks(
        suite_path,
        output_dir=args.output_dir,
        include_lattice=args.include_lattice,
        lattice_include=args.lattice_include,
        lattice_lib=args.lattice_lib,
        result_class=result_class,
        external_benchmark=args.external_benchmark,
        seed=args.seed,
        verification_status=args.verification_status,
        include_core=not args.skip_core,
        require_core=args.require_core or result_class == "publishable",
        require_lattice=args.require_lattice or result_class == "publishable",
        include_baselines=args.include_baselines or result_class == "publishable",
        include_ablations=args.include_ablations or result_class == "publishable",
        locomo_options={
            "max_conversations": args.locomo_max_conversations,
            "max_questions_per_conversation": args.locomo_max_questions,
            "include_categories": parse_category_list(args.locomo_categories),
            "include_event_summaries": args.locomo_event_summaries,
        },
    )
    write_json(args.report, report)
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(render_markdown(report))
    print(json.dumps(report, indent=2, sort_keys=True))
    if args.allow_failures or result_class == "publishable":
        return 0
    return 0 if all(run.get("passed") for run in report["runs"]) else 1


def parse_category_list(value: str) -> list[int]:
    categories = []
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        categories.append(int(item))
    return categories


if __name__ == "__main__":
    raise SystemExit(main())
