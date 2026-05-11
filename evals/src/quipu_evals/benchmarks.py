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
from .comparisons import published_results
from .core_runner import CORE_BINARY, lattice_lib_from_env, run_core_suite
from .external import DEFAULT_EXTERNAL_SUITES, external_suite_metadata, is_normalized_external_suite, load_external_suite
from .locomo import download_locomo, load_locomo_suite, write_suite
from .longmemeval import download_longmemeval, load_longmemeval_suite
from .provider_clients import ProviderError, openrouter_providers_from_env, supported_llm_provider_ids
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
    longmemeval_options: Mapping[str, Any] | None = None,
    require_lattice: bool = False,
    include_baselines: bool = False,
    include_ablations: bool = False,
    include_provider_baselines: bool = False,
    provider_options: Mapping[str, Any] | None = None,
    core_retrieval_mode: str | None = None,
    core_answer_method: str = "retrieve",
    core_answer_provider: str | None = None,
    core_answer_model: str | None = None,
    core_answer_url: str | None = None,
    core_entity_provider: str | None = None,
    core_entity_model: str | None = None,
    core_entity_url: str | None = None,
    core_embedding_provider: str | None = None,
    core_embedding_model: str | None = None,
    core_embedding_url: str | None = None,
    core_vector_dimensions: int | None = None,
    core_page_size: int | None = None,
    enable_entity_resolution: bool = False,
    core_budget_tokens: int | None = None,
    core_answer_abstain_if_weak: bool = False,
    judge_provider: str | None = None,
    judge_model: str | None = None,
    judge_cache_path: str | Path | None = None,
    reuse_existing: bool = False,
    allow_weak_judge: bool = False,
) -> dict[str, Any]:
    suite_path = Path(suite_path)
    output_dir = Path(output_dir)
    suite_path, suite = prepare_suite(
        suite_path,
        output_dir,
        external_benchmark,
        locomo_options or {},
        longmemeval_options or {},
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
    provider_options = provider_options or {}
    resolved_judge_cache_path = (
        Path(judge_cache_path)
        if judge_cache_path is not None
        else None
        if os.environ.get("QUIPU_DISABLE_JUDGE_CACHE")
        else output_dir / ".judge_cache.jsonl"
    )
    judge_client = None
    resolved_judge_provider = judge_provider or "none"
    resolved_judge_model = resolve_judge_model_for_guard(judge_provider, judge_model)
    validate_publishable_judge(
        result_class=result_class,
        judge_provider=resolved_judge_provider,
        judge_model=resolved_judge_model,
        allow_weak_judge=allow_weak_judge,
    )
    if judge_provider and judge_provider != "none":
        from .provider_clients import LlmClient
        judge_client = LlmClient(judge_provider, judge_model=judge_model, judge_cache_path=resolved_judge_cache_path)
        resolved_judge_model = str(judge_client.settings.judge_model)
    judge_provider_for_label = resolved_judge_provider if judge_client is not None else None
    common_config = benchmark_run_config(
        suite_path=suite_path,
        result_class=result_class,
        external_benchmark=external_benchmark,
        judge_provider=resolved_judge_provider,
        judge_model=resolved_judge_model,
        core_retrieval_mode=core_retrieval_mode,
        core_answer_method=core_answer_method,
        core_answer_provider=core_answer_provider,
        core_answer_model=core_answer_model,
        core_entity_provider=core_entity_provider,
        core_entity_model=core_entity_model,
        core_embedding_provider=core_embedding_provider,
        core_embedding_model=core_embedding_model,
        core_vector_dimensions=core_vector_dimensions,
        core_budget_tokens=core_budget_tokens,
        core_answer_abstain_if_weak=core_answer_abstain_if_weak,
    )
    deterministic_providers = deterministic_provider_names(
        judge_provider=judge_provider_for_label,
        judge_model=resolved_judge_model,
    )

    runs.append(
        run_case(
            "q0_raw_only_fake",
            lambda: run_suite(suite_path, baseline_id="q0_raw_only_fake", judge_provider=judge_client),
            suite_path=suite_path,
            output_dir=output_dir,
            generated_at=generated_at,
            git_commit=git_commit,
            runner="quipu_evals.runner",
            storage="fake",
            config={
                **common_config,
                "baseline": "q0_raw_only_fake",
            },
            providers=deterministic_providers,
            seed=seed,
            verification_status=verification_status,
            reuse_existing=reuse_existing,
        )
    )
    if include_baselines:
        for baseline_id in DETERMINISTIC_REQUIRED_BASELINES:
            runs.append(
                run_case(
                    baseline_id,
                    lambda baseline_id=baseline_id: run_suite(suite_path, baseline_id=baseline_id, judge_provider=judge_client),
                    suite_path=suite_path,
                    output_dir=output_dir,
                    generated_at=generated_at,
                    git_commit=git_commit,
                    runner="quipu_evals.runner",
                    storage="deterministic",
                    config={
                        **common_config,
                        "baseline": baseline_id,
                    },
                    providers=deterministic_providers,
                    seed=seed,
                    verification_status=verification_status,
                    reuse_existing=reuse_existing,
                )
            )
    if include_provider_baselines:
        try:
            openrouter_embedding_provider, openrouter_client = openrouter_providers_from_env(
                cache_path=provider_options.get("embedding_cache")
            )
        except ProviderError as exc:
            skipped_runs.append({"name": "openrouter_provider_baselines", "reason": str(exc)})
        else:
            openrouter_provider_names = {
                "extractor": "deterministic_fixture",
                "embedder": f"openrouter:{openrouter_client.settings.embedding_model}",
                "reranker": "none",
                "answer": "deterministic_prompt_match",
                "judge": provider_label(judge_provider_for_label, resolved_judge_model, default="rule_based"),
                "entityResolver": provider_label(core_entity_provider, core_entity_model, default="none"),
            }
            for baseline_id in ("vector_rag", "hybrid_bm25_vector"):
                baseline_label = f"openrouter_{baseline_id}"
                runs.append(
                    run_case(
                        baseline_label,
                        lambda baseline_id=baseline_id, baseline_label=baseline_label: run_suite(
                            suite_path,
                            baseline_id=baseline_id,
                            baseline_label=baseline_label,
                            embedding_provider=openrouter_embedding_provider,
                            judge_provider=judge_client,
                        ),
                        suite_path=suite_path,
                        output_dir=output_dir,
                        generated_at=generated_at,
                        git_commit=git_commit,
                        runner="quipu_evals.runner",
                        storage="provider",
                        config={
                            **common_config,
                            "baseline": baseline_id,
                            "baselineLabel": baseline_label,
                            "embeddingProvider": "openrouter",
                            "embeddingModel": openrouter_client.settings.embedding_model,
                        },
                        providers=openrouter_provider_names,
                        seed=seed,
                        verification_status=verification_status,
                        reuse_existing=reuse_existing,
                    )
                )
    if include_ablations:
        for ablation_id in DETERMINISTIC_ABLATIONS:
            runs.append(
                run_case(
                    f"ablation_{ablation_id}",
                    lambda ablation_id=ablation_id: run_suite(suite_path, baseline_id=ablation_id, judge_provider=judge_client),
                    suite_path=suite_path,
                    output_dir=output_dir,
                    generated_at=generated_at,
                    git_commit=git_commit,
                    runner="quipu_evals.runner",
                    storage="deterministic",
                    config={
                        **common_config,
                        "ablation": ablation_id,
                    },
                    providers=deterministic_providers,
                    seed=seed,
                    verification_status=verification_status,
                    reuse_existing=reuse_existing,
                )
            )
    core_available = shutil.which("zig") is not None
    if include_core and (core_available or require_core):
        runs.append(
            run_case(
                "core_in_memory",
                lambda: run_core_suite(
                    suite_path,
                    storage="memory",
                    scenario_artifact_dir=output_dir / "core_in_memory-scenarios",
                    reuse_existing=reuse_existing,
                    retrieval_mode=core_retrieval_mode,
                    answer_method=core_answer_method,
                    answer_provider=core_answer_provider,
                    answer_model=core_answer_model,
                    answer_url=core_answer_url,
                    entity_provider=core_entity_provider if enable_entity_resolution else None,
                    entity_model=core_entity_model if enable_entity_resolution else None,
                    entity_url=core_entity_url if enable_entity_resolution else None,
                    embedding_provider=core_embedding_provider,
                    embedding_model=core_embedding_model,
                    embedding_url=core_embedding_url,
                    vector_dimensions=core_vector_dimensions,
                    page_size=core_page_size,
                    budget_tokens=core_budget_tokens,
                    answer_abstain_if_weak=core_answer_abstain_if_weak,
                    judge_provider=judge_client,
                ),
                suite_path=suite_path,
                output_dir=output_dir,
                generated_at=generated_at,
                git_commit=git_commit,
                runner="quipu_evals.core_runner",
                storage="memory",
                config={
                    **common_config,
                    "entityProvider": core_entity_provider if enable_entity_resolution else None,
                    **(
                        {}
                        if enable_entity_resolution
                        else {"entityProviderNote": "async entity resolution disabled for in-memory core storage"}
                    ),
                    "entityModel": core_entity_model if enable_entity_resolution else None,
                    "pageSize": core_page_size,
                },
                providers=core_provider_names(
                    answer_provider=core_answer_provider,
                    answer_model=core_answer_model,
                    entity_provider=core_entity_provider if enable_entity_resolution else None,
                    entity_model=core_entity_model if enable_entity_resolution else None,
                    embedding_provider=core_embedding_provider,
                    embedding_model=core_embedding_model,
                    judge_provider=judge_provider_for_label,
                    judge_model=resolved_judge_model,
                ),
                seed=seed,
                verification_status=verification_status,
                reuse_existing=reuse_existing,
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
                        scenario_artifact_dir=output_dir / "core_lattice-scenarios",
                        reuse_existing=reuse_existing,
                        retrieval_mode=core_retrieval_mode,
                        answer_method=core_answer_method,
                        answer_provider=core_answer_provider,
                        answer_model=core_answer_model,
                        answer_url=core_answer_url,
                        entity_provider=core_entity_provider,
                        entity_model=core_entity_model,
                        entity_url=core_entity_url,
                        embedding_provider=core_embedding_provider,
                        embedding_model=core_embedding_model,
                        embedding_url=core_embedding_url,
                        vector_dimensions=core_vector_dimensions,
                        page_size=core_page_size,
                        budget_tokens=core_budget_tokens,
                        answer_abstain_if_weak=core_answer_abstain_if_weak,
                        judge_provider=judge_client,
                    ),
                    suite_path=suite_path,
                    output_dir=output_dir,
                    generated_at=generated_at,
                    git_commit=git_commit,
                    runner="quipu_evals.core_runner",
                    storage="lattice",
                    config={
                        **common_config,
                        "latticeInclude": lattice_include,
                        "latticeLib": lattice_lib,
                        "entityProvider": core_entity_provider,
                        "entityModel": core_entity_model,
                        "pageSize": core_page_size,
                    },
                    lattice_version=lattice_version(lattice_include, lattice_lib),
                    seed=seed,
                    verification_status=verification_status,
                    reuse_existing=reuse_existing,
                    core_reuse_existing=reuse_existing,
                    providers=core_provider_names(
                        answer_provider=core_answer_provider,
                        answer_model=core_answer_model,
                        entity_provider=core_entity_provider,
                        entity_model=core_entity_model,
                        embedding_provider=core_embedding_provider,
                        embedding_model=core_embedding_model,
                        judge_provider=judge_provider_for_label,
                        judge_model=resolved_judge_model,
                    ),
                )
            )
    elif include_lattice and not core_available:
        skipped_runs.append({"name": "core_lattice", "reason": "zig is not installed"})

    retrieval_mode_summary = apply_retrieval_mode_assertions(runs, output_dir)
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
        "retrievalModePassed": retrieval_mode_summary["passed"],
        "retrievalModeWarnings": retrieval_mode_summary["warnings"],
        "verification": report_verification,
        "baselineRegistry": registry_json(),
        "ablations": ablation_summaries(runs),
        "publishedComparisons": published_results(external_benchmark),
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


