# Where Quipu stands against published memory systems

As of November 22, 2026. This page answers one question: with the same
reader model, is Quipu better than, level with, or behind the memory systems
that publish LongMemEval results, and where? The iteration-by-iteration
record is in [sota-sprint-results.md](sota-sprint-results.md).

## Verdict

- **Nothing here is proven better than the state of the art.** Quipu has no
  result on all 500 questions. Two of the six question types have been run
  whole; the other four rest on samples of 19 to 26 questions.
- **One result is level with the best published GPT-4o systems:** temporal
  reasoning, 88.7% on all 133 questions with 4,096 tokens of context. That
  is above the one independently reproduced GPT-4o result (Mastra, 85.7%
  with about 30,000 tokens) and just under the highest self-reported one
  (Chronos, 90.2%). It was tuned on this category, so it is not a blind
  number.
- **Quipu is behind on multi-session questions, and that is where the
  points are.** 69% on a sample of 26, against 80% to 92% published. The
  type is 133 of the 500 questions. Knowledge update is the second gap.

## Same reader, by question type

Reader GPT-4o (`gpt-4o-2024-08-06`), LongMemEval-S, judged with the
benchmark's prompts by GPT-4o. Quipu's numbers are `correct / questions
run`; the last column is how many questions the benchmark has of that type.

| Question type | Quipu, 1,024 tokens | Quipu, 4,096 tokens | Zep | Mastra OM | Emergence Simple | Chronos Low | Full context | In benchmark |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Temporal reasoning | 113/133 (85.0%) | **118/133 (88.7%)** | 62.4% | 85.7% | 81.2% | 90.2% | 45.1% | 133 |
| Multi-session | 17/26 (65.4%) | 18/26 (69.2%) | 57.9% | 79.7% | 73.7% | 91.7% | 44.3% | 133 |
| Knowledge update | 18/23 (78.3%) | 18/23 (78.3%) | 83.3% | 85.9% | 79.5% | 96.2% | 78.2% | 78 |
| Single-session user | 22/22 (100%) | 22/22 (100%) | 92.9% | 98.6% | 95.7% | 94.3% | 81.4% | 70 |
| Single-session assistant | 16/19 (84.2%) | 18/19 (94.7%) | 80.4% | 82.1% | 100% | 100% | 94.6% | 56 |
| Single-session preference | 13/19 (68.4%) | 14/19 (73.7%) | 56.7% | 73.3% | 70.0% | 80.0% | 20.0% | 30 |
| **All 500** | not run (est. 80%) | not run (est. 83%) | 71.2% | 84.8% | 82.4% | 92.6% | 60.2% | 500 |
| Context given to the reader | about 980 tokens | about 3,800 tokens | 1,600 tokens | about 30,000 tokens | whole sessions | 15 turns and their neighbours, plus search tools | 115,000 tokens | |

How to read the Quipu columns:

- Only the temporal row is a measurement of the whole type. The 95%
  intervals on the samples are wide: multi-session 50% to 83%, knowledge
  update 58% to 90%, preference 51% to 88%, single-session assistant 75% to
  99% (all at 4,096 tokens). The temporal interval is 82% to 93%.
- The "All 500" estimates weight each type's sample accuracy by the type's
  size. They are not results and must not be quoted as one.
- The runs are from the build before sessions were joined and same-time
  facts were ordered (`it29-named4`). The GPT-4o reader has not been run on
  the current build beyond the temporal tuning half, where it scored the
  same.

The other systems:

- **Mastra Observational Memory** is the only GPT-4o row that someone else
  has reproduced (Redis measured 84.2 against a reported 84.23). Its
  overall is 84.8% weighted by question; Mastra prints 84.23% as the mean
  of the six types.
- **Chronos** (PwC, a preprint) is the highest GPT-4o result found. It does
  not name its judge model or its data version, its reader is an agent that
  can search again, and nobody has reproduced it.
- **Zep** and the full-context baseline are from Zep's paper. **Emergence
  Simple** is the configuration Emergence published; its higher "Internal"
  number (86.0%) does not state its reader and cannot be reproduced.
- Every row is self-reported except Mastra's. An independent rerun of
  several vendors by Redis moved published figures by +3 to −28 points.

## Where Quipu is ahead, level, or behind

Differences are against the reproduced system (Mastra) and against the best
self-reported one (Chronos), at 4,096 tokens, and are turned into questions
out of 500 so the types can be compared.

