# Quipu Evals

Benchmark harness for Quipu memory.

## Current Suites

- `evals/suites/quipu_synthetic.yaml`: temporal truth, cross-scope leakage,
  evidence faithfulness, preference updates, and forgetting leakage.

## Run

Raw-only fake baseline:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.runner \
  evals/suites/quipu_synthetic.yaml \
  --output artifacts/evals/q0-results.json \
  --manifest artifacts/evals/q0-manifest.json
```

Core runtime baseline:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.core_runner \
  evals/suites/quipu_synthetic.yaml \
  --strict \
  --output artifacts/evals/core-results.json \
  --manifest artifacts/evals/core-manifest.json
```

Lattice-backed core baseline:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.core_runner \
  evals/suites/quipu_synthetic.yaml \
  --storage lattice \
  --lattice-include /path/to/latticedb/include \
  --lattice-lib /path/to/latticedb/lib \
  --strict \
  --output artifacts/evals/lattice-results.json \
  --manifest artifacts/evals/lattice-manifest.json
```

The manifest is a compact, machine-readable summary with suite identity,
baseline, pass/fail status, metrics, and result artifact paths. The full result
JSON keeps per-query grades and forgetting checks.

## Planned External Adapters

- LoCoMo
- LongMemEval
- MemoryAgentBench