def benchmark_run_config(
    *,
    suite_path: Path,
    result_class: str,
    external_benchmark: str | None,
    judge_provider: str,
    judge_model: str | None,
    core_retrieval_mode: str | None,
    core_answer_method: str,
    core_answer_provider: str | None,
    core_answer_model: str | None,
    core_entity_provider: str | None,
    core_entity_model: str | None,
    core_embedding_provider: str | None,
    core_embedding_model: str | None,
    core_vector_dimensions: int | None,
    core_budget_tokens: int | None,
    core_answer_abstain_if_weak: bool,
) -> dict[str, Any]:
    return {
        "suite": str(suite_path),
        "resultClass": result_class,
        "externalBenchmark": external_benchmark,
        "judgeProvider": judge_provider,
        "judgeModel": judge_model,
        "budgetTokens": core_budget_tokens,
        "answerMethod": core_answer_method,
        "answerProvider": core_answer_provider,
        "answerModel": core_answer_model,
        "answerAbstainIfWeak": core_answer_abstain_if_weak,
        "embeddingProvider": core_embedding_provider,
        "embeddingModel": core_embedding_model,
        "vectorDimensions": core_vector_dimensions,
        "retrievalMode": core_retrieval_mode,
        "entityProvider": core_entity_provider,
        "entityModel": core_entity_model,
    }


