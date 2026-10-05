# SOTA sprint results — October 1, 2026

## Decision

The daemon now matches the E1 Python prototype on a frozen LongMemEval-S
development slice. The default configuration is hybrid BM25 + vector retrieval
over raw chunks, with session-grouped rendering and one LLM reader path. Four
Day-4 additions ship as per-request options, **default off**, because none
moved accuracy measurably with GPT-4o-mini as reader:

- `rerank` (cross-encoder rerank stage),
- `readerReasoning` (structured review before answering),
- `temporalHints` (session offsets and resolved relative dates),
- the two reader options combined.

This is a 70-question development slice that we also tuned on. It is not a
leaderboard result. The next comparable claim needs the frozen configuration
on all 500 LongMemEval-S questions.

## Protocol

- Slice: `evals/experiments/sota-dev-selection.json`. 70 questions, 10 per
  category, seed `quipu-sota-dev-20261001`. It excludes the 56 spent E1
  questions and their `_abs` families.
- Reader: `openai/gpt-4o-mini-2024-07-18`. Judge: the official LongMemEval
  prompt via `openai/gpt-4o-2024-08-06`. Embeddings:
  `openai/text-embedding-3-small`, 1536 dimensions.
- Context budget: 1,024 and 4,096 tokens. Reported tokens are actual
  `o200k_base` counts of the rendered reader context.
- Harness: `quipu_evals.sota_longmemeval`. Each question gets its own daemon
  process and fresh store, and provider calls go through the caching proxy. The
  harness and commands are documented in [evals.md](evals.md).
- Paired statistics: exact McNemar p-values, unadjusted, and descriptive
  bootstrap intervals. With n=70, a difference smaller than about 10 points is
  not distinguishable from noise.

## Results

Correct answers out of 70, at 1,024 / 4,096 tokens.

| Run | Accuracy | Gold-turn coverage | Notes |
| --- | ---: | ---: | --- |
| E1 prototype, raw arm (target) | 49 / 52 | 80.6% / 86.5% | Python prototype, same models |
| Daemon at sprint start (`a583bdc`) | 0 / 0 | 1.1% / 3.6% | Substring router, no dates, unsorted lexical search |
| + chunking, BM25, raw-evidence policy | 20 / 21 | 74.4% / 84.3% | Old answer path still in place |
| + rendering, question date, one reader path | 48 / 45 | 74.4% / 84.3% | In-memory build, BM25 only |
| + token estimate calibrated (4.2 bytes per token) | 48 / 46 | 75.6% / 86.0% | Mean context 918 / 3,618 tokens |
| + LatticeDB 0.15, hybrid with embeddings (**default**) | **53 / 50** | **83.2% / 93.2%** | Paired vs E1: +4 (p=.42) / −2 (p=.79) |
| + cross-encoder rerank (bge-reranker-v2-m3) | 50 / 51 | 83.2% / 91.8% | Adds about 2–5 s per answer |
| + reader reasoning | 51 / 49 | same as default | Paired: −2 / −1 |
| + temporal hints | 51 / 50 | same as default | Paired: −2 / 0 |
| + reasoning + temporal hints | 52 / 52 | same as default | Paired: −1 / +2. At 4K: preference +3, abstention −3 |

Every run completed all 70 questions with no runtime errors.

### Top-tier reader

The default configuration (`d1d5445`) was run with
`anthropic/claude-sonnet-5.5` as reader. Retrieval and contexts are identical
to the GPT-4o-mini rows above; the judge is unchanged.

| Run | 1,024 | 4,096 | Paired comparison |
| --- | ---: | ---: | --- |
| Default + GPT-4o-mini | 53 (75.7%) | 50 (71.4%) | — |
| Default + Sonnet 5.5 | 58 (82.9%) | 61 (87.1%) | vs GPT-4o-mini: 8/3 wins/losses (p=.23); 13/2 (p=.007) |
| Default + Sonnet 5.5 + reader reasoning | 58 (82.9%) | 63 (90.0%) | vs Sonnet 5.5 without reasoning: 2/2 (p=1.0); 3/1 (p=.63) |
| Default + Sonnet 5.5 + reasoning + temporal hints | — | 61 (87.1%) | Same as without either option |
| Default + Sonnet 5.5 at an 8,192-token budget | — | 63 (90.0%) at 8K | Gold-turn coverage 94.0% (93.2% at 4K) |

At 8K, the remaining failures are mostly recall misses on questions about two
entities, such as "which did I buy first, X or Y?". The fused query retrieves
evidence for only one side, and multi-hop needs like the user's age come from
another session. Even at 8K, all gold turns are in context for only 6 of the
10 multi-session questions. Temporal reasoning stays at 7/10 in every arm.
Query decomposition and fact keys are the next levers for these questions.

Per-category results at 4K, Sonnet 5.5 vs GPT-4o-mini, out of 10:

| Category | Sonnet 5.5 | GPT-4o-mini |
| --- | ---: | ---: |
| Abstention | 10 | 9 |
| Knowledge update | 9 | 5 |
| Single-session preference | 10 | 5 |
| Single-session assistant | 9 | 8 |
| Single-session user | 10 | 10 |
| Multi-session | 6 | 5 |
| Temporal reasoning | 7 | 8 |

With the stronger reader, 4K beats 1K, and the knowledge-update and preference
failures largely disappear. The rest of the gap is concentrated in
multi-session aggregation and temporal reasoning.

