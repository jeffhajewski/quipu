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

## Iteration 2 (October 5): built, not yet measured

These are merged on `sota-sprint`. Each new retrieval behavior is an option,
off by default:

- **Forgetting without a cap.** Forget closures follow provenance edges for
  any label, transitively; they no longer enumerate the store. Supersession
  and core lookups use indexed properties. `quipu verify leaks` flags
  forgotten text that survives in live nodes. Scale tests on stores of over
  5,000 nodes pass on both backends. They fail on the previous runtime.
- **Fact keys** (`options.factKeys`). An LLM extraction worker (`quipu jobs run
  extract`) writes quote-grounded `Assertion` nodes with optional event dates.
  When `factKeys` is on, an assertion hit retrieves its source chunk or
  message. Extraction costs about $0.03 per LongMemEval-S question with
  GPT-4o-mini, and about 78% of claims pass the quote check.
- **Query decomposition** (`options.queryExpansion`: `rules` or `llm`). Each
  sub-query runs through normal candidate generation, fact keys included, and
  the per-query lists are fused. On five known recall misses, `llm` raised
  gold-turn coverage from 40% to 55%; `rules` changed nothing.
- **Speaker indexing.** Lines from named speakers are indexed as
  `"<name>: <text>"`.
- **Question-time correction.** See the section above.

The A/B tests on the dev slice and the LoCoMo re-run are waiting for provider
credit.

## Iteration 3 (November 14): background worker, consolidation, first measurements

Three arms on the 70-question dev slice, GPT-4o-mini reader, GPT-4o judge,
LatticeDB `0.17.0`, default retrieval otherwise. Artifacts are under
`artifacts/sota/it3-control`, `it3-factkeys` and `it3-updates`.

| Arm | 1K | 4K | Knowledge-update at 4K | Extra cost per question |
| --- | --- | --- | --- | --- |
| Control (no extraction) | 52/70 | 47/70 | 5/10 | none |
| Fact keys (`--extract`, `factKeys=true`) | 50/70 | 48/70 | 5/10 | $0.029 |
| Updates (`--extract --consolidate`, `updates=true`) | 51/70 | 48/70 | 5/10 | $0.029 + $0.002 |

None of the differences is outside noise for 70 questions. What the runs do
show:

- **The gap at 4K is in reading, not retrieval.** 16 of the control's 23
  failures at 4K had every gold turn in the prompt, including all 5
  knowledge-update failures and all 6 preference failures. The reader gave the
  older value, or listed both. More context made this reader worse: 52 correct
  at 1K, 47 at 4K, with preference questions falling from 9/10 to 4/10.
- **Fact keys raise coverage but not accuracy.** Gold-turn coverage went from
  0.857 to 0.904 at 1K and from 0.949 to 0.965 at 4K. Answers did not follow.
  This is the first measurement of the iteration-2 fact keys and it matches
  E1.
