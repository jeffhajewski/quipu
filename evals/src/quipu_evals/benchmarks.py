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
from .baselines import registry_json
from .core_runner import CORE_BINARY, lattice_lib_from_env, run_core_suite
from .external import DEFAULT_EXTERNAL_SUITES, external_suite_metadata, load_external_suite
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
) -> dict[str, Any]:
    suite_path = Path(suite_path)
    suite = (
        load_external_suite(suite_path, benchmark=external_benchmark)
        if external_benchmark
        else load_suite(suite_path)
    )
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

    git_commit = current_git_commit()
    generated_at = now_iso()
    runs: list[dict[str, Any]] = []
    skipped_runs: list[dict[str, str]] = []

    runs.append(
        run_case(
            "q0_raw_only_fake",
            lambda: run_suite(suite_path),
            suite_path=suite_path,
            output_dir=output_dir,
            generated_at=generated_at,
            git_commit=git_commit,
            runner="quipu_evals.runner",
            storage="fake",
            config={"suite": str(suite_path), "resultClass": result_class, "externalBenchmark": external_benchmark},
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

    lattice_available = include_lattice and bool(lattice_include) and bool(lattice_lib)
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
        "verification": {"status": verification_status},
        "baselineRegistry": registry_json(),
        "runs": runs,
        "skippedRuns": skipped_runs,
    }
    report["benchmarkReadiness"] = evaluate_readiness(report)
    return report


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
    results_path = output_dir / f"{slug}-results.json"
    manifest_path = output_dir / f"{slug}-manifest.json"
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
        verification_status=verification_status,
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
        "artifacts": {
            "results": str(results_path),
            "manifest": str(manifest_path),
        },
    }


def render_markdown(report: Mapping[str, Any]) -> str:
    result_class = str(report.get("resultClass") or "synthetic_smoke")
    title = "External Smoke Benchmark Results" if result_class == "external_smoke" else "Benchmark Results"
    scope_description = (
        [
            "These are Quipu external smoke benchmark results. They validate the",
            "dataset normalization, replay, retrieval, grading, and artifact path on",
            "a small fixture. They are not publishable external benchmark numbers.",
        ]
        if result_class == "external_smoke"
        else [
            "These are Quipu synthetic smoke benchmark results. They are useful for",
            "tracking current correctness and basic runtime health, but they are not a",
            "claim of performance on external long-memory benchmarks yet.",
        ]
    )
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
    args = parser.parse_args()
    result_class = args.result_class or ("external_smoke" if args.external_benchmark else "synthetic_smoke")
    suite_path = (
        Path(args.suite)
        if args.suite
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
    )
    write_json(args.report, report)
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(render_markdown(report))
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if all(run.get("passed") for run in report["runs"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
