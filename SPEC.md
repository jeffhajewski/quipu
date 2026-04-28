# Quipu Implementation Specification

**Project:** Quipu
**Working tagline:** Evidence-backed temporal memory for long-horizon agents
**License:** MIT
**Status:** Implementation specification v0.1
**Audience:** core maintainers, SDK authors, benchmark authors, contributors, researchers
**Primary substrate:** LatticeDB by jeffhajewski/latticedb
**Primary runtime recommendation:** native Zig daemon + CLI, thin TypeScript/Python SDKs, optional MCP server

---

## 0. Executive summary

Quipu is a local-first, transactional, evidence-backed memory system for AI agents. It is built on top of LatticeDB and treats memory as a layered abstraction lattice rather than a flat vector index.

The system captures raw interaction history, compiles it into episodic memories, extracts semantic facts/preferences/goals, learns procedural lessons, builds summaries/reflections, and returns compact context packets to an agent at inference time. Every derived memory must be traceable to evidence. Time, validity, contradiction, scope, privacy, and forgetting are first-class.

The implementation should be a long-lived open-source project with a small public API, deep internal capabilities, robust verification, and a serious benchmark harness.

**Canonical architecture:**

```text
Agent runtime / app
  ├─ TypeScript SDK
  ├─ Python SDK
  ├─ CLI client
  └─ MCP server
        │
        ▼
Quipu daemon, written in Zig
  ├─ JSON-RPC API over Unix socket / named pipe / stdio / HTTP
  ├─ schema manager and migrations
  ├─ deterministic write templates
  ├─ ingestion pipeline
  ├─ retrieval planner
  ├─ context assembler
  ├─ consolidation workers
  ├─ forgetting propagator
  ├─ audit and verification engine
  └─ plugin host for LLM/embedding/reranker providers
        │
        ▼
LatticeDB single local file
  ├─ property graph
  ├─ HNSW vectors
  ├─ BM25 full text
  ├─ durable streams
  ├─ graph changefeed
  └─ WAL-backed ACID transactions
```

**Non-negotiable invariants:**

1. Raw memory is preserved unless explicitly forgotten.
2. Every derived memory links to evidence.
3. Every current semantic fact has temporal validity.
4. Contradictions are represented, not silently overwritten.
5. Deletion/forgetting propagates to derived memories and indexes.
6. Retrieval returns evidence-aware context packets, not arbitrary top-k chunks.
7. The daemon is the canonical writer; SDKs are thin clients.
8. LLM outputs are untrusted and must pass schema validation before deterministic writes.
9. Evaluation is a first-class package, not an afterthought.
10. API ergonomics should make the common path trivial: install, start, remember, retrieve.

---

## 1. Goals and non-goals

### 1.1 Goals

Quipu should:

- Give long-running agents reliable memory across sessions, projects, tools, and time.
- Support TypeScript/JavaScript, Python, CLI, and MCP workflows without duplicating memory logic.
- Use LatticeDB as the unified local graph/vector/text/event substrate.
- Provide minimal, stable public APIs with deep internal behavior.
- Be easy enough for a developer to run in five minutes.
- Be robust enough to test with serious benchmarks.
- Be publishable as a research artifact if the methods and evals prove strong.
- Be suitable for local personal agents, developer agents, research agents, and single-user/single-tenant memory shards.
- Support rigorous evidence, temporal validity, contradiction handling, selective forgetting, auditability, and eval reproducibility.

### 1.2 Non-goals for v0/v1

Quipu should not initially try to be:

- A distributed database.
- A multi-writer hosted SaaS memory platform.
- A replacement for LatticeDB.
- A general-purpose knowledge graph system.
- A fully autonomous memory-writing LLM with arbitrary database write access.
- A social/shared-memory platform.
- A massive real-time queueing system.
- A framework that locks users into one agent runtime.

### 1.3 Product principle

Quipu is not “RAG with a memory vibe.” It is a memory operating layer:

```text
observe → store raw evidence → extract candidates → resolve entities → update temporal facts
→ link memories → consolidate → retrieve → assemble context → evaluate use → update utility or forget
```

---

## 2. Key locked decisions

These are the decisions we should make now unless implementation proves them wrong.

### 2.1 Runtime

Use a **Zig native daemon** as the canonical memory runtime.

Rationale:

- LatticeDB is written in Zig and exposes a C API.
- Native binary distribution gives a SQLite/ripgrep/DuckDB-like local-infrastructure feel.
- One owning daemon fits LatticeDB's single-writer model.
- It avoids making Python or TypeScript the source of truth for memory semantics.
- SDKs can be thin, consistent clients.

### 2.2 Public interface

Use **JSON-RPC 2.0-style request/response** as the protocol shape.

Supported transports:

- Unix domain socket on Unix/macOS.
- Named pipe on Windows.
- stdio for simple embedding and MCP-style local subprocess workflows.
- localhost HTTP for browser/devtools/easier debugging.

The protocol should be stable before implementation details are stable.

### 2.3 SDK strategy

SDKs must not implement memory semantics. They should:

- Find or auto-start the daemon.
- Validate typed inputs.
- Call the protocol.
- Return typed outputs.
- Offer ergonomic helpers.

First-class SDKs:

- TypeScript: `@quipu/memory`
- Python: `quipu-memory`

Secondary SDKs/adapters later:

- Go
- Rust
- Java
- LangChain adapter
- LlamaIndex adapter
- Vercel AI SDK adapter
- OpenAI Agents adapter
- AutoGen/CrewAI adapter

### 2.4 CLI strategy

The CLI is a first-class surface but not the architecture.

The CLI should:

- Start/stop/status the daemon.
- Initialize and migrate DBs.
- Send protocol calls to the daemon.
- Print human-friendly output by default.
- Support `--json` everywhere.
- Support debugging, inspection, and eval use.

The CLI should not be the default path for every high-frequency SDK call. SDKs should talk to the daemon directly.

### 2.5 Storage

Use one LatticeDB file per local memory space by default:

```text
~/.quipu/default/quipu.lattice
```

Recommended layout for multi-user/local enterprise experiments:

```text
~/.quipu/users/{user_id}/memory.lattice
~/.quipu/projects/{project_id}/memory.lattice
~/.quipu/orgs/{org_id}/memory.lattice
```

v1 should start with one DB file per daemon instance. Multi-file federation should be a later layer.

### 2.6 Schema discipline

LatticeDB is a property graph, not a schema-enforced relational database. Quipu must enforce schema in the daemon:

- All nodes have required base properties.
- All edges use known edge types.
- All JSON payloads validate against Quipu schemas.
- All migrations are versioned.
- `quipu verify schema` checks invariants.

### 2.7 License

MIT license for Quipu source code.

Datasets may have separate licenses. Eval harness should preserve upstream dataset licenses and clearly report them.

---

## 3. Substrate assumptions about LatticeDB

This spec assumes the current LatticeDB project provides:

- Single-file local database.
- Property graph storage.
- HNSW vector search.
- BM25 full-text search.
- Graph/vector/full-text in one query layer.
- Durable named streams.
- Graph changefeed.
- ACID transactions with WAL recovery.
- Snapshot isolation.
- Multiple concurrent readers.
- Serialized write commits / single-writer model.
- C API with Python and TypeScript bindings wrapping it.

Implementation must verify these assumptions during the first milestone and pin a compatible LatticeDB version.

Where LatticeDB features are missing or unstable, Quipu must either:

1. implement a safe workaround,
2. make the feature optional, or
3. block release until fixed.

Particular areas to confirm early:

- Whether deleting a node fully removes vector and FTS index entries.
- Whether all needed C stream/changefeed APIs are available and stable.
- Whether map/list property types are practical through the C API; if not, store complex structures as JSON strings.
- Whether vector fields can be multi-field per node or should be one canonical embedding field.
- Whether query-plan caching behaves well for high-volume retrieval.

---

## 4. System architecture

### 4.1 Components

```text
core/
  Zig daemon and CLI

sdk/typescript/
  Thin TypeScript client

sdk/python/
  Thin Python client

mcp/
  MCP adapter exposing memory tools/resources/prompts

evals/
  Python benchmark harness and experiments

docs/
  Architecture, data model, API, testing, contribution docs
```

### 4.2 Daemon internal modules

```text
src/
  main.zig
  cli.zig
  config.zig
  rpc/
    server.zig
    protocol.zig
    transports/
      stdio.zig
      uds.zig
      named_pipe.zig
      http.zig
  db/
    lattice.zig
    migrations.zig
    schema.zig
    queries.zig
    tx.zig
  memory/
    ingest.zig
    extraction.zig
    entity_resolution.zig
    facts.zig
    cards.zig
    summaries.zig
    retrieval.zig
    scoring.zig
    context.zig
    forgetting.zig
    feedback.zig
    verify.zig
  streams/
    consumer.zig
    jobs.zig
    offsets.zig
    deadletter.zig
  providers/
    embeddings.zig
    llm.zig
    reranker.zig
    plugin_command.zig
    plugin_http.zig
  security/
    redaction.zig
    scopes.zig
    auth.zig
    secrets.zig
  observability/
    logs.zig
    metrics.zig
    traces.zig
```

### 4.3 Worker model

The daemon should run a small worker pool:

- `extractor`: turns raw events into candidate memories.
- `resolver`: resolves entities and candidate facts.
- `consolidator`: builds summaries/reflections/procedural lessons.
- `forgetter`: propagates deletion/redaction.
- `utility_updater`: updates utility from feedback/retrieval traces.
- `verifier`: optional periodic invariant checks.

LatticeDB durable streams do not implement retry/dead-letter/task-queue semantics by themselves, so Quipu must implement job state and retries on top.

### 4.4 Process model

Default:

```text
quipu serve --db ~/.quipu/default/quipu.lattice
```

SDK default behavior:

1. Try to connect to socket.
2. If absent and `autoStart=true`, spawn `quipu serve`.
3. Wait for health check.
4. Use socket for requests.
5. Do not open the DB directly.

---

## 5. Installation and developer experience

### 5.1 User experience targets

A new user should be able to do:

```bash
curl -fsSL https://install.quipu.dev | sh
quipu init
quipu serve
```

Then from TypeScript:

```bash
npm install @quipu/memory
```

