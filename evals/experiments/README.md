# Controlled memory experiments

The protocol and all four experiments are in
[`docs/memory-experiments.md`](../../docs/memory-experiments.md).
The first implementation is `quipu_evals.representation_experiment` (E1).
It runs independently of LatticeDB and the deterministic fixture baseline
registry so representation quality can be investigated before runtime changes.

## Offline harness check

```bash
just experiment-e1-test
just experiment-e1-smoke
```

The smoke command uses entirely fictional conversations and explicitly
handwritten assertions. It does not call a model or report answer accuracy.
The assertion fixture deliberately omits one causal detail, demonstrating
that an event-level evidence hit does not establish answer sufficiency.
Its context limit uses UTF-8 bytes, suitable only for checking the harness.

Outputs are ignored local files in `artifacts/experiments/e1-smoke/`:
`report.json` contains settings, input/code/prompt hashes, projections, selected
contexts, dropped passages, independent evidence metrics, and errors;
`report.md` is the readable overview.

## Provider pilot

Install the optional tokenizer dependency in a virtual environment:

```bash
python3 -m venv artifacts/experiments/venv
artifacts/experiments/venv/bin/pip install -e './evals[experiments]'
```

With `OPENROUTER_API_KEY` configured, run the five-question fictional suite:

```bash
TIKTOKEN_CACHE_DIR=artifacts/experiments/tokenizer-cache \
PYTHONPATH=evals/src artifacts/experiments/venv/bin/python \
  -m quipu_evals.representation_experiment \
  evals/suites/experiments/representation_smoke.json \
  --provider openrouter --retrieval hybrid --answer \
  --extraction-model openai/gpt-4o-mini \
  --answer-model openai/gpt-4o-mini --judge-model openai/gpt-4o \
  --embedding-model openai/text-embedding-3-small \
  --tokenizer o200k_base --budget 256 \
  --output-dir artifacts/experiments/e1-provider-pilot
```

This sends fixture source text to the configured provider and incurs usage.
The first tokenizer load can download encoding data. Other provider IDs are
supported by the existing eval client; explicitly supply their model IDs and
the tokenizer matching the reader. Hybrid mode requires an embedding endpoint.

Unlike the offline command, this command extracts assertions from source
messages with no reference answers or evidence labels. It freezes provider
responses under `artifacts/experiments/provider-cache/`, including the full
request identity and raw provider usage. Repeating the same inputs reuses those
responses. Change `--cache-dir` for an independent stochastic repeat.

Each query runs against raw passages, assertions, and their union, plus a
separately labeled budgeted oracle-source diagnostic. Hybrid retrieval combines
BM25 and cosine rankings by reciprocal rank fusion with constant 60. Ties use
passage ID. Speaker/timestamp/source wrappers count against the reader budget.
Full passages that do not fit are skipped and logged, never silently truncated.
Raw messages use fixed non-overlapping 1,200-character chunks by default.
The same reader and grader run in all arms; only the grader sees references.

Provider caches retain model responses and thus may contain source-derived
text. Keep these artifacts local. API keys are not written to artifacts.
Cached usage describes the original request, not new billed tokens; use the
`cached` field when accounting for a run. Dollar cost remains unknown unless
available in raw provider usage. Retrieval timings include embedding lookups;
individual provider call timings are reported separately by stage.

## Limits before public benchmark runs

- All outputs are explicitly non-publishable pilots. The current JSON grader
  is a strict, versioned pilot grader, not the official LongMemEval grader.
- The runner accepts normalized Quipu suites. Keep source benchmark variant,
  dataset revision, and split in suite metadata. Oracle data is not an S/M run.
- Source-event recall and all-events coverage are provenance metrics. Semantic
  assertion recall, hallucinations, and context sufficiency need span labels or
  human review; they are not inferred from those provenance scores.
- Oracle source context is still chunked and budgeted. It may drop evidence;
  this is not an unlimited oracle ceiling. On abstention questions its context
  is empty, making that diagnostic easier than realistic abstention.
- Model/transport errors remain explicit. Extraction failure marks assertion
  and combined arms for that scenario failed; raw/oracle can still run.
- Multi-message assertions currently cite one message. Chunk size, fusion
  candidates, duplicate context, and quote adequacy need development-slice
  evaluation before freezing a public run.
- No ontology, temporal conflict resolution, summaries, or forgetting is
  implemented here. Suites with forgetting operations are rejected.
- Per-category results and raw usage are available. Official grading, paired
  confidence intervals, semantic sufficiency labels, and complete amortized
  cost reporting remain the gate for the held-out E1 study.

Keep model cache directories separate for independent repeats and preserve the
original pilot directory when changing budget or model settings.
