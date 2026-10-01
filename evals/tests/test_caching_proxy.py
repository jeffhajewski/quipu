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

from quipu_evals.caching_proxy import CachingProxy, ProxyState, cache_key, parse_path  # noqa: E402


class ProxyTests(unittest.TestCase):
    def test_cache_key_is_canonical_and_endpoint_scoped(self):
        a = cache_key("chat/completions", b'{"model": "m", "messages": [1, 2]}')
        b = cache_key("chat/completions", b'{"messages":[1,2],"model":"m"}')
        self.assertEqual(a, b)
        self.assertNotEqual(a, cache_key("embeddings", b'{"messages":[1,2],"model":"m"}'))
        self.assertNotEqual(a, cache_key("chat/completions", b'{"messages":[2,1],"model":"m"}'))
        self.assertNotEqual(cache_key("embeddings", b"not json"), cache_key("embeddings", b"not json "))

    def test_paths_carry_question_tags(self):
        self.assertEqual(parse_path("/q/gpt4_1a_abs/v1/chat/completions"), ("gpt4_1a_abs", "chat/completions"))
        self.assertEqual(parse_path("/v1/embeddings"), ("untagged", "embeddings"))
        with self.assertRaises(ValueError):
            parse_path("/q/x/v1/models")

    def _state(self, directory, responses):
        state = ProxyState(Path(directory) / "cache", Path(directory) / "log.jsonl", api_key="test")
        calls = []

        def forward(endpoint, body):
            calls.append(body)
            status, payload = responses.pop(0)
            return status, json.dumps(payload).encode()
        state._forward = forward
        return state, calls

    def test_identical_requests_are_served_from_cache_and_costed_once(self):
        ok = {"choices": [{"message": {"content": "hi"}}], "usage": {"prompt_tokens": 5, "completion_tokens": 1, "cost": 0.002}}
        with tempfile.TemporaryDirectory() as directory:
            state, calls = self._state(directory, [(200, ok)])
            body = b'{"model":"m","messages":[]}'
            first = state.handle("q1", "chat/completions", body)
            second = state.handle("q2", "chat/completions", b'{"messages": [], "model": "m"}')
            self.assertEqual(len(calls), 1)
            self.assertEqual(json.loads(first[1]), json.loads(second[1]))
            self.assertFalse(first[2]["cached"])
            self.assertTrue(second[2]["cached"])
            self.assertEqual(second[2]["costUsd"], 0.0)
            self.assertEqual(second[2]["nominalCostUsd"], 0.002)
            self.assertAlmostEqual(state.spent_usd, 0.002)
            self.assertEqual([r["tag"] for r in state.records_for("q2")], ["q2"])
            self.assertEqual(len((Path(directory) / "log.jsonl").read_text().splitlines()), 2)

    def test_errors_are_not_cached(self):
        ok = {"data": [{"embedding": [0.1], "index": 0}], "usage": {"prompt_tokens": 1, "cost": 0.0}}
        with tempfile.TemporaryDirectory() as directory:
            state, calls = self._state(directory, [(500, {"error": {"message": "boom"}}), (200, {"error": "x"}), (200, ok)])
            body = b'{"model":"e","input":["a"]}'
            self.assertEqual(state.handle("q", "embeddings", body)[0], 500)
            self.assertEqual(state.handle("q", "embeddings", body)[0], 502)
            self.assertEqual(state.handle("q", "embeddings", body)[0], 200)
            self.assertEqual(state.handle("q", "embeddings", body)[0], 200)
            self.assertEqual(len(calls), 3)

    def test_spend_cap_blocks_uncached_requests(self):
        ok = {"choices": [{"message": {"content": "x"}}], "usage": {"cost": 1.5}}
        with tempfile.TemporaryDirectory() as directory:
            state, _ = self._state(directory, [(200, ok)])
            state.max_spend_usd = 1.0
            del state._forward  # Use the real method's cap check; it must refuse before any network call.
            state.spent_usd = 1.0
            status, raw, _ = state.handle("q", "chat/completions", b'{"model":"m"}')
            self.assertEqual(status, 402)
            self.assertIn("spend cap", raw.decode())

    def test_http_round_trip_through_tagged_path(self):
        ok = {"choices": [{"message": {"content": "hi"}}], "usage": {"cost": 0.0}}
        with tempfile.TemporaryDirectory() as directory:
            state, calls = self._state(directory, [(200, ok)])
            with CachingProxy(state) as proxy:
                request = urllib.request.Request(proxy.url("abc", "chat/completions"), data=b'{"model":"m"}',
                                                 headers={"Content-Type": "application/json"}, method="POST")
                with urllib.request.urlopen(request, timeout=10) as response:
                    self.assertEqual(json.loads(response.read()), ok)
                with self.assertRaises(urllib.error.HTTPError):
                    urllib.request.urlopen(urllib.request.Request(f"{proxy.base_url}/v1/models", data=b"{}", method="POST"), timeout=10)
            self.assertEqual(state.records_for("abc")[0]["endpoint"], "chat/completions")


if __name__ == "__main__":
    unittest.main()
