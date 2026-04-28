# Contributing

Quipu is intended to be a long-lived open-source project. Contributions should preserve the core invariants:

1. Raw memory is preserved unless explicitly forgotten.
2. Every derived memory links to evidence.
3. Current facts are temporal and scoped.
4. LLM outputs are validated before deterministic writes.
5. Forgetting must propagate to derived memories and indexes.
6. SDKs must not duplicate memory semantics.

Before opening a PR:

- Run unit tests.
- Run integration tests if touching storage/API.
- Add or update fixtures for memory behavior changes.
- Update SPEC.md or docs when changing public behavior.