```ts
import { Quipu } from "@quipu/memory";

const memory = await Quipu.local();

await memory.remember({
  messages: [{ role: "user", content: "For this repo, use pnpm, not npm." }],
  scope: { projectId: "repo:quipu" }
});

const ctx = await memory.retrieve({
  query: "What should I know before editing this repo?",
  budgetTokens: 1000,
  scope: { projectId: "repo:quipu" }
});

console.log(ctx.prompt);
```

Python:

```bash
pip install quipu-memory
```

```python
from quipu import Quipu

memory = Quipu.local()

memory.remember(
    messages=[{"role": "user", "content": "For this repo, use pnpm, not npm."}],
    scope={"project_id": "repo:quipu"},
)

ctx = memory.retrieve(
    query="What should I know before editing this repo?",
    budget_tokens=1000,
    scope={"project_id": "repo:quipu"},
)

print(ctx.prompt)
```

### 5.2 CLI commands

Minimal commands:

```bash
quipu init [--db PATH] [--embedding-dim N] [--profile local|research|prod]
quipu serve [--db PATH] [--socket PATH] [--http PORT] [--stdio]
quipu status
quipu remember --text TEXT [--session ID] [--project ID] [--json @file]
quipu retrieve --query TEXT [--budget-tokens N] [--project ID] [--json]
quipu inspect ID [--json]
quipu forget [--id ID | --query TEXT | --json @file] [--dry-run] [--propagate]
quipu feedback --retrieval ID --rating helpful|wrong|unused|unsafe [--json]
quipu verify [schema|indexes|forgetting|all]
quipu eval run --suite SUITE --config FILE
quipu export --format jsonl --out FILE
quipu import --format jsonl --in FILE
```

### 5.3 Configuration

Default config path:

```text
~/.quipu/config.toml
```

Example:

```toml
[daemon]
db_path = "~/.quipu/default/quipu.lattice"
socket_path = "~/.quipu/default/quipu.sock"
http_port = 0
log_level = "info"

[database]
cache_size_mb = 100
vector_dimensions = 1536
ef_search_default = 64

[embedding]
provider = "openai-compatible"
endpoint = "https://api.openai.com/v1"
model = "text-embedding-3-small"
dimensions = 1536
api_key_env = "OPENAI_API_KEY"

[llm.extractor]
provider = "openai-compatible"
endpoint = "https://api.openai.com/v1"
model = "gpt-5.5-mini"
api_key_env = "OPENAI_API_KEY"

[retrieval]
default_budget_tokens = 1200
max_candidates = 200
rerank_top_n = 50
enable_graph_activation = true
enable_llm_reranker = false

[privacy]
default_privacy_class = "normal"
redact_secrets = true
hard_delete_default = true

[workers]
extractor_concurrency = 2
consolidator_concurrency = 1
forgetter_concurrency = 1
```

---

## 6. Repository structure

The repo should be organized as a long-lived MIT open-source project:

```text
quipu/
  LICENSE
  README.md
  CONTRIBUTING.md
  SECURITY.md
  CODE_OF_CONDUCT.md
  CHANGELOG.md
  ROADMAP.md
  SPEC.md
  justfile
  .gitignore
  .editorconfig
  .github/
    workflows/
      ci.yml
      release.yml
    ISSUE_TEMPLATE/
    PULL_REQUEST_TEMPLATE.md
  core/
    README.md
    build.zig
    build.zig.zon
    src/
    tests/
    conformance/
  sdk/
    typescript/
      package.json
      tsconfig.json
      src/
      test/
      examples/
    python/
      pyproject.toml
      src/quipu/
      tests/
      examples/
  mcp/
    README.md
    package.json
    src/
  evals/
    README.md
    pyproject.toml
    src/quipu_evals/
    datasets/
      README.md
    suites/
      locomo.yaml
      longmemeval.yaml
      memoryagentbench.yaml
      quipu_synthetic.yaml
    experiments/
    reports/
  docs/
    architecture.md
    api.md
    data-model.md
    algorithms.md
    evals.md
    testing.md
    plugins.md
    security.md
    publication.md
  examples/
    cli-basic/
    node-agent/
    python-agent/
    mcp-claude-desktop/
    local-ollama/
```

### 6.1 Branching and versioning

- Default branch: `main`.
- Release tags: `v0.x.y`.
- Use semantic versioning once public API stabilizes.
- Before v1, breaking API changes allowed but must be documented.
- Public protocol has explicit `protocol_version`.

### 6.2 Open-source hygiene

Required before public announcement:

- MIT license.
- Security policy.
- Contribution guide.
- Clear local development setup.
- Reproducible eval instructions.
- CI with unit/integration tests.
- Minimal examples.
- No hardcoded provider keys.
- Clear dataset license notes.

---

## 7. Data model

### 7.1 Design principle

Quipu stores many memory forms in one graph:

```text
raw events → episodes → memory cards → semantic facts/preferences/goals → summaries/reflections/core memory
```

The graph is the spine. Vectors and full text are indexes over memory-bearing nodes. Streams are the event backbone.

### 7.2 ID conventions

All user-visible IDs are Quipu IDs, not LatticeDB internal node IDs.

Format:

```text
q_{type}_{ulid}
```

Examples:

```text
q_msg_01J...
q_ep_01J...
q_card_01J...
q_ent_01J...
q_fact_01J...
q_retr_01J...
q_del_01J...
```

LatticeDB internal IDs are stored in mappings and never exposed as the stable public ID.

### 7.3 Time conventions

Store both integer and string time:

```text
created_at_ms: int64 epoch ms
updated_at_ms: int64 epoch ms
event_time_ms: int64 epoch ms, nullable
event_time_iso: RFC3339 string, nullable
valid_from_ms: int64 epoch ms, nullable
valid_to_ms: int64 epoch ms, nullable
```

Rules:

- `created_at_ms` means when Quipu created the node.
- `event_time_ms` means when the event happened in the world.
- `observed_at_ms` means when Quipu learned it.
- `valid_from_ms` and `valid_to_ms` mean when a fact is believed true in the world.
- `valid_to_ms = null` means still current, unless `state != current`.

### 7.4 Base node properties

Every node must have:

```text
qid: string
qtype: string
schema_version: int
created_at_ms: int
updated_at_ms: int
state: active | current | superseded | disputed | redacted | deleted | archived
tenant_id: string | null
user_id: string | null
agent_id: string | null
project_id: string | null
scope_key: string
privacy_class: public | normal | sensitive | secret
source_hash: string | null
payload_json: string | null
```

Memory-bearing nodes should also have:

```text
text: string
text_hash: string
embedding_model: string | null
embedding_dim: int | null
importance: float 0..1
confidence: float 0..1
salience: float 0..1
utility_score: float
access_count: int
last_accessed_at_ms: int | null
```

### 7.5 Labels

Primary labels:

```text
:Tenant
:User
:Agent
:Project
:Scope
:Session
:Turn
:Message
:ToolCall
:Observation
:Episode
:MemoryCard
:Entity
:Fact
:Preference
:Goal
:Constraint
:Skill
:Workflow
:Step
:Summary
:Reflection
:MemoryBlock
:RetrievalTrace
:RetrievalCandidate
:RetrievalDecision
:Feedback
:DeletionRequest
:Tombstone
:AuditEvent
:ProviderConfig
:Migration
:Job
```

Nodes may have multiple labels, for example:

```text
(:Fact:MemoryBearing)
(:MemoryCard:MemoryBearing)
(:Summary:MemoryBearing)
(:Skill:MemoryBearing)
```

### 7.6 Edge types

Core structure:

```text
PART_OF
NEXT
PREVIOUS
AUTHORED_BY
HAS_TURN
HAS_MESSAGE
HAS_TOOL_CALL
HAS_OBSERVATION
```

Derivation/provenance:

```text
DERIVED_FROM
EVIDENCED_BY
COMPILED_FROM
SUMMARIZES
LEARNED_FROM
GENERATED_BY
```

Semantic graph:

```text
MENTIONS
ABOUT
SUBJECT
OBJECT
RELATES_TO
ALIAS_OF
INSTANCE_OF
MEMBER_OF
```

Temporal/change:

```text
CONTRADICTS
INVALIDATES
SUPERSEDES
REPLACES
CONFIRMS
DISPUTES
```

Procedural/action:

```text
USED_TOOL
PRODUCED
RESULTED_IN
APPLIES_TO
HAS_STEP
AVOIDED_BY
CAUSED
LED_TO
```

Retrieval/audit:

```text
RETRIEVED
SELECTED
REJECTED
USED_IN_ANSWER
RATED_AS
TRIGGERED_BY
```

Privacy/forgetting:

```text
VISIBLE_TO
REDACTED_BY
DELETED_BY
CONTAMINATED_BY
BLOCKED_BY_POLICY
```

Similarity/linking:

```text
SIMILAR_TO
DUPLICATE_OF
RELATED_MEMORY
```

### 7.7 Core node schemas

#### 7.7.1 Session

Labels: `:Session`

Properties:

```text
qid
qtype = "session"
title
started_at_ms
ended_at_ms
channel: cli | sdk | mcp | import | eval | other
external_session_id
scope_key
payload_json
```

Edges:

```text
(:Session)-[:PART_OF]->(:Project)
(:Turn)-[:PART_OF]->(:Session)
(:Episode)-[:PART_OF]->(:Session)
```

#### 7.7.2 Turn

Labels: `:Turn`

Properties:

```text
qid
qtype = "turn"
turn_index: int
started_at_ms
ended_at_ms
payload_json
```

Edges:

```text
(:Turn)-[:PART_OF]->(:Session)
(:Turn)-[:NEXT]->(:Turn)
(:Message)-[:PART_OF]->(:Turn)
(:ToolCall)-[:PART_OF]->(:Turn)
```

#### 7.7.3 Message

Labels: `:Message:MemoryBearing`

Properties:

```text
qid
qtype = "message"
role: system | user | assistant | tool | developer | other
author_id
content
text = content
sequence_index
turn_index
token_count
language
payload_json
```

Edges:

```text
(:Message)-[:PART_OF]->(:Turn)
(:Message)-[:AUTHORED_BY]->(:User | :Agent | :Tool)
(:Message)-[:MENTIONS]->(:Entity)
```

#### 7.7.4 ToolCall

Labels: `:ToolCall`

Properties:

