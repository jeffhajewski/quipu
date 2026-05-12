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


def maybe_run_python_tests(path: Path, env: dict[str, str]) -> None:
    if path.exists():
        run([sys.executable, "-m", "unittest", "discover", "-s", str(path)], env=env)
    else:
        print(f"Skipping Python tests: {path.relative_to(ROOT)} does not exist")


def maybe_run_typescript_build(env: dict[str, str]) -> None:
    sdk = ROOT / "sdk" / "typescript"
    has_deps = (sdk / "node_modules").exists()
    if shutil.which("npm") is None:
        print("Skipping TypeScript build: npm is not installed")
        return
    if not has_deps and not os.environ.get("CI"):
        print("Skipping TypeScript build: sdk/typescript/node_modules is missing")
        return
    run(["npm", "test"], cwd=sdk, env=env)


def maybe_run_node_tests(path: Path, env: dict[str, str]) -> None:
    if shutil.which("npm") is None:
        print(f"Skipping Node tests: npm is not installed for {path.relative_to(ROOT)}")
        return
    if not (path / "package.json").exists():
        print(f"Skipping Node tests: {path.relative_to(ROOT)}/package.json does not exist")
        return
    run(["npm", "test"], cwd=path, env=env)


def maybe_run_zig_build(env: dict[str, str]) -> None:
    if shutil.which("zig") is None:
        print("Skipping Zig build: zig is not installed")
        return
    env.setdefault("ZIG_GLOBAL_CACHE_DIR", "/tmp/quipu-zig-cache")
    run(["zig", "build", "test"], cwd=ROOT / "core", env=env)


def lattice_env() -> dict[str, str]:
    env = os.environ.copy()
    include = env.get("LATTICE_INCLUDE") or first_existing(
        [
            Path("/usr/local/include/lattice.h"),
            Path("/opt/homebrew/include/lattice.h"),
            Path.home() / ".local" / "include" / "lattice.h",
        ]
    )
    lib_dir = env.get("LATTICE_LIB_DIR") or lattice_lib_dir_from_env(env) or first_existing_parent(
        [
            Path("/usr/local/lib/liblattice.dylib"),
            Path("/usr/local/lib/liblattice.so"),
            Path("/opt/homebrew/lib/liblattice.dylib"),
            Path.home() / ".local" / "lib" / "liblattice.dylib",
            Path.home() / ".local" / "lib" / "liblattice.so",
        ]
    )
    missing = []
    if not include:
        missing.append("LATTICE_INCLUDE")
    if not lib_dir:
        missing.append("LATTICE_LIB_DIR")
    if missing:
        raise RuntimeError(
            "LatticeDB-backed tests require system liblattice; set "
            + " and ".join(missing)
            + " to the installed lattice.h and liblattice directory"
        )
    env["LATTICE_INCLUDE"] = include
    env["LATTICE_LIB_DIR"] = lib_dir
    return env


def lattice_lib_dir_from_env(env: dict[str, str]) -> str | None:
    if lib_path := env.get("LATTICE_LIB_PATH"):
        return str(Path(lib_path).parent)
    if prefix := env.get("LATTICE_PREFIX"):
        return str(Path(prefix) / "lib")
    return None


def first_existing(paths: list[Path]) -> str | None:
    for path in paths:
        if path.exists():
            return str(path.parent)
    return None


def first_existing_parent(paths: list[Path]) -> str | None:
    for path in paths:
        if path.exists():
            return str(path.parent)
    return None


def main() -> int:
    env = lattice_env()
    maybe_run_python_tests(ROOT / "scripts" / "tests", env)
    maybe_run_python_tests(ROOT / "sdk" / "python" / "tests", env)
    maybe_run_python_tests(ROOT / "evals" / "tests", env)
    maybe_run_typescript_build(env)
    maybe_run_node_tests(ROOT / "mcp", env)
    maybe_run_zig_build(env)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
