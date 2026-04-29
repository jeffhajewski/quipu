# Evals

The eval harness starts with the shared scenario schema in `evals/suites/quipu_synthetic.yaml`. The current suite file is JSON-compatible YAML so the scaffold can load it with Python's standard library before external YAML dependencies are introduced.

Quipu reports three result classes:

- `synthetic_smoke`: small deterministic fixtures for CI and regression checks.
- `external_smoke`: tiny normalized fixtures shaped like external benchmarks.
- `publishable`: full external benchmark runs with LatticeDB storage, baselines,
  ablations, traces, verification, and reproducible manifests.

Only `publishable` reports may be used for external benchmark claims.

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

## Benchmark Report

The benchmark collector runs the fake Q0 baseline and the core runtime baseline,
with optional LatticeDB storage, then writes JSON artifacts and a markdown
summary:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks \
  evals/suites/quipu_synthetic.yaml \
  --include-lattice \
  --lattice-include /path/to/latticedb/include \
  --lattice-lib /path/to/latticedb/lib \
  --markdown docs/benchmark-results.md
```

Use the generated report as a synthetic smoke benchmark only.

## External Smoke

The external benchmark path starts with a normalized scenario format:

- top-level metadata names the source benchmark, dataset version, license,
  fixture format, cache environment variable, and task categories;
- scenarios contain chronological events, messages, scopes, queries, expected
  answers, expected evidence event IDs, forbidden evidence, forget operations,
  and metadata;
- all files remain JSON-compatible YAML so the current dependency-free loader
  can parse them.

LoCoMo has the first smoke fixture:

```bash
PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks \
  --external-benchmark locomo \
  --markdown artifacts/benchmarks/locomo-smoke/report.md
```

`just benchmark-locomo-smoke` runs the same command. It validates replay,
retrieval, grading, forgetting, manifests, and the real-benchmark readiness
gate without requiring external model keys. It is not a LoCoMo score.

Full LoCoMo runs should use `--result-class publishable`, a real dataset path,
LatticeDB enabled, provider configuration, verification status, and generated
trace artifacts. LongMemEval and MemoryAgentBench remain next adapters.
