#!/usr/bin/env python3
"""Small repository formatting guard used before full toolchains land."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = {
    ".git",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".venv",
    "__pycache__",
    "artifacts",
    "build",
    "coverage",
    "dist",
    "htmlcov",
    "node_modules",
    "target",
    "venv",
    "zig-cache",
    "zig-out",
}
TEXT_EXTENSIONS = {
    ".c",
    ".h",
    ".html",
    ".json",
    ".js",
    ".md",
    ".mjs",
    ".py",
    ".toml",
    ".ts",
    ".txt",
    ".yaml",
    ".yml",
    ".zig",
}
TEXT_NAMES = {".editorconfig", ".gitignore", "justfile"}


def candidate_files() -> list[Path]:
    files: list[Path] = []
    for path in ROOT.rglob("*"):
        if any(part in SKIP_DIRS for part in path.relative_to(ROOT).parts):
            continue
        if not path.is_file():
            continue
        if path.name in TEXT_NAMES or path.suffix in TEXT_EXTENSIONS:
            files.append(path)
    return sorted(files)


def normalize(content: bytes) -> bytes:
    text = content.decode("utf-8")
    lines = text.splitlines()
    if not lines:
        return b""
    normalized = "\n".join(line.rstrip(" \t") for line in lines) + "\n"
    return normalized.encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true")
    group.add_argument("--fix", action="store_true")
    args = parser.parse_args()

    changed: list[Path] = []
    unreadable: list[Path] = []
    for path in candidate_files():
        try:
            original = path.read_bytes()
            normalized = normalize(original)
        except UnicodeDecodeError:
            unreadable.append(path.relative_to(ROOT))
            continue
        if original != normalized:
            changed.append(path.relative_to(ROOT))
            if args.fix:
                path.write_bytes(normalized)

    if unreadable:
        for path in unreadable:
            print(f"Non-UTF-8 text candidate: {path}", file=sys.stderr)
        return 1

    if changed and args.check:
        for path in changed:
            print(f"Needs formatting: {path}", file=sys.stderr)
        return 1

    if changed:
        print(f"Formatted {len(changed)} file(s).")
    else:
        print("Formatting check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
