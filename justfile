set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# SOTA sprint harness (docs/evals.md). Set QUIPU_ARTIFACTS when running from a worktree.
sota_artifacts := env_var_or_default("QUIPU_ARTIFACTS", justfile_directory() + "/artifacts")
sota_python := sota_artifacts + "/experiments/venv/bin/python"
sota_env := "QUIPU_ARTIFACTS=" + sota_artifacts + " TIKTOKEN_CACHE_DIR=" + sota_artifacts + "/experiments/tokenizer-cache PYTHONPATH=evals/src"

fmt:
    python3 scripts/check_format.py --fix

test:
    python3 scripts/run_tests.py

smoke: test eval-smoke benchmark-locomo-smoke

install-smoke:
    bash -n scripts/install.sh

daemon-smoke:
    cd core && zig build
    core/zig-out/bin/quipu --db /tmp/quipu-daemon-smoke.lattice health

sdk-smoke:
    python3 -m unittest discover -s sdk/python/tests
    cd sdk/typescript && npm test

eval-smoke:
    PYTHONPATH=evals/src python3 -m quipu_evals.runner evals/suites/quipu_synthetic.yaml

experiment-e1-smoke:
    PYTHONPATH=evals/src python3 -m quipu_evals.representation_experiment evals/suites/experiments/representation_smoke.json --assertion-fixture evals/fixtures/representation_assertions.json

experiment-e1-test:
    python3 -m unittest discover -s evals/tests -p test_representation_experiment.py

sota-test:
    cd evals/tests && PYTHONPATH=../src python3 -m unittest test_sota_longmemeval test_sota_locomo test_caching_proxy test_core_runner test_longmemeval_study test_study_analysis

# Build core into artifacts/sota/bin/<name>; pass --lattice --lattice-include ... --lattice-lib ... for Lattice.
sota-build name *flags:
    {{sota_env}} python3 -m quipu_evals.sota_longmemeval build --out {{sota_artifacts}}/sota/bin/{{name}} {{flags}}

# Run the daemon built by sota-build on the frozen dev slice (both budgets by default).
sota-run name run_name *flags:
    {{sota_env}} {{sota_python}} -m quipu_evals.sota_longmemeval run --daemon-binary {{sota_artifacts}}/sota/bin/{{name}}/bin/quipu --run-name {{run_name}} {{flags}}

# E1 raw-arm reference (the target the daemon must match) on the same slice.
sota-e1-reference:
    {{sota_env}} python3 -m quipu_evals.longmemeval_study prepare --dataset {{sota_artifacts}}/experiments/upstream/longmemeval_s_cleaned.json --selection evals/experiments/sota-dev-selection.json --output {{sota_artifacts}}/sota/e1-splits
    {{sota_env}} {{sota_python}} -m quipu_evals.longmemeval_study evaluate --suite {{sota_artifacts}}/sota/e1-splits/sota-dev.json --cache {{sota_artifacts}}/sota/cache/study --output {{sota_artifacts}}/sota/e1-raw-reference --arms raw --budgets 1024 4096 --workers 8 --upstream {{sota_artifacts}}/experiments/LongMemEval-upstream/src/evaluation/evaluate_qa.py
    {{sota_env}} {{sota_python}} -m quipu_evals.sota_longmemeval summarize-e1 --report {{sota_artifacts}}/sota/e1-raw-reference/report.json

# LoCoMo through the same daemon harness: pinned locomo10.json + locomo-audit errors.json, sha256-checked.
sota-locomo-download:
    {{sota_env}} python3 -m quipu_evals.sota_locomo download

# Run the daemon built by sota-build on LoCoMo (both budgets, categories 1-5; 5 reported separately).
sota-locomo-run name run_name *flags:
    {{sota_env}} {{sota_python}} -m quipu_evals.sota_locomo run --daemon-binary {{sota_artifacts}}/sota/bin/{{name}}/bin/quipu --run-name {{run_name}} {{flags}}

# Paired comparison, B versus A (each a run report.json or an E1 study report.json).
sota-compare a b out:
    {{sota_env}} {{sota_python}} -m quipu_evals.sota_longmemeval compare --a {{a}} --b {{b}} --output {{out}}

eval-core-smoke:
    PYTHONPATH=evals/src python3 -m quipu_evals.core_runner evals/suites/quipu_synthetic.yaml --strict

benchmark:
    PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks evals/suites/quipu_synthetic.yaml --markdown docs/benchmark-results.md

benchmark-lattice:
    PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks evals/suites/quipu_synthetic.yaml --include-lattice --markdown docs/benchmark-results.md

synthetic-smoke: eval-smoke eval-core-smoke