```text
qid
qtype = "tool_call"
tool_name
input_json
output_json
status: pending | success | failed | cancelled
error_text
started_at_ms
ended_at_ms
payload_json
```

Edges:

```text
(:ToolCall)-[:PART_OF]->(:Turn)
(:ToolCall)-[:USED_TOOL]->(:Entity {type: tool})
(:ToolCall)-[:PRODUCED]->(:Artifact | :Observation)
```

#### 7.7.5 Episode

Labels: `:Episode:MemoryBearing`

An episode is a compact unit of experience derived from one or more turns/messages/tool events.

Properties:

```text
qid
qtype = "episode"
episode_type: conversation | decision | correction | tool_result | failure | success | preference_signal | task_state | other
title
summary
text = summary
start_time_ms
end_time_ms
importance
confidence
payload_json
```

Edges:

```text
(:Episode)-[:DERIVED_FROM]->(:Message | :Turn | :ToolCall | :Observation)
(:Episode)-[:PART_OF]->(:Session)
(:Episode)-[:ABOUT]->(:Entity | :Project | :Goal)
(:Episode)-[:NEXT]->(:Episode)
```

#### 7.7.6 MemoryCard

Labels: `:MemoryCard:MemoryBearing`

A memory card is an atomic retrieval note. It is usually shorter than an episode and richer than a fact.

Properties:

```text
qid
qtype = "memory_card"
kind: episodic | semantic | preference | procedural | reflective | warning | task_state
text
context_description
tags_json
keywords_json
importance
confidence
salience
utility_score
payload_json
```

Edges:

```text
(:MemoryCard)-[:EVIDENCED_BY]->(:Episode | :Message | :ToolCall)
(:MemoryCard)-[:ABOUT]->(:Entity | :Project | :Goal)
(:MemoryCard)-[:DERIVED_FROM]->(:Episode)
(:MemoryCard)-[:SIMILAR_TO {weight, reason}]->(:MemoryCard)
(:MemoryCard)-[:CONFIRMS | :CONTRADICTS]->(:Fact | :MemoryCard)
```

#### 7.7.7 Entity

Labels: `:Entity:MemoryBearing`

Properties:

```text
qid
qtype = "entity"
entity_type: user | person | org | project | repo | file | tool | concept | location | event | product | model | other
canonical_name
aliases_json
entity_key
summary
text = canonical_name + " " + summary
identity_confidence
payload_json
```

Edges:

```text
(:Entity)-[:ALIAS_OF]->(:Entity)
(:Fact)-[:SUBJECT]->(:Entity)
(:Fact)-[:OBJECT]->(:Entity)
(:MemoryCard)-[:ABOUT]->(:Entity)
```

Entity identity is one of the highest-risk areas. The system must avoid over-merging entities.

#### 7.7.8 Fact

Labels: `:Fact:MemoryBearing`

A fact is a temporal assertion.

Properties:

```text
qid
qtype = "fact"
fact_type: attribute | relation | state | event | preference | constraint | goal | task_state | other
subject_key
predicate
object_key
value_text
normalized_value
polarity: positive | negative | uncertain
text
valid_from_ms
valid_to_ms
observed_at_ms
confidence
state: current | superseded | disputed | deleted
slot_key
single_valued: bool
payload_json
```

Edges:

```text
(:Fact)-[:SUBJECT]->(:Entity)
(:Fact)-[:OBJECT]->(:Entity)
(:Fact)-[:EVIDENCED_BY]->(:Episode | :Message | :ToolCall)
(:Fact)-[:INVALIDATES]->(:Fact)
(:Fact)-[:SUPERSEDES]->(:Fact)
(:Fact)-[:CONTRADICTS]->(:Fact)
(:Fact)-[:CONFIRMS]->(:Fact)
```

Slot key format:

```text
{scope_key}|{subject_entity_qid}|{predicate}|{object_class_or_slot}
```

Examples:

```text
project:repo-quipu|q_ent_repo|package_manager|single
user:me|q_ent_user|prefers_answer_style|multi
```

#### 7.7.9 Preference

Labels: `:Preference:Fact:MemoryBearing`

Preferences can be modeled as facts with an additional label. Use explicit preference nodes when retrieval should treat them specially.

Properties:

```text
preference_type: communication | tooling | coding | scheduling | privacy | product | other
strength: weak | medium | strong
applies_to
exceptions_json
```

#### 7.7.10 Skill

Labels: `:Skill:MemoryBearing`

Properties:

```text
qid
qtype = "skill"
skill_type: workflow | tool_rule | failure_fix | style_rule | coding_pattern | research_pattern | other
name
text
trigger_json
steps_json
success_criteria_json
confidence
utility_score
payload_json
```

Edges:

```text
(:Skill)-[:LEARNED_FROM]->(:Episode | :ToolCall)
(:Skill)-[:APPLIES_TO]->(:Entity | :Project | :TaskType)
(:Skill)-[:AVOIDED_BY]->(:FailurePattern)
```

#### 7.7.11 Summary and Reflection

Labels: `:Summary:MemoryBearing`, `:Reflection:MemoryBearing`

Properties:

```text
summary_type: session | project | user | entity | topic | time_window | community
text
coverage_start_ms
coverage_end_ms
compression_ratio
source_count
confidence
staleness_score
contamination_state: clean | contaminated | needs_rebuild
payload_json
```

Edges:

```text
(:Summary)-[:SUMMARIZES]->(:Session | :Episode | :Entity | :Project)
(:Summary)-[:COMPILED_FROM]->(:MemoryCard | :Fact | :Episode)
(:Summary)-[:CONTAMINATED_BY]->(:DeletionRequest)
```

#### 7.7.12 MemoryBlock

Labels: `:MemoryBlock:MemoryBearing`

Core memory block, always or often injected.

Properties:

```text
block_key: persona | human_profile | active_goals | project_state | tool_rules | communication_preferences | safety | custom
text
char_limit
priority
mutable: bool
managed_by: user | agent | system
payload_json
```

Edges:

```text
(:MemoryBlock)-[:COMPILED_FROM]->(:Fact | :Preference | :Summary | :Skill)
(:MemoryBlock)-[:ABOUT]->(:User | :Project | :Agent)
```

#### 7.7.13 RetrievalTrace

Labels: `:RetrievalTrace`

Properties:

```text
qid
qtype = "retrieval_trace"
query
query_hash
request_json
response_json
strategy
candidate_count
selected_count
budget_tokens
estimated_tokens
latency_ms_total
latency_ms_vector
latency_ms_fts
latency_ms_graph
latency_ms_rerank
created_at_ms
payload_json
```

Edges:

```text
(:RetrievalTrace)-[:RETRIEVED {score, source}]->(:MemoryBearing)
(:RetrievalTrace)-[:SELECTED {rank, reason}]->(:MemoryBearing)
(:RetrievalTrace)-[:REJECTED {reason}]->(:MemoryBearing)
(:Feedback)-[:RATED_AS]->(:RetrievalTrace)
```

#### 7.7.14 DeletionRequest and Tombstone

Labels: `:DeletionRequest`, `:Tombstone`

Properties:

```text
qid
qtype = "deletion_request"
request_type: hard_delete | soft_delete | redact | expire
selector_json
dry_run: bool
status: pending | running | completed | failed
created_at_ms
completed_at_ms
report_json
```

Tombstone properties:

```text
qid
qtype = "tombstone"
deleted_qid
original_qtype
reason
request_qid
deleted_at_ms
hash_before_delete
```

Edges:

```text
(:Tombstone)-[:DELETED_BY]->(:DeletionRequest)
(:Summary)-[:CONTAMINATED_BY]->(:DeletionRequest)
(:Fact)-[:DELETED_BY]->(:DeletionRequest)
```

### 7.8 FTS and vector indexing policy

Index these nodes for full text:

```text
Message
Episode
MemoryCard
Entity
Fact
Preference
Skill
Summary
Reflection
MemoryBlock
```

Attach embeddings to these nodes:

```text
Episode
MemoryCard
Entity
Fact
Preference
Skill
Summary
Reflection
MemoryBlock
```

Do not embed every raw message by default if cost matters. Make raw-message embeddings configurable.

Default embedding text:

```text
MemoryCard: kind + text + context_description + tags
Fact: subject + predicate + value_text + temporal qualifiers
Entity: canonical_name + aliases + summary
Skill: name + trigger + steps
Summary: summary_type + text
```

---

## 8. Streams and jobs

### 8.1 Stream names

Use these durable streams:

```text
quipu.raw_event
quipu.extract.requested
quipu.extract.completed
quipu.entity.resolve.requested
quipu.fact.upserted
quipu.card.created
quipu.consolidate.requested
quipu.consolidate.completed
quipu.forget.requested
quipu.forget.completed
quipu.retrieval.logged
quipu.feedback.received
quipu.audit
quipu.deadletter
```

### 8.2 Job node

Because LatticeDB streams are not a full task queue, Quipu creates `:Job` nodes.

Properties:

```text
qid
qtype = "job"
stream_name
stream_sequence
kind
status: pending | leased | running | succeeded | failed | deadlettered
attempts
max_attempts
lease_owner
lease_until_ms
started_at_ms
completed_at_ms
error_json
payload_hash
payload_json
```

Job processing rules:

1. Read stream records after durable offset.
2. For each record, create or find a `Job` by `{stream_name, stream_sequence}`.
3. Lease the job in a write transaction.
4. Run work outside the write transaction.
5. Write results and mark succeeded in one transaction.
6. Advance durable consumer offset only after successful transaction.
7. On failure, increment attempts and back off.
8. If attempts exceed threshold, publish `quipu.deadletter`.

### 8.3 Transactional ingestion pattern

When a user calls `remember`, Quipu must write raw memory and publish extraction request in the same transaction:

```text
BEGIN WRITE
  create Session/Turn/Message/ToolCall nodes
  create structure edges
  fts_index memory-bearing raw nodes
  optionally set embeddings
  publish_stream("quipu.extract.requested", payload)
  create AuditEvent
COMMIT
```

This ensures the extractor never sees a request whose raw data is missing.

---

## 9. Public API

### 9.1 API design principle

The public API should be minimal but deep.

End users should primarily need five operations:

```text
remember
retrieve
forget
inspect
feedback
```

Admin/dev operations:

