from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from typing import Any, Callable, Mapping

from .artifacts import build_manifest, write_json
from .core_runner import CORE_BINARY, lattice_lib_from_env, run_core_suite
from .runner import run_suite


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_SUITE = ROOT / "evals" / "suites" / "quipu_synthetic.yaml"


def collect_benchmarks(
    suite_path: str | Path = DEFAULT_SUITE,
    *,
    output_dir: str | Path = ROOT / "artifacts" / "benchmarks",
    include_lattice: bool = False,
    lattice_include: str | None = None,
    lattice_lib: str | None = None,
) -> dict[str, Any]:
    suite_path = Path(suite_path)
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    git_commit = current_git_commit()
    generated_at = now_iso()
    runs: list[dict[str, Any]] = []

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
            config={"suite": str(suite_path)},
        )
    )
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
            config={"suite": str(suite_path)},
        )
    )

    lattice_available = include_lattice and bool(lattice_include) and bool(lattice_lib)
    if lattice_available:
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
                        "latticeInclude": lattice_include,
                        "latticeLib": lattice_lib,
                    },
                    lattice_version=lattice_version(lattice_include, lattice_lib),
                )
            )

    return {
        "schemaVersion": "quipu.benchmark.report.v1",
        "generatedAt": generated_at,
        "gitCommit": git_commit,
        "suite": str(suite_path),
        "latticeRequested": include_lattice,
        "latticeIncluded": lattice_available,
        "runs": runs,
    }


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
    lines = [
        "# Benchmark Results",
        "",
        "These are Quipu synthetic smoke benchmark results. They are useful for",
        "tracking current correctness and basic runtime health, but they are not a",
        "claim of performance on external long-memory benchmarks yet.",
        "",
        "Durations are local harness wall-clock timings, not optimized daemon latency.",
        "",
        f"- Generated: `{report.get('generatedAt')}`",
        f"- Git commit: `{report.get('gitCommit') or 'unknown'}`",
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
            "- LoCoMo, LongMemEval, or MemoryAgentBench.",
            "- Real provider embeddings, reranking, or LLM extraction quality.",
            "- Long-running daemon transport latency.",
            "- Large-store retrieval latency or storage growth.",
            "",
        ]
    )
    return "\n".join(lines)


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
    parser.add_argument("suite", nargs="?", default=str(DEFAULT_SUITE))
    parser.add_argument("--output-dir", type=Path, default=ROOT / "artifacts" / "benchmarks")
    parser.add_argument("--report", type=Path, default=ROOT / "artifacts" / "benchmarks" / "report.json")
    parser.add_argument("--markdown", type=Path, help="Write a markdown summary report")
    parser.add_argument("--include-lattice", action="store_true")
    parser.add_argument("--lattice-include", default=os.environ.get("LATTICE_INCLUDE"))
    parser.add_argument("--lattice-lib", default=lattice_lib_from_env())
    args = parser.parse_args()

    report = collect_benchmarks(
        args.suite,
        output_dir=args.output_dir,
        include_lattice=args.include_lattice,
        lattice_include=args.lattice_include,
        lattice_lib=args.lattice_lib,
    )
    write_json(args.report, report)
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(render_markdown(report))
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if all(run.get("passed") for run in report["runs"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
