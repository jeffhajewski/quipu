set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

fmt:
    python3 scripts/check_format.py --fix

test:
    python3 scripts/run_tests.py

eval-smoke:
    PYTHONPATH=evals/src python3 -m quipu_evals.runner evals/suites/quipu_synthetic.yaml

eval-core-smoke:
    PYTHONPATH=evals/src python3 -m quipu_evals.core_runner evals/suites/quipu_synthetic.yaml --strict

ci:
    python3 scripts/check_format.py --check
    python3 scripts/run_tests.py

spec:
    printf '%s\n' "See SPEC.md"
