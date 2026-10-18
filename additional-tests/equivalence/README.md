# Result-equivalence test (HOL vs. pure-SQL baseline)

This is **not** a timing benchmark. It removes any doubt that the `map` operator
(`apply_mt_pw`), the free lambdas and the pure-SQL CASE baseline compute **the same
results** for the same input, so the speedups cannot be dismissed as comparing two
different computations.

## What it does

It takes blobs of the generated benchmarks verbatim, each with the session settings
its timed type uses (`benchmark.py` `TYPE_SESSION_SETTINGS`), runs them against the
freshly built PostgreSQL and compares the results:

| check | sides | points |
|---|---|---|
| streaming, bit-identical checksum | `hol_pw_jitnoopt` vs `baseline_case_jitoff` | 10k x 100, 80k x 350 |
| streaming, bit-identical checksum | `free_lambda_jitoff` vs `baseline_case_jitoff` | 10k x 100, 80k x 350 |
| aggregated, relative error <= 1e-9 | core sweep, all three types at width 8 | 80k x 100 |
| aggregated, relative error <= 1e-9 | use case, `usecase_map_pw_jitnoopt` vs `usecase_case_jitoff` | 10k x 100 |

10k x 100 exercises all 10 distinct first-order variants; 80k x 350 is the largest
slice point. The aggregated results differ in the last digits only because the
summation order differs (a Gather's partial aggregates vs. the operator's per-job sums).

## How it avoids false negatives

- **Checksums, not row diffs.** Each side is reduced to `count(*)`,
  `sum(hashfloat8(result))` as numeric (exact and order-independent), min and max.
  Equal checksums mean bit-identical results, independent of row order or worker count.
- **Exact keys.** The operator emits `(x, y, z, result)`, the SQL sides
  `(lambda_id, data_id, result)`; the SQL side is joined back to `nums` on `data_id`,
  so both are keyed on the stored float8 coordinates.
- **`--exact`** replaces the checksum with a tolerant per-row comparison
  (`max(|a - b| / greatest(|a|, |b|, 1)) <= 1e-9` after sorting the M results per data
  point). It materialises both result sets and needs several GB of disk.

## Running it

Requires the built engine (`hol-lambdas/install`) and the generated benchmarks:

```bash
python3 generate_benchmarks.py && python3 generate_usecase_benchmarks.py
python3 additional-tests/equivalence/run_equivalence.py
```

It runs its own cluster on port 5457 (`PG_REPO=<dir>` points it at another build) and
prints `RESULT: PASS` when every check passes.
