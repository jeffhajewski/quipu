set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

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
