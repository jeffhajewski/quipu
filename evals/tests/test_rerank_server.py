from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "evals" / "src"))

from quipu_evals.rerank_server import (  # noqa: E402
    RerankRequestError,
    RerankServer,
    RerankService,
    ScoreCache,
    cache_key,
    model_identity,
    parse_request,
)


class FakeScorer:
    """Scores a pair by how many query words the document contains."""

    def __init__(self):
        self.pairs = []

    def __call__(self, pairs):
        self.pairs.extend(pairs)
        return [float(sum(word in document.lower() for word in query.lower().split())) for query, document in pairs]


def post(url, payload):
    request = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST",
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as exc:
        with exc:
            return exc.code, json.loads(exc.read())


class RerankServerTests(unittest.TestCase):
    def test_cache_key_covers_model_query_and_document(self):
        identity = model_identity("BAAI/bge-reranker-v2-m3", 512)
        key = cache_key(identity, "q", "d")
        self.assertEqual(key, cache_key(identity, "q", "d"))
        self.assertEqual(len(key), 64)
        self.assertNotEqual(key, cache_key(model_identity("BAAI/bge-reranker-v2-m3", 1024), "q", "d"))
        self.assertNotEqual(key, cache_key(model_identity("other", 512), "q", "d"))
        self.assertNotEqual(key, cache_key(identity, "q2", "d"))
        self.assertNotEqual(key, cache_key(identity, "q", "d2"))
        # Field boundaries cannot be forged by moving text between fields.
        self.assertNotEqual(cache_key(identity, "a", "bc"), cache_key(identity, "ab", "c"))

    def test_parse_request_validates_the_cohere_shape(self):
        model, query, documents, top_n, return_documents = parse_request(
            {"model": "m", "query": "q", "documents": ["a", {"text": "b"}], "return_documents": False})
        self.assertEqual((model, query, documents, top_n, return_documents), ("m", "q", ["a", "b"], 2, False))
        for body in ({"query": "", "documents": []}, {"query": "q"}, {"query": "q", "documents": [1]},
                     {"query": "q", "documents": ["a"], "top_n": 0}, {"query": "q", "documents": ["a"], "top_n": True}):
            with self.subTest(body=body), self.assertRaises(RerankRequestError):
                parse_request(body)

    def test_service_sorts_truncates_and_caches_scores(self):
        with tempfile.TemporaryDirectory() as directory:
            scorer = FakeScorer()
            service = RerankService("fake-model", scorer, ScoreCache(Path(directory)))
            documents = ["2023-05-20 user: My dog Rex likes the park.", "2023-05-22 user: I adopted a cat named Miso.",
                         "The repo uses pnpm.", "Miso the cat and Rex the dog"]
            body = {"model": "fake-model", "query": "cat miso", "documents": documents, "top_n": 3,
                    "return_documents": False}
            response = service.rerank(body)
            self.assertEqual([r["index"] for r in response["results"]], [1, 3, 0])
            self.assertEqual([r["relevance_score"] for r in response["results"]], [2.0, 2.0, 0.0])
            self.assertNotIn("document", response["results"][0])
            self.assertEqual(response["meta"]["scored"], 4)
            self.assertEqual(len(scorer.pairs), 4)

            again = service.rerank({**body, "top_n": 4, "return_documents": True})
            self.assertEqual(len(scorer.pairs), 4)  # Every pair came from the cache.
            self.assertEqual(again["meta"]["cached"], 4)
            self.assertEqual([r["index"] for r in again["results"]], [1, 3, 0, 2])
            self.assertEqual(again["results"][0]["document"], {"text": documents[1]})

            # A new process reloads the scores from disk.
            reloaded_scorer = FakeScorer()
            reloaded = RerankService("fake-model", reloaded_scorer, ScoreCache(Path(directory)))
            self.assertEqual(reloaded.rerank(body)["results"], response["results"])
            self.assertEqual(reloaded_scorer.pairs, [])
            # Another model never reuses those scores.
            other_scorer = FakeScorer()
            RerankService("other-model", other_scorer, ScoreCache(Path(directory))).rerank({**body, "model": None})
            self.assertEqual(len(other_scorer.pairs), 4)

    def test_http_endpoint_serves_the_cohere_wire_format(self):
        service = RerankService("fake-model", FakeScorer(), ScoreCache(None))
        with RerankServer(service) as server:
            status, response = post(server.url, {"model": "fake-model", "query": "rex", "documents": ["a cat", "Rex"],
                                                 "top_n": 2, "return_documents": False})
            self.assertEqual(status, 200)
            self.assertEqual(response["results"], [{"index": 1, "relevance_score": 1.0},
                                                   {"index": 0, "relevance_score": 0.0}])
            status, response = post(server.url, {"model": "another-model", "query": "rex", "documents": ["Rex"]})
            self.assertEqual(status, 400)
            self.assertIn("another-model", response["message"])
            status, _ = post(server.url, {"query": "rex"})
            self.assertEqual(status, 400)
            status, _ = post(server.url.replace("/v1/rerank", "/v1/embeddings"), {"query": "rex", "documents": []})
            self.assertEqual(status, 404)
            with urllib.request.urlopen(server.url.replace("/v1/rerank", "/health"), timeout=10) as health:
                self.assertEqual(json.loads(health.read())["model"], "fake-model")


if __name__ == "__main__":
    unittest.main()
