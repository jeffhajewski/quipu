# SOTA Usability Work Plan

This plan turns the Mem0, A-Mem, Letta, and Zep comparison into implementation
work. The goal is for Quipu to become the simplest memory system to adopt while
preserving its stronger architectural promise: local-first, evidence-backed,
temporal, inspectable, and forgettable agent memory.

## Product Thesis

Quipu should feel as easy as Mem0, as temporally disciplined as Zep/Graphiti,
as useful for agent context as Letta, and as organically connected as A-Mem.

The durable wedge is not "another vector memory." It is:

- one local binary and one local file;
- plug-and-play SDK, MCP, CLI, and proxy surfaces;
- evidence-linked derived memory;
- temporal truth and contradiction handling;
- deletion that propagates through derived memory;
- structured context packets with inspectable traces.

## Workstreams

### 1. Five-Minute Adoption

Make Quipu useful before a developer reads the architecture.

Tasks:

- Add `quipu quickstart` that initializes a DB, starts the daemon, writes a
  sample memory, retrieves it, and prints next steps.
- Add SDK one-liners: `Quipu()` should discover or start a local daemon with a
  sensible default DB path.
- Add a small "drop-in memory loop" example for Python and TypeScript.
- Add a `remember_text` / `search_text` convenience layer on top of the stable
  protocol, while keeping the canonical JSON-RPC methods unchanged.
- Add copy-paste examples for coding agents, personal assistants, support
  agents, and research agents.

Acceptance:

- A fresh developer can install Quipu, store memory, retrieve memory, and use an
  SDK example in under five minutes.
- No provider key is required for the first successful memory round trip.

### 2. OpenAI-Compatible Memory Proxy

Make Quipu adoptable by changing configuration rather than rewriting agents.

Tasks:

- Add `quipu proxy --port 7337` with OpenAI-compatible chat endpoints.
- Before forwarding a chat request, retrieve relevant Quipu context and inject
  it as a system or tool-context message.
- After the model response, write the user and assistant turn to Quipu.
- Support provider forwarding to OpenAI-compatible backends through environment
  variables.
- Add safeguards for prompt caching by optionally inserting memory as a separate
  context/tool message instead of mutating the system prompt.

Acceptance:

- Existing OpenAI-compatible clients can get memory by changing `base_url`.
- The proxy exposes trace metadata for what memory was injected.

### 3. Agent Framework Integrations

Meet developers where they already build agents.

Tasks:

- Ship first-party adapters for LangGraph, Vercel AI SDK, OpenAI Agents SDK,
  CrewAI, LlamaIndex, and AutoGen.
- Expand MCP examples for Claude Desktop, Codex, Cursor, and local model hosts.
- Add framework-specific integration tests that remember, retrieve, answer, and
  forget a memory.
- Add a compatibility matrix in docs.

Acceptance:

- Each integration has a minimal working example and a tested round trip.
- Integrations do not reimplement memory semantics outside the daemon.

### 4. Presets and Memory Schemas

Turn SOTA architecture into product defaults.

Tasks:

- Add presets: `coding-agent`, `personal-assistant`, `support-agent`,
  `research-agent`, and `general`.
- Each preset defines default scopes, extraction slots, core block templates,
  retrieval needs, and forgetting policy defaults.
- Add domain memory types where useful: `Goal`, `Constraint`, `Skill`,
  `Decision`, `Issue`, and `Artifact`.
- Add schema conformance fixtures for each preset.

Acceptance:

- A developer can opt into high-quality behavior without writing extraction
  prompts.
- Preset output remains evidence-linked and schema-validated.

### 5. MemoryCards Inspired by A-Mem

Add lightweight self-organizing notes without sacrificing provenance.

Tasks:

- Extend `MemoryCard` with generated keywords, tags, contextual description,
  importance, utility, and related-card links.
- Link cards with typed relationships such as `RELATED_TO`, `CAUSES`,
  `REFINES`, `CONTRADICTS`, and `SUPPORTS`.
- Version card evolution instead of overwriting generated descriptions.
- Use card links as a retrieval signal alongside lexical, vector, graph, and
  temporal scoring.

Acceptance:

- Card evolution is inspectable and reversible.
- Every card version remains traceable to raw evidence.

### 6. Zep-Class Temporal Graph Retrieval

Make temporal and relational reasoning a core strength.

Tasks:

- Add robust `Entity` nodes and entity resolution jobs.
- Add fact edges or fact-like nodes with validity windows, invalidation reason,
  and evidence references.
- Support bitemporal fields: when a fact was true in the world and when Quipu
  learned or invalidated it.
- Add graph expansion from query entities, recent entities, and scoped core
  blocks.
- Add reranking options: reciprocal rank fusion, MMR, graph-distance boosting,
  recency, utility, and optional cross-encoder/provider reranking.