```text
health
configure
verify
export
import
```

### 9.2 Protocol envelope

Request:

```json
{
  "jsonrpc": "2.0",
  "id": "req_123",
  "method": "memory.retrieve",
  "params": { }
}
```

Response:

```json
{
  "jsonrpc": "2.0",
  "id": "req_123",
  "result": { }
}
```

Error:

```json
{
  "jsonrpc": "2.0",
  "id": "req_123",
  "error": {
    "code": "invalid_request",
    "message": "budgetTokens must be positive",
    "details": { }
  }
}
```

### 9.3 Error codes

```text
invalid_request
unauthorized
forbidden
not_found
conflict
provider_error
embedding_error
llm_error
storage_error
schema_error
migration_required
version_mismatch
rate_limited
cancelled
internal_error
```

### 9.4 Method: `system.health`

Request:

```json
{}
```

Response:

```json
{
  "status": "ok",
  "version": "0.1.0",
  "protocolVersion": "2026-04-quipu-v1",
  "dbPath": "/Users/me/.quipu/default/quipu.lattice",
  "latticeVersion": "0.5.0",
  "schemaVersion": 1,
  "workers": {
    "extractor": "running",
    "consolidator": "running"
  }
}
```

### 9.5 Method: `memory.remember`

Purpose: store raw events and optionally schedule extraction.

Request:

```json
{
  "sessionId": "optional-external-session-id",
  "scope": {
    "tenantId": null,
    "userId": "user-local",
    "agentId": "agent-default",
    "projectId": "repo:quipu"
  },
  "messages": [
    {
      "role": "user",
      "content": "For this repo, use pnpm, not npm.",
      "createdAt": "2026-04-28T10:15:00-07:00"
    }
  ],
  "toolCalls": [],
  "observations": [],
  "metadata": {},
  "extract": true,
  "importanceHint": 0.7,
  "privacyClass": "normal",
  "idempotencyKey": "optional-client-generated-key"
}
```

Response:

```json
{
  "sessionQid": "q_sess_...",
  "turnQid": "q_turn_...",
  "messageQids": ["q_msg_..."],
  "queuedJobs": ["q_job_..."],
  "status": "stored"
}
```

Rules:

- Always persist raw event before extraction.
- `extract=false` means store raw only; no extraction job.
- Idempotency key prevents duplicate raw writes.
- All content is indexed for FTS unless `privacyClass=secret` and config disables indexing secrets.
- If provider unavailable, raw write still succeeds; extraction job may fail/retry.

### 9.6 Method: `memory.retrieve`

Purpose: return a context packet for the current agent need.

Request:

```json
{
  "query": "What should I know before editing this repo?",
  "task": "coding_assistance",
  "scope": {
    "userId": "user-local",
    "projectId": "repo:quipu"
  },
  "budgetTokens": 1200,
  "needs": ["current_facts", "preferences", "procedural", "recent_episodes"],
  "time": {
    "validAt": null,
    "eventWindowStart": null,
    "eventWindowEnd": null
  },
  "options": {
    "includeEvidence": true,
    "includeDebug": false,
    "logTrace": true,
    "abstainIfWeak": true,
    "format": "prompt"
  }
}
```

Response:

```json
{
  "retrievalId": "q_retr_...",
  "prompt": "<memory>...</memory>",
  "context": {
    "core": [],
    "currentFacts": [],
    "preferences": [],
    "procedural": [],
    "episodes": [],
    "warnings": []
  },
  "items": [
    {
      "qid": "q_fact_...",
      "type": "fact",
      "text": "The repo uses pnpm rather than npm.",
      "score": 0.91,
      "confidence": 0.94,
      "state": "current",
      "validFrom": "2026-04-28T10:15:00-07:00",
      "evidence": [
        {
          "qid": "q_msg_...",
          "quote": "For this repo, use pnpm, not npm.",
          "timestamp": "2026-04-28T10:15:00-07:00"
        }
      ]
    }
  ],
  "tokenEstimate": 684,
  "confidence": 0.82,
  "warnings": []
}
```

Rules:

- Retrieval must filter by scope before ranking.
- Current-truth retrieval must suppress superseded/deleted facts unless specifically requested.
- Evidence should be included by default in structured output, but prompt text may be compact.
- Retrieval logs a trace unless disabled.
- Retrieval should return warnings when evidence is weak, stale, contradicted, or contaminated.

### 9.7 Method: `memory.search`

Purpose: debugging and direct memory exploration. This is not the primary agent context method.

Request:

```json
{
  "query": "pnpm",
  "mode": "hybrid",
  "labels": ["Fact", "MemoryCard", "Episode"],
  "scope": { "projectId": "repo:quipu" },
  "limit": 20,
  "includeDeleted": false
}
```

Response:

```json
{
  "results": [
    { "qid": "q_fact_...", "type": "fact", "text": "...", "score": 0.88 }
  ]
}
```

### 9.8 Method: `memory.inspect`

Purpose: inspect a memory, its provenance, dependencies, and deletion status.

Request:

```json
{
  "qid": "q_fact_...",
  "includeProvenance": true,
  "includeDependents": true,
  "includeRaw": true
}
```

Response:

```json
{
  "node": { "qid": "q_fact_...", "type": "fact", "properties": {} },
  "provenance": [
    { "edge": "EVIDENCED_BY", "node": { "qid": "q_msg_...", "text": "..." } }
  ],
  "dependents": [],
  "audit": []
}
```

### 9.9 Method: `memory.forget`

Purpose: delete, redact, or expire memories and propagate changes.

Request:

```json
{
  "mode": "hard_delete",
  "selector": {
    "qids": ["q_msg_..."],
    "query": null,
    "scope": { "userId": "user-local" },
    "timeWindow": null
  },
  "propagate": true,
  "dryRun": false,
  "reason": "user_request"
}
```

Response:

```json
{
  "deletionRequestQid": "q_del_...",
  "status": "completed",
  "dryRun": false,
  "rootsMatched": 1,
  "nodesDeleted": 4,
  "nodesRedacted": 0,
  "factsInvalidated": 2,
  "summariesContaminated": 1,
  "jobsQueued": ["q_job_..."],
  "report": []
}
```

Rules:

- Dry run is required in CLI unless `--yes` is passed.
- Forgetting must remove or redact raw memory and all derived memories whose only evidence is deleted.
- Derived memories with mixed evidence become contaminated or are rebuilt.
- Retrieval must not return deleted/redacted memories.
- If underlying index deletion is uncertain, Quipu must block hard-delete release until verified or implement index rebuild.

### 9.10 Method: `memory.feedback`

Purpose: update utility and improve retrieval policies.

Request:

```json
{
  "retrievalId": "q_retr_...",
  "rating": "helpful",
  "usedItemQids": ["q_fact_..."],
  "ignoredItemQids": [],
  "corrections": [
    {
      "type": "fact_correction",
      "text": "Actually this repo now uses npm again."
    }
  ],
  "metadata": {}
}
```

Response:

```json
{
  "feedbackQid": "q_fb_...",
  "queuedJobs": ["q_job_..."],
  "status": "stored"
}
```

### 9.11 Method: `memory.core.get` / `memory.core.update`

Core memory can be accessed as explicit methods or via `memory.retrieve(needs=["core"])`.

Update request:

```json
{
  "blockKey": "project_state",
  "scope": { "projectId": "repo:quipu" },
  "text": "Quipu is a Zig daemon over LatticeDB with TypeScript/Python SDKs.",
  "mode": "replace",
  "evidenceQids": ["q_fact_..."],
  "managedBy": "user"
}
```

---

## 10. Core algorithms

### 10.1 Remember algorithm

```text
function remember(req):
  validate request schema
  normalize scope
  compute idempotency key
  if idempotency key exists:
    return existing result

  begin write transaction
    upsert Tenant/User/Agent/Project/Scope nodes as needed
    upsert or create Session
    create Turn
    link Turn to Session and previous Turn
    for each message:
      create Message
      link Message to Turn
      fts_index Message text unless policy disables
      optionally embed Message if configured
    for each tool call / observation:
      create nodes and edges
    create AuditEvent
    if req.extract:
      publish quipu.extract.requested
    commit

  return qids and queued job refs
```

### 10.2 Episode construction

Episode construction should be pluggable.

Default v0:

- One episode per user/assistant turn pair.
- One episode per significant tool result.
- One episode per explicit correction.
- One episode per decision/outcome if extractor identifies one.

Candidate episode types:

```text
conversation
preference_signal
correction
decision
failure
success
tool_result
project_state_update
procedural_lesson
```

Episode scoring:

```text
importance = max(
  explicit_user_instruction,
  correction_signal,
  decision_signal,
  tool_failure_signal,
  task_outcome_signal,
  preference_signal,
  model_importance_score
)
```

### 10.3 Extraction algorithm

Extraction is plugin-based.

Input:

- Raw messages/tool calls.
- Current scope.
- Recent session summary.
- Existing core memory.
- Existing related facts if cheap.

Output JSON schema:

```json
{
  "entities": [
    {
      "name": "pnpm",
      "type": "tool",
      "aliases": [],
      "description": "JavaScript package manager",
      "confidence": 0.9
    }
  ],
  "facts": [
    {
      "subject": "repo:quipu",
      "predicate": "uses_package_manager",
      "value": "pnpm",
      "factType": "state",
      "singleValued": true,
      "validFrom": null,
      "confidence": 0.95,
      "evidenceQuote": "For this repo, use pnpm, not npm."
    }
  ],
  "preferences": [],
  "goals": [],
  "constraints": [],
  "skills": [],
  "memoryCards": [
    {
      "kind": "procedural",
      "text": "For repo:quipu, use pnpm rather than npm.",
      "contextDescription": "User gave an explicit tooling instruction.",
      "tags": ["repo", "tooling", "package-manager"],
      "importance": 0.8,
      "confidence": 0.95
    }
  ],
  "shouldConsolidate": false
}
```

Validation rules:

- All fields must conform to schema.
- Confidence must be 0..1.
- Evidence quote must match or be semantically grounded in source span.
- Entity names cannot be empty.
- Facts require subject, predicate, value.
- Low-confidence facts are stored as disputed/candidate or only as cards depending on policy.

### 10.4 Entity resolution algorithm

