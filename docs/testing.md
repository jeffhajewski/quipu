# Testing

See [../SPEC.md](../SPEC.md).

Current checks:

```bash
python3 scripts/check_format.py --check
python3 scripts/run_tests.py
PYTHONPATH=evals/src python3 -m quipu_evals.core_runner --strict
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
`evals/tests/test_synthetic.py`.