def validate_publishable_judge(
    *,
    result_class: str,
    judge_provider: str,
    judge_model: str | None,
    allow_weak_judge: bool,
) -> None:
    if result_class != "publishable" or allow_weak_judge:
        return
    if judge_provider == "none":
        raise ValueError("Publishable runs require an LLM judge. Pass --judge-provider or --allow-weak-judge.")
    model = judge_model or "unknown"
    if is_weak_publishable_judge_model(model):
        raise ValueError(f"Publishable runs require judge model gpt-4o or stronger, got: {model}")


def resolve_judge_model_for_guard(judge_provider: str | None, judge_model: str | None) -> str | None:
    if judge_model:
        return judge_model
    if not judge_provider or judge_provider == "none":
        return None
    from .provider_clients import PROVIDER_PROFILES

    profile = PROVIDER_PROFILES.get(judge_provider)
    prefix = (profile.provider if profile is not None else judge_provider).upper()
    return (
        os.environ.get("QUIPU_JUDGE_MODEL")
        or os.environ.get(f"{prefix}_JUDGE_MODEL")
        or os.environ.get(f"{prefix}_MODEL")
        or (profile.judge_model if profile is not None else None)
    )


def is_weak_publishable_judge_model(model: str | None) -> bool:
    if model is None:
        return False
    return "gpt-4o-mini" in model.lower()


