# Functions Become Data — Artifact

Artifact of the paper

> Clemens Ruck and Maximilian E. Schüle. **Functions Become Data.**
> Proc. ACM Manag. Data 4, 6 (SIGMOD), Article 351 (December 2026).
> https://doi.org/10.1145/3856346

It contains the implementation, a PostgreSQL 17.4 source tree extended with lambda
functions as first-class data (a `lambda` type with per-column signatures, higher-order
and partial application, and the parallel `map` operator), and everything needed to
reproduce the paper's evaluation.

## Contents

| path | what |
|---|---|
| `hol-lambdas/` | the modified PostgreSQL 17.4 source tree |
| `hol-lambdas/src/ext/` | the table functions (`map` = `apply_mt_pw_ext.c`) and SQL testers for the lambda features |
| `build_helper.sh` | builds and installs the engine into `hol-lambdas/install/` |
| `run_all.sh` | runs all measurements of the paper and writes the figures' CSVs |
| `benchmark.py`, `generate_benchmarks.py` | scaling slices and core sweep (Figure "scaling") |
| `run_usecase_benchmark.py`, `generate_usecase_benchmarks.py` | the use case (Figure "use case") |
| `additional-tests/timing/` | phase breakdown of the `map` operator (Figure "timing") |
| `additional-tests/equivalence/` | checks that all variants compute identical results |
| `setup-scripts/setup.sql` | tables and functions every benchmark cluster is loaded with |
| `report.py`, `results/*.py` | a markdown report per run, and the CSVs the figures read |

`benchmarks/`, `results/<run>/` and `bench_logs/` are created by the scripts.

## Requirements

Linux with a PostgreSQL-from-source toolchain and Python 3:

- gcc/g++ and `make`, `flex`, `bison`, `perl`
- LLVM and Clang development packages (the lambda JIT; the paper used LLVM 18)
- OpenMP (part of gcc), ICU headers, `pkg-config`, `readline`, `zlib`
- Python packages `psycopg` (version 3) and `pandas` (only for the figure CSVs)

On Ubuntu 24.04: `apt install build-essential flex bison perl clang llvm llvm-dev
libicu-dev pkg-config libreadline-dev zlib1g-dev python3-psycopg python3-pandas`.
The `Dockerfile` installs the same.

## 1. Build

```bash
./build_helper.sh            # release build (-O2), as measured in the paper
./build_helper.sh --debug    # debug build
```

It configures, builds and installs the engine and its table functions into
`hol-lambdas/install/` (about 5–10 minutes). From a zip archive, the executable bits are
lost: run `bash build_helper.sh` and `chmod +x run_all.sh` once.

## 2. Reproduce the paper

```bash
./run_all.sh                                   # everything below, on the paper's machine
./run_all.sh --smoke --topology local          # all stages in a few minutes, any machine
python3 additional-tests/timing/run_ptime.py   # the timing figure (not part of run_all.sh)
```

| paper | command | output |
|---|---|---|
| scaling (a) data, (c) lambdas | `python3 benchmark.py --types baseline_case_jitoff free_lambda_jitoff hol_pw_jitnoopt` | `results/bench_<stamp>/` |
| scaling (b) parallel speedup | `python3 benchmark.py --types baseline_case_agg_cores_jitoff free_lambda_agg_cores_jitoff agg_cores_pw_jitnoopt` | `results/bench_<stamp>/` |
| use case | `python3 run_usecase_benchmark.py` | `results/usecase_<stamp>/` |
| timing (a)–(c) | `python3 additional-tests/timing/run_ptime.py`, then `agg_ptime.py results/timing_<stamp>` | `results/timing_<stamp>/v2_timing_*.csv` |
| correctness | `python3 additional-tests/equivalence/run_equivalence.py` | `RESULT: PASS` |
| the figures' CSVs | `python3 results/publish_to_paper.py bench_<stamp> --usecase-run usecase_<stamp>` | `results/paper_csv/bench_<stamp>/` |

`benchmark.py` without `--types` runs both scaling sets. `run_all.sh` generates the
queries, runs the scaling and use-case benchmarks and the equivalence check, and writes
`report.md` (speedups, worker counts, JIT conditions) and the figures' CSVs, named as
in the paper's sources (`bic_*.csv`). On the paper's machine this takes about 45 minutes,
the timing breakdown another 5.

**What is measured.** Every benchmark type runs in a fresh cluster (port 5433),
2 warmups + 20 measured runs per point plus one untimed verification run, round robin
over the points; the figures show the minimum. All points run at 16 processes on both
sides: the SQL baselines are pinned to 15 workers + the leader, the `map` operator launches
16 workers. CASE dispatch and the free lambdas run with JIT off, the `map` operator on
its fast JIT path (L3) without LLVM optimisation and inlining. The verification run
checks every point's plan and worker count and records them in
`results/<run>/conditions_<type>.jsonl`; `PROVENANCE.md` records the commit, the binaries'
md5s and all settings.

**Hardware.** The paper's machine is an 18-core Intel Xeon W-2295 (36 CPUs with
hyperthreading), Ubuntu 24.04. The runners pin postgres to 16 cores and themselves to
the remaining two (`--topology server`, the default). On other machines, add an entry to
`TOPOLOGIES` in `benchmark.py`, or use `--topology local` (12 CPUs, oversubscribed): it
runs everything, but the timings are not comparable to the paper's.

## 3. Correctness

`additional-tests/equivalence/run_equivalence.py` runs blobs of the generated benchmarks
verbatim, each with its timed type's settings, and checks that the `map` operator, the
free lambdas and the CASE baseline produce bit-identical results (up to 28 million rows)
and identical aggregates; see its README. It needs no special hardware.

The SQL testers in `hol-lambdas/src/ext/` exercise the lambda features themselves
(stored and higher-order lambdas, partial application with `_`, lambdas in filters,
joins, grouping, parallel plans). Run them against a scratch cluster:

```bash
cd hol-lambdas
install/bin/initdb -D /tmp/lambdas -A trust
install/bin/pg_ctl -D /tmp/lambdas -o "-p 5499 -c shared_preload_libraries=llvmjit" -w start
cd src/ext && ../../install/bin/psql -X -p 5499 -d postgres -f lambda-partials-tester.sql
cd ../.. && install/bin/pg_ctl -D /tmp/lambdas stop
```

The engine also passes PostgreSQL's regression suite (`make -C hol-lambdas check`) except
for three catalog sanity tests that list the new lambda types and functions.

## Docker

```bash
docker build -t hol-lambdas .
docker run --rm --shm-size=8g hol-lambdas            # equivalence check
docker run --rm -it --shm-size=8g hol-lambdas bash   # a shell, e.g. ./run_all.sh --smoke --topology local
```

`--shm-size` is needed: the `map` operator hands its results over in shared memory
(1.3 GB at the largest point), and the benchmark clusters reserve 4 GB of it at start.

## License

The benchmark harness and the lambda extension are licensed under the GNU General Public
License v3.0 (`LICENSE`), Copyright (C) 2025-2026 Clemens Ruck. The PostgreSQL source
tree under `hol-lambdas/` remains under the PostgreSQL License (`hol-lambdas/COPYRIGHT`).
