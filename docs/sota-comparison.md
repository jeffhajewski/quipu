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

## Latency, tokens and cost

What each source reports. Every figure is measured by a different party on
its own machines, so read the column for order of magnitude.

| System | Context given to the reader | Model calls per question | Time to answer | Cost | Source of the figures |
| --- | --- | --- | --- | --- | --- |
| Quipu, 1,024 budget | about 980 tokens (1,330 with prompt and question) | 1 | median 1.05 s, p95 1.5 s | background jobs about $0.03 per history (GPT-4o-mini); reader $0.004 per question | this repository's runs |
| Quipu, 4,096 budget | about 3,800 tokens (4,130) | 1 | median 1.1 s, p95 1.6 to 1.9 s | reader $0.011 per question | same |
| Zep | 1,600 tokens | not stated | 2.58 s | not reported | Zep's paper |
| Mastra Observational Memory | about 30,000 tokens | not stated | 4.12 s | $0.365 per session; 188 s to ingest an example | time and cost from Redis's rerun |
| Emergence Simple | whole sessions | not stated; the prompt asks for a chain of thought | 7.12 s median | $0.249 per session (Redis's rerun of its fast variant) | Emergence's post |
| Chronos Low | 15 reranked turns with a neighbour each side, then whatever its searches return | 1 to write guidance, then an agent loop of unstated length | not reported | not reported | the paper |
| Redis Remis + Instruct | not reported | not stated | 1.78 s | $0.070 per session; 248 s to ingest an example | Redis's report |
| Full context | about 115,000 tokens | 1 | 28.9 s (Zep's run), 10.4 s (Emergence's) | not reported | Zep's paper, Emergence's post |

About Quipu's row:

- The time is `memory.answer` end to end with GPT-4o, over the 190 reader
  calls of two runs that were not served from the cache. All but about 20
  milliseconds of it (p95 about 60) is the reader call: retrieval and
  rendering are local.
- It flatters Quipu in two ways. The question's embedding came from the
  cache, so one embedding call is missing from the time, and each question
  has its own store of about 500 messages, which is small.
- The background jobs' time has not been measured: their model calls came
  from the cache in these runs. Ingest without them took 2 to 4 seconds per
  history, also with cached embeddings.
- Redis's cost per session counts answer tokens only, at list price, for
  about five questions per session; it is not comparable to a cost per
  history.

No source reports tokens per question for Mastra's reader beyond the
average context, and Chronos reports neither time, tokens nor cost.

## How Chronos gets its number

Chronos (PwC, [arXiv 2603.16862](https://arxiv.org/html/2603.16862v1)) has
the highest GPT-4o result found, and the largest lead over Quipu is on
multi-session questions (91.7% against 69.2%).

What it stores:

- **Events with a range of dates.** A model extracts subject-verb-object
  events, each with a first and last moment it could have happened, so
  "last month" becomes a window. Quipu does the same (`eventStart`,
  `eventEnd`).
- **Two to four rewordings of each event**, so a search for "fitness
  tracker" finds "bought a Fitbit".
- **Two indexes**, one of events and one of raw turns. No graph, no
  summaries, no topics.

How it answers:

1. One model call reads the question and writes one to five lines of
   guidance on what to look for, which go into the reader's instructions.
2. The 100 nearest turns are reranked by a cross-encoder to 15, each shown
   with the turn before and after, grouped by session under a date.
3. The reader is an agent. It can search turns or events by meaning, or
   grep either by text, as many times as it chooses, before it answers.

What its own ablation says (a 116-question sample, GPT-4o reader, baseline
93.1%):

| Removed | Accuracy | Change |
| --- | ---: | ---: |
| The events index | 58.6% | −34.5 |
| The first retrieval, leaving the agent to search from nothing | 76.7% | −16.4 |
| Search by meaning, leaving grep | 77.6% | −15.5 |
| The question-specific guidance | 78.4% | −14.7 |
| The date filter | 78.4% | −14.7 |
| Grep, leaving search by meaning | 80.2% | −12.9 |
| The reranker | 81.0% | −12.1 |

- The guidance matters most for preference questions (85.7% to 42.9%
  without it) and temporal ones (96.8% to 67.7%).
- With a stronger reader (Claude Opus 4.6) most of these removals cost 0 to
  3 points. Much of the machinery makes up for GPT-4o.
- The authors name counting and abstention as GPT-4o's remaining errors.

What Quipu does not do that Chronos does:

- **Its reader cannot look again.** Quipu's reader gets one context and
  answers in one call. A counting question needs every instance, and an
  agent that can grep for "bought" finds the ones a single retrieval
  missed. This is the likeliest source of the multi-session gap, and it is
  work done while the question waits, which is the cost Chronos does not
  report.
- **Its instructions do not change with the question.** One fixed prompt
  serves every question.
- **It stores no rewordings** of a fact for search.

What follows for Quipu, in the order of how well it fits a system whose
work is done before the question arrives:

1. Have the background jobs list a topic's distinct items and amounts, so a
   count can be read off instead of searched for.
2. Test question-specific guidance: it is one small call, and Chronos's
   own numbers credit it with most of the preference and temporal gain.
3. Measure Quipu the way it is meant to be used: an agent holding
   `memory.search` and `memory.retrieve` as tools, free to call them again.
   That is the like-for-like of Chronos's reader, and it needs no change to
   the daemon.

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
- **Latency on a large store with nothing cached**, and the time the
  background jobs take. See the table above for what is known.
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

Fetched November 22, 2026. The Mastra, Chronos and Emergence rows and
Redis's table were read on the pages directly; the rest come from a survey
of the primary pages.

- LongMemEval: <https://arxiv.org/html/2410.10813v2>
- Zep and the full-context baseline: <https://arxiv.org/html/2501.13956>
- Mastra Observational Memory:
  <https://mastra.ai/research/observational-memory>
- Redis's reproductions:
  <https://redis.io/resources/agent-memory-benchmark-report> (its
  full table has two rows that repeat one number in every column; they are
  not used here)
- Emergence: <https://emergence.ai/blog/sota-on-longmemeval-with-rag>
- Chronos: <https://arxiv.org/html/2603.16862v1>
- LightMem (and its GPT-4o-mini baselines):
  <https://arxiv.org/html/2510.18866v4>
- MemOS: <https://github.com/MemTensor/MemOS>
- Honcho (the Gemini 3 Pro full-context baseline):
  <https://plasticlabs.ai/blog/research/Benchmarking-Honcho>