Acceptance:

- Retrieval traces show candidate source, entity expansion, temporal filtering,
  reranking, budget decisions, and dropped-item reasons.
- Temporal questions can retrieve current and historical facts without silently
  overwriting old truth.

### 7. Letta-Style Core Blocks

Make Quipu useful as always-visible agent context, not only as search.

Tasks:

- Support evidence-backed `Core` blocks for user, project, organization,
  agent, task, and persona context.
- Add block compilation from lower-level evidence and memory cards.
- Add read-only and read-write policies.
- Add shared block scopes for multi-agent coordination.
- Add contamination handling: when evidence is forgotten, rebuild affected
  blocks without deleted text.

Acceptance:

- Agents can request compact always-visible context with citations.
- Forgetting invalidates or rebuilds affected blocks.

### 8. Trust, Inspection, and Local Dashboard

Make Quipu's discipline visible.

Tasks:

- Add a local dashboard for memories, evidence, entities, facts, core blocks,
  retrieval traces, jobs, and forget dry-runs.
- Add "why does Quipu remember this?" and "what would be deleted?" flows.
- Add exact-string leakage checks to verification.
- Add user-facing warnings for stale, contradicted, low-confidence, or
  cross-scope candidate memory.

Acceptance:

- A developer can inspect any retrieved memory down to source messages.
- A dry-run forget report is understandable without reading raw JSON.

### 9. Provider and Local Model Quality

Keep the default path simple while allowing high-quality deployments.

Tasks:

- Add config-driven extraction, embedding, answer, entity, and reranker
  providers.
- Add OpenAI-compatible provider presets for OpenRouter, OpenAI, Ollama, LM
  Studio, and vLLM.
- Quarantine invalid provider output into inspectable failed jobs.
- Add small local-model defaults for private/offline mode.

Acceptance:

- Provider failures cannot corrupt memory.
- Quipu remains useful in deterministic/no-key mode.

### 10. Benchmarks and Competitive Claims

Earn the SOTA story with reproducible runs.

Tasks:

- Align LoCoMo reporting against Mem0, A-Mem, and Zep categories where possible.
- Add LongMemEval and MemoryAgentBench adapters.
- Track accuracy, evidence recall, latency, token use, storage growth, provider
  cost, and forgetting leakage.
- Publish ablations for raw-only, cards-only, graph-only, core-only, hybrid, and
  full Quipu.
- Preserve strict wording: only `publishable` reports can support external
  claims.

Acceptance:

- One command can produce a reproducible benchmark report with manifests.
- Reports clearly separate local reproducibility from vendor leaderboard claims.

## Suggested Sequence

### Phase 1: Adoption Wedge

- `quipu quickstart`
- SDK auto-start polish
- Python and TypeScript drop-in examples
- improved README path
- first preset: `coding-agent`

Why first: this makes Quipu feel real and easy before deeper architecture work
lands.

### Phase 2: Context Surfaces

- OpenAI-compatible proxy
- MCP examples
- LangGraph and Vercel AI SDK adapters
- evidence-backed core blocks

Why second: users should be able to plug Quipu into existing agent loops with
minimal glue.

### Phase 3: Memory Quality

- MemoryCard enrichment and linking
- robust entity resolution
- graph expansion
- temporal/bitemporal fact handling
- reranking and retrieval traces

Why third: this is where Quipu becomes SOTA rather than merely convenient.

### Phase 4: Trust and Operations

- local dashboard
- better `verify`
- job observability
- provider quarantine
- deletion/rebuild workflows

Why fourth: production users need to inspect and repair memory, not just call
`search`.

### Phase 5: Benchmark and Publication

- LongMemEval adapter
- MemoryAgentBench adapter
- aligned LoCoMo runs
- ablation matrix
- publication-quality reports

Why fifth: benchmark claims should trail real capability and reproducibility.

## Near-Term Backlog

1. Add `quipu quickstart`.
2. Make SDK `Quipu()` default to local daemon discovery/autostart.
3. Add `coding-agent` preset with package manager, test command, repo style,
   project constraints, and user response-style extraction.
4. Add evidence-backed core block compilation for project and user scopes.
5. Add OpenAI-compatible proxy MVP.
6. Enrich `MemoryCard` with keywords, tags, context, utility, and related links.
7. Add retrieval trace fields for scoring and dropped-item reasons.
8. Add LangGraph and Vercel AI SDK examples.
9. Add local dashboard read-only MVP.
10. Add LongMemEval adapter.

## Non-Goals For This Push

- Do not turn Quipu into a hosted SaaS platform.
- Do not make SDKs own memory semantics.
- Do not optimize benchmark numbers by weakening evidence, forgetting, or
  temporal guarantees.
- Do not require a provider key for basic local memory.
- Do not make graph complexity visible on the happy path.