Answer cost per arm was $0.41 at 1K and $1.05 at 4K, or $0.58 and $1.21 with
reasoning. Answer latency p50 was 2.7–3.2 s, or 3.9–4.1 s with reasoning.

## LoCoMo

LoCoMo runs through the same daemon harness (`quipu_evals.sota_locomo`; see
[evals.md](evals.md)). Protocol:

- Data: `snap-research/locomo@3eb6f2c`. Questions in categories 1–4 (1,540)
  are scored; category 5, adversarial, is reported separately.
- Judge: Mem0's `ACCURACY_PROMPT` with GPT-4o-mini.
- Speaker names are stored as message roles.
- The audit-corrected answer key (`dial481/locomo-audit`) is scored as a
  sensitivity check alongside the official key, never in its place.

The daemon used was the default configuration (`d1d5445`) with a GPT-4o-mini
reader.

| Run | 1,024 | 4,096 | Gold-turn coverage |
| --- | ---: | ---: | ---: |
| Speaker name as role (protocol) | 65.5% | 79.5% | 56.1% / 79.0% |
| Speaker name in message text (diagnostic) | 78.5% | 83.7% | 72.9% / 89.8% |

Per-category accuracy for the protocol run:

| Category | 1,024 | 4,096 |
| --- | ---: | ---: |
| Multi-hop | 47.2% | 73.0% |
| Temporal | 60.7% | 63.9% |
| Open-domain | 42.7% | 58.3% |
| Single-hop | 76.1% | 90.1% |
| Adversarial (category 5, reported separately) | 34.3% | 22.2% |

The diagnostic run is incomplete: 173 questions failed with HTTP 402 because
the provider account ran out of credit, and those failures count as errors,
not wrong answers. The audit key changes totals by under one point.

The gap between the two runs was a retrieval bug: a speaker's own lines did
not match searches for their name. `a0c71d0` indexes `"<role>: <text>"` for
messages whose role is a person's name. That fix has not been re-measured yet.

Two other findings:

- Unlike the LongMemEval slice, LoCoMo benefits from 4K over 1K. At 1K, 410
  of 531 wrong answers had no gold turn in context.
- Temporal failures happen even with the evidence present: at 4K, 72 of 116
  wrong temporal answers had every gold turn in context. The reader resolves
  relative dates against the wrong session.

## Protocol correction: question time

LongMemEval sometimes stamps an evidence session later on the question's day
than the question itself. Every daemon run above sent the exact question time
as `time.validAt`, which filtered that evidence out. That affected 3 of the 70
dev questions (all "which came first" temporal questions) and about 41 of
roughly 470 non-abstention questions in the full set, 40 of them
temporal-reasoning. The E1 reference applies no time filter, so this
understated the daemon on exactly the temporal questions it seemed to fail.

From `8a2ded1`, the harness sends the end of the question's day (`--valid-at
end-of-day`, the new default). The reader's current date is unchanged, and
same-day evidence is no longer dropped. `--valid-at question` reproduces the
earlier runs. Results above have not been re-measured; re-measuring is blocked
until the provider account has credit.

## What we learned

- **The reader is now the bottleneck, not retrieval.** At 4K, 93% of gold
  turns reach the reader. Of the 20 wrong answers, 15 had every gold turn in
  context. The errors were:
  - stale values on knowledge updates,
  - generic preference advice,
  - abstaining when the evidence was present,
  - counting mistakes.
- **More context hurts GPT-4o-mini.** Accuracy fell from 1K to 4K even though
  coverage rose from 83% to 93%. E1's held-out run showed the same pattern.
- **The reranker did not raise coverage.** Hybrid retrieval already surfaces
  the gold evidence, so reordering it changes little.
- **Reasoning trades one category for another.** The structured reasoning
  prompt fixes preference and knowledge-update answers. Its instruction
  against over-abstaining also suppresses correct abstentions, so the net
  effect is flat. A better-balanced prompt is a dev-slice tuning task.
- **Ingest latency.** Batched embeddings cut ingest from 346 s to about 50 s
  per LongMemEval-S question (about 495 messages). The batched vectors are not
  bit-identical to single requests, because the provider computes them
  differently in a batch, but on this slice retrieval and answers were
  unchanged.

## Cost

The sprint's provider spend was about $12 in total:

- $0.27 for the E1 reference,
- $1.50 across the GPT-4o-mini daemon harness runs,
- about $6.80 for the four Sonnet 5.5 arms,
- $3.35 for the LoCoMo runs,
- the rest on agent smoke tests.

Embeddings cost about $0.13 per uncached full slice. A GPT-4o-mini reader with
the GPT-4o judge costs about $0.05–0.15 per arm.

## Open items

- Run the frozen configuration on all 500 questions. Report the 374 questions
  that neither E1 nor this sprint used separately from the full set. Add a
  whole-history baseline with the same reader.
- Multi-session aggregation (6/10 with Sonnet 5.5) is the weakest category.
  At 4K, all gold turns are in context for 88% of questions. Larger budgets
  and fact keys pointing back to raw evidence (E1's `assertion_keys` arm) are
  the next retrieval levers.
- The runtime's `fullTextSearch("", 1000)` enumeration cap still bounds
  supersession, provenance and forget closures. Forget propagation must not
  depend on a 1,000-node cap.
- Ingest still waits about 1 s per `memory.remember` on the embedding
  provider. Getting under the 50 ms write latency SOTA systems report needs
  asynchronous embedding after the write.
- In reasoning mode the reader still cites a few invalid support qids (8 of
  140 rows). Those answers are kept, with `supportValid=false`.
