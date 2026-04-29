from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any, Mapping


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
) -> dict[str, Any]:
    artifacts: dict[str, str] = {}
    if results_path is not None:
        artifacts["results"] = str(results_path)
    return {
        "schemaVersion": "quipu.eval.run.v1",
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "runner": runner,
        "storage": storage,
        "suite": {
            "path": str(suite_path),
            "name": run_json.get("suiteName"),
            "version": run_json.get("suiteVersion"),
        },
        "baseline": run_json.get("baseline"),
        "passed": run_json.get("passed"),
        "metrics": run_json.get("metrics", {}),
        "artifacts": artifacts,
        "gitCommit": git_commit,
        "config": dict(config or {}),
        "latticeVersion": lattice_version,
        "durationMs": duration_ms,
    }


def write_json(path: str | Path, payload: Mapping[str, Any]) -> None:
    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
