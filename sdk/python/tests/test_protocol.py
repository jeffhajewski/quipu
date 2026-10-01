from __future__ import annotations

import json
import os
import shutil
import sys
import subprocess
import tempfile
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
CORE_DIR = ROOT / "core"
CORE_BINARY = CORE_DIR / "zig-out" / "bin" / "quipu"


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
            "memoryAnswerParams",
            "memoryAnswerResult",
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
        self.assertIn("answerTrace", defs)
        self.assertIn("answerTrace", defs["memoryAnswerResult"]["properties"])
        self.assertIn("supportValid", defs["answerTrace"]["properties"])
        self.assertIn("supportValid", defs["answerTrace"]["required"])
        self.assertNotIn("evidenceGate", defs["answerTrace"]["properties"])
        self.assertEqual(defs["memoryAnswerResult"]["properties"]["prompt"]["type"], ["string", "null"])
        self.assertIn("slotKey", defs["memoryItem"]["properties"])
        self.assertIn("abstainIfWeak", defs["memoryAnswerParams"]["properties"]["options"]["properties"])
        answer_options = defs["memoryAnswerParams"]["properties"]["options"]["properties"]
        retrieve_options = defs["memoryRetrieveParams"]["properties"]["options"]["properties"]
        self.assertEqual(answer_options["readerReasoning"]["type"], "boolean")
        self.assertEqual(answer_options["temporalHints"]["type"], "boolean")
        self.assertEqual(retrieve_options["temporalHints"]["type"], "boolean")
        self.assertNotIn("readerReasoning", retrieve_options)
        trace = defs["answerTrace"]
        self.assertEqual(trace["properties"]["readerMode"]["enum"], ["none", "direct", "reasoning"])
        self.assertEqual(trace["properties"]["reasoning"]["type"], ["string", "null"])
        self.assertEqual(trace["properties"]["timeReferences"]["type"], ["string", "null"])
        self.assertEqual(trace["properties"]["temporalHints"]["type"], "boolean")
        for optional in ("readerMode", "temporalHints", "timeReferences", "reasoning"):
            self.assertNotIn(optional, trace["required"])

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

    def test_memory_answer_fixture_includes_optional_answer_trace(self):
        fixture = json.loads((FIXTURE_DIR / "memory.answer.success.json").read_text())
        result = fixture["response"]["result"]

        self.assertIn("answerTrace", result)
        self.assertEqual(result["answerTrace"]["strategy"], "deterministic_fallback")
        self.assertTrue(result["answerTrace"]["supportValid"])
        self.assertEqual(result["answerTrace"]["validation"]["status"], "accepted")
        self.assertTrue(result["prompt"].startswith("<memory>"))

    def test_rerank_options_are_validated(self):
        methods_schema = json.loads((SCHEMA_DIR / "methods.schema.json").read_text())
        defs = methods_schema["$defs"]
        for method in ("memoryRetrieveParams", "memoryAnswerParams"):
            options = defs[method]["properties"]["options"]["properties"]
            self.assertEqual(options["rerank"]["type"], "boolean")
            self.assertEqual(options["rerankCandidates"]["minimum"], 1)
        self.assertIn("rerank", defs["retrievalTrace"]["properties"])
        self.assertIn("reranker", defs["systemHealthResult"]["properties"]["capabilities"]["properties"])

        for method in ("memory.retrieve", "memory.answer"):
            with self.subTest(method=method):
                validate_rpc_params(method, {"query": "q", "options": {"rerank": False, "rerankCandidates": 20}})
                for options in ({"rerank": "no"}, {"rerankCandidates": 0}, {"rerankCandidates": 2.5},
                                {"rerankCandidates": True}):
                    with self.assertRaises(QuipuProtocolError):
                        validate_rpc_params(method, {"query": "q", "options": options})

    def test_memory_answer_reader_options_fixture_reports_reasoning_and_hints(self):
        fixture = json.loads((FIXTURE_DIR / "memory.answer.reader_options.json").read_text())
        options = fixture["request"]["params"]["options"]
        trace = fixture["response"]["result"]["answerTrace"]

        self.assertTrue(options["readerReasoning"])
        self.assertTrue(options["temporalHints"])
        self.assertEqual(trace["readerMode"], "reasoning")
        self.assertTrue(trace["temporalHints"])
        self.assertEqual(trace["timeReferences"], '"last week" = 2023-05-22 to 2023-05-28')
        self.assertIsInstance(trace["reasoning"], str)
        self.assertNotIn(trace["reasoning"], fixture["response"]["result"]["answer"])
        self.assertIn("## session s-late 2023-05-22 (Mon), 8 days ago", fixture["response"]["result"]["prompt"])

        default_trace = json.loads((FIXTURE_DIR / "memory.answer.success.json").read_text())["response"]["result"]["answerTrace"]
        self.assertEqual(default_trace["readerMode"], "none")
        self.assertFalse(default_trace["temporalHints"])
        self.assertIsNone(default_trace["reasoning"])

    def test_reader_options_are_validated_per_method(self):
        validate_rpc_params(
            "memory.answer",
            {"query": "q", "options": {"readerReasoning": True, "temporalHints": False}},
        )
        validate_rpc_params("memory.retrieve", {"query": "q", "options": {"temporalHints": True}})
        with self.assertRaises(QuipuProtocolError):
            validate_rpc_params("memory.answer", {"query": "q", "options": {"readerReasoning": "yes"}})
        with self.assertRaises(QuipuProtocolError):
            validate_rpc_params("memory.retrieve", {"query": "q", "options": {"readerReasoning": True}})

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

    def test_local_client_builds_stdio_command(self):
        client = Quipu.local(binary="quipu-test", db_path="/tmp/quipu.lattice")
        try:
            self.assertTrue(hasattr(client.transport, "command"))
            self.assertEqual(client.transport.command, ["quipu-test", "--db", "/tmp/quipu.lattice", "serve-stdio"])
        finally:
            client.close()

    def test_default_client_uses_local_stdio_transport(self):
        previous_binary = os.environ.pop("QUIPU_CORE_BINARY", None)
        previous_db_path = os.environ.pop("QUIPU_DB_PATH", None)
        try:
            client = Quipu()
            try:
                self.assertTrue(hasattr(client.transport, "command"))
                self.assertEqual(client.transport.command, ["quipu", "serve-stdio"])
            finally:
                client.close()
        finally:
            if previous_binary is not None:
                os.environ["QUIPU_CORE_BINARY"] = previous_binary
            if previous_db_path is not None:
                os.environ["QUIPU_DB_PATH"] = previous_db_path

    @unittest.skipUnless(shutil.which("zig"), "zig is not installed")
    def test_stdio_client_calls_core_process(self):
        env = os.environ.copy()
        env["ZIG_GLOBAL_CACHE_DIR"] = "/tmp/quipu-zig-cache"
        subprocess.run(["zig", "build"], cwd=str(CORE_DIR), check=True, env=env)

        with tempfile.TemporaryDirectory() as tmp_dir:
            db_path = str(Path(tmp_dir) / "sdk-python.lattice")
            with Quipu.stdio([str(CORE_BINARY), "--db", db_path, "serve-stdio"]) as client:
                remembered = client.remember(
                    scope={"projectId": "repo:test"},
                    messages=[{"role": "user", "content": "Use pnpm through the SDK."}],
                )
                retrieved = client.retrieve(
                    query="pnpm",
                    scope={"projectId": "repo:test"},
                    needs=["current_facts"],
                    options={"includeDebug": True},
                )

                self.assertEqual(remembered["status"], "stored")
                self.assertIn("The repo uses pnpm as its package manager.", retrieved["prompt"])
                self.assertEqual(len(retrieved["context"]["currentFacts"]), 1)
                self.assertEqual(retrieved["trace"]["keptCount"], 1)

    @unittest.skipUnless(shutil.which("zig"), "zig is not installed")
    def test_local_client_auto_starts_core_stdio(self):
        env = os.environ.copy()
        env["ZIG_GLOBAL_CACHE_DIR"] = "/tmp/quipu-zig-cache"
        subprocess.run(["zig", "build"], cwd=str(CORE_DIR), check=True, env=env)

        with tempfile.TemporaryDirectory() as tmp_dir:
            db_path = str(Path(tmp_dir) / "sdk-python-local.lattice")
            with Quipu.local(binary=str(CORE_BINARY), db_path=db_path) as client:
                self.assertEqual(client.health()["status"], "ok")


if __name__ == "__main__":
    unittest.main()
