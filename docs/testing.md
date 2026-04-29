# Testing

See [../SPEC.md](../SPEC.md).

Current checks:

```bash
python3 scripts/check_format.py --check
python3 scripts/run_tests.py
PYTHONPATH=evals/src python3 -m quipu_evals.core_runner --strict
```

Eval runners can also write artifacts:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.core_runner \
  --strict \
  --output artifacts/evals/core-results.json \
  --manifest artifacts/evals/core-manifest.json
```

Synthetic benchmark report:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks \
  --include-lattice \
  --markdown docs/benchmark-results.md
```

External smoke:

```bash
just benchmark-locomo-smoke
```

This writes ignored artifacts under `artifacts/benchmarks/locomo-smoke/` and
keeps the report marked `external_smoke`, not `publishable`.

Real LoCoMo adapter smoke against one conversation and five questions:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks \
  /path/to/locomo10.json \
  --external-benchmark locomo \
  --locomo-max-conversations 1 \
  --locomo-max-questions 5 \
  --allow-failures
```

Optional LatticeDB-backed eval smoke:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.core_runner \
  --storage lattice \
  --lattice-include "$LATTICE_INCLUDE" \
  --lattice-lib "$LATTICE_LIB_DIR" \
  --strict
```

Set `LATTICE_INCLUDE` and `LATTICE_LIB_DIR` or `LATTICE_LIB_PATH` to enable the
optional Lattice synthetic eval and vector-search tests in
`evals/tests/test_synthetic.py`. Use LatticeDB `0.6.0` or newer; the Lattice
adapter depends on the native stream APIs introduced in that C ABI.