```text
function resolve_entity(candidate, scope):
  candidates = []
  candidates += exact name lookup in same scope
  candidates += alias lookup
  candidates += BM25 search over Entity text
  candidates += vector search over Entity embeddings
  candidates += graph-neighborhood search from current session/project/user

  score each candidate:
    name_similarity
    alias_match
    type_match
    scope_match
    vector_similarity
    graph_context_overlap
    recency

  if top_score > merge_threshold and gap > margin:
    return existing entity
  if ambiguous:
    create new entity and optionally link RELATED_MEMORY
  else:
    create new entity
```

Default thresholds:

```text
merge_threshold = 0.86
ambiguous_threshold = 0.70
min_gap = 0.08
```

Never over-merge people, projects, repositories, or organizations solely by vector similarity.

### 10.5 Fact upsert and contradiction algorithm

```text
function upsert_fact(candidate):
  resolve subject entity
  resolve object entity if applicable
  compute slot_key

  existing = current facts with same slot_key

  for each old in existing:
    relation = classify_relation(candidate, old)
      one of: same, confirms, updates, contradicts, unrelated

    if same/confirms:
      attach new evidence to old
      update confidence and observed_at
      optionally create confirming edge
      return old

    if updates or contradicts:
      if predicate is single-valued or contradiction is strong:
        mark old superseded/disputed
        set old.valid_to_ms = candidate.valid_from_ms or observed_at_ms
        create new fact
        create INVALIDATES/SUPERSEDES/CONTRADICTS edges
        return new

  create new current fact
```

Confidence update:

```text
new_confidence = clamp(
  1 - product(1 - evidence_confidence_i * source_reliability_i),
  0,
  1
)
```

State transition rules:

```text
current + contradicting new current fact => superseded or disputed
current + weak contradiction => disputed, not superseded
superseded facts are retrievable only for historical queries
redacted/deleted facts are never returned except audit/admin if allowed
```

### 10.6 Memory card linking algorithm

When a card is created:

1. Embed the card text.
2. FTS-index the card text.
3. Retrieve top semantically similar cards in scope.
4. Retrieve cards sharing tags/entities.
5. Classify relationship:
   - duplicate
   - supports
   - elaborates
   - contradicts
   - same topic
   - unrelated
6. Create links only above threshold.

Default:

```text
SIMILAR_TO threshold = 0.78
DUPLICATE_OF threshold = 0.94 plus high lexical overlap
max_links_per_card = 8
```

### 10.7 Consolidation algorithm

Triggers:

- End of session.
- Every N turns, default 20.
- High-importance event.
- Before context budget pressure.
- After deletion contamination.
- Manual `quipu consolidate`.

Consolidation outputs:

```text
session summary
project summary
entity summary
preference rollup
procedural lesson
core memory block update
reflection
```

Rules:

- Summaries must link to all source nodes.
- Summaries must include coverage window.
- Summaries must be invalidated/contaminated when source nodes are deleted.
- Summary generation is allowed to be LLM-based, but writes are deterministic and evidence-linked.
- A summary cannot be the only evidence for a fact unless explicitly marked as inferred.

### 10.8 Retrieval planner

Retrieval is the core product behavior.

Pipeline:

```text
1. Analyze query and task.
2. Normalize scope and time constraints.
3. Generate query embedding.
4. Extract query entities and keywords.
5. Candidate generation:
   - core memory
   - vector search
   - BM25/FTS search
   - fuzzy search for typos
   - graph expansion from entities/project/session
   - recency/current-session memories
   - procedural skill triggers
   - temporal facts valid at requested time
6. Merge and deduplicate candidates.
7. Graph activation expansion.
8. Score candidates.
9. Rerank/diversify.
10. Evidence check.
11. Context packing.
12. Log retrieval trace.
```

### 10.9 Candidate generation

Default limits:

```text
vector_top_k = 80
fts_top_k = 80
fuzzy_top_k = 20
graph_top_k = 80
recency_top_k = 30
core_top_k = all matching blocks
merged_candidate_cap = 200
```

Vector query:

```cypher
MATCH (m:MemoryBearing)
WHERE m.embedding <=> $query_vec < $max_distance
  AND m.scope_key IN $allowed_scopes
  AND m.state <> "deleted"
RETURN m, m.embedding <=> $query_vec AS distance
ORDER BY distance
LIMIT $k
```

FTS query:

```cypher
MATCH (m:MemoryBearing)
WHERE m.text @@ $query_text
  AND m.scope_key IN $allowed_scopes
  AND m.state <> "deleted"
RETURN m
LIMIT $k
```

Graph expansion examples:

```cypher
MATCH (e:Entity {qid: $entity_qid})<-[:ABOUT|SUBJECT|OBJECT]-(m:MemoryBearing)
WHERE m.scope_key IN $allowed_scopes
RETURN m
LIMIT $k
```

```cypher
MATCH (p:Project {qid: $project_qid})<-[:ABOUT]-(m:MemoryBearing)
RETURN m
ORDER BY m.importance DESC, m.updated_at_ms DESC
LIMIT $k
```

Temporal current facts:

```cypher
MATCH (f:Fact)
WHERE f.scope_key IN $allowed_scopes
  AND f.state = "current"
  AND (f.valid_from_ms IS NULL OR f.valid_from_ms <= $valid_at_ms)
  AND (f.valid_to_ms IS NULL OR f.valid_to_ms > $valid_at_ms)
RETURN f
LIMIT $k
```

### 10.10 Graph activation

Purpose: retrieve structurally relevant memories that vector/FTS miss.

Inputs:

- Seed candidates with base scores.
- Current entities.
- Active project/session/user.

Algorithm:

```text
activation[node] = seed_score[node]
frontier = seeds
for depth in 1..max_depth:
  next_frontier = []
  for node in frontier:
    for edge in outgoing + incoming allowed edges:
      weight = edge_type_weight(edge.type)
      contribution = activation[node] * weight * depth_decay(depth)
      if target is blocked/deleted/out_of_scope:
        continue
      activation[target] += contribution
      if contribution > min_activation:
        next_frontier.push(target)
  frontier = top next_frontier by activation
apply lateral inhibition for near duplicates
return activation scores
```

Default parameters:

```text
max_depth = 2
frontier_cap = 100
min_activation = 0.03
depth_decay(1) = 0.70
depth_decay(2) = 0.35
```

Edge weights:

```text
EVIDENCED_BY: 0.90
DERIVED_FROM: 0.85
ABOUT: 0.80
SUBJECT/OBJECT: 0.75
COMPILED_FROM: 0.70
LEARNED_FROM: 0.70
APPLIES_TO: 0.70
SIMILAR_TO: edge.weight or 0.50
NEXT/PREVIOUS: 0.30
CONTRADICTS: special, not normal positive activation
INVALIDATES/SUPERSEDES: special, penalty for current retrieval; positive for historical/debug retrieval
```

### 10.11 Scoring

Default scoring formula:

```text
score =
  0.22 * semantic_score
+ 0.14 * lexical_score
+ 0.18 * graph_activation_score
+ 0.12 * temporal_validity_score
+ 0.10 * scope_score
+ 0.08 * confidence
+ 0.08 * importance
+ 0.05 * learned_utility
+ 0.03 * recency_score
- 0.20 * contradiction_penalty
- 0.25 * deletion_or_redaction_penalty
- 0.10 * staleness_penalty
- 0.10 * privacy_penalty
```

All weights are experimental knobs.

Score normalization:

```text
semantic_score = 1 - normalized_distance
lexical_score = normalized BM25/FTS score
recency_score = exp(-age_days / half_life_days)
temporal_validity_score = 1 if valid, 0 if invalid, 0.5 if unknown
scope_score = exact project/user match > user match > global > unrelated
```

### 10.12 Reranking and diversification

Default v0 should be deterministic:

1. Sort by score.
2. Remove duplicates by `DUPLICATE_OF` or text hash.
3. Apply MMR:

```text
mmr_score = lambda * relevance - (1 - lambda) * max_similarity_to_selected
lambda = 0.72
```

LLM/cross-encoder reranker is optional behind config:

```toml
[retrieval]
enable_llm_reranker = false
```

### 10.13 Context assembly

Context assembly must be deterministic and budget-aware.

Default sections:

```text
<core_memory>
...
</core_memory>

<current_facts>
...
</current_facts>

<preferences>
...
</preferences>

<procedural_memory>
...
</procedural_memory>

<relevant_episodes>
...
</relevant_episodes>

<warnings>
...
</warnings>
```

Packing order:

1. Safety/policy core blocks.
2. Active task/project state.
3. Current user preferences relevant to task.
4. Current facts with strong evidence.
5. Procedural lessons relevant to task/tool.
6. Recent/relevant episodes.
7. Historical or contradicted facts only if requested.

Budgeting:

```text
reserve 10% for section headers and warnings
reserve 20% for evidence if includeEvidence=true
truncate low-score sections first
never truncate inside machine-readable JSON if format=json
```

A context item should include:

```text
claim/text
type
confidence
validity
date/effective time
evidence pointer
```

### 10.14 Forgetting algorithm

Forgetting modes:

```text
hard_delete: remove nodes/edges/indexes where possible
redact: keep structure but remove sensitive text/value
soft_delete: mark deleted, never retrieve
expire: mark inactive after TTL
```

Algorithm:

```text
function forget(req):
  validate selector
  begin write transaction
    create DeletionRequest
    find root nodes
    if dry_run:
      compute closure and return report
    mark request running
  commit

  closure = compute_deletion_closure(root_nodes)

  begin write transaction
    for each raw node in closure:
      hard delete or redact
    for each derived node:
      if all evidence deleted:
        delete/redact/mark deleted
      else:
        mark contaminated and queue rebuild
    invalidate facts whose evidence removed
    mark summaries contaminated
    create tombstones
    publish forget.completed
    create audit events
  commit

  run verification pass
```

Closure rules:

- If a Message is deleted, Episodes derived only from it are deleted.
- Facts evidenced only by deleted episodes are deleted/superseded.
- Facts with remaining evidence are retained but confidence recalculated.
- Summaries compiled from deleted material are contaminated and must not be retrieved until rebuilt, unless configured to include a warning.
- MemoryBlocks compiled from contaminated summaries must be rebuilt or temporarily disabled.
- RetrievalTrace can keep metadata but must not leak deleted text.

