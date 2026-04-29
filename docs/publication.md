# Publication Gate

Quipu benchmark claims must be generated from reports marked `publishable`.
Synthetic and external smoke reports are development checks only.

## Real Benchmark Ready

A report is real benchmark ready only when all readiness checks pass:

- external dataset adapter;
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

## Current Status

LoCoMo has the first external smoke fixture at
`evals/suites/external/locomo_mini.yaml`. The harness can also normalize the
real upstream `locomo10.json` file and run it through the core runner with trace
artifacts. A full report still remains blocked on configured LatticeDB runs,
provider-backed answer/judge scoring, and the required baseline/ablation set.

LongMemEval and MemoryAgentBench remain planned adapters.