| Question type | vs Mastra | vs Chronos | Questions at stake | How sure |
| --- | ---: | ---: | ---: | --- |
| Multi-session | −10 points | −22 points | 14 to 30 | Sample of 26; behind even at the top of the interval against Chronos |
| Knowledge update | −8 | −18 | 6 to 14 | Sample of 23; the whole type was last run five iterations ago, with the smaller reader only (85.9%) |
| Single-session preference | level | −6 | 0 to 2 | Sample of 19 |
| Temporal reasoning | +3 | −2 | level | Whole type, but tuned on |
| Single-session assistant | +13 | −5 | level | Sample of 19 |
| Single-session user | +1 | +6 | level | Sample of 22 |

- **Level or ahead with far less context.** On temporal reasoning Quipu
  with about 980 tokens (85.0%) matches Mastra with about 30,000 (85.7%),
  and is 23 points above Zep at 1,600 tokens. This is the nearest thing to
  a result that is better than the published state: accuracy per token of
  context. It is one type, and it was tuned on.
- **Behind on combining sessions.** The multi-session misses are counts and
  sums across sessions ("how many albums have I bought", "how much did I
  raise in total"). In 7 of the 8 misses a fact from every gold turn was in
  the context; the reader miscounted, had to work out for itself that three
  mentions were one purchase, or lacked a detail extraction had dropped.
  Nothing the background jobs build today lists distinct items or totals.
- **Behind on knowledge update with this reader, as far as a sample of 23
  shows.** All five misses had a fact from every gold turn in context.

## With the smaller reader

Reader GPT-4o-mini. No published system has a clearly documented result
above about 78% with this reader.

| | Temporal reasoning | All 500 |
| --- | ---: | ---: |
| Quipu, 4,096 tokens | 109/133 (82.0%) | not run (est. 78%) |
| Quipu, 1,024 tokens | 103/133 (77.4%) | not run (est. 74%) |
| MemOS (answer model not named; temporal figure quoted by other papers) | 77.4% | 77.8% |
| LightMem | 67.2% | 68.6% |
| Zep | 54.1% | 63.8% |
| Full context | 36.5% | 55.4% |

The temporal figure is the highest found for this reader, with the same
caveat as above. The overall figures are estimates.

## What has not been measured

- **All 500 questions on one frozen build.** 258 questions have not been
  run on any build of the last five iterations, and 203 of them have never
  been run with the background jobs at all.
- **A current reader.** Every published result above 90% uses a reader
  newer than GPT-4o (GPT-5-class, Gemini 3, Claude 4.5 and later), and the
  reader is most of the gain: Mastra goes from 84.2% to 94.9% by changing
  only the reader, and Gemini 3 Pro with the whole history and no memory
  system scores 92.0% (as Honcho reports it). Quipu's last run with a stronger reader predates the
  background jobs.
- **LoCoMo with the background jobs.** The only LoCoMo run is of the
  October default configuration.
- **Latency and cost per question** under the conditions the others report.
  What is known: the background jobs cost about $0.03 of GPT-4o-mini per
  115,000-token history (extraction, consolidation, summaries, patterns).
- **Whether "evidence in context" means what it says.** The harness counts
  a gold turn as present when any fact extracted from it is shown, even if
  the detail the question needs was dropped.

## What to do next, in order

1. Run all 500 questions with GPT-4o on the current build, so the table
   above has one real row. About $20 at the cost of the last runs, most of
   it the background jobs on the 258 histories not yet processed.
2. Build what multi-session questions need: per-topic lists of distinct
   items and amounts, with repeated mentions merged, written by the
   background jobs. This is the largest gap and it is squarely the kind of
   work the jobs exist for.
3. Rerun the whole knowledge-update type with GPT-4o to learn whether the
   gap in the sample is real.
4. Run the frozen build once with a current reader, to stand beside the
   2026 results.

## Sources

Fetched November 22, 2026. The Mastra and Chronos rows were read on the
pages directly; the rest come from a survey of the primary pages.

- LongMemEval: <https://arxiv.org/html/2410.10813v2>
- Zep and the full-context baseline: <https://arxiv.org/html/2501.13956>
- Mastra Observational Memory:
  <https://mastra.ai/research/observational-memory>
- Redis's reproductions:
  <https://redis.io/resources/agent-memory-benchmark-report>
- Emergence: <https://emergence.ai/blog/sota-on-longmemeval-with-rag>
- Chronos: <https://arxiv.org/html/2603.16862v1>
- LightMem (and its GPT-4o-mini baselines):
  <https://arxiv.org/html/2510.18866v4>
- MemOS: <https://github.com/MemTensor/MemOS>
- Honcho (the Gemini 3 Pro full-context baseline):
  <https://plasticlabs.ai/blog/research/Benchmarking-Honcho>
