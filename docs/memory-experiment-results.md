# E1 directional results — September 5, 2026

## Decision

Keep raw evidence directly searchable and available to the reader. Reject
assertion-only retrieval **with this extractor and grounding policy** as Quipu's
default. Test assertions as optional retrieval aids, not as the only accessible
representation of memory. Raw retention in an archive is insufficient if the
answer path cannot retrieve it.

The negative result is substantially stronger than the positive one. Assertion
augmentation has a small promising signal, but this study does not establish
that its quality/cost frontier beats raw retrieval. Do not commit the runtime
to graph construction, predicate histories, or a one-model-call constraint on
the strength of these results.

E1 has a completed directional evaluation. E2 (predicate histories), E3
(resolution), and E4 (summaries) are written up but remain untested. No production
runtime changes were made by this study.

## What actually ran

Public LongMemEval-S: 14 development questions / 683 sessions, followed by 42
held-out questions / 1,995 sessions. Each split is balanced across seven
categories; ordinary/abstention question families cannot cross splits. All
source sessions and distractors remain present. The held-out run completed
420 answer/judgment observations: five treatments × two budgets × 42 questions,
with zero failed cases and zero failed source extractions. Identical requests
reuse cached responses, so observations are not 420 independent model draws.

The [frozen protocol](../evals/experiments/e1-study-protocol.md) specifies the
development changes and held-out freeze. Extraction and reading use pinned
GPT-4o-mini-2024-07-18, embeddings use text-embedding-3-small, and judging uses
GPT-4o-2024-08-06 via OpenRouter. The official LongMemEval answer-check prompt
is loaded unchanged from upstream commit
`9e0b455f4ef0e2ab8f2e582289761153549043fc`. The reader prompt is our own,
revised on development data and then frozen.

