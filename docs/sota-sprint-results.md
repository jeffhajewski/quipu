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

The sprint's provider spend was about $1.80 in total:

- $0.27 for the E1 reference,
- $1.50 across the daemon harness runs,
- the rest on agent smoke tests.

Embeddings cost about $0.13 per uncached full slice. A GPT-4o-mini reader with
the GPT-4o judge costs about $0.05–0.15 per arm.

## Open items

- Run a top-tier reader on the dev slice, then the frozen configuration on all
  500 questions, and a whole-history baseline with that reader.
- The runtime's `fullTextSearch("", 1000)` enumeration cap still bounds
  supersession, provenance and forget closures. Forget propagation must not
  depend on a 1,000-node cap.
- Ingest still waits about 1 s per `memory.remember` on the embedding
  provider. Getting under the 50 ms write latency SOTA systems report needs
  asynchronous embedding after the write.
- In reasoning mode the reader still cites a few invalid support qids (8 of
  140 rows). Those answers are kept, with `supportValid=false`.