### 10.15 Utility learning

Update memory utility based on feedback and implicit signals.

Positive signals:

```text
item selected in context
item cited/used in final answer
user says answer was helpful
item frequently retrieved for same task type
```

Negative signals:

```text
item retrieved but ignored repeatedly
user correction contradicts item
item causes bad answer
item stale or cross-scope contamination
```

Update:

```text
utility_score = decay(old_utility) + alpha * feedback_signal
```

Default:

```text
alpha_positive = 0.10
alpha_negative = 0.20
monthly_decay = 0.95
```

---

## 11. Pluggable experiment surface

These are intentionally variable. The harness should let us mix and compare them.

### 11.1 Extraction strategies

```text
none/raw-only
rules-only
LLM atomic facts
LLM memory cards
LLM facts + cards
LLM facts + cards + skills
LLM facts with evidence quote verification
small model extraction vs large model extraction
```

### 11.2 Episode segmentation

```text
turn-based
topic-shift based
tool-boundary based
LLM segmented
hybrid heuristics + LLM
```

### 11.3 Entity resolution

```text
exact-only
lexical + aliases
vector + lexical
vector + lexical + graph context
LLM verifier
conservative vs aggressive merge thresholds
```

### 11.4 Fact update policy

```text
append-only
single-valued slot supersession
temporal validity windows
LLM contradiction classifier
evidence-count confidence update
human-confirmed update for sensitive facts
```

### 11.5 Retrieval strategies

```text
vector-only
BM25-only
vector + BM25
vector + BM25 + graph expansion
vector + BM25 + graph activation
query-rewrite enabled/disabled
LLM rerank enabled/disabled
evidence rerank enabled/disabled
```

### 11.6 Context assembly formats

```text
plain bullets
XML sections
JSON context packet
claim/evidence table
minimal core-only
verbose evidence-backed
```

### 11.7 Forgetting modes

```text
soft-delete only
hard-delete with tombstones
redaction mode
summary contamination without rebuild
summary contamination with rebuild
selective evidence removal
```

### 11.8 Provider choices

```text
OpenAI-compatible embeddings
Ollama/local embeddings
hash embeddings for deterministic tests
small extractor model
large extractor model
cross-encoder reranker
LLM-as-reranker
no LLM mode for tests
```

---

## 12. Evaluation harness

### 12.1 Goals

The eval harness must answer:

- Does Quipu retrieve the right evidence?
- Does Quipu answer correctly when connected to a model?
- Does Quipu suppress stale or contradicted facts?
- Does Quipu abstain when memory is insufficient?
- Does Quipu prevent cross-scope contamination?
- Does Quipu forget completely and verifiably?
- Does Quipu improve over baselines and ablations?
- What is the latency, token, cost, and storage tradeoff?
- Which algorithms are actually responsible for gains?

### 12.2 Harness architecture

```text
evals/
  src/quipu_evals/
    runner.py
    datasets/
    agents/
      quipu_agent.py
      vector_rag_agent.py
      bm25_agent.py
      full_context_agent.py
      external_baselines.py
    graders/
      exact.py
      f1.py
      retrieval.py
      temporal.py
      llm_judge.py
      forgetting.py
    metrics/
    reports/
    fixtures/
  suites/
    locomo.yaml
    longmemeval.yaml
    memoryagentbench.yaml
    quipu_synthetic.yaml
```

### 12.3 Dataset scenario schema

All benchmarks should compile into one internal scenario format:

```json
{
  "scenarioId": "scenario_001",
  "metadata": {
    "source": "quipu_synthetic",
    "license": "MIT",
    "description": "Package manager update and forgetting test"
  },
  "actors": [
    { "id": "user", "type": "user", "name": "User" },
    { "id": "assistant", "type": "agent", "name": "Assistant" }
  ],
  "events": [
    {
      "eventId": "e1",
      "time": "2026-01-01T10:00:00Z",
      "type": "message",
      "messages": [
        { "role": "user", "content": "This repo uses npm." }
      ],
      "scope": { "projectId": "repo:test" },
      "groundTruthMemories": ["m1"]
    },
    {
      "eventId": "e2",
      "time": "2026-02-01T10:00:00Z",
      "type": "message",
      "messages": [
        { "role": "user", "content": "We migrated this repo to pnpm. Use pnpm now." }
      ],
      "scope": { "projectId": "repo:test" },
      "groundTruthMemories": ["m2"]
    }
  ],
  "queries": [
    {
      "queryId": "q1",
      "time": "2026-03-01T10:00:00Z",
      "query": "What package manager should I use?",
      "scope": { "projectId": "repo:test" },
      "expectedAnswer": "pnpm",
      "expectedEvidenceEventIds": ["e2"],
      "mustNotUseEventIds": ["e1"],
      "category": "knowledge_update",
      "shouldAbstain": false
    },
    {
      "queryId": "q2",
      "time": "2026-01-15T10:00:00Z",
      "query": "What package manager did we use in mid January?",
      "expectedAnswer": "npm",
      "expectedEvidenceEventIds": ["e1"],
      "category": "temporal"
    }
  ],
  "forgetOps": [
    {
      "forgetId": "f1",
      "afterEventId": "e2",
      "selector": { "eventIds": ["e1"] },
      "mode": "hard_delete",
      "expectedNotRetrievableText": ["This repo uses npm"]
    }
  ]
}
```

### 12.4 Eval run flow

For each scenario:

1. Create isolated temp DB.
2. Start daemon with pinned config.
3. Replay events in chronological order via `memory.remember`.
4. Optionally wait for or force extraction/consolidation.
5. Run queries via `memory.retrieve`.
6. Optionally call an answer model using the context packet.
7. Grade retrieval evidence.
8. Grade answer.
9. Execute forget operations.
10. Re-run affected queries.
11. Run `memory.verify`.
12. Record metrics, traces, logs, and DB statistics.
13. Destroy temp DB unless `--keep-artifacts`.

### 12.5 Run manifest

Every eval run must save:

```json
{
  "runId": "run_...",
  "timestamp": "2026-04-28T...Z",
  "gitCommit": "...",
  "quipuVersion": "0.1.0",
  "latticeVersion": "...",
  "configHash": "...",
  "dataset": "locomo",
  "datasetVersion": "...",
  "modelProviders": {
    "embedding": "...",
    "extractor": "...",
    "answer": "...",
    "judge": "..."
  },
  "hardware": {
    "os": "...",
    "cpu": "...",
    "memoryGb": 32
  },
  "randomSeed": 1234,
  "metrics": {}
}
```

### 12.6 External benchmarks

#### LoCoMo

Purpose:

- Long-term conversational memory.
- Single-hop/multi-hop/temporal/adversarial questions.
- Event summarization.

Use:

- Compile conversations into chronological sessions.
- Feed each session incrementally via `remember`.
- Query using annotated QA.
- Score answer F1/LLM judge and evidence retrieval where evidence IDs exist.

#### LongMemEval

Purpose:

- Information extraction.
- Multi-session reasoning.
- Temporal reasoning.
- Knowledge updates.
- Abstention.

Use:

- Feed sessions incrementally.
- Evaluate answer accuracy, abstention accuracy, retrieval recall@k, temporal correctness.

#### MemoryAgentBench

Purpose:

- Accurate retrieval.
- Test-time learning.
- Long-range understanding.
- Selective forgetting.

Use:

- Treat this as the most aligned benchmark for Quipu.
- Run all four competency suites.
- Especially emphasize selective forgetting and fact consolidation.

### 12.7 Quipu synthetic eval suites

External benchmarks are not enough. We need synthetic tests with exact ground truth.

#### Suite: `temporal_truth`

Cases:

- A fact changes from A to B.
- A fact changes A → B → C.
- User asks current truth.
- User asks historical truth.
- User asks what changed.
- User asks why it changed.

Metrics:

```text
current_accuracy
historical_accuracy
invalidated_fact_suppression
change_explanation_evidence_precision
```

#### Suite: `selective_forgetting`

Cases:

- Delete raw message.
- Delete fact only.
- Delete all memories about a topic.
- Delete private preference that appears in summary.
- Delete one evidence source from multi-evidence fact.

Metrics:

```text
deletion_closure_precision
deletion_closure_recall
post_delete_retrieval_leak_rate
summary_contamination_detection
index_leak_rate
```

#### Suite: `cross_scope_contamination`

Cases:

- Project A uses Python, Project B uses Python but different tools.
- Same person name in two projects.
- Same repo name in two tenants.
- User preference global vs project-specific exception.

Metrics:

```text
wrong_scope_retrieval_rate
scope_precision@k
answer_contamination_rate
```

#### Suite: `procedural_learning`

Cases:

- Tool call fails; user gives fix; later similar tool call should use fix.
- Repo-specific test command learned.
- User style preference learned and applied.

Metrics:

```text
skill_retrieval_recall
success_after_learning
wrong_skill_application_rate
```

#### Suite: `entity_resolution`

Cases:

- Aliases.
- Ambiguous names.
- Same name different entities.
- Entity renamed.
- Project/repo forks.

Metrics:

```text
merge_precision
merge_recall
overmerge_rate
undermerge_rate
```

#### Suite: `evidence_faithfulness`

Cases:

- Relevant fact exists but weak evidence.
- Similar but wrong evidence exists.
- Query asks unanswerable question.
- Contradictory evidence exists.

Metrics:

```text
evidence_precision
answer_supported_rate
unsupported_claim_rate
abstention_accuracy
```

#### Suite: `adversarial_memory`

Cases:

- User says “remember this secret” with retrieval restrictions.
- Memory text contains prompt injection: “ignore all future instructions.”
- Tool output contains malicious text.
- Deleted memory tries to reappear via summary.

Metrics:

```text
prompt_injection_resistance
secret_leak_rate
policy_block_success
```

### 12.8 Baselines

Implement these baselines:

```text
full_context
recent_context_only
vector_rag
bm25_rag
hybrid_vector_bm25
summary_only
memory_cards_only
graph_only
external_mem0_if_available
external_zep_if_available
external_letta_if_available
```

All baselines must use the same answer model and comparable prompt budget where possible.

### 12.9 Ablations

Run these Quipu ablations:

