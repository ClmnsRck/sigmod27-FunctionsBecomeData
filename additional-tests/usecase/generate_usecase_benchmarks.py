#!/usr/bin/env python3
"""
Generate SQL blobs for the use-case section: In-Database Model Selection.

Compares the HOL Map operator (apply_mt) against a hand-written pure-SQL CTE.
Both sides evaluate the *same* higher-order expression for every (data, model)
pair and reduce it to a single global average:

    g(x,y,z,f) = abs(f(x,y,z)) * 0.9 + f(x,y,z)
    result_i   = (g(x,y,z,f_i) + g(z,y,x,f_i)) / 2
    output     = avg(result_i)   over all data rows and all models

Self-contained additional test: writes the two benchmark files next to this
script. Run with run_usecase_benchmark.py.
"""

from typing import Iterable, List, Tuple
import argparse
import sys
import os

# ----------------------------
# Helpers
# ----------------------------

def build_bench(statements: Iterable[str]) -> str:
    body = "\n\n".join(s.rstrip() for s in statements)
    return f"{body}\n"

# 10 structurally distinct FOL expression templates.
# Placeholders {x}, {y}, {z} map to the three input columns.
# These must stay in sync with the CASE expression in setup_usecase.sql.
FOL_VARIANTS = [
    "{x} + {y} * {z}",           # 0
    "{x} * {y} + {z}",           # 1
    "{x} - {y} + {z}",           # 2
    "{x} * {z} + {y}",           # 3
    "({x} + {y}) * {z}",         # 4
    "{x} * {x} + {y} * {z}",     # 5
    "{x} * {y} * {z}",           # 6
    "({x} - {z}) * ({y} + 1.0)", # 7
    "{x} + {y} + {z}",           # 8
    "{x} * ({y} - {z})",         # 9
]


def create_usecase_map_statement(
    top_level_lambda: str,
    data_table: str,
    lambda_table: str,
    scaling_level_data: int,
    scaling_level_lambdas: int,
    num_cores: int = 17,
) -> str:
    """
    HOL Map operator: apply_mt produces one result per (data, model) pair;
    the average is the model-selection score, aggregated in SQL on top.
    """
    query = "--SPLIT\n"
    query += f"-- {num_cores} {scaling_level_data} {scaling_level_lambdas}\n"
    query += "SELECT avg(result) FROM apply_mt(\n"
    query += f"    {top_level_lambda},\n"
    query += f"    (select x, y, z from {data_table} where id <= {scaling_level_data}),\n"
    query += f"    (select * from {lambda_table} where id <= {scaling_level_lambdas}),\n"
    query += "    NTHREADS_MARKER, 0);\n"
    return query


def create_usecase_sql_statement(
    data_table: str,
    scaling_level_data: int,
    scaling_level_lambdas: int,
    num_cores: int = 17,
) -> str:
    """
    Pure-SQL equivalent of the Map+reduce above. Each lambda index uses a
    different FOL variant (cycling through FOL_VARIANTS) to mirror lambdas_hol,
    exactly as in the main benchmark_baseline, but reduced to a global average.
    """
    header = "--SPLIT\n"
    header += f"-- {num_cores} {scaling_level_data} {scaling_level_lambdas}\n"

    # NOT MATERIALIZED removes the CTE optimisation fence so the planner may inline
    # the per-row projection under a parallel-aware scan (a MATERIALIZED CTE scan is
    # never parallelised). Results are identical; only the plan can now go parallel.
    body = f"""WITH data_scan AS NOT MATERIALIZED (
  SELECT
    d.id AS data_id,\n"""

    width = len(str(scaling_level_lambdas))
    for idx in range(scaling_level_lambdas):
        i = idx + 1
        variant = FOL_VARIANTS[idx % len(FOL_VARIANTS)]
        fwd = variant.format(x="d.x", y="d.y", z="d.z")
        rev = variant.format(x="d.z", y="d.y", z="d.x")
        expr = (
            f"((abs({fwd}) * 0.9 + ({fwd})) + "
            f"(abs({rev}) * 0.9 + ({rev}))) / 2"
        )
        if idx != 0:
            body += ",\n"
        body += f"    ({expr})::float8 AS e{i:0{width}d}"

    body += f"""
  FROM {data_table} d
  WHERE d.id <= {scaling_level_data}
)
SELECT avg(v.result)
FROM data_scan s
CROSS JOIN LATERAL (VALUES """
    for idx in range(scaling_level_lambdas):
        i = idx + 1
        if idx != 0:
            body += ","
        if idx != 0 and idx % 5 == 0:
            body += "\n    "
        body += f"({i:0{width}d}, s.e{i:0{width}d})"
    body += "\n) AS v(lambda_id, result);"

    return header + body


# ----------------------------
# Script
# ----------------------------

def scaling_pairs() -> List[Tuple[int, int]]:
    """
    Two sweeps, mirroring the original use-case study:
      - data scaling : vary ndata, fixed nmodels = 50
      - model scaling: vary nmodels, fixed ndata = 10000
    Deduplicated, order preserved.
    """
    pairs: List[Tuple[int, int]] = []
    seen = set()

    for ndata in [1000, 5000, 10000, 30000, 50000, 80000]:
        p = (ndata, 50)
        if p not in seen:
            seen.add(p)
            pairs.append(p)

    for nmodels in [2, 5, 10, 20, 50, 100]:
        p = (10000, nmodels)
        if p not in seen:
            seen.add(p)
            pairs.append(p)

    return pairs


def main():
    parser = argparse.ArgumentParser(
        description="Generate use-case (model selection) benchmark SQL blobs: Map vs pure SQL."
    )
    parser.add_argument("--stdout", action="store_true", help="Write all SQL to stdout instead of files.")
    args = parser.parse_args()

    out_dir = os.path.dirname(os.path.abspath(__file__))

    top_level_lambda = """lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2)"""
    data_table = "nums"
    lambda_table = "lambdas_hol"

    pairs = scaling_pairs()

    # --------------- USE-CASE MAP BENCHMARK ----------------
    file_name = "benchmark_usecase_map.sql"
    stmts: List[str] = []
    for ndata, nmodels in pairs:
        stmts.append(
            create_usecase_map_statement(
                top_level_lambda=top_level_lambda,
                data_table=data_table,
                lambda_table=lambda_table,
                scaling_level_data=ndata,
                scaling_level_lambdas=nmodels,
            )
        )
    final_sql = build_bench(stmts)
    if args.stdout:
        sys.stdout.write(f"\n-- >>> {file_name} >>>\n")
        sys.stdout.write(final_sql)
    else:
        with open(os.path.join(out_dir, file_name), "w", encoding="utf-8") as f:
            f.write(final_sql)

    # --------------- USE-CASE SQL BENCHMARK ----------------
    file_name = "benchmark_usecase_sql.sql"
    stmts = []
    for ndata, nmodels in pairs:
        stmts.append(
            create_usecase_sql_statement(
                data_table=data_table,
                scaling_level_data=ndata,
                scaling_level_lambdas=nmodels,
            )
        )
    final_sql = build_bench(stmts)
    if args.stdout:
        sys.stdout.write(f"\n-- >>> {file_name} >>>\n")
        sys.stdout.write(final_sql)
    else:
        with open(os.path.join(out_dir, file_name), "w", encoding="utf-8") as f:
            f.write(final_sql)


if __name__ == "__main__":
    main()