def deterministic_provider_names(
    *,
    judge_provider: str | None = None,
    judge_model: str | None = None,
) -> dict[str, str]:
    return {
        "extractor": "deterministic_fixture",
        "embedder": "deterministic_fixture",
        "reranker": "none",
        "answer": "deterministic_prompt_match",
        "judge": provider_label(judge_provider, judge_model, default="rule_based"),
        "entityResolver": "none",
    }


def core_provider_names(
    *,
    answer_provider: str | None = None,
    answer_model: str | None = None,
    entity_provider: str | None = None,
    entity_model: str | None = None,
    embedding_provider: str | None = None,
    embedding_model: str | None = None,
    judge_provider: str | None = None,
    judge_model: str | None = None,
) -> dict[str, str]:
    return {
        "extractor": "deterministic_fixture",
        "embedder": provider_label(embedding_provider, embedding_model, default="deterministic_fixture"),
        "reranker": "none",
        "answer": provider_label(answer_provider, answer_model, default="deterministic_prompt_match"),
        "judge": provider_label(judge_provider, judge_model, default="rule_based"),
        "entityResolver": provider_label(entity_provider, entity_model, default="none"),
    }


def provider_label(provider: str | None, model: str | None, *, default: str) -> str:
    if not provider:
        return default
    if model:
        return f"{provider}:{model}"
    return provider


def prepare_suite(
    suite_path: Path,
    output_dir: str | Path,
    external_benchmark: str | None,
    locomo_options: Mapping[str, Any],
    longmemeval_options: Mapping[str, Any],
) -> tuple[Path, Any]:
    if external_benchmark is None:
        return suite_path, load_suite(suite_path)
    if external_benchmark == "locomo":
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
    if external_benchmark == "longmemeval":
        if is_normalized_external_suite(suite_path):
            return suite_path, load_external_suite(suite_path, benchmark="longmemeval")

        suite = load_longmemeval_suite(
            suite_path,
            variant=str(longmemeval_options.get("variant") or "oracle"),
            max_conversations=_optional_int(longmemeval_options.get("max_conversations")),
            max_sessions_per_conversation=_optional_int(longmemeval_options.get("max_sessions_per_conversation")),
            include_question_types=longmemeval_options.get("include_question_types"),
        )
        normalized_path = Path(output_dir) / "normalized-longmemeval-suite.json"
        write_suite(normalized_path, suite)
        return normalized_path, suite
    return suite_path, load_external_suite(suite_path, benchmark=external_benchmark)


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


def apply_retrieval_mode_assertions(runs: list[dict[str, Any]], output_dir: Path) -> dict[str, Any]:
    failing_runs = []
    for run in runs:
        assertion = retrieval_mode_assertion(run, output_dir)
        run["retrievalModeAssertion"] = assertion
        if not assertion.get("passed", False):
            failing_runs.append(str(run.get("name") or run.get("baseline") or "unknown"))
    return {"passed": not failing_runs, "warnings": failing_runs}


def retrieval_mode_assertion(run: Mapping[str, Any], output_dir: Path) -> dict[str, Any]:
    run_name = str(run.get("name") or run.get("baseline") or "unknown")
    if run.get("storage") not in {"memory", "lattice"}:
        return {"passed": True, "message": "not applicable: non-core run"}

    config = run_manifest_config(run, output_dir)
    mode = str(config.get("retrievalMode") or "").lower()
    if mode not in {"graph", "hybrid"}:
        mode_label = mode or "default"
        return {"passed": True, "message": f"not applicable: retrievalMode is {mode_label}"}

    stats = inspect_retrieval_traces(run, output_dir)
    inspected = stats["inspected"]
    classified = stats["classified"]
    fts_only = stats["fts_only"]
    if inspected == 0:
        return {
            "passed": False,
            "message": f"retrievalMode {mode} could not be verified for {run_name}: no trace-bearing artifacts found",
        }
    if classified == 0:
        return {
            "passed": False,
            "message": (
                f"retrievalMode {mode} could not be verified for {run_name}: "
                f"{inspected} inspected trace(s) had no candidateSources"
            ),
        }
    if fts_only == classified:
        return {
            "passed": False,
            "message": (
                f"retrievalMode {mode} failed for {run_name}: "
                f"all {classified} classified trace(s) were FTS-only"
            ),
        }
    return {
        "passed": True,
        "message": (
            f"retrievalMode {mode} verified for {run_name}: "
            f"{classified - fts_only}/{classified} classified trace(s) were not FTS-only"
        ),
    }


def run_manifest_config(run: Mapping[str, Any], output_dir: Path) -> dict[str, Any]:
    run_config = run.get("config")
    config_payload = dict(run_config) if isinstance(run_config, Mapping) else {}
    artifacts = run.get("artifacts", {})
    if isinstance(artifacts, Mapping):
        manifest_ref = artifacts.get("manifest")
        if isinstance(manifest_ref, str):
            manifest_path = artifact_path(manifest_ref, output_dir)
            if manifest_path.exists():
                try:
                    manifest = json.loads(manifest_path.read_text())
                except json.JSONDecodeError:
                    manifest = {}
                config = manifest.get("config") if isinstance(manifest, Mapping) else None
                if isinstance(config, Mapping):
                    config_payload.update(dict(config))
                    return config_payload
    return config_payload


