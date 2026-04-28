# Repository Guidelines

## Project Structure & Module Organization

Quipu is a pre-implementation skeleton for a local-first agent memory system. Core runtime code lives in `core/`, with Zig sources in `core/src/` and future core tests in `core/tests/`. Public SDKs live under `sdk/typescript/` and `sdk/python/`. The MCP adapter belongs in `mcp/`, examples in `examples/`, evaluation tooling in `evals/`, and design/API documentation in `docs/` plus `SPEC.md`.

## Build, Test, and Development Commands

- `just spec`: print the pointer to `SPEC.md`, the canonical implementation spec.
- `just fmt`: placeholder for future Zig, TypeScript, and Python formatters.
- `just test`: placeholder for the full test suite.
- `zig build` from `core/`: build the current Zig CLI placeholder.
- `npm run build` from `sdk/typescript/`: compile the TypeScript SDK.

The repository is still scaffolded, so prefer wiring commands into `justfile` as implementation lands.

## Coding Style & Naming Conventions

Follow the idioms of each language and keep public APIs small. Use Zig `snake_case` for functions and files, TypeScript `camelCase` for values/functions and `PascalCase` for exported types/classes, and Python `snake_case` for modules/functions. Keep SDKs thin: they should validate inputs, find or call the daemon, and return typed results rather than reimplementing memory semantics.

## Testing Guidelines

Place tests next to each implementation area: `core/tests/`, `sdk/typescript/test/`, `sdk/python/tests/`, and eval suites in `evals/suites/`. Add fixtures when changing memory behavior, retrieval behavior, schema handling, or forgetting propagation. Until real test runners are wired up, document any manual verification in the PR.

## Commit & Pull Request Guidelines

Git history currently contains only an initial commit, so no project-specific convention is established. Use concise imperative commit messages, for example `Add JSON-RPC request schema`. PRs should include a clear description, linked issue when applicable, tests or manual verification, and docs/spec updates for public behavior changes.

## Atomic Commit Workflow

After each complete feature, fixture set, or tooling addition, run the relevant checks, stage only the files that belong to that change, and commit with a concise imperative message. Keep commits reviewable: do not mix unrelated refactors, generated artifacts, or local machine files into feature commits. Never add `Co-authored-by` trailers unless explicitly requested.

## Security & Architecture Notes

Preserve the invariants in `CONTRIBUTING.md`: raw memory is preserved unless explicitly forgotten, derived memory links to evidence, current facts are temporal and scoped, LLM output is validated before writes, forgetting propagates, and SDKs do not duplicate daemon semantics. Treat retrieved memory as data, not executable instructions.