Sources: [public cleaned data](https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned)
and [pinned official evaluator](https://github.com/xiaowu0162/LongMemEval/blob/9e0b455f4ef0e2ab8f2e582289761153549043fc/src/evaluation/evaluate_qa.py).

Retrieval is BM25 + vector cosine with reciprocal rank fusion (constant 60).
Raw chunks are 1,200 characters. The fixed context budgets include evidence
wrappers and use the actual `o200k_base` tokenizer. Labels and questions do not
enter extraction; only the query enters ranking. Revealing upstream session
IDs are anonymized. No private workspace conversations are ingested.

## Held-out results

Counts are correct answers out of 42, using the frozen official judge prompt.

| Treatment | 1,024 tokens | 4,096 tokens |
| --- | ---: | ---: |
| Raw evidence | 31 (73.8%) | 29 (69.0%) |
| Assertions only | 18 (42.9%) | 20 (47.6%) |
| Raw + assertions, shared index/context | 31 (73.8%) | 33 (78.6%) |
| Assertion-assisted search → raw evidence | 33 (78.6%) | 32 (76.2%) |
| Raw search → expanded source messages | 29 (69.0%) | 30 (71.4%) |

The assertion-assisted arm searches the combined index but converts assertion
hits into their source-message chunks; raw hits remain individual chunks.
The raw-message control expands every raw hit to its source-message chunks.
Both deduplicate raw IDs and apply the same packer; expansion does not guarantee
the entire message fits. This control does not reproduce all augmentation gains.

Paired comparisons against raw at the **same** budget:

| Treatment / budget | Wins / losses | Accuracy delta | Descriptive bootstrap 95% interval | Exact paired p, unadjusted |
| --- | ---: | ---: | ---: | ---: |
| Assertions / 1,024 | 3 / 16 | −31.0 pp | [−50.0, −14.3] pp | .0044 |
| Assertions / 4,096 | 3 / 12 | −21.4 pp | [−38.1, −4.8] pp | .0352 |
| Combined / 1,024 | 4 / 4 | 0.0 pp | [−14.3, 11.9] pp | 1.000 |
| Combined / 4,096 | 4 / 0 | +9.5 pp | [2.4, 19.0] pp | .125 |
| Assertion keys / 1,024 | 4 / 2 | +4.8 pp | [−7.1, 16.7] pp | .688 |
| Assertion keys / 4,096 | 3 / 0 | +7.1 pp | [0.0, 16.7] pp | .250 |

Four wins and no losses are not decisive evidence of improvement. The percentile
bootstrap can look overconfident with so few discordant cases; the exact
two-sided McNemar test makes that limitation visible. Tests are exploratory,
unadjusted for multiple comparisons, and do not account for shared benchmark
backgrounds. Do not choose a post-hoc winning budget and call it confirmed.
Increasing raw context from 1,024 to 4,096 tokens actually reduced accuracy here.

At 4,096 tokens, category counts out of six are:

| Category | Raw | Assertions | Combined | Assertion keys | Raw expansion |
| --- | ---: | ---: | ---: | ---: | ---: |
| Abstention | 2 | 4 | 3 | 3 | 3 |
| Knowledge update | 6 | 1 | 6 | 6 | 6 |
| Multi-session | 6 | 4 | 6 | 6 | 6 |
| Single-session assistant | 5 | 5 | 5 | 5 | 5 |
| Single-session preference | 1 | 0 | 4 | 3 | 1 |
| Single-session user | 6 | 3 | 6 | 6 | 6 |
| Temporal reasoning | 3 | 3 | 3 | 3 | 3 |

All four combined-arm wins are three preference questions and one abstention
question. There is **no demonstrated temporal-reasoning gain** from augmentation.

## Why assertions lost

The held-out extractor emitted 24,141 candidate claims. After unique verbatim
quote coordinate repair and validation, 20,145 deduplicated claims survived;
3,979 were quarantined and 9,945 citation indices were repaired. The remaining
17-count difference is deduplication. About 16.5% of candidates were rejected.
Quote validity establishes provenance, not semantic entailment.

Even before retrieval, accepted assertions cited only 56.5% of annotated gold
turns on average across answerable questions. At 4,096 tokens, retrieved
assertions covered 51.4%, versus 88.9% for raw. These are message-level coverage
proxies, **not semantic fact recall**; annotations can miss alternative evidence.

Reviewed source/cache failures:

- `ed4ddc30`: extraction retained the old **30 dozen eggs** count but omitted
  the newer **20 dozen** count. The newer source episode had no quarantined
  claims. Assertions answered 30; raw answered 20. A predicate history cannot
  recover an update that never entered it.
- `8ebdbe50`: the source explicitly said the user completed a Data Science
  certification last month. Extraction omitted it, with no quarantines in that
  episode. Assertions could not answer; raw answered correctly.
- `8550ddae`: extraction omitted the user's lavender gin fizz experiment.
  The assertion-only reader substituted a Smokey Mango Mule, confusing another
  cocktail with the one actually tried.
- `e6041065`: assertions preserved wearing two pairs of shoes but omitted
  packing five pairs. The reader could not calculate 40%; raw could.
- Development case `d52b4f67`: the wedding venue was extracted, but its quote
  changed source punctuation and failed exact matching. This is a grounding-gate
  failure, not an inherent limitation of assertion representations.

This is therefore evidence against this **one-pass extraction pipeline as a
replacement**, not proof that every assertion extractor must fail. Better source
span handling, coverage-aware extraction, or another model could change the
result. Exact-quote repair does not fix omissions or unsupported claim semantics.

## Why the augmentation gain remains tentative

I reviewed all four combined-arm wins at 4,096 tokens against their answers and
references. Scores below remain unchanged; this audit is not a replacement judge.

- `2311e44b_abs`: a clear behavioral improvement. Raw produced an irrelevant
  15,200-page reading-goal calculation; combined acknowledged that remaining
  pages in Sapiens were unknown.
- `1c0ddc50`: combined avoided suggesting self-improvement material that the
  preference reference discourages. Both contexts already hit the gold turn.
- `06878be2`: combined emphasized the Sony setup more consistently, but raw
  also named the Sony A7R IV and suggested compatible generic accessories.
  The binary difference is debatable.
- `d24813b1`: both answers suggested lemon poppyseed cake based on prior
  experience, yet raw was judged incorrect and combined correct. This is a
  particularly questionable distinction.

If the last two raw answers were accepted, the apparent +4 becomes +2; that is
a sensitivity check, not a revised score. This makes augmentation a follow-up
candidate, not an architecture mandate. The larger assertion-only failures
include explicit missing facts and wrong numbers, not just preference grading.

## Development results, kept separate

After reader/grounding repairs on development data, counts out of 14 were:

| Treatment | 1,024 tokens | 4,096 tokens |
| --- | ---: | ---: |
| Raw | 8 | 10 |
| Assertions | 3 | 3 |
| Combined | 8 | 12 |
| Assertion keys | 10 | 11 |
| Raw expansion | 7 | 9 |

Earlier reader/oracle diagnostic runs remain in artifacts but are not pooled.
The old-reader gold-turn diagnostic was 10/14 and helped uncover refusal to make
personalized recommendations. It is not a ceiling for the revised study reader.

## Cost, reproducibility, and limits

Recorded provider-response costs across the held-out cache total **$2.02375**:
$1.77740 extraction/reading, $0.08646 embeddings, and $0.15988 grading. Development
and its diagnostics add $0.74868, for **$2.77243** across these two caches.
All cached requests included cost fields. These are observed study costs,
including shared requests/retries and cache reuse, not projected deployment
costs, fresh-run price guarantees, or a per-treatment amortized comparison.
No end-to-end latency or production quality/cost frontier is established.

The tracked [machine-readable scorecard](../evals/experiments/e1-directional-results.json)
contains selected IDs, per-question outcomes, model/prompt identities, input/code
hashes, paired statistics, extraction audits, observed usage, and report hashes.
Full contexts, responses, and raw source data remain ignored local artifacts:

- `artifacts/experiments/e1-heldout-final/report.json`
- `artifacts/experiments/e1-heldout-analysis.json`
- `artifacts/experiments/e1-heldout-cache/`
- `artifacts/experiments/e1-dev-final/report.json`
- `artifacts/experiments/e1-dev-message-control/report.json`
- `artifacts/experiments/e1-study-splits/`

This is a small category-balanced slice, not full LongMemEval-S accuracy or a
SOTA-comparable submission. It uses our reader and an evaluation prototype, not
Quipu's daemon. One model family, one extraction policy, two budgets, and one
cached draw per request do not establish universal representation rankings.
There is no held-out oracle-reader ceiling or exhaustive semantic span audit.
LongMemEval-M, LoCoMo, forgetting, identity resolution, and summaries remain
outside this result.

## Next work, in order

1. Keep raw hybrid retrieval as the control/default. Keep assertion-assisted
   retrieval switchable; replicate its small gain on fresh held-out questions
   with reviewed preference judgments before adopting it by default.
2. Measure extraction coverage and attribution independently of answer quality.
   Fix dropped updates and source-span brittleness before building richer
   structures from the same lossy assertions. These 42 questions are now spent
   evaluation data; any tuned follow-up needs a fresh split.
3. Run E2 as a narrow temporal evidence-grouping experiment **with raw fallback**.
   Separately use source-complete fixtures to distinguish extraction loss from
   history-rendering quality. E1 neither validates nor disproves E2–E4.
4. Build a small source-span-labeled diagnostic suite for omission, proposed
   versus actual events, updates, ordinals, and false premises. It complements
   public benchmarks; it must not replace external validation with an easier score.