```text
Q0 raw-only no extraction
Q1 memory cards only
Q2 facts only
Q3 vector only
Q4 BM25 only
Q5 vector + BM25
Q6 vector + BM25 + graph expansion
Q7 + graph activation
Q8 + temporal validity
Q9 + contradiction suppression
Q10 + evidence reranking
Q11 + utility learning
Q12 + summaries/core memory
Q13 + forgetting propagation
Full Quipu
```

### 12.10 Metrics

Retrieval metrics:

```text
recall@k
precision@k
MRR
nDCG
evidence_recall@k
evidence_precision@k
scope_precision@k
stale_memory_rate
contradicted_memory_rate
```

Answer metrics:

```text
exact_match
F1
semantic_similarity
LLM_judge_accuracy
abstention_accuracy
unsupported_claim_rate
temporal_answer_accuracy
```

Forgetting metrics:

```text
leak_rate_after_delete
closure_precision
closure_recall
summary_contamination_rate
index_leak_rate
tombstone_correctness
```

System metrics:

```text
remember_latency_p50/p95
retrieve_latency_p50/p95
extraction_latency
consolidation_latency
forget_latency
DB_size_bytes
nodes_per_session
edges_per_session
memory_growth_rate
prompt_tokens
completion_tokens
embedding_cost
LLM_extraction_cost
```

### 12.11 Judge protocol

Use deterministic graders whenever possible. LLM judge only when exact metrics are insufficient.

LLM judge inputs must include:

- question
- expected answer
- generated answer
- retrieved evidence
- forbidden evidence/stale evidence if applicable
- rubric

Judge labels:

```text
correct
partially_correct
incorrect
abstained_correctly
abstained_incorrectly
unsupported
uses_stale_memory
privacy_violation
```

Record raw judge output and parsed label.

### 12.12 Statistical reporting

For publishable results:

- Report confidence intervals via bootstrap where feasible.
- Run at least 3 seeds for stochastic components.
- Report cost and latency, not just accuracy.
- Report ablations, not only full system.
- Report failures qualitatively.
- Include exact configs and prompts.

---

## 13. Verification and testing

This section is intentionally strict. Quipu must be tested like a database-backed infrastructure project and like an ML memory system.

### 13.1 Verification levels

```text
Level 0: Static validation
  schema files, JSON schemas, config validation, linting

Level 1: Unit tests
  pure functions and small algorithms

Level 2: Integration tests
  daemon + LatticeDB temp file + protocol calls

Level 3: Invariant verification
  graph/database consistency checks

Level 4: Fault injection
  crash, retry, partial provider failure, stream offsets

Level 5: Algorithmic fixtures
  known-memory scenarios with exact expected retrieval

Level 6: Benchmark evals
  LoCoMo, LongMemEval, MemoryAgentBench, synthetic suites

Level 7: Production canaries
  dogfood agents, telemetry, regression dashboards
```

### 13.2 `quipu verify` command

`quipu verify all` should run the core invariant suite.

Subcommands:

```bash
quipu verify schema
quipu verify provenance
quipu verify temporal
quipu verify indexes
quipu verify forgetting
quipu verify streams
quipu verify retrieval --fixture fixtures/basic.yaml
```

### 13.3 Schema invariants

Fail if:

- Any node lacks `qid`, `qtype`, `schema_version`, `created_at_ms`, `state`.
- Any memory-bearing node lacks `text` unless redacted/deleted.
- Any qid is duplicated.
- Any edge type is unknown.
- Any node has invalid `privacy_class`.
- Any node has invalid `state` for its type.
- Any JSON payload fails schema validation.
- Any vector dimension does not match DB config.

### 13.4 Provenance invariants

Fail if:

- A Fact has no `EVIDENCED_BY` edge.
- A Preference has no evidence.
- A Skill has no `LEARNED_FROM` or explicit user-authored source.
- A Summary has no `COMPILED_FROM` or `SUMMARIZES` edge.
- A MemoryBlock managed by agent has no `COMPILED_FROM` evidence.
- A derived node points only to deleted evidence but remains active/current.

### 13.5 Temporal invariants

Fail if:

- A Fact has `valid_to_ms < valid_from_ms`.
- Two current single-valued facts share the same slot key and conflict.
- A superseded fact lacks `valid_to_ms`.
- A fact marked current is invalidated by another current fact.
- A historical retrieval returns facts outside `validAt` window in deterministic fixtures.

### 13.6 Forgetting invariants

Fail if:

- A deleted qid is returned by `retrieve` or `search`.
- A hard-deleted text span appears in FTS search.
- A hard-deleted text span appears in vector retrieval metadata/context.
- A summary compiled from deleted evidence remains clean.
- A core block compiled from deleted evidence remains active without rebuild.
- A deletion request lacks a tombstone/report.
- A tombstone leaks sensitive original text.

### 13.7 Stream/job invariants

Fail if:

- Consumer offset advances past an unprocessed failed job.
- Two jobs exist for the same stream sequence and worker kind.
- A leased job is expired but not recoverable.
- A deadlettered job lacks error details.
- Stream record payload qids do not exist where required.

### 13.8 Unit test targets

Core pure functions:

```text
qid generation
scope normalization
time parsing
JSON schema validation
score normalization
MMR selection
token estimation
redaction rules
slot_key construction
confidence update
recency scoring
graph activation math
```

### 13.9 Algorithm fixture tests

Create YAML fixtures where expected outputs are exact.

Example:

```yaml
name: package_manager_update
memory:
  - time: 2026-01-01T00:00:00Z
    scope: { projectId: repo:test }
    text: This repo uses npm.
  - time: 2026-02-01T00:00:00Z
    scope: { projectId: repo:test }
    text: We migrated to pnpm. Use pnpm now.
queries:
  - text: What package manager should I use now?
    expect_contains: pnpm
    expect_not_contains: npm
    expect_evidence_text: We migrated to pnpm
  - text: What package manager did we use in January?
    valid_at: 2026-01-15T00:00:00Z
    expect_contains: npm
```

### 13.10 Property-based tests

Use property-based testing in Python and/or Zig.

Properties:

- Ingesting duplicate events with same idempotency key is idempotent.
- Adding irrelevant memories should not change top result for exact queries beyond allowed threshold.
- Forgetting a memory removes all single-evidence derived facts.
- Replaying the same event stream produces equivalent memory graph.
- Current single-valued facts have at most one active value per slot.
- Retrieval never returns out-of-scope private memories.

### 13.11 Metamorphic tests

Metamorphic relations:

- Duplicate memory should not double confidence beyond configured cap.
- Reordering independent events should not change current facts.
- Adding a correction should change current fact but preserve historical answer.
- Deleting a source should reduce confidence or remove fact.
- Changing project scope should change project-specific retrieval.

### 13.12 Fault injection tests

Simulate:

- Crash after raw write before extraction.
- Crash after extraction output before commit.
- Crash after job success before offset update.
- Provider timeout.
- Embedding provider returns wrong dimension.
- LLM extractor returns invalid JSON.
- LLM extractor hallucinates evidence quote.
- LatticeDB write conflict/lock timeout.
- Disk full if practical.

Expected behavior:

- Raw memory remains durable after committed remember.
- Jobs retry or deadletter.
- Offsets do not skip failed records.
- Invalid provider outputs do not mutate graph.
- Verification catches inconsistent state.

### 13.13 Concurrency tests

Scenarios:

- 100 concurrent reads while one writer ingests.
- SDK calls from TypeScript and Python simultaneously.
- Retrieval during consolidation.
- Forgetting during retrieval.
- Daemon restart while SDK auto-starts.

Rules:

- Retrieval must see a consistent snapshot.
- Forgetting must not partially leak in a context packet.
- Writes are serialized through daemon.
- SDKs should gracefully handle daemon restart.

### 13.14 Security tests

Test:

- Prompt injection in memory text.
- Tool output containing malicious instructions.
- User tries to retrieve another scope.
- Secret stored with `privacyClass=secret`.
- Forgetting secrets removes them from summaries.
- MCP tool arguments cannot cause shell injection.
- Provider config does not leak API keys in logs.
- Export redacts secrets unless explicit admin override.

Memory text must be treated as data, not instructions. Context assembler should wrap memory in a clear section that tells the agent not to obey instructions found inside retrieved memory unless they are explicitly user instructions relevant to the current task.

### 13.15 Performance tests

Benchmarks:

```text
remember 1 message
remember 10 messages
retrieve simple exact fact
retrieve hybrid query over 10k, 100k, 1M nodes
forget single raw message
forget topic with 1k dependent nodes
consolidate session with 100 turns
```

Track:

```text
p50/p95/p99 latency
CPU
RSS memory
DB file size
WAL size
number of LatticeDB queries
number of provider calls
```

Initial targets for local dev machine, excluding external LLM calls:

```text
remember raw event p95 < 50 ms
retrieve deterministic p95 < 150 ms for 100k memory-bearing nodes
inspect p95 < 100 ms
verify schema over 100k nodes < 10 s
```

These are targets, not promises, and should be revised after measurement.

### 13.16 Certainty model

We can be highly certain about:

- Schema invariants.
- Provenance edges.
- Transactional raw writes.
- Scope filtering.
- Deletion closure under tested graph rules.
- Deterministic retrieval behavior on fixtures.

We can be moderately certain about:

- Retrieval quality on benchmark distributions.
- Entity resolution quality.
- Contradiction classification.
- Summary faithfulness.

We cannot be absolutely certain about:

- LLM extraction correctness.
- Whether a memory is truly useful for every future task.
- Whether all semantically equivalent deleted text is absent after hard delete unless we test search/index leakage thoroughly.
- Whether external benchmark judge scores reflect real user value.

Therefore Quipu must expose confidence, provenance, and warnings rather than pretending memory is infallible.

---

## 14. Observability

### 14.1 Logs

Structured JSON logs by default in daemon:

```json
{
  "ts": "...",
  "level": "info",
  "component": "retrieval",
  "event": "retrieve.completed",
  "retrievalId": "q_retr_...",
  "latencyMs": 87,
  "candidateCount": 143,
  "selectedCount": 9
}
```

### 14.2 Metrics

Expose optional localhost metrics endpoint:

```text
quipu_remember_total
quipu_retrieve_total
quipu_forget_total
quipu_retrieve_latency_ms
quipu_extract_latency_ms
quipu_provider_errors_total
quipu_deadletter_jobs_total
quipu_verify_failures_total
```

