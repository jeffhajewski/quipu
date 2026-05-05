from __future__ import annotations

from types import SimpleNamespace
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import quipu_dashboard  # noqa: E402


class FakeMemory:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, object]]] = []

    def search(self, **kwargs: object) -> dict[str, object]:
        self.calls.append(("search", kwargs))
        return {"results": [{"qid": "q_1", "type": "fact"}]}

    def retrieve(self, **kwargs: object) -> dict[str, object]:
        self.calls.append(("retrieve", kwargs))
        return {"retrievalId": "q_retr_1", "warnings": [], "trace": {"keptCount": 1}}


def handler_for(memory: FakeMemory) -> quipu_dashboard.Handler:
    handler = object.__new__(quipu_dashboard.Handler)
    handler.server = SimpleNamespace(state=quipu_dashboard.State(memory))
    return handler


class DashboardTests(unittest.TestCase):
    def test_read_only_sections_are_rendered(self) -> None:
        for endpoint in (
            "/api/memories",
            "/api/evidence",
            "/api/entities",
            "/api/facts",
            "/api/core-blocks",
            "/api/retrieval-traces",
            "/api/jobs",
        ):
            self.assertIn(endpoint, quipu_dashboard.HTML)

    def test_label_search_scopes_limits_and_includes_deleted(self) -> None:
        memory = FakeMemory()
        handler = handler_for(memory)

        result = handler._label_search(
            "q=package&projectId=repo%3Aquipu&limit=500&includeDeleted=true",
            ["Fact", "Preference", "Procedure"],
            "Fact Preference Procedure",
        )

        self.assertEqual(result["results"][0]["qid"], "q_1")
        self.assertEqual(memory.calls[0][0], "search")
        self.assertEqual(
            memory.calls[0][1],
            {
                "query": "package",
                "mode": "fts",
                "labels": ["Fact", "Preference", "Procedure"],
                "scope": {"projectId": "repo:quipu"},
                "limit": 100,
                "includeDeleted": True,
            },
        )

    def test_retrieval_traces_use_debug_and_evidence(self) -> None:
        memory = FakeMemory()
        handler = handler_for(memory)

        result = handler._retrieval_traces("q=pnpm&userId=local-user")

        self.assertEqual(result["retrievalId"], "q_retr_1")
        self.assertEqual(memory.calls[0][0], "retrieve")
        self.assertEqual(memory.calls[0][1]["query"], "pnpm")
        self.assertEqual(memory.calls[0][1]["scope"], {"userId": "local-user"})
        self.assertEqual(memory.calls[0][1]["options"], {"includeDebug": True, "includeEvidence": True})


if __name__ == "__main__":
    unittest.main()
