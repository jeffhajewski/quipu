#!/usr/bin/env python3
"""Run the checks that are available for the current scaffold."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]


def run(command: list[str], cwd: Path = ROOT, env: Optional[dict[str, str]] = None) -> None:
    print(f"$ {' '.join(command)}", flush=True)
    subprocess.run(command, cwd=str(cwd), check=True, env=env)


def maybe_run_python_tests(path: Path) -> None:
    if path.exists():
        run([sys.executable, "-m", "unittest", "discover", "-s", str(path)])
    else:
        print(f"Skipping Python tests: {path.relative_to(ROOT)} does not exist")


def maybe_run_typescript_build() -> None:
    sdk = ROOT / "sdk" / "typescript"
    has_deps = (sdk / "node_modules").exists()
    if shutil.which("npm") is None:
        print("Skipping TypeScript build: npm is not installed")
        return
    if not has_deps and not os.environ.get("CI"):
        print("Skipping TypeScript build: sdk/typescript/node_modules is missing")
        return
    run(["npm", "test"], cwd=sdk)


def maybe_run_zig_build() -> None:
    if shutil.which("zig") is None:
        print("Skipping Zig build: zig is not installed")
        return
    env = os.environ.copy()
    env.setdefault("ZIG_GLOBAL_CACHE_DIR", "/tmp/quipu-zig-cache")
    run(["zig", "build", "test"], cwd=ROOT / "core", env=env)


def main() -> int:
    maybe_run_python_tests(ROOT / "sdk" / "python" / "tests")
    maybe_run_python_tests(ROOT / "evals" / "tests")
    maybe_run_typescript_build()
    maybe_run_zig_build()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
