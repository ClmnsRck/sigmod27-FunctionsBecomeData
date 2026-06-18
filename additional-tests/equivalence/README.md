# Result-equivalence test (HOL vs. pure-SQL baseline)

This is **not** a timing benchmark. It exists to remove any doubt that the HOL
`map` operator (`apply_mt`) and the pure-SQL baseline compute **the same
results** for the same input — so the speedup numbers can't be dismissed as
comparing two different computations.

## What it does

It takes the **first blob** of the generated benchmarks verbatim
(`benchmarks/benchmark_hol.sql` vs. `benchmarks/benchmark_baseline.sql`; with
`--with-cores`, also `benchmark_cores.sql` vs. `benchmark_baseline_cores.sql`),
runs both against the freshly built PostgreSQL, and compares their result sets.

It compares the *actual benchmark SQL*, not a hand-written re-derivation, so
there is no room to argue the verified queries differ from the timed ones.

## How it avoids false negatives (FP + ordering)

- **No `=` on floats.** Result values are compared with a tolerance:
  `max(|hr - br| / greatest(|hr|, |br|, 1))`. The clamped denominator makes this
  a true *relative* error for `|value| >= 1` and a (stricter) *absolute* error
  for `|value| < 1`, so a single threshold (`TOL_REL = 1e-9`) is sound.
- **Exact key join.** HOL emits `(x, y, z, result)`; the baseline emits
  `(lambda_id, data_id, result)`. Both are keyed on the data coordinates
  `(x, y, z)` — the *stored* `float8` values, copied through unchanged on both
  sides (no arithmetic applied to them), hence bit-identical and safe to equate.
- **Order/threading independent.** Within each data point the `M` result values
  are sorted on both sides and compared i-th vs. i-th. Equal multisets per data
  point ⇒ identical computation regardless of emission order or thread count.
- **Cardinality.** A `FULL OUTER JOIN` asserts there are no unmatched rows and
  that both sides have the same row count.

`PASS` iff: row counts equal **and** 0 unmatched rows **and** `max_rel_err <= TOL_REL`.

## Running it

Requires the built fork (`hol-postgres/` on the server, `hol-lambdas/` locally)
and the generated `benchmarks/*.sql`. On the server, first
`source ~/enable_all.sh` (loads LLVM/Python/db env).

```bash
cd additional-tests/equivalence
python3 run_equivalence.py              # data/lambda pair (10k x 50 = 500k rows)
python3 run_equivalence.py --with-cores # also the 8M-row pair (needs several GB temp disk)
```

The default pair already exercises all 10 distinct FOL variants (50 lambdas =
5 full cycles), so it is sufficient to prove value-equivalence; the cores pair
only repeats the same variants over more rows and is opt-in because it is
disk-heavy.

## Latest result

```
data/lambda (first blob: 10k tuples, 50 lambdas)
  hol_rows=500000  base_rows=500000  unmatched=0
  max_abs_err=0    max_rel_err=0     (tol=1e-9)   -> PASS
```

The two implementations produced **bit-identical** doubles across all 500,000
result rows — not merely within tolerance.
