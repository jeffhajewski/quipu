# Evals

The eval harness starts with the shared scenario schema in `evals/suites/quipu_synthetic.yaml`. The current suite file is JSON-compatible YAML so the scaffold can load it with Python's standard library before external YAML dependencies are introduced.

Run the smoke baseline with:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.runner \
  evals/suites/quipu_synthetic.yaml \
  --output artifacts/evals/q0-results.json \
  --manifest artifacts/evals/q0-manifest.json
```

The Q0 fake baseline stores raw scenario events in memory, retrieves by scope-filtered lexical overlap, and grades exact answers, expected evidence IDs, forbidden evidence, scope leakage, and deletion leakage. It exists to keep eval fixtures executable before the daemon storage implementation is complete.

The in-memory core smoke baseline runs the compiled Zig process through `quipu serve-stdio`:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.core_runner \
  --strict \
  --output artifacts/evals/core-results.json \
  --manifest artifacts/evals/core-manifest.json
```

This baseline is expected to pass current-fact, historical valid-at, cross-scope, preference-update, and deletion-leak checks against the synthetic smoke suite.

The same suite can run against the optional LatticeDB adapter:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.core_runner \
  --storage lattice \
  --lattice-include /path/to/latticedb/include \
  --lattice-lib /path/to/latticedb/lib \
  --strict \
  --output artifacts/evals/lattice-results.json \
  --manifest artifacts/evals/lattice-manifest.json
```

The manifest uses `quipu.eval.run.v1` and records suite identity, runner,
storage backend, baseline, pass/fail status, aggregate metrics, and result
artifact paths.
