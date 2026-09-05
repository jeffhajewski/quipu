# Memory architecture experiments

Status: E1 runner and fictional provider pilot completed September 5, 2026;
held-out E1 evaluation and E2–E4 remain pending.

These experiments test the event-sourced design proposal before changing
Quipu's runtime architecture. Preserved evidence, scoped access, validated
writes, and explicit forgetting remain requirements. Graphs, summaries, and
the number of model calls are experimental choices.

The prototype belongs in `evals/`. It must not become a second production
implementation of daemon memory semantics. A successful experiment produces
an implementation decision, supporting traces, and runtime requirements.

## Shared protocol

- Ingestion receives source conversations only. Questions, reference answers,
  evidence labels, and `groundTruthMemories` never enter extraction, indexing,
  resolution, or answer generation. Only scoring and a separately labeled
  oracle-evidence diagnostic can use labels.
- Freeze source data, extraction outputs, prompts, models, retrieval settings,
  context budgets, and grading for paired comparisons. Record content hashes,
  code identity, provider/model IDs, run errors, and per-query traces.
- Build projections per conversation and scope. Queries see only evidence
  available at their timestamp. Distinguish source conversation time, ingest
  time, and assertion validity; never infer world-state recency from import
  order.
- Use the same reader and reader prompt across treatments. Grade answer
  correctness separately from evidence coverage, stale evidence, and errors.
  A runtime failure is not an incorrect semantic answer. Report both valid-run
  accuracy and completion rate; never hide failed queries from the denominator.
- Compare at fixed reader context budgets, including evidence wrappers. Use
  actual tokenizer counts for model-backed experiments; record the tokenizer.
  Report context utilization and dropped items. Do not equate top-k passages
  across representations with equal cost.
- Record calls and latency separately for extraction, embeddings, retrieval,
  answering, and grading. Preserve provider usage when available. Missing token
  usage or dollar cost is unknown, never zero. Separate cold construction from
  cached replay and amortize ingest over stated query counts.
- Keep exact evidence quotes and source IDs on derived records. A valid quote
  proves provenance, not that the derived assertion is entailed by it.

### Data and execution stages

1. Handwritten, adversarial smoke cases validate the harness. They are not
   architectural evidence or a leaderboard score.
2. A fixed development slice of LongMemEval-S supports debugging and threshold
   selection. Preserve the upstream answerer/judge protocol for comparable
   answer scores. Keep oracle data explicitly labeled as a reader diagnostic.
3. Freeze configuration before evaluation on held-out conversations. Use all
   categories and report paired differences with confidence intervals, grouped
   by conversation rather than treating related questions as independent.
4. Check the selected configuration on LongMemEval-M and LoCoMo with their
   respective grading protocols. Pin dataset revisions and disclose exceptions.

No current `FakeQuipuClient` ablation is a substitute for these experiments.
Its summary treatment prefixes raw text; its no-provider reader uses reference
answer matching. Existing reports combining all grades into `queriesPassed`
must not be presented as official answer accuracy.

### Common diagnostics

Report source-event recall and all-required-events coverage, but do not call
either evidence sufficiency: an assertion can cite the correct session while
omitting its answer. Also inspect whether the exact supporting detail survives
extraction and the assembled reader context. Measure that on manually labeled
source spans and a reviewed sample of failures.

Run the same reader on gold source evidence as a separate diagnostic. Compare
source coverage, assertion coverage, retrieved-context sufficiency, oracle-reader
accuracy, and final answer accuracy to localize loss. Abstention cases have no
positive-evidence recall denominator; report abstention accuracy separately.

## E1: Does assertion extraction improve retrieval?

Hypothesis: atomic assertions improve matching and context efficiency, while
retrieving raw evidence alongside them recovers details extraction misses.

Treatments:

| ID | Searchable and returned representation |
| --- | --- |
| `raw` | Source passages with speaker and conversation timestamp |
| `assertions` | Independently extracted atomic claims with source references |
| `combined` | Both passage types under one shared context budget |

Use BM25 as a cheap diagnostic and BM25 plus real embeddings with reciprocal
rank fusion for the main comparison. Fix passage construction, embedding model,
fusion settings, and reader budget. Extract each episode once without access to
questions; reuse those outputs across treatments. Preserve uncertainty, negation,
dates, scope, and speaker attribution in assertion text. Validate exact quotes
and message indices before admitting assertions to retrieval.

Fixtures should cover paraphrases, exact names/commands, assistant-origin facts,
rare reasons, multi-event evidence, corrections, identity ambiguity, scope
conflicts, future evidence, and unanswerable questions. Include cases where a
correctly sourced assertion omits the requested detail.

Primary outcomes: answer accuracy and evidence sufficiency at equal context
budgets. Secondary outcomes: event recall, extraction omissions/hallucinations,
abstention, context utilization, and total cost over multiple query counts.

Decision: promote assertions only if a held-out paired comparison improves the
accuracy/cost frontier. If assertions alone lose detail but combined retrieval
wins, preserve the raw retrieval path. If neither helps, retain raw hybrid
retrieval and investigate passage construction/reranking before graph work.

## E2: Do predicate histories add value?

Hypothesis: grouping versions of a scoped predicate makes temporal evidence
more complete without crowding out other evidence.

Compare E1's selected representation with the same representation plus
deterministically rendered predicate histories. Hold extraction and resolution
fixed. Use a small explicit schema first; do not add ontology induction,
spreading activation, or a new resolver in this experiment. Maintain searchable
individual evidence in both arms so history-vector dilution is observable.

Represent explicit interval ends, unknown gaps, planned future states,
retractions, and corrections separately. Group keys include scope and relevant
qualifiers. Test both valid-at and as-known-at questions. Repeat the input with
different flush boundaries and require equivalent semantic results.

