# Publication Gate

Quipu benchmark claims must be generated from reports marked `publishable`.
Synthetic and external smoke reports are development checks only.

## Real Benchmark Ready

A report is real benchmark ready only when all readiness checks pass:

- external dataset adapter;
- full external dataset, not a smoke fixture or limited slice;
- replay into the Quipu daemon;
- LatticeDB-backed storage;
- retrieval traces;
- answer generation;
- grading;
- required baselines;
- Quipu ablations;
- verification pass;
- reproducible report and manifests.

The benchmark collector writes this gate into `benchmarkReadiness`. Missing
items block publication.

Reports may include `publishedComparisons` from Mem0, Zep, Letta, Memobase,
Memvid, or paper baselines. Treat those as external reference points only until
Quipu has a `publishable` report with the same dataset slice, model setup,
judge, and retrieval budget.

## Current Status

LoCoMo has the first external smoke fixture at
`evals/suites/external/locomo_mini.yaml`. The harness can also normalize the
real upstream `locomo10.json` file and run it through the core runner with trace
artifacts. Required deterministic baselines and Q0-Q13/full Quipu ablations can
now be emitted as run artifacts and manifests.

A local full LoCoMo report has passed the readiness gate with LatticeDB `0.6.0`
storage, retrieval traces, baselines, ablations, deterministic answer/grading,
verification, and manifests. Its scores are not directly comparable to
published vendor runs until the answer model, judge, retrieval cutoff, dataset
slice, and category set are aligned.

LongMemEval and MemoryAgentBench remain planned adapters.
