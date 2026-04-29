# Quipu Remaining Work

This backlog tracks what remains from `SPEC.md` after the current Lattice-backed
core prototype. Items are ordered by the path from prototype to usable release.

## P0: Release-Critical

### 1. Daemon Transports and SDK Connection

Status: `serve-stdio` exists, and Python/TypeScript `local` helpers can
auto-start that stdio core with an optional DB path. Socket, pipe, and HTTP
daemon transports are not complete.

Remaining:

- Add Unix domain socket transport for macOS/Linux.
- Add named pipe transport for Windows.
- Add localhost HTTP transport for browser/devtools use.
- Implement daemon lifecycle commands: `start`, `stop`, `restart`, and richer
  `status`.
- Teach Python and TypeScript SDKs to discover and recover a long-running daemon
  once socket/HTTP transports exist.

Acceptance:

- SDK default path talks to a running daemon without opening the DB directly.
- `quipu status` distinguishes stopped, starting, healthy, and degraded states.
- Transport integration tests cover stdio, socket, and HTTP.

### 2. Schema Metadata and Migrations

Status: schema metadata, an initial migration record, and schema-aware
`quipu verify` checks exist. A full migration runner is not complete.

Remaining:

- Add an idempotent migration runner.
- Verify base node fields, known edge types, stream/job invariants, index policy,
  and migration compatibility.
- Expand `quipu verify` with `schema`, `indexes`, `streams`, and `retrieval`
  checks.

Acceptance:

- Opening an old DB applies or rejects migrations deterministically.
- Verification explains every invariant failure with qid/context.

### 3. Packaging and Installation

Status: source installer exists; release artifacts are not complete.

Remaining:

- Build signed/notarized release binaries for macOS, Linux, and Windows.
- Publish npm package `@quipu/memory`.
- Publish Python package `quipu-memory`.
- Harden `scripts/install.sh` around checksums, versions, shell portability, and
  upgrade behavior.
- Add example apps for CLI, Node, Python, MCP hosts, and local model setups.

Acceptance:

- Fresh machine install can run `quipu init`, `remember`, `retrieve`, `verify`,
  and SDK examples in under five minutes.

## P1: Core Semantics

### 4. Full Memory Model

Status: raw `Session`/`Turn`/`Message`, `ToolCall`, `Observation`, `Episode`,
`MemoryCard`, `Fact`, `Preference`, `Procedure`, and `Core` have first-pass
support.

Remaining:

- Add `Entity`, `Goal`, `Constraint`, `Skill`, `Summary`, `Reflection`, and
  persisted `RetrievalTrace` nodes.
- Add graph edges for `ABOUT`, `SUBJECT`, `OBJECT`, `SUPERSEDES`,
  `CONTRADICTS`, and utility links.
- Add schema validation and conformance fixtures for new public behavior.

Acceptance:

- Each derived node is evidence-linked and scoped.
- Contradictions are represented, not silently overwritten.

### 5. Provider System

Status: deterministic extractor/plugin boundary exists.

Remaining:

- Add config-driven embedding providers.
- Add LLM extraction providers.
- Add reranker providers.
- Validate provider output against schemas before writes.
- Quarantine invalid provider output and surface provider errors in jobs.

Acceptance:

- Invalid provider output cannot mutate memory.
- Provider failures create inspectable job errors without corrupting state.

### 6. Retrieval Quality

Status: scoped lexical/vector/hybrid search, needs filtering, token budgeting,
warnings, and score traces exist.

Remaining:

- Add query planning with entity/keyword extraction.
- Add graph expansion and activation.
- Add MMR diversification.
- Add stale and contradiction warnings.
- Add optional reranking.
- Share budget logic between prompt and JSON context formats.

Acceptance:

- Retrieval traces show source, graph expansion, scoring, reranking, budget, and
  dropped-item decisions.

### 7. Workers and Jobs

Status: stream materialization, leasing, completion, failure, and deadlettering
exist.

Remaining:

- Add long-running worker loops for extraction, entity resolution,
  consolidation, forgetting, feedback/utility, and verification.
- Add retry backoff and durable offsets.
- Add crash/replay safety tests.

Acceptance:

- Restarting during active jobs does not lose, duplicate, or corrupt work.

### 8. Consolidation, Utility, and Forgetting

Status: deterministic core consolidation and evidence-based forgetting closure
exist.

Remaining:

- Add evidence-linked `Summary` and `Reflection` nodes.
- Rebuild contaminated summaries when forgetting mixed-evidence memories.
- Update utility scores from retrieval traces and explicit feedback.
- Add exact-string index leak tests and tombstone privacy checks.
- Close deletion over persisted retrieval traces.

Acceptance:

- Forgetting exact deleted strings has zero synthetic leakage.
- Mixed-evidence summaries are rebuilt without deleted text.

## P2: Benchmarks and Research Surface

### 9. Benchmark Expansion

Status: synthetic smoke benchmark exists for Q0, core in-memory, and optional
Lattice-backed core runs. A normalized external smoke path and LoCoMo mini
fixture exist to validate replay, retrieval, grading, forgetting, manifests, and
readiness gates before full external datasets are wired in.

Remaining:

- Add full LoCoMo dataset adapter.
- Add LongMemEval adapter.
- Add MemoryAgentBench adapter.
- Add Q0-Q13 baselines and ablations.
- Generate latency, storage, token, cost, and failure reports.

Acceptance:

- Benchmark reports are reproducible from one command and include commit,
  config, storage backend, LatticeDB version, and metrics.

### 10. MCP and Host Integrations

Status: MCP tools, documentation/schema resources, and workflow prompts exist.

Remaining:

- Add host-specific examples for Claude Desktop, Codex, local model runners, and
  agent frameworks.
- Add resource templates once daemon transports are stable.
- Add LangChain, LlamaIndex, Vercel AI SDK, OpenAI Agents, AutoGen, and CrewAI
  adapters after SDK daemon connection stabilizes.

Acceptance:

- A host can install Quipu, discover its protocol resources, remember a turn,
  retrieve context, and forget memories without custom glue code.