def inspect_retrieval_traces(run: Mapping[str, Any], output_dir: Path) -> dict[str, int]:
    stats = {"inspected": 0, "classified": 0, "fts_only": 0}
    for payload in retrieval_trace_payloads(run, output_dir):
        for trace in traces_from_payload(payload):
            stats["inspected"] += 1
            sources = trace.get("candidateSources")
            if not isinstance(sources, Mapping):
                continue
            stats["classified"] += 1
            if is_fts_only_trace_sources(sources):
                stats["fts_only"] += 1
    return stats


def retrieval_trace_payloads(run: Mapping[str, Any], output_dir: Path) -> list[Mapping[str, Any]]:
    payloads: list[Mapping[str, Any]] = []
    for directory in scenario_artifact_dirs(run, output_dir):
        if not directory.exists() or not directory.is_dir():
            continue
        for path in sorted(directory.glob("*.json")):
            payload = load_json_mapping(path)
            if payload is not None:
                payloads.append(payload)
        if payloads:
            return payloads

    artifacts = run.get("artifacts", {})
    if isinstance(artifacts, Mapping):
        for key in ("results", "traces"):
            value = artifacts.get(key)
            if not isinstance(value, str):
                continue
            payload = load_json_mapping(artifact_path(value, output_dir))
            if payload is not None:
                payloads.append(payload)
            if payloads:
                return payloads
    return payloads


def scenario_artifact_dirs(run: Mapping[str, Any], output_dir: Path) -> list[Path]:
    directories = []
    run_name = str(run.get("name") or "")
    if run_name:
        directories.append(output_dir / f"{run_name}-scenarios")

    artifacts = run.get("artifacts", {})
    if isinstance(artifacts, Mapping):
        for key in ("scenarioArtifacts", "scenarioArtifactsDir", "scenarios"):
            value = artifacts.get(key)
            if isinstance(value, str):
                directories.append(artifact_path(value, output_dir))

    if run_name == "core_lattice":
        directories.append(output_dir / "scenarios")
    return dedupe_paths(directories)


def traces_from_payload(payload: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    traces = []
    for query in payload.get("queries", []):
        if not isinstance(query, Mapping):
            continue
        trace = query.get("trace")
        if isinstance(trace, Mapping):
            traces.append(trace)
    for item in payload.get("traces", []):
        if not isinstance(item, Mapping):
            continue
        trace = item.get("trace")
        if isinstance(trace, Mapping):
            traces.append(trace)
    return traces


def is_fts_only_trace_sources(sources: Mapping[str, Any]) -> bool:
    return (
        int(sources.get("fts") or 0) > 0
        and int(sources.get("vector") or 0) == 0
        and int(sources.get("graph") or 0) == 0
    )


def load_json_mapping(path: Path) -> Mapping[str, Any] | None:
    if not path.exists() or not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text())
    except json.JSONDecodeError:
        return None
    return payload if isinstance(payload, Mapping) else None


def artifact_path(value: str, output_dir: Path) -> Path:
    path = Path(value)
    if path.is_absolute() or path.exists():
        return path
    root_path = ROOT / path
    if root_path.exists():
        return root_path
    return output_dir / path.name


def dedupe_paths(paths: list[Path]) -> list[Path]:
    seen = set()
    result = []
    for path in paths:
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        result.append(path)
    return result


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
    reuse_existing: bool = False,
    core_reuse_existing: bool = False,
    providers: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    results_path = output_dir / f"{slug}-results.json"
    manifest_path = output_dir / f"{slug}-manifest.json"
    if reuse_existing and not core_reuse_existing and results_path.exists() and manifest_path.exists():
        return load_existing_case(
            slug,
            results_path=results_path,
            manifest_path=manifest_path,
            storage=storage,
            config=config,
        )
    started = time.perf_counter()
    run = fn()
    duration_ms = (time.perf_counter() - started) * 1000
    run_json = run.to_json()
    case_verification_status = _verification_status(run_json, verification_status)
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
        providers=providers,
    )
    manifest["generatedAt"] = generated_at
    write_json(manifest_path, manifest)
    return {
        "name": slug,
        "baseline": run_json.get("baseline"),
        "storage": storage,
        "passed": run_json.get("passed"),
        "metrics": run_json.get("metrics", {}),
        "config": dict(config),
        "providers": dict(providers or {}),
        "durationMs": round(duration_ms, 3),
        "latticeVersion": lattice_version,
        "verification": run_json.get("verification", {"status": case_verification_status}),
        "artifacts": {
            "results": str(results_path),
            "manifest": str(manifest_path),
            **extra_artifacts,
        },
    }


