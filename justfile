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
    PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks --external-benchmark locomo --output-dir artifacts/benchmarks/locomo-smoke --report artifacts/benchmarks/locomo-smoke/report.json --markdown artifacts/benchmarks/locomo-smoke/report.md

benchmark-locomo-full dataset:
    PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks {{dataset}} --result-class publishable --external-benchmark locomo --include-lattice --require-lattice --allow-failures --markdown artifacts/benchmarks/locomo-full/report.md

benchmark-locomo-download:
    PYTHONPATH=evals/src python3 -m quipu_evals.benchmarks --external-benchmark locomo --download-locomo --result-class publishable --include-lattice --require-lattice --allow-failures --markdown artifacts/benchmarks/locomo-full/report.md

benchmark-external-all: benchmark-locomo-smoke

ci:
    python3 scripts/check_format.py --check
    python3 scripts/run_tests.py

spec:
    printf '%s\n' "See SPEC.md"
