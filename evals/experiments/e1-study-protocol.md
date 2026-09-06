# E1 directional study, September 5, 2026

This is a paired, category-balanced LongMemEval-S experiment, not a leaderboard
submission. Selection is frozen by `longmemeval_study prepare` with seed
`quipu-e1-20260905`: two development and six held-out questions in each of seven
categories. Corresponding ordinary/abstention question families cannot cross
the split. Every selected question retains its full source history.

Source: public `xiaowu0162/longmemeval-cleaned/longmemeval_s_cleaned.json`.
The generated suites record its SHA256. Official grading source is upstream
LongMemEval commit `9e0b455f4ef0e2ab8f2e582289761153549043fc`, specifically
`src/evaluation/evaluate_qa.py:get_anscheck_prompt`. The experiment uses that
function unchanged, its yes/no prompt, temperature 0 and max_tokens 10.
The provider route is OpenRouter, with pinned GPT-4o-2024-08-06 judging and
GPT-4o-mini-2024-07-18 extraction/reading. The reader prompt is Quipu's E1
study prompt, not the upstream generation script. The initial pilot reader
was revised on development evidence-only diagnostics to allow personalized
recommendations and combine compatible facts across sessions. The old reader
results are preserved separately and never pooled with the study. Embeddings use
text-embedding-3-small; budgets are 1,024 and 4,096 `o200k_base` tokens.

Primary treatments are raw messages, extracted assertions, and both. Raw
passages are 1,200-character chunks; retrieval uses BM25 plus vector cosine
and reciprocal rank fusion (constant 60). The same wrapper and exact context
budget apply to each treatment. No answer labels guide ingestion, ranking,
or packing. Session IDs are anonymized because upstream IDs can reveal which
sessions contain evidence. Extraction sees only timestamp and source messages.

During development, examine quotation validation and parser failures before
attributing errors to memory representations. A wrong source-message index may
be repaired mechanically only if the exact quote occurs in exactly one source
message. Ambiguous or non-verbatim quotes remain quarantined. The raw provider
response and repair counts remain available. This repairs source coordinates;
it does not certify that the claim is entailed by its quote.

Malformed JSON receives bounded syntax/Unicode retries. Illegal backslash
escapes can be preserved literally before parsing; exact quote validation still
applies. One development episode caused the model to repeat Unicode escapes
until its output limit, and succeeded when the same source was sent with literal
Unicode. All original provider responses remain cached for audit.

An optional development follow-up, `assertion_keys`, searches the same combined
index but expands hits back to original source messages for the reader,
deduplicating raw passage IDs. It tests whether assertions help as retrieval
keys without replacing source evidence. Freeze the held-out arms after reviewing
development results. Do not tune on held-out results or silently pool the splits.

All per-query contexts, answers, official judgments, selected source IDs,
gold-turn coverage, quarantines, usage, and errors remain in ignored artifacts.
Paired differences and question-level bootstrap intervals accompany counts.
Each selected question has its own history; matched abstention families are
excluded to avoid that obvious dependency. Broader shared benchmark backgrounds
can still correlate cases. Balanced-slice accuracy is not the full benchmark's
frequency-weighted accuracy, and bootstrap intervals on this small sample are
descriptive rather than definitive significance claims.

Code can be run with `PYTHONPATH=evals/src` and the existing experiment venv:

```bash
python -m quipu_evals.longmemeval_study prepare --output artifacts/experiments/e1-study-splits
python -m quipu_evals.longmemeval_study extract --suite artifacts/experiments/e1-study-splits/dev.json --output artifacts/experiments/e1-dev-extraction --workers 16
python -m quipu_evals.longmemeval_study evaluate --suite artifacts/experiments/e1-study-splits/dev.json --output artifacts/experiments/e1-dev --workers 4
```

Request and extraction caches make interrupted jobs resumable. Extraction is
batched across independent episodes. The code does not ingest private workspace
conversations; this study sends only public benchmark material to the provider.

## Held-out freeze

Before inspecting any held-out score, freeze these arms: `raw`, `assertions`,
`combined`, and `assertion_keys`, at both 1,024 and 4,096 tokens. Keep the study
reader prompt, extraction prompt, exact-quote grounding policy, models and
retrieval/packing settings unchanged. The dev and held-out caches are separate.
The held-out split has 42 questions and 1,995 sessions. Its ingestion is
query-blind and can run ahead of evaluation. An oracle-turn diagnostic remains
separate from these treatments.

Before opening held-out scores, add one confound control: `raw_message` expands
a raw retrieval hit to all chunks of its source message, without assertion
extraction. Development showed an ordinal-list question benefiting from source
expansion. This control distinguishes assertion-assisted matching from a simpler
context-assembly improvement. It uses the same budgets, reader and grader.
