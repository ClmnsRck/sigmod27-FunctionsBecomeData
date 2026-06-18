#!/usr/bin/env python3

from typing import Iterable, List
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
# These must stay in sync with the CASE expression in setup.sql.
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

def create_apply_statement(
    top_level_lambda: str,
    data_table: str,
    lambda_table: str,
    scaling_level_data: int,
    scaling_level_lambdas: int,
    num_cores: int
) -> str:
    query = ""
    query += f"--SPLIT\n"

    query += f"-- {num_cores} {scaling_level_data} {scaling_level_lambdas}\n"
    
    query += f"select * from apply_mt(\n"

    query += f"    {top_level_lambda},\n"

    query += f"    (select x, y, z from {data_table} where id <= {scaling_level_data}),\n"
    query += f"    (select * from {lambda_table} where id <= {scaling_level_lambdas}),\n"
    
    query += f"    NTHREADS_MARKER, 0);\n"
    
    return query

def create_pure_sql_statement(
    data_table: str,
    scaling_level_data: int,
    scaling_level_lambdas: int,
    num_cores: int = 17
) -> str:
    """
    Generates a pure-SQL equivalent of the HOL apply_mt benchmark.
    Each lambda index uses a different FOL variant (cycling through FOL_VARIANTS)
    to mirror the varied lambdas_hol table in setup.sql.

    HOL semantics replicated:
      g(x,y,z,f) = abs(f(x,y,z)) * 0.9 + f(x,y,z)
      result_i   = (g(x,y,z,f_i) + g(z,y,x,f_i)) / 2

    num_cores controls CPU pinning via the --SPLIT header (default 17 = all cores);
    the runner caps PostgreSQL's parallel workers to match.
    """

    header = ""
    header += "--SPLIT\n"
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
SELECT
  v.lambda_id,
  s.data_id,
  v.result
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

def main():
    parser = argparse.ArgumentParser(
        description="Generate SQL blobs for lambda/HOL UDF apply_l1_2 and apply_fast. "
                    "Writes one benchmark file per (repo, test, type)."
    )
    parser.add_argument("--stdout", action="store_true", help="Write all SQL to stdout instead of files.")
    args = parser.parse_args()

    out_dir = os.path.join(os.getcwd(), "benchmarks")
    if not args.stdout:
        os.makedirs(out_dir, exist_ok=True)

    description="Scaling Data/Lambdas"
    top_level_lambda="""lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2)"""
    data_table="nums"
    scaling_lambdas=[50, 100, 150, 200, 250, 300]
    scaling_data=[10000, 20000, 30000, 40000, 50000,
                    60000, 70000, 80000]

    #-------------- GENERAL BENCHMARK -----------------
    stmts: List[str] = []
    for scale_lambdas in scaling_lambdas:
        for scale_data in scaling_data:
            stmts.append(
                create_apply_statement(
                    top_level_lambda=top_level_lambda,
                    data_table=data_table,
                    lambda_table= "lambdas_hol",
                    scaling_level_data=scale_data,
                    scaling_level_lambdas=scale_lambdas,
                    num_cores=17
                )
            )

    final_sql = build_bench(stmts)
    file_name = f"benchmark_hol.sql"

    if args.stdout:
        sys.stdout.write(f"\n-- >>> {file_name} >>>\n")
        sys.stdout.write(final_sql)
    else:
        out_path = os.path.join(out_dir, file_name)
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(final_sql)
    
    # --------------- CORE SCALING BENCHMARK ----------------
    file_name = f"benchmark_cores.sql"
    stmts: List[str] = []
    for scale in [0, 1, 2, 4, 8, 16, 32]:
        stmts.append(
            create_apply_statement(
                top_level_lambda=top_level_lambda,
                data_table=data_table,
                lambda_table= "lambdas_hol",
                scaling_level_data=80000,
                scaling_level_lambdas=100,
                num_cores=scale
            )
        )
    
    final_sql = build_bench(stmts)
    if args.stdout:
        sys.stdout.write(f"\n-- >>> {file_name} >>>\n")
        sys.stdout.write(final_sql)
    else:
        out_path = os.path.join(out_dir, file_name)
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(final_sql)
    


    # --------------- PURE SQL BENCHMARK ----------------
    file_name = f"benchmark_baseline.sql"
    stmts: List[str] = []
    for scale_data in scaling_data:
        for scale_lambdas in scaling_lambdas:
            stmts.append(
                create_pure_sql_statement(
                    data_table=data_table,
                    scaling_level_data=scale_data,
                    scaling_level_lambdas=scale_lambdas
                )
            )
    
    final_sql = build_bench(stmts)
    if args.stdout:
        sys.stdout.write(f"\n-- >>> {file_name} >>>\n")
        sys.stdout.write(final_sql)
    else:
        out_path = os.path.join(out_dir, file_name)
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(final_sql)

    # --------------- PURE SQL CORE SCALING BENCHMARK ----------------
    # Mirrors the apply_mt CORE SCALING benchmark (same fixed 80000 data / 100
    # lambdas, same core points) so the cores figure gets a PostgreSQL line next
    # to the UDF. The runner caps max_parallel_workers_per_gather per blob to the
    # chunk's thread budget, so this measures whether pure SQL scales with cores.
    file_name = f"benchmark_baseline_cores.sql"
    stmts: List[str] = []
    for scale in [0, 1, 2, 4, 8, 16, 32]:
        stmts.append(
            create_pure_sql_statement(
                data_table=data_table,
                scaling_level_data=80000,
                scaling_level_lambdas=100,
                num_cores=scale
            )
        )

    final_sql = build_bench(stmts)
    if args.stdout:
        sys.stdout.write(f"\n-- >>> {file_name} >>>\n")
        sys.stdout.write(final_sql)
    else:
        out_path = os.path.join(out_dir, file_name)
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(final_sql)


if __name__ == "__main__":
    main()