benchmark-locomo-smoke:
    PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks --external-benchmark locomo --include-baselines --include-ablations --allow-failures --output-dir artifacts/benchmarks/locomo-smoke --report artifacts/benchmarks/locomo-smoke/report.json --markdown artifacts/benchmarks/locomo-smoke/report.md

benchmark-locomo-graph-smoke:
    PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks --external-benchmark locomo --include-baselines --include-ablations --include-lattice --core-retrieval-mode graph --core-entity-provider deterministic --enable-entity-resolution --core-budget-tokens 8192 --allow-failures --output-dir artifacts/benchmarks/locomo-graph-smoke --report artifacts/benchmarks/locomo-graph-smoke/report.json --markdown artifacts/benchmarks/locomo-graph-smoke/report.md

benchmark-locomo-full dataset:
    PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks {{dataset}} --result-class publishable --external-benchmark locomo --include-baselines --include-ablations --include-lattice --require-lattice --core-retrieval-mode graph --core-answer-method answer --core-entity-provider deterministic --enable-entity-resolution --core-budget-tokens 32768 --reuse-existing --allow-failures --markdown artifacts/benchmarks/locomo-full/report.md

# Legacy external-benchmark pipeline (unpinned upstream main). The SOTA harness uses sota-locomo-download.
benchmark-locomo-download:
    PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks --external-benchmark locomo --download-locomo --result-class publishable --include-baselines --include-ablations --include-lattice --require-lattice --core-retrieval-mode graph --core-answer-method answer --core-entity-provider deterministic --enable-entity-resolution --core-budget-tokens 32768 --reuse-existing --allow-failures --markdown artifacts/benchmarks/locomo-full/report.md

benchmark-longmemeval-smoke:
    PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks --external-benchmark longmemeval --include-baselines --include-ablations --enable-entity-resolution --core-budget-tokens 8192 --allow-failures --output-dir artifacts/benchmarks/longmemeval-smoke --report artifacts/benchmarks/longmemeval-smoke/report.json --markdown artifacts/benchmarks/longmemeval-smoke/report.md

benchmark-longmemeval-full dataset:
    PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks {{dataset}} --result-class publishable --external-benchmark longmemeval --include-baselines --include-ablations --include-lattice --require-lattice --core-retrieval-mode graph --core-answer-method answer --core-answer-provider openrouter --core-answer-model openai/gpt-4o --core-entity-provider deterministic --enable-entity-resolution --core-budget-tokens 32768 --reuse-existing --allow-failures --markdown artifacts/benchmarks/longmemeval-full/report.md

benchmark-longmemeval-download:
    PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks --external-benchmark longmemeval --download-longmemeval --longmemeval-variant oracle --result-class publishable --include-baselines --include-ablations --include-lattice --require-lattice --core-retrieval-mode graph --core-answer-method answer --core-answer-provider openrouter --core-answer-model openai/gpt-4o --core-entity-provider deterministic --enable-entity-resolution --core-budget-tokens 32768 --reuse-existing --allow-failures --markdown artifacts/benchmarks/longmemeval-full/report.md

benchmark-synthesis-lab-retrieval:
    PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks evals/suites/external/longmemeval_synthesis_lab.yaml --result-class external_smoke --include-lattice --require-lattice --core-retrieval-mode graph --core-entity-provider deterministic --enable-entity-resolution --core-budget-tokens 32768 --core-page-size 32768 --reuse-existing --allow-failures --output-dir artifacts/benchmarks/synthesis-lab-retrieval --report artifacts/benchmarks/synthesis-lab-retrieval/report.json --markdown artifacts/benchmarks/synthesis-lab-retrieval/report.md

benchmark-synthesis-lab-answer:
    PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks evals/suites/external/longmemeval_synthesis_lab.yaml --result-class external_smoke --include-lattice --require-lattice --core-retrieval-mode graph --core-answer-method answer --core-answer-provider openrouter --core-answer-model openai/gpt-4o --core-answer-abstain-if-weak --core-entity-provider deterministic --enable-entity-resolution --core-budget-tokens 32768 --core-page-size 32768 --reuse-existing --allow-failures --output-dir artifacts/benchmarks/synthesis-lab-answer --report artifacts/benchmarks/synthesis-lab-answer/report.json --markdown artifacts/benchmarks/synthesis-lab-answer/report.md

benchmark-external-all: benchmark-locomo-smoke benchmark-locomo-graph-smoke benchmark-longmemeval-smoke

ci:
    python3 scripts/check_format.py --check
    python3 scripts/run_tests.py

spec:
    printf '%s\n' "See SPEC.md"