Fixtures: delayed narration; a correction to a past interval; a gap between
residences; cessation/resumption; concurrent employers; a future planned move;
an imported historical conversation; and an obscure old value in a long chain.

Primary outcomes: temporal answer accuracy, stale-answer rate, and all-required
evidence coverage. Secondary outcomes: unrelated-query regressions, context
cost, update latency, and sensitivity to history length/truncation.

Decision: adopt grouped history only if it improves held-out temporal results
without a material overall regression. Choose the simplest physical index that
provides the benefit; this experiment does not establish a need for a graph DB.

## E3: Is mechanical resolution sufficient?

Hypothesis: conservative mechanical resolution handles easy cases; selective
model adjudication improves ambiguous cases enough to justify its cost.

Use identical extracted mentions and relation candidates in three arms:
mechanical resolution with an unresolved state; that resolver plus adjudication
only in a frozen uncertainty band; and adjudication of all candidate pairs as
a cost/quality reference. Keep candidate generation fixed to isolate decisions.
Evaluate entity identity and relation equivalence separately before composing
them. Never use answer labels as resolver feedback.

Adjudication can return same, different, or unresolved. Record its evidence and
decision version. Keep identity alternatives reversible. Do not count repeated
imports, repeated extraction, or assistant echoes as independent support.

Fixtures: two Sarahs of the same type; changing names and roles; sparse aliases;
`visited` versus `lives_in`; positive `likes` versus positive `dislikes`; inverse
relations; narrower entailment; and a false merge later contradicted by evidence.

Primary outcomes: false-merge rate, missed-link rate, unresolved rate, and
downstream answer accuracy. Report candidate recall separately from decision
accuracy. Secondary outcomes: calls per ingested episode, latency, repair scope,
and whether a repaired projection produces the same result as a clean rebuild.

Decision: choose thresholds on development data, with an explicit penalty for
false merges. Keep selective adjudication only if it improves the held-out
quality/cost frontier. A reversible bad merge still counts as a wrong answer
until repaired.

## E4: Do disposable summaries help?

Hypothesis: summaries grounded directly in source evidence improve abstract
retrieval without the accumulating loss of recursive compaction.

Compare the selected evidence representation alone, plus source-grounded
summaries used only as retrieval keys, and plus source-grounded summaries also
eligible for the reader context. Add a recursive-summary treatment as a
diagnostic of compaction depth, not as the only summary baseline. Freeze episode
groups and source evidence across arms. Keep summaries versioned and disposable.

Test explicit fact questions, broad themes, causal explanations, plans,
procedures, and rare details. Vary depth (0, 1, 2, 4, 8), source volume, and
context budget. At each depth distinguish source retention, semantic fidelity,
and answer quality. Count regeneration cost and repeated query-time synthesis.

Primary outcomes: answer accuracy and evidence sufficiency. Secondary outcomes:
unsupported summary claims, rare-detail recall, depth sensitivity, context
utilization, and amortized cost. Forget a supporting source, rebuild, and check
that neither summaries nor their retrieval keys resurrect it.

Decision: keep summaries only in the roles where they improve held-out utility.
If source-grounded summaries stay accurate while recursive ones degrade, forbid
evidence replacement/recursive dependence rather than all summaries.

## Lifecycle suite and implementation sequence

A separate, system-agnostic lifecycle suite should test corrections, identity
splits, replay, duplicate support, and erasure through observable answers and
source evidence. Do not require Quipu's internal graph layout. Review existing
[MemoryAgentBench](https://arxiv.org/abs/2507.05257) and
[LongMemEval-V2](https://arxiv.org/abs/2605.12493) before broadening its scope.

| Milestone | Status | Exit criterion |
| --- | --- | --- |
| Shared protocol and four experiment definitions | Written | Reviewable hypotheses, controls, metrics, decisions |
| E1 independent runner and smoke fixtures | Implemented | Real representations; no gold leakage; budgeted traces |
| E1 provider-backed pilot | Completed on fictional smoke data | Frozen extraction; all three arms; separate reader/grade metrics |
| E1 held-out public benchmark | Pending | Official grading, paired uncertainty, complete usage accounting |
| E2 predicate-history prototype | Pending | E1 baseline frozen; temporal semantics specified |
| E3 resolution comparison | Pending | Labeled candidate pairs and conservative baseline |
| E4 summary comparison | Pending | Source-grounded summary generation and depth fixtures |

Promote successful behavior into `SPEC.md` and the daemon only after reviewing
the experiment. A smoke run or small provider pilot does not select an
architecture. Log negative findings and unresolved cases alongside wins.

### First E1 pilot: September 5, 2026

The [runner and commands](../evals/experiments/README.md) now implement all three
E1 representations, BM25/real-vector hybrid retrieval, frozen extraction and
provider responses, an actual reader-token budget, and separate answer/evidence
metrics. The offline fixture deliberately loses a causal detail while preserving
its provenance; it reports no answer accuracy.

The first provider pilot used five entirely fictional questions, GPT-4o-mini
for extraction/reading, GPT-4o for the pilot grader, text-embedding-3-small for
vectors, and a 256-token context limit with `o200k_base`. All three arms and the
budgeted oracle-source diagnostic answered 5/5 correctly, with no runtime
errors. This is an end-to-end harness check, not evidence favoring any arm.

Local artifacts are in `artifacts/experiments/e1-provider-pilot/`; a replay of
the frozen responses with the final runner is in
`artifacts/experiments/e1-provider-replay/`. Artifacts and provider caches remain
ignored. The next E1 milestone is a fixed LongMemEval-S development slice with
official grading and manually reviewed evidence sufficiency, followed by a
held-out paired comparison. E2–E4 remain specified experiments, not implemented
capabilities.
