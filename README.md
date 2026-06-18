# Functions Become Data - Artifact

This artifact contains the benchmark scripts used for the paper. The implementation
under test is the PostgreSQL variant in `hol-lambdas/`, a PostgreSQL 17.4 source tree
extended with higher-order SQL lambda functions (a native `lambda` type plus a parallel
`map` operator).

> ## Before you run on your own hardware, read this
>
> The benchmark runners (`benchmark.py` and the runners under `additional-tests/`) pin
> CPU affinity to the exact core topology of the machine we used for the paper. On a
> machine with a different number of cores this pinning fails with an error (it asks the
> OS for cores that don't exist) instead of just running slower.
>
> So before you run the timing benchmarks, set the topology constants to match your
> machine, i.e. the number of physical cores and the hyperthread sibling offset:
>
> - `benchmark.py`: the `RunnerConfig` fields near the top (`hyperthreading_offset`,
>   `reserved_core`, `best_effort_cores`).
> - `additional-tests/usecase/run_usecase_benchmark.py`: the same `RunnerConfig` fields.
> - `additional-tests/parallel/run_parallelism_benchmark.py`: the `HYPERTHREADING_OFFSET`,
>   `RESERVED_CORE`, `BEST_EFFORT_CORES` constants.
>
> If you just want a quick check that needs no topology changes and no special hardware,
> run the result-equivalence smoke test (Section 3) or the default `Dockerfile` command.
> Neither of them pins CPU affinity. A later revision will detect the host topology
> automatically.

## What is in this repository?

- `hol-lambdas/`: PostgreSQL source tree with higher-order lambda support. The lambda C
  extension and its sanity-check SQL live in `hol-lambdas/src/ext/`.
- `benchmark.py`: main benchmark runner for the HOL map operator, the pure-SQL baseline,
  and the core-scaling experiments.
- `generate_benchmarks.py`: (re)generates the SQL inputs in `benchmarks/`.
- `benchmarks/`: generated SQL benchmark inputs.
- `setup-scripts/setup.sql`: schema and function setup loaded by the runner.
- `additional-tests/`: the result-equivalence (correctness) check and the extra
  experiments (use case, k-means, parallelism, timing breakdowns).
- `build_helper.sh`: wrapper that builds `hol-lambdas/`.
- `download_helper.sh`: clones the PostgreSQL fork. You only need this if you don't
  already have the in-tree `hol-lambdas/` source, which is included here anyway.
- `results/`, `bench_logs/`: output destinations (timestamped per run).
- `Dockerfile`: reproducibility image. It builds the whole stack and by default runs the
  result-equivalence smoke test.
- `REPRODUCING.md`: experiment-to-paper mapping, hardware/time notes, smoke test.
- `LICENSE`: GNU GPL v3 (see the License section below).

## Minimal prerequisites

A Linux machine with Python 3 and a working PostgreSQL-from-source toolchain. In
practice you need:

- a C/C++ compiler toolchain
- `make`
- LLVM/Clang development packages (the lambda JIT requires LLVM; the build uses
  `--with-llvm`)
- OpenMP support (`-fopenmp`; the `map` operator uses a thread pool)
- `flex`, `bison`, `perl`
- the usual PostgreSQL build dependencies such as `readline` and `zlib`
- Python package `psycopg` (psycopg 3)

## 1. Build the modified PostgreSQL

From the repository root (the naked `./configure` is needed once so the build script's
`make clean` works):

```bash
cd hol-lambdas
./configure
./tools/complete_build.sh
cd ..
```

Or just run `./build_helper.sh` from the root (add `--debug` for the debug build). This
creates the local installation under `hol-lambdas/install/` that the benchmark scripts
use.

### Alternative: build and smoke-test with Docker

The `Dockerfile` builds the whole stack and by default runs the result-equivalence check
(no special hardware needed):

```bash
docker build -t hol-artifact .
docker run --rm hol-artifact            # equivalence smoke test
docker run --rm -it hol-artifact bash   # shell for the full benchmarks
```

See `REPRODUCING.md` for which experiment backs which part of the paper.

## 2. Run the main benchmark suite

`benchmark.py` creates a fresh PostgreSQL cluster automatically (port `5433`, database
`bench`), loads `setup-scripts/setup.sql`, runs the selected benchmark types, and writes
logs and results into timestamped folders. It pins CPU affinity using the topology
constants near the top of `benchmark.py`, so adjust those for your machine.

Run all benchmark groups:

```bash
python3 benchmark.py
```

Run a subset:

```bash
python3 benchmark.py --types hol baseline      # choose from: hol baseline cores baseline_cores
```

Outputs are written to:

- `results/bench_YYYYMMDD_HHMMSS/`
- `bench_logs/bench_YYYYMMDD_HHMMSS/`

To (re)generate the SQL benchmark inputs:

```bash
python3 generate_benchmarks.py
```

## 3. Correctness check (HOL vs. pure-SQL)

`additional-tests/equivalence/` is not a timing benchmark. It checks that the HOL `map`
operator (`apply_mt`) and the pure-SQL baseline compute the same results for the same
input (tolerance-based float comparison, independent of row order and thread count).

```bash
cd additional-tests/equivalence
python3 run_equivalence.py
cd ../..
```

See `additional-tests/equivalence/README.md` for the comparsion methodology.

## 4. Additional experiments

Each subdirectory under `additional-tests/` is self-contained. It builds its own fresh
cluster against `hol-lambdas/install/` and has its own runner:

- `usecase/`: in-database model-selection use case (`python3 run_usecase_benchmark.py`);
  writes CSVs under `usecase/results/`.
- `kmeans/`: k-means use case (`python3 run_kmeans_benchmark.py`).
- `parallel/`: core-scaling / parallelism (`python3 run_parallelism_benchmark.py`).
- `timing/`, `timing_agg/`, `timing_scale_expr/`: per-phase timing breakdowns
  (`./run_timing_benchmark.sh`).

## Notes

- The scripts are written for Linux and use fixed CPU-affinity settings tuned for the
  machine reported in the paper. Adjust the topology constants at the top of
  `benchmark.py` (and the `additional-tests/` runners) accordingly.
- `benchmark.py` assumes the `hol-lambdas/` directory name is unchanged.
- JIT/LLVM is required: the cluster is started with `shared_preload_libraries=llvmjit`.
  For benchmark stability, durability is disabled (`fsync`, `synchronous_commit`,
  `full_page_writes` are off).
- Standalone sanity-check SQL for the lambda features lives in `hol-lambdas/src/ext/`
  (e.g. `lambda-freeFromUDF-tester.sql`, `lambda-partials-tester.sql`). Run them with the
  built `psql` against a database where the extension functions have been created.

## License

This artifact (the benchmark harness and the lambda extensions) is licensed under the
GNU General Public License v3.0, see `LICENSE`. Copyright (C) 2026 Anonymous Author(s)
(under double-blind review).

The bundled PostgreSQL source tree under `hol-lambdas/` is a derivative of PostgreSQL and
remains available under the PostgreSQL License; see `hol-lambdas/COPYRIGHT`. PostgreSQL's
permissive terms are compatible with redistribution of the combined work under the GPL.
