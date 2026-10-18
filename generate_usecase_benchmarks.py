#!/usr/bin/env python3
"""
Generate the SQL blobs for the use case (in-database model selection).

Compares the map operator (apply_mt_agg_pw) against hand-written CASE-dispatch SQL.
Both sides evaluate the same higher-order expression for every (data, model) pair
and reduce it to a single global average:

    g(x,y,z,f) = abs(f(x,y,z)) * 0.9 + f(x,y,z)
    result_i   = (g(x,y,z,f_i) + g(z,y,x,f_i)) / 2
    output     = avg(result_i)   over all data rows and all models

Writes benchmarks/benchmark_usecase_{map_pw,case}.sql; run them with
run_usecase_benchmark.py.
"""

from typing import Iterable, List, Tuple
import argparse
import os
import sys

# The expression builders are shared with the main suite: they have to stay
# identical to lambdas_hol in setup.sql.
from generate_benchmarks import (
    DATA_TABLE, LAMBDA_TABLE, TOP_LEVEL_LAMBDA, WIDTH,
    blob_header, fol_result_expr, operator_width_setup, sql_width_setup)


def build_bench(statements: Iterable[str]) -> str:
    body = "\n\n".join(s.rstrip() for s in statements)
    return f"{body}\n"


def create_usecase_map_pw_statement(ndata: int, nmodels: int, nthreads: int = WIDTH) -> str:
    """
    The map operator with built-in aggregation: apply_mt_agg_pw evaluates the
    expression for every (data, model) pair and reduces it to one flat average
    internally. Mode 1 = L3, the fast path.
    """
    query = blob_header(nthreads, ndata, nmodels, operator_width_setup(nthreads))
    query += "SELECT result FROM apply_mt_agg_pw(\n"
    query += f"    {TOP_LEVEL_LAMBDA},\n"
    query += f"    (select x, y, z from {DATA_TABLE} where id <= {ndata}),\n"
    query += f"    (select * from {LAMBDA_TABLE} where id <= {nmodels}),\n"
    query += f"    {nthreads}, 1);\n"
    return query


def create_usecase_case_statement(ndata: int, nmodels: int, nthreads: int = WIDTH) -> str:
    """
    The same reduction in plain SQL: each model body is selected by a runtime key
    (CASE dispatch). The parallel degree is pinned on the data table, so both sides
    run nthreads processes.
    """
    header = blob_header(nthreads, ndata, nmodels,
                         sql_width_setup(nthreads, DATA_TABLE), table=DATA_TABLE)
    body = "SELECT avg(CASE l.lambda_id\n"
    for idx in range(nmodels):
        body += f"    WHEN {idx + 1} THEN {fol_result_expr(idx)}\n"
    body += f"""  END)
FROM {DATA_TABLE} d
CROSS JOIN generate_series(1, {nmodels}) AS l(lambda_id)
WHERE d.id <= {ndata};"""
    return header + body


# Two sweeps: the data axis at 100 models, the model axis at 10,000 rows.
# Bounds: setup.sql builds 120,000 rows in nums and 500 in lambdas_hol; the blobs
# select `where id <= N`, so exceeding either would silently measure less.
DATA_SWEEP = ([10000, 20000, 40000, 60000, 80000, 100000], 100)
MODEL_SWEEP = (10000, [50, 100, 150, 200, 250])
MAX_NDATA = 120000
MAX_NMODELS = 500


def scaling_pairs() -> List[Tuple[int, int]]:
    """The data sweep, then the model sweep; the shared corner point only once."""
    data_levels, fixed_models = DATA_SWEEP
    fixed_data, model_levels = MODEL_SWEEP
    pairs: List[Tuple[int, int]] = []
    for p in [(n, fixed_models) for n in data_levels] + [(fixed_data, m) for m in model_levels]:
        if p not in pairs:
            pairs.append(p)
    for ndata, nmodels in pairs:
        if ndata > MAX_NDATA or nmodels > MAX_NMODELS:
            raise SystemExit(f"point ({ndata}, {nmodels}) exceeds what setup.sql builds "
                             f"({MAX_NDATA} rows in nums, {MAX_NMODELS} in lambdas_hol)")
    return pairs


def main():
    parser = argparse.ArgumentParser(description="Generate the use-case benchmark SQL blobs.")
    parser.add_argument("--out-dir", default=None, help="Output directory (default: ./benchmarks).")
    parser.add_argument("--stdout", action="store_true", help="Write all SQL to stdout instead of files.")
    args = parser.parse_args()

    out_dir = args.out_dir or os.path.join(os.getcwd(), "benchmarks")
    if not args.stdout:
        os.makedirs(out_dir, exist_ok=True)

    pairs = scaling_pairs()
    print(f"[usecase] {len(pairs)} blobs -> " + ", ".join(f"{n}x{m}" for n, m in pairs),
          file=sys.stderr)

    files = {
        "benchmark_usecase_map_pw.sql": [create_usecase_map_pw_statement(n, m) for n, m in pairs],
        "benchmark_usecase_case.sql": [create_usecase_case_statement(n, m) for n, m in pairs],
    }
    for file_name, stmts in files.items():
        final_sql = build_bench(stmts)
        if args.stdout:
            sys.stdout.write(f"\n-- >>> {file_name} >>>\n")
            sys.stdout.write(final_sql)
        else:
            with open(os.path.join(out_dir, file_name), "w", encoding="utf-8") as f:
                f.write(final_sql)
            print(f"[usecase] wrote {file_name} ({len(stmts)} blobs)", file=sys.stderr)


if __name__ == "__main__":
    main()