- **Extraction misses what consolidation needs.** In the Instagram question
  the new value ("close to 1300") was extracted and the old one ("I've got
  1250 followers") was not; 198 of that store's 268 claims came from assistant
  messages. The consolidation job therefore compares new claims with earlier
  raw messages rather than with earlier claims.
- **Consolidation found few updates and the reader ignored the one that
  mattered.** The jobs compared 5,524 user claims across the 70 stores; the
  model proposed 65 pairs and 26 passed the checks. Seven 4K prompts carried a tag, four of them
  knowledge-update questions. Three of those were already correct. The fourth
  (Instagram) had the right tag on the stale line and the reader still
  answered 1250. Of the eight tags that reached a prompt, five paired the
  right statements and three did not (a trip to Chicago against a trip to San
  Francisco, a watch against a laptop).

So `--consolidate` and `options.updates` stay off by default. (Iteration 4
replaced `options.updates` with `options.facts`.) What would make
them worth turning on, in order: a reader that acts on the tag (the reasoning
mode or a stronger model, not yet tried); candidates from vector search as
well as full text, so the gym and wake-up-time updates are found; and
extraction that keeps the user's own statements of fact.

The background worker (`quipu serve --background on`) is new in this
iteration. It is plumbing, not an accuracy lever: with a model that takes one
second per call, `memory.remember` returned in 15 to 23 ms and a search during
extraction in 3 ms, and the claims appeared without any request asking for
them.

This iteration cost $2.33: $0.17 control, $2.00 fact keys (extraction is
$1.95 of it), $0.15 updates (extraction came from the proxy cache), and about
$0.02 of smoke tests.

## Iteration 4 (November 15): facts the user stated, and which ones were replaced

Iteration 3 ended with a reader that had both values in front of it and still
gave the old one, and an extractor that had not captured the user's own
values. This iteration changes both ends: what the background jobs write, and
how the result is shown to the reader.

- **Extraction keeps what people say about themselves**
  (`quipu.extract.speaker-facts.v4`). The assistant's replies are no longer
  sent. In the prototype 10,010 of 10,169 extracted facts were grounded on a
  quote from the message, at about $0.011 per question (it was $0.029).
- **Consolidation compares claims with claims** (`quipu.updates.v2`): a
  propose call per conversation, a verify call per proposed pair that asks for
  the thing and both values before the verdict, then a deterministic check of
  the values against the two claim texts. In the prototype the propose call
  suggested 713 pairs across the 70 stores and 31 survived. GPT-4o as the
  verifier was not better than GPT-4o-mini.
- **`options.facts` replaces `options.updates`.** Claims are listed ahead of
  the raw evidence as `(current, from DATE)` or `(superseded, DATE to DATE)`,
  within 30% of the token budget. The raw evidence stays; it gets the rest.
  The first version listed every matching claim. The version that is kept
  lists only replaced claims and their replacements; the measurements below
  are why.

### Prototype, dev slice

A Python prototype over the same stores, reader, judge and budgets as the
iteration 3 control (52/70 at 1K, 47/70 at 4K):

| Arm | 1K | 4K |
| --- | --- | --- |
| Control | 52/70 | 47/70 |
| Facts section, no consolidation | 52/70 | 51/70 |
| Facts + consolidation, "OUTDATED/CURRENT" wording | 54/70 | 55/70 |
| Facts + consolidation, dated `current`/`superseded` lines, no legend | 53/70 | 54/70 |
| Facts + consolidation, dated lines and a one-line legend | 55/70 | 57/70 |

The last row is what the daemon first implemented. At 4K it won 11 questions
and lost 1: knowledge-update 9/10 (control 5/10), preference 7/10 (4/10),
multi-session 6/10 (4/10).

The dev slice was tuned on: the five knowledge-update failures of the control
drove the design, and the wording was picked from three tries on the same 70
questions. The held-out results below show how much of this was real.

### Daemon, every matching claim listed

Same harness, reader, judge and budgets as the control, which is the same
binary with no options (it reproduces the iteration 3 control answer for
answer). The held-out sample is `evals/experiments/sota-heldout-selection.json`:
63 questions, nine per category, disjoint from E1 and the dev slice, frozen
before any run.

| Slice | Budget | Control | Facts | Wins / losses | Delta (bootstrap 95%) |
| --- | ---: | ---: | ---: | ---: | --- |
| Dev (tuned on) | 1K | 52/70 | 54/70 | 6 / 4 | +2.9 pp [-5.7, +11.4] |
| Dev (tuned on) | 4K | 47/70 | 55/70 | 9 / 1 | +11.4 pp [+2.9, +20.0] |
| Held-out | 1K | 48/63 | 47/63 | 5 / 6 | -1.6 pp [-11.1, +7.9] |
| Held-out | 4K | 48/63 | 44/63 | 3 / 7 | -6.3 pp [-15.9, +3.2] |

The dev gain did not carry over. Splitting the 266 question-budget rows by
what the reader was shown explains both results:

| Facts section contained | Rows | Wins | Losses |
| --- | ---: | ---: | ---: |
| A superseded fact and its replacement | 30 | 5 | 0 |
| Only claims with no replacement | 236 | 18 | 18 |

- **Consolidation's output helps when it is shown.** All five wins are at 4K,
  four of them knowledge-update questions.
- **Listing the other claims only moves answers around.** It changed 36
  answers and improved none on balance. On the dev slice the changes happened
  to fall 11 to 5 in its favor; on held-out, 7 to 13 against.
- **`current` claimed too much.** Every claim without a replacement was
  labeled `current`, including old values whose replacement consolidation had
  missed. Held-out question `07741c45` was lost that way: "keeps old sneakers
  under the bed" was listed as current, and the reader repeated it.
- **Other held-out losses the claims caused:**
  - a claim that said "today" under a date label was read as the question's
    date (`bcbe585f`),
  - claims about plans ("thinking of buying a cow") were taken as events on
    an abstention question (`gpt4_70e84552_abs`),
  - near-duplicate claims pushed a gold message out of the 1K context
    (`d851d5ba`).

### Daemon, replaced facts only

So `options.facts` now lists a claim only when a live update links it to
another: the replaced claim and the one that replaced it. Extraction and
consolidation are unchanged, so these runs reuse the cached model calls.

| Slice | Budget | Control | Facts | Wins / losses |
| --- | ---: | ---: | ---: | ---: |
| Dev | 1K | 52/70 | 51/70 | 0 / 1 |
| Dev | 4K | 47/70 | 50/70 | 3 / 0 |
| Held-out | 1K | 48/63 | 48/63 | 0 / 0 |
| Held-out | 4K | 48/63 | 49/63 | 2 / 1 |

- A facts section appeared in 47 of the 266 rows. Those rows had 4 wins and no
  losses, all four at 4K on knowledge-update questions: 7/10 on dev (control
  5/10) and 8/9 on held-out (6/9).
- At 1K the section changed no answer.
- The 1 win and 2 losses are in rows without a section. In about half of
  those rows the raw context differs from the control's by an item or two at
  the edge of the budget, so having claims in the store shifts raw retrieval
  slightly even though claims are not candidates. The cause has not been
  isolated; claims share the full-text and vector indexes with raw text.
- Neither slice is a clean test of this version. It was chosen after looking
  at both, so the confirmation below is the result to trust.

### Confirmation on unseen knowledge-update questions

`evals/experiments/sota-ku-confirm-selection.json` holds the 39
knowledge-update questions that E1, the dev slice and the held-out sample all
left unused. It was frozen before any run on it, with one hypothesis: the
replaced-facts section answers more of them than the control at 4K and no
fewer at 1K.

| Budget | Control | Facts | Wins / losses | Delta (bootstrap 95%) |
| ---: | ---: | ---: | ---: | --- |
| 1K | 35/39 | 38/39 | 3 / 0 | +7.7 pp [0.0, +17.9] |
| 4K | 32/39 | 35/39 | 3 / 0 | +7.7 pp [0.0, +17.9] |

- The hypothesis held in direction at both budgets. Five questions improved at
  one budget or the other and none got worse.
- The sample is small: the exact McNemar p is 0.25 at each budget. Read it as
  "consistent with the 4 wins and no losses on the earlier slices", not as a
  measured effect size.
- Five of the six wins had a facts section in the context. The answers
  changed from the old value to the new one: Hawaii to Paris for the most
  recent family trip, 125 stars to 120, a 5K best of 27:12 to 25:50.
- A section appeared for 22 of the 39 questions. Consolidation wrote 41
  updates from 701 proposed pairs, at $0.0106 per question for extraction and
  $0.0053 for consolidation, with no failed jobs.

### The whole knowledge-update category, next to published systems

Adding the last 16 knowledge-update questions
(`evals/experiments/sota-ku-rest-selection.json`, frozen before its run)
completes the benchmark's category: all 78 questions of type
`knowledge-update`, the six `_abs` ones included. That is the one place where
this work can be set beside published numbers, which are reported on the same
78 questions with the same GPT-4o judge.

| Arm (GPT-4o-mini reader) | 1K | 4K |
| --- | ---: | ---: |
| Control | 66/78 (84.6%) | 59/78 (75.6%) |
| Extraction, consolidation and `options.facts` | 69/78 (88.5%) | 67/78 (85.9%) |
| Wins / losses | 3 / 0 | 8 / 0 |

- A facts section appeared for 40 of the 78 questions.
- 55 of the 78 questions were never looked at before this version was fixed
  (the confirmation sample and these 16). On those the result is 3 wins and 0
  losses at 1K, and 4 and 0 at 4K. The other 23 were seen during development
  and supply the other four 4K wins, so the 8 / 0 (exact McNemar p = 0.008)
  overstates the evidence. The direction has not failed on any sample.

Published knowledge-update accuracy on LongMemEval-S, as their authors report
it:

| System | Reader | Knowledge-update |
| --- | --- | ---: |
| Full context | GPT-4o | 78.2% |
| Zep | GPT-4o | 83.3% |
| Mastra Observational Memory | GPT-4o | 85.9% (67/78) |
| Supermemory | GPT-5 | 87.2% |
| Supermemory | Gemini 3 Pro | 89.7% |
| Mastra Observational Memory | Gemini 3 Pro | 94.9% (74/78) |
| Mastra Observational Memory | GPT-5-mini | 96.2% (75/78) |
| **Quipu, control** | GPT-4o-mini, 4K / 1K | 75.6% / 84.6% |
| **Quipu, with the background jobs** | GPT-4o-mini, 4K / 1K | 85.9% / 88.5% |

Sources: the Zep and full-context rows are from Zep's report as reproduced in
[Supermemory's results](https://supermemory.ai/research/longmembench); the
Supermemory rows are from the same page; the Mastra rows are from
[Mastra's research page](https://mastra.ai/research/observational-memory).

How to read this:

- **On this category Quipu is now in the range of the GPT-4o-reader systems,
  with a weaker reader.** The control was below full-context GPT-4o at 4K; the
  background jobs close that gap.
- **It is not at the level of the best systems.** Those reach 95% with
  stronger readers. Quipu's earlier Sonnet 5.5 run suggests the reader
  accounts for much of that distance, but the facts arm has not been run with
  a stronger reader.
- **It is one category of six.** Knowledge-update is 78 of 500 questions. The
  facts section does nothing for the other categories, and Quipu has no
  full-benchmark number yet.
- **The setups differ.** Each vendor uses its own retrieval budget and prompt.
  A [Redis report](https://redis.io/resources/agent-memory-benchmark-report/)
  says published memory scores often do not hold up when rerun under one
  judge, so treat every row, this one included, as self-reported.

### Cost and volume

| | Dev (70) | Held-out (63) |
| --- | ---: | ---: |
| Extraction calls | 3,334 | 3,003 |
| Claims written | 11,206 | 10,082 |
| Extraction cost per question | $0.0104 | $0.0107 |
| Consolidation jobs | 1,802 | 1,607 |
| Consolidation calls | 2,658 | 2,375 |
| Pairs proposed | 998 | 893 |
| Updates written | 37 | 30 |
| Consolidation cost per question | $0.0049 | $0.0048 |

- 99% of extracted claims passed validation (109 of 11,317 quarantined on
  dev, almost all for a quote not found in the message).
- One consolidation job of 3,409 failed: the model's reply was malformed on
  both tries. Its question stays in the results.
- About one update is written per 95 sessions, half an update per question's
  history, so most questions never see a facts section. Raising that rate
  without admitting wrong pairs is the open problem: the propose call
  suggests 28 pairs for each one that survives.

The runs took a night instead of an hour. Three harness runs at once (18
workers in all, each with its own daemon) on a closed laptop ended in a
thermal emergency sleep, after which the machine ran for under a minute every
quarter hour. Runs now go one at a time at three workers.

## Iteration 5 (November 15): temporal reasoning

Knowledge-update was the category the background jobs were built for.
Temporal reasoning is the other one the goal names, and nothing so far had
measured it beyond the 24 questions in the dev and held-out slices.

### Samples

The 109 temporal-reasoning questions outside those slices were cut in half by
hash before any run: `sota-tr-tune` (55, looked at freely) and
`sota-tr-confirm` (54, read only in aggregate until a configuration was
fixed). With `sota-tr-seen` (the 24 seen earlier) they make up the
benchmark's whole 133-question category.

### How the control fails

The control scored 32/55 at 1K and 38/55 at 4K on the tuning half. Its 17
failures at 4K:

- **Nine had every gold turn in the context.** The reader picked the wrong
  date, subtracted wrongly, or ordered events by the wrong date (a pre-order
  date instead of the arrival date). The same happens at 1K, where one answer
  counted April 15 to April 21 as "23 days".
- **Four were multi-event questions with one event missing** ("the order of
  the sports events I watched in January").
- **Three had no gold turn at all.** They name a time and not a topic: "What
  kitchen appliance did I buy 10 days ago?" The message says "I just got a
  smoker today" and shares almost no words with the question.
- One was an abstention question.

### What was tried, on the tuning half

GPT-4o-mini reader, 55 questions:

| Arm | 1K | 4K |
| --- | ---: | ---: |
| Control | 32 | 38 |
| `temporalHints` | 32 | 38 |
| `timeAnchors` | 32 | 37 |
| `timeAnchors` + `temporalHints` | 33 | 39 |
| `timeAnchors` (first version) + `temporalHints` + `readerReasoning` | 39 | 37 |
| Background jobs: `factKeys` + `facts` | 31 | 33 |
| Background jobs: `factKeys` + `facts` + `temporalHints` | 33 | 31 |
| Background jobs + `temporalHints` + `timeAnchors` (first version) | 36 | 33 |

- **`timeAnchors` is new** (see [algorithms.md](algorithms.md#time-anchors)):
  when the question names a time, what the user said inside that window is
  placed first. The first version anchored any message, 12 per window, and
  mostly brought in long assistant replies; the kept version anchors only
  what a speaker said.
- **The background jobs made temporal answers worse at 4K**: 1 win and 8
  losses with hints (McNemar p = 0.04), 2 and 7 without. Gold-turn coverage
  rose from 90% to 92%, so this is the reader, not retrieval.
  - Rows with an `[event DATE]` tag: 1 win, 5 losses at 4K. A tag on one line
    was read as the date of something mentioned two lines later.
  - Rows with a facts section: no wins, 3 losses at 4K (3 wins, 1 loss at 1K).
    One was a false update: "planning a longer bike ride this weekend" was
    marked superseded, and the reader took the replacement date as the day a
    bike was fixed. So the facts section is not free outside knowledge-update
    questions.
- **`readerReasoning` helped at 1K and not at 4K.** It was not taken further.

### The whole category

`timeAnchors` with `temporalHints` was the configuration fixed for the frozen
half. It failed there at 4K (28/54 against 33), and the rows show why: in the
113 rows per budget that no anchor touched, the hints alone account for 3 wins
and 13 losses at 4K. `timeAnchors` alone was then run on all three samples.
That choice was made after seeing the frozen half's totals, so its frozen-half
result below is not a clean confirmation; what protects it is that a row
without a time in the question is byte-identical to the control.

| Reader | Arm | 1K | 4K |
| --- | --- | ---: | ---: |
| GPT-4o-mini | Control | 78/133 (58.6%) | 91/133 (68.4%) |
| GPT-4o-mini | `timeAnchors` | 79/133 (59.4%) | 90/133 (67.7%) |
| GPT-4o-mini | `timeAnchors` + `temporalHints` | 80/133 (60.2%) | 84/133 (63.2%) |
| GPT-4o | Control | 91/133 (68.4%) | 93/133 (69.9%) |
| GPT-4o | `timeAnchors` | 93/133 (69.9%) | 95/133 (71.4%) |

- **Anchors fix the retrieval they were built for.** They changed 20 rows per
  budget. Gold-turn coverage at 4K went from 90% to 96% on the tuning half and
  from 87% to 94% on the frozen half.
- **Whether that becomes answers depends on the reader.** In those 40 rows
  GPT-4o-mini had 5 wins and 5 losses; GPT-4o had 5 wins and 1 loss, 3 and 0
  of them on the frozen half.
- **`temporalHints` costs GPT-4o-mini answers at 4K.** It stays off by
  default.
- **A stronger reader is not the missing piece.** GPT-4o adds 10 points at 1K
  and 1.5 at 4K.

### Background jobs with a GPT-4o reader

The background jobs lost answers with GPT-4o-mini. One probe asked whether
that is the reader: the tuning half again, with extraction and consolidation,
`factKeys`, `facts` and `timeAnchors`, and GPT-4o reading.

| Arm (GPT-4o reader, tuning half, 55) | 1K | 4K |
| --- | ---: | ---: |
| Control | 40 | 40 |
| `timeAnchors` | 41 | 40 |
| Background jobs + `timeAnchors` | 42 | 43 |

Against the control that is 5 wins and 3 losses at 1K and 4 wins and 1 loss
at 4K; against `timeAnchors` alone, 5 and 4, then 3 and 0. With GPT-4o-mini
the same jobs cost five answers at 4K. So the event dates and the facts
section appear to help a reader strong enough to use them and to mislead a
weaker one. Three answers in 55 on the tuning half is within
the noise measured above, so the same arm was then run unchanged on the
frozen half and on the 24 earlier-seen questions:

| Sample (GPT-4o reader) | Control 1K | Jobs 1K | Control 4K | Jobs 4K |
| --- | ---: | ---: | ---: | ---: |
| Tuning half (55) | 40 | 42 | 40 | 43 |
| Frozen half (54) | 33 | 37 | 36 | 41 |
| Seen earlier (24) | 18 | 20 | 17 | 19 |
| **Whole category (133)** | 91 (68.4%) | 99 (74.4%) | 93 (69.9%) | 103 (77.4%) |

- **The frozen half agrees.** 6 wins and 2 losses at 1K, 8 and 3 at 4K
  (McNemar p = 0.29 and 0.23: the direction holds, the sample is too small to
  settle it alone). Against `timeAnchors` alone it is 5 and 2, then 6 and 3.
- **Over the whole category it is 14 wins and 4 losses at 4K** (p = 0.03,
  unadjusted, and this is one of about ten arms tried) and 13 and 5 at 1K
  (p = 0.10). Against `timeAnchors` alone: 11 and 3 at 4K, 12 and 6 at 1K.
- No extract or consolidate job failed in these 133 histories, and no
  question errored. The frozen half took 8,947 claims and 29 updates.
- The GPT-4o-mini reader was not rerun with this exact arm on the whole
  category. On the tuning half it lost answers with every background-jobs
  variant, so for now this is a result about GPT-4o.

### Next to published systems

Temporal-reasoning accuracy on LongMemEval-S (133 questions), as reported by
each system's authors (same sources as the knowledge-update table):

| System | Reader | Temporal reasoning |
| --- | --- | ---: |
| Full context | GPT-4o | 45.1% |
| Zep | GPT-4o | 62.4% |
| **Quipu, control** | GPT-4o-mini, 4K | 68.4% |
| **Quipu, control** | GPT-4o, 4K | 69.9% |
| **Quipu, `timeAnchors`** | GPT-4o, 4K | 71.4% |
| **Quipu, background jobs + `timeAnchors`** | GPT-4o, 4K | 77.4% (103/133) |
| Supermemory | GPT-5 | 81.2% |
| Supermemory | Gemini 3 Pro | 82.0% |
| Mastra Observational Memory | GPT-4o | 85.7% (114/133) |
| Mastra Observational Memory | Gemini 3 Pro | 94.0% (125/133) |
| Mastra Observational Memory | GPT-5-mini | 95.5% (127/133) |

With the same reader, Quipu with its background jobs is 15 points above Zep
and 8 below Mastra's observational memory (10 answers in 133). Without the
jobs it was 14 below. That is still the largest measured gap to the state of
the art in this document, and retrieval does not explain it: every gold turn
is in the 4K context for more than nine questions in ten, and 11 of the 13
wrong answers on the frozen half had all of them.

What is left is the form of the evidence. The reader gets raw turns that say
"last week" and "a month ago" under a session date, and has to resolve, order
and subtract them itself. The systems above 85% do that work before the
question arrives and hand the reader dated observations. Quipu's background
extraction resolves some event dates and shows them as tags on raw lines.
GPT-4o uses those tags; GPT-4o-mini reads a tag as the date of something two
lines later. The next design to test is the one those systems use: a timeline
of the user's dated events, written by the background jobs with every relative
date resolved, shown to the reader as its own section.

## Iteration 6 (November 16–17): LatticeDB 0.18, and dates in facts

### LatticeDB 0.18

The adapter now targets LatticeDB 0.18.0, which can remove a node's vector.
Forgetting a message removes its vector instead of overwriting it with a
placeholder, and vector search no longer has to filter placeholders out. When
a store is opened, any vector still held by a forgotten or unsearchable node
is removed, so stores written by the 0.17 build are cleaned on first open.
Checked end to end: a store written by the 0.17 build with one forgotten
message held a vector for that message before the 0.18 build opened it and
none after.

### Relative dates in extracted facts

Extraction kept the speaker's wording, so a fact could say "yesterday" with
no way to tell which day. A deterministic resolver (`core/src/temporal.zig`)
now rewrites relative times against the date of the message: single days
become calendar dates, weeks, months and years become periods, and times it
cannot place ("recently", "a few weeks ago") get the day they were said.
See `docs/algorithms.md`, step 6.

Measured on the claims of 24 held-out histories (3,928 claims, about 164 per
history):

| | Claims |
| --- | ---: |
| Named a relative time | 654 (16.6%) |
| Rewritten to a calendar date or period | 369 |
| Could only be given the day it was said | 285 |
| Named one day | 101 |
| ...of which the model had already dated | 33 (27 the same day, 6 wrong) |
| ...of which got an event date for the first time | 68 |

All six dates the model got wrong were "last Saturday" or "last Sunday"
placed a week early. Claims with an event date rose from 273 to 341.
Duplication was low: 0.5% of claims were exact repeats and 1.1% near repeats
by wording.

On answers the change is neutral. The tuning half of temporal reasoning (55
questions, GPT-4o reader, extraction and consolidation on, `factKeys`,
`facts` and `timeAnchors`):

| Arm | 1K | 4K |
| --- | ---: | ---: |
| Before date resolution | 42 | 43 |
| Dates written into the fact and its search text | 43 | 40 |
| Dates written into the fact, search on the model's wording | 42 | 43 |

The first attempt lost three answers at 4K. One was traced to month names in
the fact's search text matching a question that named months, which changed
what was retrieved. Facts are now searched on the model's wording and matched
on time through their event date; that arm has no wins and no losses against
the earlier one. The reader rarely sees fact text in these arms, so better
facts cannot move answers until something is built on them. Not run on the
frozen half, since there is no gain to confirm.

## Iteration 7 (November 17): nodes built above the facts, a prototype

This iteration is a prototype outside the daemon. Its scripts, journals and
results are in `artifacts/experiments/pattern-benchmark/` (not in git).
Nothing in `core/` changed.

### The question

LongMemEval asks about things that were said. This iteration asks about
things that were never said and only show up when many sessions are compared:
a preference, or what goes with what. The idea under test is that a
background pass should build nodes above the raw memory that hold such
conclusions, so the reader does not have to work them out at question time.

### The benchmark

Synthetic journals written by GPT-4o-mini from day-by-day notes that a
generator plans. Each journal threads topics through ordinary days as passing
observations. For a topic with a regularity, one detail goes with the outcome
nearly every time (for example runs on pavement and an aching knee). For a
topic without one, detail and outcome are independent. The regularity is
never stated. Every scenario appears once with and once without a regularity
across a set, so an arm that always says "yes, there is a cause" scores half.

| Set | Journals | Entries each | Occasions per topic | Use |
| --- | ---: | ---: | ---: | --- |
| Tuned-on | 8 | 80 short | 10 | development |
| Fresh | 8 | 80 short | 10 | run once; 4 scenarios new to the pipeline |
| Larger, tuned-on | 2 | 200, from 51 to 582 words | 12 | development |
| Larger, fresh | 4 | 200, from 45 to 602 words | 12 | run once |

Each short journal has one topic of each kind and one lookup question. Each
larger journal is about 50,000 tokens and has two topics of each kind and two
lookups; a planted observation is two sentences among the sixteen storylines
and several hundred one-off events of the surrounding year. A
correct answer names the deciding detail, or says that nothing consistent
explains it. Questions are worded as a person would ask them ("Why is my
knee hurting?") and do not say that a pattern exists. An earlier wording that
did ("Is there a pattern in when my knee hurts after a run?") flattered
every arm and was dropped.

### The pipeline that worked

1. **Gather by recurrence.** Every sentence of every entry is embedded.
   Sentences from different entries are linked when their similarity is at
   least 0.65, and each linked set is a group whose occasions are the entries
   it came from. Groups covering nearly the same entries are merged. No model
   is involved and nothing is filtered for salience first.
2. **Decide what is worth analysing.** A model reads each group's sentences
   and marks it routine, a developing story, or separate occasions that went
   differently. Only the last kind goes on.
3. **Propose and count.** GPT-4o reads the occasions and proposes up to four
   generalisations, each as a circumstance and an outcome phrased as yes/no
   questions. GPT-4o-mini, which never sees the generalisation, answers both
   questions for every occasion. The program counts the two-by-two table and
   keeps a generalisation when Fisher's exact test gives p ≤ 0.06 and the
   outcome rate differs by at least 0.6. When none passes, the node records
   that the occasions were compared and nothing held.
4. **Read.** The three analysed nodes nearest the question go on top of raw
   entries retrieved by similarity.

### Results

Fresh journals, natural questions, pattern plus no-pattern questions out of
16 (lookups were 8 of 8 in every row):

| Context given to the reader | Tokens | GPT-4o-mini | GPT-4o |
| --- | ---: | ---: | ---: |
| Raw entries by similarity | 300 | 5 | 5 |
| Derived nodes + raw entries | 300 | 5 | 8 |
| Raw entries by similarity | 1,200 | 1 | 5 |
| Derived nodes + raw entries | 1,200 | 7 | 11 |
| Whole journal | 4,836 | 1 | 1 |

The tuned-on journals gave 3, 11 and 2 for the three 1,200-token and
whole-journal rows with GPT-4o. Most of the gain is on no-pattern questions
(7 of 8 against 1 of 8 at 1,200 tokens with GPT-4o); real patterns tied at 4
of 8. Facts from the daemon's current extraction prompt, given alone, scored
0 to 1 of 8 on patterns in every set.

Fresh larger journals, same scoring, out of 16:

| Context given to the reader | Tokens | GPT-4o-mini | GPT-4o |
| --- | ---: | ---: | ---: |
| Raw entries by similarity | 300 | 6 | 8 |
| Derived nodes + raw entries | 300 | 8 | 9 |
| Raw entries by similarity | 1,200 | 3 | 3 |
| Derived nodes + raw entries | 1,200 | 8 | 10 |
| Whole journal | 50,217 | 0 | not run |

Here the arms separate on real patterns: derived nodes found 4 of 8 with
both readers at both budgets, raw retrieval 0 to 2, the whole journal none.
Raw retrieval's score at 300 tokens is abstention: one long entry fills the
budget, the reader says it cannot tell, and that is right for a no-pattern
question (6 to 7 of 8) and wrong for a pattern. The two larger journals used
for development gave 8 of 8 against 4 of 8 with GPT-4o at 1,200 tokens, so
the fresh result is the weaker and the more honest one. Lookups cost
something: at 1,200 tokens derived nodes answered 3 of 8 against 5 of 8 for
raw retrieval, because the nodes take budget from the entries.

By stage, on the fresh short journals unless noted:

| Stage | Measure | Result |
| --- | --- | ---: |
| Gathering, model proposes groups and a second model checks | planted topics in a clean node | 7 of 16 |
| Gathering, model names each occasion's kind | same, tuned-on | 4 of 16 |
| Gathering by sentence similarity | same | 13 of 16 |
| Analysis, GPT-4o-mini proposes, support judged per occasion | patterns found with gathering given, tuned-on | 0–1 of 8 |
| Analysis, GPT-4o-mini proposes, counted table | same | 4 of 8 |
| Analysis, GPT-4o proposes, counted table | same | 6–7 of 8 |
| Whole pipeline, node level | real patterns found | 5 of 8 |
| Whole pipeline, node level | false patterns on no-pattern topics | 1 of 8 |
| Gathering by sentence similarity, fresh larger | planted topics gathered whole; in a clean node | 16 of 16; 12 of 16 |
| Whole pipeline, node level, fresh larger | real patterns found | 5 of 8 |
| Whole pipeline, node level, fresh larger | false patterns on no-pattern topics | 2 of 8 (one node chaining two topics) |

### What did not work

- **Asking a model what items have in common.** It groups by how things
  turned out (good nights apart from bad nights) or by mood ("positive
  experiences during the day", 103 facts), which removes the contrast the
  analysis needs.
- **Naming each occasion's kind as it is read.** "Noticed a woman at the
  train platform" became "a train platform observation". The level that
  matters cannot be told from one occasion.
- **Judging support occasion by occasion.** "Sleeps better after takeaway
  curry" passed with 9 of 10 because every night without curry counted as
  support. Whether two things go together has to be counted on both sides.
- **Picking salient points per entry.** In the larger journals at most three
  points per entry kept both halves of a planted observation in 0 to 7 of 12
  entries. What matters across sessions cannot be judged inside one.
- **Listing rejected candidates in a "nothing held" node.** GPT-4o-mini
  sometimes repeats a rejected candidate as the answer.

### Four follow-on experiments

Each was run on the prototype with the rest held fixed.

**Going back over what was already processed.** The first 60% of each larger
journal (70% of each short one) arrived first and nodes were built from it;
then the rest arrived. Three policies, over all 22 journals (28 topics with a
regularity, 28 without):

| Policy when new entries arrive | Real patterns found | False patterns |
| --- | ---: | ---: |
| Analyse a node once, when it first has enough occasions | 11 of 28 | 0 of 28 |
| Keep the early generalisations, update only their counts | 18 of 28 | 0 of 28 |
| Gather and analyse everything again | 19 of 28 | 3 of 28 |

On the 12 fresh journals the three rows are 5, 10 and 10 of 16, with 0, 0
and 3 false. Seven patterns that read "nothing found" early passed once the
later occasions were counted, and no early finding was overturned. Updating
counts needs only the small model on the new occasions. A generalisation
worded before an occasion happened is also tested fairly by it: on topics
with a regularity, 44 of 54 later occasions went the way the leading early
generalisation said; on topics without one, 29 of 60, which is chance.
Rebuilding proposes four new generalisations after seeing all the data each
time, which is where its three false patterns came from; three against none
is too few to call a difference.

**What to embed.** Gathering was rerun with different text embedded for each
sentence (topics gathered cleanly, tuned-on short journals, best threshold
for each):

| Text embedded | Clean groups |
| --- | ---: |
| The bare sentence | 15 of 16 |
| The sentence with the one before it | 10 of 16 |
| The sentence with one on each side | 4 of 16 |
| A model's self-contained restatement of each occasion | 13 of 16 |

Neighbouring sentences carry other topics, so adding them links unrelated
days. On the fresh short journals the restatement tied the bare sentence at
its best threshold (13 against 15 of 16). The journals are written so that a
sentence carries its own point; dialogue, where "yes, that one" means nothing
alone, is not covered by this test.

**More detail in a node.** With the nodes fixed and only their wording
changed (GPT-4o-mini, fresh short and tuned-on larger journals, 12 questions
of each kind at 300 tokens): adding the circumstances that were checked and
made no difference changed nothing (6 and 3 of 12 either way). Removing the
rejected candidates from a "nothing found" node raised no-pattern answers
from 3 to 11 of 12. On the fresh larger journals the same removal added 1 to
2 answers of 8 for the small reader and nothing for GPT-4o.

**Direction between nodes.** A later occasion is paired with the earlier one
it most resembles within seven days, and a model says whether it is about
what became of it. Pairs inside a group merge into one occasion; a group
whose occasions regularly follow another group's becomes a directed
"followed by" link. This repaired the seed-tray topics on the short journals
and moved two of three delayed no-pattern topics on the larger ones from "too
few to tell" to a correct "nothing found". It did not repair purchases on the
larger journals: there the sentences sit in one chained group of 139 entries,
and the clean sub-groups divide by wording ("online at midnight … regret"
apart from "in a shop … happy"), so neither holds a contrast.

### Tightening the benchmark (November 18)

Three weaknesses in the benchmark itself were found and corrected.

**The wording was templated.** Every occasion of a topic was worded nearly
the same way ("I lost it badly", each time), because the notes came from
templates. Identical sentences gather trivially and are easy to read off.
Two reworded sets were built from the plans of h8–h15:

- **v8–v15** reworded each note on its own. That broke references: "I lost it
  badly", two sentences after the chess game, became "I failed miserably",
  which no reader can tie to the game. The analysis found 2 of 8 patterns.
  The set is flawed and is kept only as a record of the mistake.
- **w8–w15** reword the notes of an entry together. Each occasion has its own
  wording, and a note that refers back names what it refers to ("I lost that
  game quite badly").

| Step | Templated (h8–h15) | Varied (w8–w15) |
| --- | ---: | ---: |
| Topics whose node holds every occasion and nothing else (of 16) | 14 | 10 |
| Patterns the analysis found (of 8) | 5 | 4 |
| False patterns on no-pattern topics (of 8) | 1 | 0 |

The analysis survives varied wording; gathering loses more. Of the four
patterns missed on w8–w15, three are topics the templated set also missed
(seed trays, whose outcome is reported days later; headaches, with too few
occasions the small model could read; and attraction). The fourth, evenings
with friends, was swallowed by a chained group of 39 entries.

Answers on w8–w15, pattern and no-pattern questions together (16):

| Reader | Context | 300 tokens | 1,200 tokens |
| --- | --- | ---: | ---: |
| GPT-4o-mini | Raw entries | 5 | 2 |
| GPT-4o-mini | Nodes on top of raw entries | 8 | 7 |
| GPT-4o | Raw entries | 5 | 3 |
| GPT-4o | Nodes on top of raw entries | 9 | 12 |

The whole journal (4,631 tokens) gave 1 and 3. All eight lookups were right
in every cell. Most of the gain is on the no-pattern questions: at 1,200
tokens GPT-4o with nodes answered 8 of 8 correctly that nothing explains the
outcome, and 0 of 8 from raw entries, where it names a cause that is not
there. On pattern questions the nodes delivered the four patterns the
analysis had found (4 of 8 against 3 of 8).

**No one similarity cut-off suits every journal.** Topics gathered cleanly by
linking sentences above a cut-off, before any model is involved:

| Journals | 0.55 | 0.60 | 0.65 | 0.70 |
| --- | ---: | ---: | ---: | ---: |
| h8–h15, templated (of 16) | 15 | 15 | 13 | 12 |
| s8–s15, clipped diary style (of 16) | 9 | 15 | 16 | 10 |
| w8–w15, varied wording (of 16) | 12 | 16 | 13 | 9 |
| g0–g1, 200 entries (of 8) | 4 | 6 | 8 | 7 |
| g2–g5, 200 entries, fresh (of 16) | 6 | 11 | 12 | 8 |

Short journals want about 0.60 and the 200-entry journals 0.65: with more
sentences in the store there are more chance links, and a lower cut-off
chains unrelated days together. A fixed global cut-off is the wrong rule.

**What to embed, again.** Facts were extracted with the numbers of the
sentences each came from, and four texts were embedded: the bare sentence,
the fact statement, the source span, and fact plus span. On w8–w15 at the
best cut-off they gathered 16, 15, 16 and 14 of 16 topics. Of 2,066 facts,
1,701 came from one sentence, 358 from two and 7 from three, so in these
journals a span is nearly always the sentence itself. The comparison needs
dialogue or longer prose before it says anything about multi-sentence spans.

**Grading was checked by hand.** GPT-4o grades every answer against the
reference. The 32 pattern and no-pattern answers of the GPT-4o reader at
1,200 tokens on w8–w15 were read and graded by hand. The hand grade agreed
on 28. The other four are two questions, in both arms: answers that name the
right factor but hedge, or add an irrelevant one, which the judge marks
wrong either way. No disagreement changes a comparison.

**Who writes the benchmark.** The scenarios, the observation templates, the
plan of which occasion carries which circumstance and outcome, the questions
and the reference answers are written by hand or by code. GPT-4o-mini turns
the notes into diary prose, rewords them for the varied sets, and invents the
background events and storylines. A splitter bug that broke sentences after
"Mr." and "Dr." was fixed; it had affected 1.3% of the sentences in the
200-entry journals and none in the short ones.

### A fresh confirmation set, written by hand (November 18)

Every set above had been looked at while the pipeline was being built or its
settings chosen. A new set, x0–x7, was written after that work stopped: eight
new topics (loaves that come out flat, calls with a brother that end in a
row, rolls of film that come back ruined, punctures, one-to-ones that leave
the writer flat, sketches thrown away, dinners for guests that go wrong,
sneezing fits). In each, the circumstance that goes with the bad outcome is
the one general knowledge would not pick: the dish cooked many times goes
wrong, the loaf proved in the fridge comes out flat. The topics, templates,
questions and reference answers are hand-written; GPT-4o-mini only rewords
the notes and writes the diary prose, as for w8–w15. The film topic reports
its outcome two entries later. Nothing was changed after the set was run.

**A grouping rule that does not chain.** Linking any two sentences above a
cut-off lets one stray pair join two topics. The alternative tried here
merges two groups only when their members are alike on average: sentences
link at 0.60 as before, and two groups merge only if the mean similarity
between all their members is at least 0.45. On the sets already seen it
gathered 68 of 72 topics cleanly against 62 or 63 for the best single
cut-off, with one setting for short and 200-entry journals, and the largest
group in g2–g5 shrank from 169 entries to 85. Those settings were picked on
those sets; x0–x7 is the first independent check.

| Step on x0–x7 | Linking above 0.65 | Average-link 0.60 / 0.45 |
| --- | ---: | ---: |
| Topics gathered cleanly before any model (of 16) | 15 | 16 |
| Topics whose node holds every occasion (of 16) | 14 | 16 |
| Patterns the analysis found (of 8) | 6 | 6 |
| Regularities reported on no-pattern topics (of 8) | 1 | 3 |

The two patterns missed are the same under both rules: film, whose outcome
arrives two entries after the roll is shot (the small model could tie only
six of ten occasions together), and sketches, where the small model read
the occasions unreliably (it counted 5, 0, 1, 0 on one run and 1, 2, 0, 5 on
the other).

The regularities reported on no-pattern topics were checked against what was
planted. Only one of the three is a pipeline error:

- **Punctures (both rules): true of the journal.** The destination of each
  ride was drawn at random, and by chance all three rides to Aunt Sal's went
  without trouble while six of the other seven had a puncture (p = 0.033).
  The node says exactly that. The benchmark's reference answer is wrong, not
  the node.
- **Loaves (average-link): true of the journal.** The background filler
  includes "tried a new bread recipe and it came out dense" six times. The
  gatherer rightly put those six loaves in the bread node, and with them the
  rye-blend loaves rose three times in four against one in twelve for the
  rest (p = 0.027). Under the other rule the same node was counted
  differently on a different run and stayed below the cut.
- **Film (average-link): an error.** The claim was a compound one ("the
  Pentax, at places other than the bus depot") and the small model counted
  4, 1, 0, 4 where the plan gives 2, 1, 2, 5. A compound condition found by
  search over ten occasions, counted across entries two apart, should not
  pass on one test.

Two lessons for the benchmark follow. A free attribute drawn at random lines
up with the outcome by chance often enough to matter: testing every free
attribute of all 104 topics built so far finds five such coincidences at
p ≤ 0.06 (four in pattern topics, where they compete with the planted
circumstance, and this one in a no-pattern topic). None is in the no-pattern
topics of the earlier sets, so the false-pattern counts reported above
stand. And filler must be checked against the topics; the generator should
reject a journal with either flaw.

Answers on x0–x7, pattern and no-pattern questions together (16):

| Reader | Context | 300 tokens | 1,200 tokens |
| --- | --- | ---: | ---: |
| GPT-4o-mini | Raw entries | 3 | 3 |
| GPT-4o-mini | Nodes (linking above 0.65) on raw entries | 5 | 8 |
| GPT-4o-mini | Nodes (average-link) on raw entries | 8 | 8 |
| GPT-4o | Raw entries | 1 | 2 |
| GPT-4o | Nodes (linking above 0.65) on raw entries | 6 | 13 |
| GPT-4o | Nodes (average-link) on raw entries | 8 | 11 |

The whole journal (4,751 tokens) gave 3 and 2. Lookups were right in every
cell but one (7 of 8 for GPT-4o with average-link nodes at 300 tokens). The
picture from w8–w15 holds on unseen topics: from raw entries GPT-4o gets
none of the eight no-pattern questions right (it names a cause that is not
there) and finds 2 of 8 real patterns; with nodes it gets 8 of 8 no-pattern
questions and 5 of 8 pattern questions.
The 32 GPT-4o answers at 1,200 tokens were graded by hand as well; the hand
grade differs from the judge on two, one in each arm, both hedged answers
the judge marked wrong.

Going back over a node as entries arrive was repeated on this set, with the
first 60% of each journal arriving first. Analysing a node once, when it
first had enough occasions, found 4 of 8 patterns. Keeping the early
generalisations and updating only their counts found 6, with nothing
reported on the no-pattern topics. Gathering and analysing everything again
also found 6, and reported the punctures coincidence. A generalisation
worded before the later occasions existed predicted them 15 times in 18 on
pattern topics and 6 times in 13 on no-pattern topics. This matches the
earlier sets: keep the claim, keep counting.

Average-link gathers better and holds every occasion in all 16 topics, but
it did not find more patterns, and its larger, more complete nodes gave the
analysis more to over-read. It is the better gathering rule; the analysis
needs a guard against compound claims before the two are combined.

### Cause-and-effect links, on hand-written chains (November 18)

The first test of links between an event and what it led to (under "Four
follow-on experiments") showed little benefit. Two things were wrong with
it. The chains had been invented by GPT-4o, and the questions could be
answered from the one entry that similarity retrieval already finds. A
second look at the proposing step also showed that focus decides whether a
cause is found at all: asked about one sentence at a time, the small model
found the planted cause of 15 events in 16; handed a whole entry and a week
of earlier text, it found almost none.

**The journals.** Two 200-entry journals, d0 and d1, each carry eight chains
of three events written by hand, and four one-off events with no cause given
anywhere. A chain's events sit in different entries, a few days apart, and
share few words: a delivery van knocks down the garden wall; the
insurer's assessor needs the writer at home on Friday morning; the writer
moves a dental check-up. The entry about the check-up does not say why. The
background (storylines, small events, chores) is the same as in g0–g5.
GPT-4o-mini wrote the diary prose from the notes; the planted sentences were
read afterwards and are faithful.

**Building the links.** For every sentence, GPT-4o-mini is asked one
question: did something in the previous six entries bring this about?
GPT-4o then checks each proposal, stating the relation before the verdict.

| | d0 | d1 | Both |
| --- | ---: | ---: | ---: |
| Proposals | 1,104 | 1,005 | 2,109 |
| Links kept by the check | 376 | 360 | 736 |
| Middle event linked to its root (of 8) | 7 | 7 | 14 of 16 |
| End event linked to its middle or root (of 8) | 6 | 4 | 10 of 16 |
| End event traceable to its root through kept links (of 8) | 5 | 4 | 9 of 16 |
| One-off events given a cause (of 4) | 0 | 0 | 0 of 8 |

The check kept every planted step the proposer found; the misses are all in
proposing. Most kept links are not planted: the background storylines are
full of real consequences. They were not audited one by one.

**What reaches the reader.** Whether the entry at the far end of a chain is
in a 1,200-token context, by entry date:

| Question | Entry looked for | Raw entries | Extra sentences + raw | Links + raw |
| --- | --- | ---: | ---: | ---: |
| "Why did I move my dental check-up?" | the root | 1 of 16 | 2 of 16 | 11 of 16 |
| "What came of the van hitting my wall?" | the end | 0 of 16 | 2 of 16 | 11 of 16 |

"Extra sentences" is a control: the same share of the budget spent on the
single sentences most similar to the question. The far end of a chain shares
no words with the question, so similarity does not find it at any
granularity; following links does.

**Answers** at 1,200 tokens, as answers that reach the far end of the chain /
answers that reach at least the middle, of 16. "Chains" hands the reader the
same links composed into one line per chain (A led to B, which led to C).

| Reader | Context | Why did I…? | What chain of events ended with…? | What came of…? |
| --- | --- | ---: | ---: | ---: |
| GPT-4o-mini | Raw entries | 0 / 1 | 1 / 4 | 0 / 9 |
| GPT-4o-mini | Extra sentences + raw | 0 / 5 | 1 / 8 | 0 / 15 |
| GPT-4o-mini | Links + raw | 3 / 11 | 8 / 10 | 0 / 14 |
| GPT-4o-mini | Chains + raw | 3 / 10 | 9 / 10 | 3 / 14 |
| GPT-4o | Raw entries | 0 / 2 | 1 / 5 | 0 / 9 |
| GPT-4o | Extra sentences + raw | 1 / 8 | 2 / 9 | 1 / 15 |
| GPT-4o | Links + raw | 3 / 11 | 10 / 11 | 7 / 14 |
| GPT-4o | Chains + raw | 6 / 11 | 10 / 11 | 6 / 14 |

At 300 tokens the composed chains matter more: on the chain-of-events
question both readers reached the root 8 times in 16 with chains, against 1
and 3 with separate links and 0 from raw entries. GPT-4o-mini given the
whole journal (51,600 tokens) reached the middle on 5 of 16 "why" questions
and the root on none. Asked why a one-off event happened, both readers said
the journal does not say in 7 or 8 of 8 cases in every arm; the links did
not make them invent reasons.

What this shows:

- **The links carry information retrieval cannot reach.** The root of a
  chain is in context 11 times in 16 with links and once without.
- **The question decides whether it is used.** Asked "why", a reader gives
  the nearest cause and stops, even with the whole chain in front of it; a
  person would too. Links still help there (the nearest cause is itself an
  entry the question does not resemble: 11 of 16, against 1 or 2 from raw
  entries and 5 to 8 with the control). Asked for
  the chain of events, the readers use all of it: 8 to 10 of 16 against 1.
- **The small reader does not join two links itself.** On "what came of"
  it never reached the end event from separate links, and did 3 times from
  composed chains; GPT-4o did 6 or 7 times either way. This is the same
  finding as for patterns: the joining has to be done before the reader.
- **Raw retrieval invents chains.** Asked for a chain of events with only
  similar entries in context, GPT-4o told a confident wrong story in 3 of
  16 answers, tying the event to an unrelated entry.

Limits of this test. Sixteen chains by one author. A grade changes by one or
two per cell when the judge's prompt is edited, so only the large gaps
count. One answer was led astray by a kept link that tied a planted event to
a background storyline (a leak in the flat, the piano under a tarpaulin).
The 700 unplanted links were not audited. And the proposer asks about every
sentence, which costs about 2,900 small-model calls and 1,100 GPT-4o checks
for a 200-entry journal, $1.50 to $2.30. Asking only about one-off events,
and giving the proposer extracted claims instead of six whole entries, are
the two cuts to try.

### Why nodes cost lookups, and the fix (November 18)

On the 200-entry journals, adding nodes took plain lookups ("where did I
book a cabin?") from 7 of 12 to 4 of 12 at 1,200 tokens. Two separate causes
were found, and neither needs a switch to work around.

**Nodes were added whether or not the question was about them.** The three
nodes nearest the question always went in, about 300 tokens, including
"nothing found" nodes about haircuts and the bus. A lookup has no node that
is about it, so those tokens were taken from the entries for nothing.

**The prototype ranked whole entries.** In all 12 lookups the sentence that
holds the answer is the single nearest sentence to the question. The entry
that holds it ranked between 1st and 80th, because one line in a 600-token
entry barely moves the entry's embedding.

The fix has two rules, both about using the smallest unit of evidence:

- An entry ranks by its best sentence. An entry too long for what is left of
  the budget is cut to the hit sentence and its neighbours.
- A node goes in only when more than half of the ten sentences nearest the
  question are that node's own evidence. A node is found through what it was
  built from, not through a fixed allowance or the wording of its summary.

What the node rule selects, with no reader involved, over all 36 lookups and
72 pattern and no-pattern questions of the g, h, w and x sets:

| Rule | Lookups given a node (of 36) | Topic's node picked, where one exists (of 67) |
| --- | ---: | ---: |
| Node's text among the ten nearest items | 1 | 54 |
| Node owns more than half of the ten nearest sentences | 0 | 62 |

Before, every lookup context carried nodes (28 of 28 at 1,200 tokens on the
g, w and x sets), and the topic's node was in 51 of the 56 pattern and
no-pattern contexts; with the ownership rule it is in 48.

Answers on the long journals, g0–g5 (12 lookups):

| Context | GPT-4o-mini, 300 | GPT-4o-mini, 1,200 | GPT-4o, 300 | GPT-4o, 1,200 |
| --- | ---: | ---: | ---: | ---: |
| Whole entries | 4 | 7 | 4 | 7 |
| Three nearest nodes + whole entries (before) | 4 | 4 | 4 | 4 |
| Entries by best sentence | 12 | 12 | 11 | 11 |
| Node by its evidence + entries by best sentence | 12 | 12 | 11 | 11 |

On the short sets all 16 lookups were right in every arm. Pattern and
no-pattern questions together, over g0–g5, w8–w15 and x0–x7 (56):

| Context | GPT-4o-mini, 300 | GPT-4o-mini, 1,200 | GPT-4o, 300 | GPT-4o, 1,200 |
| --- | ---: | ---: | ---: | ---: |
| Whole entries | 16 | 9 | 18 | 12 |
| Three nearest nodes + whole entries (before) | 25 | 28 | 29 | 43 |
| Entries by best sentence | 11 | 7 | 18 | 16 |
| Node by its evidence + entries by best sentence | 22 | 26 | 34 | 41 |

The lookups are repaired and the pattern questions hold. The small
difference at 1,200 tokens (41 against 43, 26 against 28) was traced
question by question for GPT-4o. With the topic's own node in context the
reader does the same either way (no-pattern 24 of 26 before, 22 of 24
after; pattern 17 of 25 and 17 of 24). Two no-pattern answers that were
right before had no node of their topic in context at all: unrelated
"nothing found" nodes had nudged the reader into saying that nothing
explains it, which is credit the old arm should not have had. The other two
are film and purchases, the topics whose outcome arrives in a later entry:
gathering had split each into two nodes, so neither half owned most of the
nearest sentences. That is the known gathering gap, not a selection one.

**The daemon already avoids most of the first cause.** It indexes a long
message as 1,200-byte chunks, which the prototype's whole-entry arm did not
model. The six long journals were ingested into the daemon as built
(LatticeDB backend, `text-embedding-3-small`, no extraction) and
`memory.retrieve` was called for the 12 lookups: the answer was in the
returned prompt 11 times at 1,200 tokens and 8 times at 300, against 7 and 4
for whole entries and 12 and 12 for sentence ranking. The one miss at 1,200
is a single sentence in a 3,000-character entry whose chunk does not rank.
Sentence-level keys would recover it and the 300-token cases; that is the
user-proposed "embed the text a fact came from" applied to raw retrieval.

So in the daemon the rule that matters is the second one: choose a node by
following the evidence links upward from the retrieved leaves, and include
it only when it owns most of them. That makes derived nodes free for
questions they are not about, and no option is needed to turn them off.

### Limits

- The benchmark and the pipeline have the same author, and every planted
  regularity has one shape: one circumstance goes with one outcome. Totals,
  trends and changed preferences are not covered. No outside benchmark and no
  other memory system has been run.
- Ten occasions with one exception sits at the significance cut. One
  occasion the small model cannot read loses a real pattern; one coincidence
  among four candidates makes a false one.
- A topic whose outcome is reported in a later entry (a purchase and the
  regret a few days on, a roll of film and its scans) is still mostly
  missed: seed trays on h8–h15 and w8–w15, film on x0–x7. Linking any two
  sentences above a threshold chains unrelated days together in a long
  journal. Average-link grouping does not, and held on a fresh set, but it
  has not been run end to end on the 200-entry journals.
- The benchmark's own journals contain regularities nobody planted (5 of
  104 topics). The generator does not yet reject them.
- Choosing a node through its evidence fixed the lookups it used to cost,
  but the rule was chosen on sets already seen, and it misses topics that
  gathering splits in two (outcomes reported in a later entry).
- One step needs GPT-4o. Sixteen questions per set is a small sample; the
  pooled difference at 1,200 tokens (22 of 32 against 8 of 32) is not.

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

Iterations 3 and 4 came after that total and cost about $7.40 more: $2.33 for
iteration 3, about $1.60 for the iteration 4 prototype runs, and $3.43 for
the iteration 4 daemon runs ($2.17 on the two every-claim arms, $0.17 on the
held-out control, $0.04 on the replaced-facts reruns, $1.04 on the two
knowledge-update samples). Calls cut off when the laptop slept may have been billed
without being recorded, so the true figure is slightly higher.

Iteration 5 cost about $6.30: $1.45 on the GPT-4o-mini temporal runs, $2.19
on the GPT-4o control and `timeAnchors` runs, and $2.66 on the three
background-jobs runs with GPT-4o ($0.77, $1.58 and $0.31; extraction and
consolidation are about $0.016 per question, the GPT-4o reader about $0.014).

Iteration 6 cost about $1.00 ($0.67 and $0.33 for the two date-resolution
runs).

Iteration 7 cost about $20 by a running tally, all on prototype runs: about
$1.60 on the first graph prototypes over LongMemEval claims and the rest on
the pattern benchmark. For one 80-entry journal, gathering costs nothing
beyond embeddings and the analysis about $0.10; for one 200-entry journal of
50,000 tokens the analysis costs about $0.25. Updating the counts of existing
generalisations when new entries arrive cost about $0.01 per journal.

The November 18 work cost about $16 by the same kind of tally: about $4 on
the varied-wording sets and the chunking comparison, $2.50 on a link run
over model-written chains that was stopped at its cap, $2.00 on the fresh
pattern set end to end, and $7.60 on the two hand-written cause-and-effect
journals ($3.90 building links, $3.70 on answers and grading).

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
- Consolidation finds few updates: 118 from 2,830 proposed pairs over 188
  question histories, mostly numbers and times. Changed names, places and
  preferences with reworded sentences are missed. Each missed update is a
  knowledge-update question the facts section cannot help.
- Extracted claims are not yet useful to the reader on their own. Listing
  them did not help on held-out questions. Relative dates are now resolved
  (iteration 6) and repeats turned out to be rare (about 1%), so neither
  explains it. What is missing is anything built above the claims: nodes that
  connect related claims and say how they relate. Iteration 7 prototyped
  this outside the daemon and it held on unseen journals, including a set
  written by hand after the pipeline was frozen. Before porting: check it on
  a benchmark we did not write; run average-link grouping end to end on the
  long journals and stop compound claims passing on one test; make the
  benchmark generator reject journals with unplanted regularities; decide
  when a node with no finding gets
  new generalisations proposed, given that keeping the early ones and
  updating counts found as many patterns as rebuilding with fewer false
  ones; and decide what a node stores (the generalisations, each occasion's
  two answers, the links to what followed) so that forgetting an entry
  recomputes the findings built on it.
- Cause-and-effect links reach evidence that similarity retrieval does not
  (the root of a chain in context 11 times in 16 against once), but building
  them asks a question of every sentence. Cut the cost (one-off events only,
  extracted claims as the window), audit the unplanted links, and test on
  chains longer than three events before porting.
- Extraction alone shifts raw retrieval slightly, which `docs/algorithms.md`
  says it should not with `factKeys` off. On the dev and held-out runs that
  moved 3 answers in 266 rows (1 better, 2 worse). Find the cause: shared
  BM25 statistics and the shared vector index are the suspects.
- Temporal reasoning with a GPT-4o reader is 77.4% at 4K, 8 points under the
  best published GPT-4o result. Most remaining errors have every gold turn in
  context. A dated timeline section written by the background jobs is the
  next thing to test, and it has to help GPT-4o-mini too: today the jobs help
  GPT-4o on temporal questions and cost GPT-4o-mini answers.
- The facts arm has been run on the whole knowledge-update category only. It
  has not been run on all 500 questions or with a stronger reader, and 11 of
  the 78 knowledge-update questions are still wrong at 4K.