def load_existing_case(
    slug: str,
    *,
    results_path: Path,
    manifest_path: Path,
    storage: str,
    config: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    run_json = json.loads(results_path.read_text())
    manifest = json.loads(manifest_path.read_text())
    artifacts = manifest.get("artifacts", {})
    if not isinstance(artifacts, Mapping):
        artifacts = {}
    manifest_config = manifest.get("config")
    config_payload = dict(config or {})
    if isinstance(manifest_config, Mapping):
        config_payload.update(dict(manifest_config))
    manifest_providers = manifest.get("providers")
    artifact_payload = {
        "results": str(results_path),
        "manifest": str(manifest_path),
        **{key: value for key, value in artifacts.items() if isinstance(key, str) and isinstance(value, str)},
    }
    return {
        "name": slug,
        "baseline": run_json.get("baseline"),
        "storage": str(manifest.get("storage") or storage),
        "passed": run_json.get("passed"),
        "metrics": run_json.get("metrics", {}),
        "config": config_payload,
        "providers": dict(manifest_providers) if isinstance(manifest_providers, Mapping) else {},
        "durationMs": float(manifest.get("durationMs") or 0.0),
        "latticeVersion": manifest.get("latticeVersion"),
        "verification": run_json.get("verification", {"status": manifest.get("verification", {}).get("status", "not_run")}),
        "artifacts": artifact_payload,
        "reused": True,
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
    ]
    methodology_lines = _render_methodology(report) if external_benchmark else []
    if methodology_lines:
        lines.extend(["", "## Methodology", "", *methodology_lines])
    lines.extend(
        [
            "",
        "| Baseline | Storage | Pass | Queries | Forget Ops | Duration | LatticeDB |",
        "| --- | --- | ---: | ---: | ---: | ---: | --- |",
        ]
    )
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
    retrieval_assertion_lines = _render_retrieval_mode_assertions(report)
    if retrieval_assertion_lines:
        lines.extend(["", *retrieval_assertion_lines])
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
    comparison_lines = _render_published_comparisons(report.get("publishedComparisons", []))
    if comparison_lines:
        lines.extend(["", *comparison_lines])
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
            *_not_covered_lines(report),
            "",
        ]
    )
    return "\n".join(lines)


def _render_methodology(report: Mapping[str, Any]) -> list[str]:
    config = _methodology_config(report)
    if not config:
        return []
    retrieval_mode = _display_value(config.get("retrievalMode"), default="default")
    budget = _display_value(config.get("budgetTokens"))
    dimensions = _display_value(config.get("vectorDimensions"))
    lines = [
        f"- Retrieval mode / budget: `{retrieval_mode}` / `{budget}`",
        (
            "- Answer method / provider / model: "
            f"`{_display_value(config.get('answerMethod'))}` / "
            f"`{_display_value(config.get('answerProvider'))}` / "
            f"`{_display_value(config.get('answerModel'))}`"
        ),
        (
            "- Judge provider / model: "
            f"`{_display_value(config.get('judgeProvider'), default='none')}` / "
            f"`{_display_value(config.get('judgeModel'))}`"
        ),
        (
            "- Embedding provider / model / dimensions: "
            f"`{_display_value(config.get('embeddingProvider'))}` / "
            f"`{_display_value(config.get('embeddingModel'))}` / "
            f"`{dimensions}`"
        ),
    ]
    entity_provider = config.get("entityProvider")
    if entity_provider:
        lines.append(f"- Entity provider: `{entity_provider}`")
    return lines


def _methodology_config(report: Mapping[str, Any]) -> dict[str, Any]:
    configs = []
    core_configs = []
    for run in report.get("runs", []):
        if not isinstance(run, Mapping):
            continue
        config = run.get("config")
        if not isinstance(config, Mapping):
            continue
        config_dict = dict(config)
        configs.append(config_dict)
        if run.get("storage") in {"memory", "lattice"}:
            core_configs.append(config_dict)
    for config in core_configs:
        if config.get("entityProvider"):
            return config
    if core_configs:
        return core_configs[0]
    return configs[0] if configs else {}


def _render_retrieval_mode_assertions(report: Mapping[str, Any]) -> list[str]:
    if "retrievalModePassed" not in report:
        return []
    passed = bool(report.get("retrievalModePassed"))
    warnings = [str(item) for item in report.get("retrievalModeWarnings", []) if isinstance(item, str)]
    lines = [
        "## Retrieval Mode Assertions",
        "",
        f"Status: `{'passed' if passed else 'failed'}`",
    ]
    if not warnings:
        lines.append("")
        lines.append("No retrieval-mode warnings.")
        return lines

    lines.extend(
        [
            "",
            f"Failing runs: {', '.join(f'`{item}`' for item in warnings)}",
            "",
            "| Run | Message |",
            "| --- | --- |",
        ]
    )
    warning_set = set(warnings)
    for run in report.get("runs", []):
        if not isinstance(run, Mapping):
            continue
        name = str(run.get("name") or run.get("baseline") or "unknown")
        if name not in warning_set:
            continue
        assertion = run.get("retrievalModeAssertion")
        message = assertion.get("message") if isinstance(assertion, Mapping) else ""
        lines.append(f"| `{name}` | {_table_cell(message)} |")
    return lines


