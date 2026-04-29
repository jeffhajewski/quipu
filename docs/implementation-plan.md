# Quipu Implementation Plan

This plan tracks the remaining implementation work from `SPEC.md`. Each block
should land as one or more atomic commits with focused verification.

## 1. Daemon and CLI

- Add durable defaults: `~/.quipu/default/quipu.lattice` and config discovery.
- Implement `quipu init`, `serve`, `status`, `remember`, `retrieve`, `inspect`,
  `forget`, `feedback`, `export`, and `import`.
- Add Unix socket and HTTP transports; keep stdio as the embedded/MCP path.
- Teach SDKs to connect to a running daemon, auto-start when configured, and
  recover from daemon restarts.

## 2. Schema and Migrations

- Store schema metadata in the database.
- Add migration records and an idempotent migration runner.
- Expand verification to check base node fields, index policy, stream/job
  invariants, and migration compatibility.
- Add `quipu verify schema indexes streams retrieval`.

## 3. Full Memory Model

- Add raw `ToolCall` and `Observation` ingestion.
- Add `Episode`, `MemoryCard`, `Entity`, `Goal`, `Constraint`, `Skill`,
  `Summary`, `Reflection`, and richer `RetrievalTrace` nodes.
- Add graph edges for `PART_OF`, `DERIVED_FROM`, `ABOUT`, `SUBJECT`, `OBJECT`,
  `COMPILED_FROM`, `SUPERSEDES`, `CONTRADICTS`, and utility links.

## 4. Extraction and Providers

- Define provider interfaces for embeddings, LLM extraction, reranking, and
  plugin execution.
- Add config-driven provider loading.
- Validate all extractor output against schemas before deterministic writes.
- Quarantine invalid provider output and surface provider errors in jobs.

## 5. Retrieval Quality

- Add query planning, query entities/keywords, candidate-source accounting, and
  score breakdowns.
- Add graph expansion/activation, MMR diversification, weak/stale/contradiction
  warnings, and optional reranking.
- Improve context packing so prompt and JSON formats share budget logic.

## 6. Workers and Jobs

- Implement job leasing, retry backoff, offsets, deadletter publishing, and job
  completion state transitions.
- Add worker loops for extraction, entity resolution, consolidation, forgetting,
  feedback/utility, and verification.
- Add crash/replay safety tests for stream offsets and failed jobs.

## 7. Consolidation and Utility

- Add deterministic session/project summary generation first.
- Add evidence-linked summaries, contamination markers, and rebuild jobs.
- Update utility scores from retrieval traces and explicit feedback.

## 8. Forgetting Hardening

- Add query/time/scope selectors.
- Compute deletion closure across raw, derived, summary, core, and trace nodes.
- Support mixed-evidence invalidation/rebuild behavior.
- Add exact-string index leak tests and tombstone privacy checks.

## 9. Evals and Benchmarks

- Save run manifests with commit, config, LatticeDB version, and metrics.
- Add LoCoMo, LongMemEval, and MemoryAgentBench adapters.
- Add baselines and ablations Q0-Q13.
- Generate reports with latency, storage, token, cost, and failure summaries.

## 10. MCP, Packaging, and Release

- Add MCP resources and prompts.
- Publish npm and Python packages once daemon connection is stable.
- Build release binaries and install artifacts for macOS/Linux/Windows.
- Add examples for CLI, Node, Python, MCP hosts, and local model setups.
