from __future__ import annotations

import json
from pathlib import Path
import subprocess
from typing import Any, Mapping, Optional, Sequence


class CoreStdioClient:
    """Small NDJSON client for `quipu serve-stdio` integration tests."""

    def __init__(self, binary: Path, extra_args: Sequence[str] = ()) -> None:
        self.binary = binary
        self.extra_args = list(extra_args)
        self.process: Optional[subprocess.Popen[str]] = None
        self.next_id = 1

    def __enter__(self) -> "CoreStdioClient":
        self.process = subprocess.Popen(
            [str(self.binary), *self.extra_args, "serve-stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        if self.process is None:
            return
        if self.process.stdin is not None:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=2)
        if self.process.stdout is not None:
            self.process.stdout.close()
        if self.process.stderr is not None:
            self.process.stderr.close()

    def call(self, method: str, params: Mapping[str, Any]) -> Mapping[str, Any]:
        if self.process is None or self.process.stdin is None or self.process.stdout is None:
            raise RuntimeError("client is not running")
        request_id = f"core_{self.next_id}"
        self.next_id += 1
        request = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": dict(params),
        }
        self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

        line = self.process.stdout.readline()
        if not line:
            stderr = self.process.stderr.read() if self.process.stderr is not None else ""
            raise RuntimeError(f"core process exited without a response: {stderr}")
        response = json.loads(line)
        if "error" in response:
            raise RuntimeError(response["error"]["message"])
        return response["result"]
