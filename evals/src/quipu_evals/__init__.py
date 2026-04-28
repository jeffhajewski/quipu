"""Quipu eval harness."""

from .scenarios import load_suite

__all__ = ["load_suite", "run_scenario", "run_suite"]


def run_scenario(*args, **kwargs):
    from .runner import run_scenario as _run_scenario

    return _run_scenario(*args, **kwargs)


def run_suite(*args, **kwargs):
    from .runner import run_suite as _run_suite

    return _run_suite(*args, **kwargs)
