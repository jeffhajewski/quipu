from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
from typing import Any, Mapping


DEFAULT_PROVIDERS = {
    "extractor": "deterministic_fixture",
    "embedder": "deterministic_fixture",
    "reranker": "none",
    "answer": "deterministic_prompt_match",
    "judge": "rule_based",
}


def build_manifest(
    run_json: Mapping[str, Any],
    *,
    suite_path: str | Path,
    runner: str,
    storage: str,
    results_path: str | Path | None = None,
    git_commit: str | None = None,
    config: Mapping[str, Any] | None = None,
    lattice_version: str | None = None,
    duration_ms: float | None = None,
    providers: Mapping[str, str] | None = None,
    seed: int = 0,
    verification_status: str = "not_run",
) -> dict[str, Any]:
    artifacts: dict[str, str] = {}
    if results_path is not None:
        artifacts["results"] = str(results_path)
    generated_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    config_payload = dict(config or {})
    return {
        "schemaVersion": "quipu.eval.run.v1",
        "runId": _run_id(generated_at, suite_path, runner, storage, config_payload),
        "generatedAt": generated_at,
        "runner": runner,
        "storage": storage,
        "suite": {
            "path": str(suite_path),
            "name": run_json.get("suiteName"),
            "version": run_json.get("suiteVersion"),
        },
        "dataset": {
            "name": run_json.get("suiteName"),
            "version": run_json.get("suiteVersion"),
        },
        "baseline": run_json.get("baseline"),
        "passed": run_json.get("passed"),
        "metrics": run_json.get("metrics", {}),
        "artifacts": artifacts,
        "gitCommit": git_commit,
        "quipuVersion": "0.1.0",
        "config": config_payload,
        "configHash": _hash_json(config_payload),
        "providers": dict(providers or DEFAULT_PROVIDERS),
        "hardware": _hardware_summary(),
        "randomSeed": seed,
        "verification": {"status": verification_status},
        "latticeVersion": lattice_version,
        "durationMs": duration_ms,
    }


def write_json(path: str | Path, payload: Mapping[str, Any]) -> None:
    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def _hash_json(payload: Mapping[str, Any]) -> str:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _run_id(
    generated_at: str,
    suite_path: str | Path,
    runner: str,
    storage: str,
    config: Mapping[str, Any],
) -> str:
    payload = {
        "generatedAt": generated_at,
        "suitePath": str(suite_path),
        "runner": runner,
        "storage": storage,
        "config": dict(config),
    }
    return "run_" + _hash_json(payload)[:16]


def _hardware_summary() -> dict[str, str]:
    return {
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "processor": platform.processor(),
        "python": platform.python_version(),
    }
