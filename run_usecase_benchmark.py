#!/usr/bin/env python3
"""
Runner for the use case (in-database model selection, usecase_benchmark figure).

Runs the use-case types through benchmark.py's own blob loop, so they are measured
exactly like the main suite: same server settings, CPU fence, warmups, untimed
verification run, conditions records and provenance.

    python3 generate_usecase_benchmarks.py         # writes benchmarks/benchmark_usecase_*.sql
    python3 run_usecase_benchmark.py               # the paper's run: both types, -r 20
    python3 run_usecase_benchmark.py --blob 1 -r 1 # smoke

Results go to results/usecase_<stamp>/, logs to bench_logs/usecase_<stamp>/.
"""

from __future__ import annotations

import argparse
import time

import benchmark as B


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Run the use-case benchmarks in fresh clusters. The defaults are the paper's run.")
    B.add_run_args(ap, B.USECASE_TYPES, B.USECASE_TYPES)
    args = ap.parse_args()
    cfg = B.make_cfg(args)
    B.run_types(cfg, args, time.strftime("usecase_%Y%m%d_%H%M%S"), tag="usecase")


if __name__ == "__main__":
    main()
