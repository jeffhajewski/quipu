# Evals

The eval harness starts with the shared scenario schema in `evals/suites/quipu_synthetic.yaml`. The current suite file is JSON-compatible YAML so the scaffold can load it with Python's standard library before external YAML dependencies are introduced.

Run the smoke baseline with:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.runner evals/suites/quipu_synthetic.yaml
```

The Q0 fake baseline stores raw scenario events in memory, retrieves by scope-filtered lexical overlap, and grades exact answers, expected evidence IDs, forbidden evidence, scope leakage, and deletion leakage. It exists to keep eval fixtures executable before the daemon storage implementation is complete.