def _display_value(value: object, *, default: str = "-") -> str:
    if value is None or value == "":
        return default
    return str(value)


def _render_published_comparisons(comparisons: object) -> list[str]:
    if not isinstance(comparisons, list) or not comparisons:
        return []
    rows = [item for item in comparisons if isinstance(item, Mapping)]
    rows.sort(key=lambda item: float(item.get("score", 0.0)), reverse=True)
    lines = [
        "## Published External Reference Points",
        "",
        "These are published external results from other systems. They use different answer models, judges, retrieval cutoffs, dataset slices, and sometimes disputed methodologies; use them as orientation, not an apples-to-apples ranking unless the full methodology is aligned.",
        "",
        "| System | Benchmark | Score | Metric | Dataset | Source |",
        "| --- | --- | ---: | --- | --- | --- |",
    ]
    for item in rows:
        source = _markdown_link(str(item.get("source") or "source"), str(item.get("source_url") or ""))
        lines.append(
            "| "
            f"{_table_cell(item.get('system'))} | "
            f"{_table_cell(item.get('benchmark'))} | "
            f"{_format_score(item.get('score'))} | "
            f"{_table_cell(item.get('metric'))} | "
            f"{_table_cell(item.get('dataset'))} | "
            f"{source} |"
        )
    return lines


def _not_covered_lines(report: Mapping[str, Any]) -> list[str]:
    external_benchmark = report.get("externalBenchmark")
    ready = report.get("benchmarkReadiness", {}).get("status") == "ready"
    if external_benchmark == "locomo" and ready:
        return [
            "- Apples-to-apples LoCoMo leaderboard ranking against external systems using the same answer model, judge, retrieval cutoff, and category subset.",
            "- LongMemEval or MemoryAgentBench results.",
            "- Provider-backed embeddings, reranking, LLM extraction quality, semantic scoring, or LLM judge scoring parity with published vendor runs.",
            "- Optimized long-running daemon latency or persistent large-store storage growth.",
        ]
    return [
        "- Publishable LoCoMo, LongMemEval, or MemoryAgentBench results.",
        "- Real provider embeddings, reranking, or LLM extraction quality.",
        "- Long-running daemon transport latency.",
        "- Large-store retrieval latency or storage growth.",
    ]


def _markdown_link(label: str, url: str) -> str:
    if not url:
        return _table_cell(label)
    return f"[{_table_cell(label)}]({url})"


def _format_score(value: object) -> str:
    try:
        score = float(value)
    except (TypeError, ValueError):
        return "-"
    return f"{score:g}"