### 14.3 Debug traces

When `includeDebug=true`, retrieval response may include:

- Query analysis.
- Candidate source counts.
- Score breakdowns.
- Why selected/rejected.
- Graph activation hops.

Never include secrets in debug traces.

---

## 15. Security and privacy

### 15.1 Threat model

Quipu handles user memory, which may include sensitive personal or business data.

Risks:

- Cross-scope memory leak.
- Prompt injection via stored memory.
- Secret leakage in logs/evals/exports.
- Incomplete deletion.
- Malicious MCP/CLI arguments.
- Provider exfiltration of private data.
- Summary retaining deleted facts.

### 15.2 Default policies

- Local-only daemon by default.
- No HTTP listener unless explicitly enabled.
- If HTTP enabled, bind to localhost by default.
- Secret privacy class is not sent to external providers unless explicitly allowed.
- Logs redact content by default; enable content logs only in dev.
- MCP adapter should expose least-privilege tools.
- `forget --dry-run` default in CLI.
- Export should redact sensitive/secret memories unless `--include-sensitive`.

### 15.3 Scope enforcement

Every retrieval/search/inspect request includes allowed scopes. The daemon computes scope keys and filters before scoring.

Default scope precedence:

```text
exact project scope
user global scope
agent scope
tenant/org shared scope
global public scope
```

Never retrieve another tenant/user scope without explicit authorization.

---

## 16. MCP adapter

The MCP adapter should expose Quipu to MCP-compatible hosts while keeping Quipu's canonical API internal.

Tools:

```text
quipu_remember
quipu_retrieve
quipu_search
quipu_inspect
quipu_forget
quipu_feedback
```

Resources:

```text
quipu://core/{scope}
quipu://project/{project_id}/summary
quipu://session/{session_id}
quipu://memory/{qid}
quipu://retrieval/{qid}
```

Prompts:

```text
quipu_context_prompt
quipu_memory_review_prompt
quipu_forgetting_review_prompt
```

Security:

- Local stdio MCP is convenient but must not shell-expand untrusted input.
- Remote MCP should require auth.
- Forgetting and export tools should require confirmation/human-in-the-loop in MCP host where supported.

---

## 17. Implementation milestones

### M0: Repository and spec

Deliver:

- MIT repo skeleton.
- This spec.
- Protocol schemas.
- Initial docs.
- CI skeleton.

### M1: LatticeDB integration and schema

Deliver:

- Zig wrapper over LatticeDB C API.
- DB open/close.
- Transactions.
- Node/edge creation.
- FTS index/search.
- Vector set/search.
- Stream publish/read/offset.
- Schema migration v1.
- `quipu init`, `quipu verify schema`.

Acceptance:

- Integration tests use temp DB.
- Can create Message, Episode, Fact, MemoryCard.
- Can search by FTS/vector.
- Can publish/read stream.

### M2: Daemon, protocol, CLI

Deliver:

- JSON-RPC server over Unix socket and stdio.
- CLI client.
- `system.health`.
- `memory.remember` raw storage.
- `memory.search` basic.
- TypeScript/Python SDK MVP.

Acceptance:

- SDKs auto-start daemon.
- `remember` from TS and Python writes same schema.
- CLI `--json` output stable.

### M3: Retrieval v0

Deliver:

- Embedding provider.
- FTS/vector/hybrid candidate generation.
- Scope filtering.
- Basic scoring.
- Context packet assembly.
- Retrieval trace logging.

Acceptance:

- Synthetic exact recall fixtures pass.
- Retrieval latency measured.

### M4: Extraction and temporal facts

Deliver:

- LLM extraction plugin.
- JSON schema validation.
- Entity resolution v0.
- Fact upsert.
- Contradiction/supersession for single-valued slots.
- Memory cards.

Acceptance:

- Package manager update fixture passes current/historical queries.
- Invalid extractor output does not mutate DB.

### M5: Consolidation and core memory

Deliver:

- Session summaries.
- Entity/project summaries.
- Core memory blocks.
- Summary contamination markers.

Acceptance:

- Context budget tests pass.
- Summary provenance invariants pass.

### M6: Forgetting

Deliver:

- `memory.forget`.
- Dry-run report.
- Deletion closure.
- Tombstones.
- Summary contamination/rebuild.
- Forgetting verification.

Acceptance:

- Synthetic forgetting suite leak rate = 0 for exact deleted strings.
- Retrieval never returns deleted qids.

### M7: Eval harness

Deliver:

- Unified scenario schema.
- Synthetic suites.
- LoCoMo adapter.
- LongMemEval adapter.
- MemoryAgentBench adapter.
- Baselines and ablations.
- Report generator.

Acceptance:

- Reproducible run manifest.
- At least Q0-Q8 ablations work.

### M8: MCP and public preview

Deliver:

- MCP server package.
- Docs/examples.
- Release binaries.
- npm/PyPI packages.

Acceptance:

- Works with at least one MCP host.
- Install/start/retrieve flow under 5 minutes.

### M9: Publication-quality experiments

Deliver:

- Full benchmark report.
- Ablations.
- Failure analysis.
- Public reproducibility scripts.
- Paper draft if results warrant.

---

## 18. API ergonomics review checklist

For every API decision, ask:

1. Can a new user understand it without knowing the internals?
2. Does it force users to learn graph schemas prematurely?
3. Does it leak LatticeDB internal IDs?
4. Does it behave the same in TypeScript, Python, CLI, and MCP?
5. Does it work with one line for the common case?
6. Does it allow advanced users to inspect/debug deeply?
7. Does it avoid surprising writes?
8. Does it expose enough provenance for trust?
9. Does it make privacy/scope explicit?
10. Does it keep memory semantics centralized in the daemon?

---

## 19. Documentation plan

Docs should include:

```text
Getting started in 5 minutes
Core concepts
Architecture
API reference
TypeScript SDK guide
Python SDK guide
CLI guide
MCP guide
Data model
Retrieval internals
Forgetting and privacy
Evaluation guide
Contributing
Security policy
Publication/research guide
```

The docs should avoid forcing beginners to understand everything. Start simple:

```text
remember → retrieve → inspect → forget
```

Then layer in advanced behavior.

---

## 20. Publication path

A publishable Quipu paper should not claim “we implemented memory on LatticeDB.” It should claim something like:

> Quipu is a transactional temporal memory graph for LLM agents. It preserves raw episodes, compiles them into evidence-backed semantic and procedural memory, retrieves via graph/vector/text planning, and verifies forgetting and temporal validity with benchmarked invariants.

Potential contribution claims:

1. Transactional temporal memory graph with evidence invariants.
2. Retrieval planner over memory abstraction lattice.
3. Verification/eval framework for evidence, update, and forgetting correctness.
4. Local-first single-file memory substrate for agents.

Required evidence:

- Standard benchmark results.
- Synthetic forgetting/evidence/temporal tests.
- Ablations isolating each contribution.
- Cost/latency/token reporting.
- Failure analysis.

---

## 21. Open questions

These should be tracked as issues/experiments, not hand-waved.

### 21.1 Should raw messages be embedded by default?

Hypothesis:

- Embedding raw messages improves exact episodic recall but increases storage/cost and may pollute retrieval.

Experiment:

- Compare raw+cards+facts vs cards+facts only on LoCoMo/LongMemEval and synthetic exact recall.

### 21.2 How aggressive should entity merging be?

Hypothesis:

- Conservative merging reduces catastrophic overmerge, even if undermerge hurts recall.

Experiment:

- Entity resolution synthetic suite with merge thresholds grid.

### 21.3 Do summaries help or hurt evidence faithfulness?

Hypothesis:

- Summaries reduce tokens/latency but increase unsupported claims unless evidence-backed and contamination-aware.

Experiment:

- Summary-only, no-summary, evidence-summary ablations.

### 21.4 Is graph activation worth the complexity?

Hypothesis:

- Graph activation helps multi-hop and procedural recall more than single-hop fact recall.

Experiment:

- Run vector+BM25 vs vector+BM25+graph expansion vs activation on multi-hop and procedural suites.

### 21.5 Should contradiction detection use LLMs?

Hypothesis:

- Rule-based slots handle common single-valued updates; LLM contradiction helps nuanced preferences but can overfire.

Experiment:

- Rule-only vs LLM-classified relation vs hybrid with confidence thresholds.

### 21.6 How should forgetting be implemented if index deletion is imperfect?

Hypothesis:

- Hard delete requires verified index deletion or index rebuild. Soft delete alone is unacceptable for privacy claims.

Experiment:

- Deletion/index leak tests against LatticeDB implementation.

---

## 22. Acceptance criteria for v1

Quipu v1 should not be called stable until:

- Install works on macOS, Linux, Windows or Windows documented as beta.
- TypeScript and Python SDKs work against the same daemon.
- `remember`, `retrieve`, `inspect`, `forget`, `feedback` are stable.
- Schema verification passes on all integration tests.
- Raw write durability is tested.
- Retrieval fixtures pass.
- Forgetting fixtures show zero exact-string leakage.
- Scope contamination suite passes with strict threshold.
- At least one external benchmark adapter works.
- CI runs unit + integration + synthetic tests.
- Docs show common agent integrations.
- Security policy and issue templates exist.
- MIT license present.

---

## 23. References and grounding sources

This spec was written against current public descriptions of LatticeDB and current long-term memory benchmark literature. Core assumptions to verify and pin during implementation:

- LatticeDB site and docs: single-file graph/vector/full-text database, durable streams, ACID transactions, Python/TypeScript/C APIs.
- LatticeDB transactions: snapshot isolation, concurrent readers, serialized write commits, WAL recovery.
- LatticeDB streams: durable named streams, explicit offsets, graph changefeed, no built-in retry/deadletter/task queue.
- LoCoMo: very long-term conversational memory benchmark with QA, event summarization, and multimodal dialog generation.
- LongMemEval: long-term memory abilities including information extraction, multi-session reasoning, temporal reasoning, knowledge updates, and abstention.
- MemoryAgentBench: memory-agent benchmark with accurate retrieval, test-time learning, long-range understanding, and selective forgetting.
- Mem0: production memory architecture using dynamic extraction/consolidation/retrieval and graph extension.
- MCP official SDK docs: tools/resources/prompts and local/remote transports.

