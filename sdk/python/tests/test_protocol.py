from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "sdk" / "python" / "src"))

from quipu import (  # noqa: E402
    Quipu,
    QuipuProtocolError,
    SUPPORTED_METHODS,
    validate_json_rpc_request,
    validate_json_rpc_response,
    validate_rpc_params,
)


FIXTURE_DIR = ROOT / "protocol" / "conformance"
SCHEMA_DIR = ROOT / "protocol" / "schemas"


def load_fixtures():
    return [
        json.loads(path.read_text())
        for path in sorted(FIXTURE_DIR.glob("*.json"))
        if path.name != "README.md"
    ]


class ProtocolFixtureTests(unittest.TestCase):
    def test_protocol_schemas_define_public_methods(self):
        for path in sorted(SCHEMA_DIR.glob("*.json")):
            with self.subTest(schema=path.name):
                json.loads(path.read_text())

        methods_schema = json.loads((SCHEMA_DIR / "methods.schema.json").read_text())
        defs = methods_schema["$defs"]
        expected_defs = {
            "systemHealthParams",
            "systemHealthResult",
            "memoryRememberParams",
            "memoryRememberResult",
            "memoryRetrieveParams",
            "memoryRetrieveResult",
            "memorySearchParams",
            "memorySearchResult",
            "memoryInspectParams",
            "memoryInspectResult",
            "memoryForgetParams",
            "memoryForgetResult",
            "memoryFeedbackParams",
            "memoryFeedbackResult",
            "memoryCoreGetParams",
            "memoryCoreGetResult",
            "memoryCoreUpdateParams",
            "memoryCoreUpdateResult",
        }
        self.assertTrue(expected_defs.issubset(defs))

    def test_fixtures_cover_public_methods(self):
        success_methods = {
            fixture["request"]["method"]
            for fixture in load_fixtures()
            if "result" in fixture["response"]
        }
        self.assertEqual(success_methods, SUPPORTED_METHODS)

    def test_success_fixtures_validate(self):
        for fixture in load_fixtures():
            with self.subTest(fixture=fixture["name"]):
                validate_json_rpc_response(fixture["response"])
                if "result" in fixture["response"]:
                    validate_json_rpc_request(fixture["request"])
                    validate_rpc_params(fixture["request"]["method"], fixture["request"]["params"])

    def test_error_fixture_rejects_bad_request(self):
        fixture = json.loads((FIXTURE_DIR / "memory.retrieve.invalid_request.json").read_text())
        with self.assertRaises(QuipuProtocolError):
            validate_json_rpc_request(fixture["request"])
        validate_json_rpc_response(fixture["response"])


class QuipuClientTests(unittest.TestCase):
    def test_client_delegates_valid_rpc_request_to_transport(self):
        calls = []

        def transport(request):
            calls.append(request)
            return {
                "jsonrpc": "2.0",
                "id": request["id"],
                "result": {
                    "status": "ok",
                    "version": "0.1.0",
                    "protocolVersion": "2026-04-quipu-v1",
                    "schemaVersion": 1,
                    "workers": {},
                },
            }

        client = Quipu(transport=transport)
        result = client.health()

        self.assertEqual(result["status"], "ok")
        self.assertEqual(calls[0]["method"], "system.health")
        validate_json_rpc_request(calls[0])


if __name__ == "__main__":
    unittest.main()