def _table_cell(value: object) -> str:
    return str(value or "-").replace("|", "\\|")


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
    parser.add_argument("--include-provider-baselines", action="store_true")
    parser.add_argument("--core-retrieval-mode", choices=["fts", "vector", "hybrid", "graph"], default=os.environ.get("QUIPU_CORE_RETRIEVAL_MODE"))
    parser.add_argument("--core-answer-method", choices=["retrieve", "answer"], default=os.environ.get("QUIPU_CORE_ANSWER_METHOD", "retrieve"))
    parser.add_argument("--core-answer-abstain-if-weak", action="store_true", help="Pass memory.answer options.abstainIfWeak=true for core answer runs")
    core_llm_provider_choices = ["deterministic", *supported_llm_provider_ids()]
    parser.add_argument("--core-answer-provider", choices=core_llm_provider_choices, default=os.environ.get("QUIPU_ANSWER_PROVIDER"))
    parser.add_argument("--core-answer-model", default=os.environ.get("QUIPU_ANSWER_MODEL") or os.environ.get("OPENROUTER_ANSWER_MODEL"))
    parser.add_argument("--core-answer-url", default=os.environ.get("QUIPU_ANSWER_URL") or os.environ.get("OPENROUTER_ANSWER_URL"))
    parser.add_argument("--core-entity-provider", choices=core_llm_provider_choices, default=os.environ.get("QUIPU_ENTITY_PROVIDER"))
    parser.add_argument("--core-entity-model", default=os.environ.get("QUIPU_ENTITY_MODEL") or os.environ.get("OPENROUTER_ENTITY_MODEL"))
    parser.add_argument("--core-entity-url", default=os.environ.get("QUIPU_ENTITY_URL") or os.environ.get("OPENROUTER_ENTITY_URL"))
    parser.add_argument("--core-embedding-provider", choices=["hash", "openrouter"], default=os.environ.get("QUIPU_EMBEDDING_PROVIDER"))
    parser.add_argument("--core-embedding-model", default=os.environ.get("QUIPU_EMBEDDING_MODEL") or os.environ.get("OPENROUTER_EMBEDDING_MODEL"))
    parser.add_argument("--core-embedding-url", default=os.environ.get("QUIPU_EMBEDDING_URL") or os.environ.get("OPENROUTER_EMBEDDING_URL"))
    parser.add_argument("--core-vector-dimensions", type=int, default=int(os.environ["QUIPU_VECTOR_DIMENSIONS"]) if os.environ.get("QUIPU_VECTOR_DIMENSIONS") else None)
    parser.add_argument("--core-page-size", type=int, default=int(os.environ["QUIPU_LATTICE_PAGE_SIZE"]) if os.environ.get("QUIPU_LATTICE_PAGE_SIZE") else None)
    parser.add_argument("--enable-entity-resolution", action="store_true")
    parser.add_argument("--core-budget-tokens", type=int, default=None)
    parser.add_argument("--judge-provider", choices=["none", *supported_llm_provider_ids()], default=os.environ.get("QUIPU_JUDGE_PROVIDER", "none"))
    parser.add_argument("--judge-model", default=os.environ.get("QUIPU_JUDGE_MODEL"))
    parser.add_argument(
        "--judge-cache",
        type=Path,
        help="JSONL cache for LLM judge results (default: <output-dir>/.judge_cache.jsonl)",
    )
    parser.add_argument("--allow-weak-judge", action="store_true", default=False)
    parser.add_argument(
        "--provider-embedding-cache",
        type=Path,
        default=Path(os.environ.get("QUIPU_PROVIDER_EMBEDDING_CACHE", "artifacts/provider-cache/openrouter-embeddings.jsonl")),
    )
    parser.add_argument("--reuse-existing", action="store_true", help="Reuse existing per-run artifacts in the output directory")
    parser.add_argument("--download-locomo", action="store_true")
    parser.add_argument("--download-longmemeval", action="store_true")
    parser.add_argument("--dataset-cache", type=Path, default=Path(os.environ.get("QUIPU_DATASET_CACHE", ".quipu-datasets")))
    parser.add_argument("--locomo-max-conversations", type=int)
    parser.add_argument("--locomo-max-questions", type=int)
    parser.add_argument(
        "--locomo-categories",
        default="1,2,3,4,5",
        help="Comma-separated LoCoMo category numbers to include",
    )
    parser.add_argument("--locomo-event-summaries", action="store_true")
    parser.add_argument("--longmemeval-variant", choices=["oracle", "s", "m"], default="oracle")
    parser.add_argument("--longmemeval-max-conversations", type=int)
    parser.add_argument("--longmemeval-max-sessions", type=int)
    parser.add_argument(
        "--longmemeval-question-types",
        help="Comma-separated LongMemEval question types to include, such as temporal-reasoning,knowledge-update,abstention",
    )
    parser.add_argument("--allow-failures", action="store_true")
    args = parser.parse_args()
    if args.download_locomo and args.external_benchmark != "locomo":
        parser.error("--download-locomo requires --external-benchmark locomo")
    if args.download_longmemeval and args.external_benchmark != "longmemeval":
        parser.error("--download-longmemeval requires --external-benchmark longmemeval")
    result_class = args.result_class or ("external_smoke" if args.external_benchmark else "synthetic_smoke")
    downloaded_suite = None
    if args.download_locomo:
        downloaded_suite = download_locomo(args.dataset_cache)
    if args.download_longmemeval:
        downloaded_suite = download_longmemeval(args.dataset_cache, variant=args.longmemeval_variant)
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
        include_provider_baselines=args.include_provider_baselines,
        provider_options={"embedding_cache": args.provider_embedding_cache},
        core_retrieval_mode=args.core_retrieval_mode,
        core_answer_method=args.core_answer_method,
        core_answer_provider=args.core_answer_provider,
        core_answer_model=args.core_answer_model,
        core_answer_url=args.core_answer_url,
        core_entity_provider=args.core_entity_provider,
        core_entity_model=args.core_entity_model,
        core_entity_url=args.core_entity_url,
        core_embedding_provider=args.core_embedding_provider,
        core_embedding_model=args.core_embedding_model,
        core_embedding_url=args.core_embedding_url,
        core_vector_dimensions=args.core_vector_dimensions,
        core_page_size=args.core_page_size,
        enable_entity_resolution=args.enable_entity_resolution,
        core_budget_tokens=args.core_budget_tokens,
        core_answer_abstain_if_weak=args.core_answer_abstain_if_weak,
        judge_provider=args.judge_provider,
        judge_model=args.judge_model,
        judge_cache_path=args.judge_cache,
        allow_weak_judge=args.allow_weak_judge,
        reuse_existing=args.reuse_existing,
        locomo_options={
            "max_conversations": args.locomo_max_conversations,
            "max_questions_per_conversation": args.locomo_max_questions,
            "include_categories": parse_category_list(args.locomo_categories),
            "include_event_summaries": args.locomo_event_summaries,
        },
        longmemeval_options={
            "variant": args.longmemeval_variant,
            "max_conversations": args.longmemeval_max_conversations,
            "max_sessions_per_conversation": args.longmemeval_max_sessions,
            "include_question_types": parse_string_list(args.longmemeval_question_types),
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


def parse_string_list(value: str | None) -> list[str] | None:
    if value is None:
        return None
    items = [item.strip() for item in value.split(",") if item.strip()]
    return items or None


if __name__ == "__main__":
    raise SystemExit(main())
