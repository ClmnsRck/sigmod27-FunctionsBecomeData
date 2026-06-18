# Reproducing the results

This document maps each experiment in the artifact to the part of the paper it backs,
and gives a fast smoke test for reviewers. Figure and table numbers refer to the
submitted paper's evaluation section (§5); fill in exact numbers as needed.

## Hardware / time expectations

- The full suite was run on the many-core machine described in the paper's evaluation
  section (§5). `benchmark.py` pins CPU affinity using topology constants near the top of
  the file, so edit these for your machine (a mismatched topology will error, not just
  slow down).
- A full run is long, with many repeats over large inputs. Use the smoke test below to
  check that things work, and the full runs to reproduce the reported numbers.
- JIT/LLVM is required, and durability is disabled for stability (see the top-level
  `README.md`).

## Quick smoke test (minutes, no special hardware)

Checks the build, and that the HOL `map` operator and the pure-SQL baseline compute
identical results. This is a correctness check, not a timing run:

```bash
cd additional-tests/equivalence
python3 run_equivalence.py        # 10k tuples x 50 lambdas = 500k rows -> PASS
cd ../..
```

With Docker (builds everything and runs the same check as the default command):

```bash
docker build -t hol-artifact .
docker run --rm hol-artifact
```

## Experiment to paper mapping

| Run | Measures | Output | Backs (paper §5) |
|-----|----------|--------|------------------|
| `python3 benchmark.py --types hol baseline` | HOL map operator vs. pure-SQL baseline throughput, scaling over #lambdas (M) and #data rows (N) | `results/bench_*/` , `bench_logs/bench_*/` | throughput / scaling experiment (§5.1) |
| `python3 benchmark.py --types cores baseline_cores` and `additional-tests/parallel/run_parallelism_benchmark.py` | core-scaling of the evaluation phase | `results/bench_*/`, `additional-tests/parallel/*_agg.csv` | core-scaling experiment (§5.2) |
| `additional-tests/timing/`, `additional-tests/timing_agg/`, `additional-tests/timing_scale_expr/` (`./run_timing_benchmark.sh`) | per-phase timing breakdown (data fetch / injection / JIT / evaluation) and the `map_agg` aggregation-pushdown variant | `*_agg.csv` in each dir | per-phase timing breakdown / aggregation experiment |
| `additional-tests/usecase/run_usecase_benchmark.py` | in-database model-selection use case, data- and model-scaling | `additional-tests/usecase/results/` | use-case experiment (§5.6) |
| `additional-tests/kmeans/run_kmeans_benchmark.py` | k-means use case (`kmeans_v2`) | `additional-tests/kmeans/*.csv` | use-case experiment (§5.6) |
| `additional-tests/equivalence/run_equivalence.py` | HOL vs. pure-SQL result equivalence | stdout (`PASS`/`FAIL`) | correctness of the comparison (supports §5; addresses the reviewers' correctness question) |

## Regenerating the SQL inputs

The contents of `benchmarks/` are generated:

```bash
python3 generate_benchmarks.py
```

## Notes on the CSVs

`benchmark.py` writes one CSV per `(test, type)` under a timestamped
`results/bench_YYYYMMDD_HHMMSS/` folder. The `additional-tests/*/agg-*.py` scripts then
aggregate the raw CSVs into the `*_agg.csv` summries that the paper's plots are built
from.
