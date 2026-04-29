from __future__ import annotations

from pathlib import Path
from typing import Any
import json

from .scenarios import Suite, load_suite


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_EXTERNAL_SUITES = {
    "locomo": ROOT / "evals" / "suites" / "external" / "locomo_mini.yaml",
}
EXTERNAL_SCENARIO_FORMAT = "quipu.external.scenario.v1"


def load_external_suite(path: str | Path, *, benchmark: str | None = None) -> Suite:
    suite = load_suite(path)
    validate_external_suite(suite, benchmark=benchmark)
    return suite


def is_normalized_external_suite(path: str | Path) -> bool:
    try:
        raw = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return False
    if not isinstance(raw, dict):
        return False
    metadata = raw.get("metadata", {})
    return isinstance(metadata, dict) and metadata.get("format") == EXTERNAL_SCENARIO_FORMAT


def validate_external_suite(suite: Suite, *, benchmark: str | None = None) -> None:
    metadata = dict(suite.metadata)
    if metadata.get("format") != EXTERNAL_SCENARIO_FORMAT:
        raise ValueError(f"metadata.format must be {EXTERNAL_SCENARIO_FORMAT}")
    if benchmark is not None and metadata.get("benchmark") != benchmark:
        raise ValueError(f"metadata.benchmark must be {benchmark}")
    if not metadata.get("datasetVersion"):
        raise ValueError("metadata.datasetVersion must be set")
    if not suite.scenarios:
        raise ValueError("external suites must contain at least one scenario")
    categories = {query.category for scenario in suite.scenarios for query in scenario.queries}
    required = set(metadata.get("tasks", []))
    missing = sorted(required - categories)
    if missing:
        raise ValueError(f"external suite is missing task categories: {', '.join(missing)}")


def external_suite_metadata(suite: Suite) -> dict[str, Any]:
    metadata = dict(suite.metadata)
    return {
        "format": metadata.get("format"),
        "benchmark": metadata.get("benchmark"),
        "datasetName": metadata.get("datasetName", suite.name),
        "datasetVersion": metadata.get("datasetVersion", suite.version),
        "source": metadata.get("source"),
        "license": metadata.get("license"),
        "tasks": list(metadata.get("tasks", [])),
    }
