#!/usr/bin/env python3
"""
Generate the SQL blobs for the HOL benchmarks and their pure-SQL baselines.

Each blob looks like this; benchmark.py runs the setup lines once, untimed, and
times only the statement after --QUERY:

  --SPLIT
  -- nthreads=<W> ndata=<N> nlambdas=<M> [table=<name>[,<name>]]
  SET max_parallel_workers_per_gather = ...;
  --QUERY
  <statement>

`table` is set for the plain-SQL types only: the table whose parallel degree the
blob pins (ALTER TABLE ... SET (parallel_workers = W-1) in the setup lines), so a
generated file alone says at which width it ran.

The suite is what the paper's figures read (benchmark.py ALL_TYPES): the two grid
slices at WIDTH = 16 processes and the core sweep over SWEEP_POINTS. The use-case
blobs come from generate_usecase_benchmarks.py.
"""

from typing import Iterable, List, Optional, Tuple
import argparse
import sys
import os


# ----------------------------
# Grid
# ----------------------------

SCALING_DATA = [10000, 20000, 30000, 40000, 50000, 60000, 70000, 80000,
                100000, 120000]
SCALING_LAMBDAS = [50, 100, 150, 200, 250, 300, 350]

# The two 1D slices the paper plots (results/agg_bench_results.py, keep in sync).
CUT_DATA = 80000
CUT_LAMBDAS = 100

# Core sweep point. M stays above the widest sweep point, because the operator
# caps its workers at the number of lambdas on L3.
CORES_DATA = 80000
CORES_LAMBDAS = 100

# Widths in processes. Every slice and use-case blob runs at WIDTH on both sides
# (SQL: WIDTH-1 workers + the participating leader; operator: WIDTH workers + an idle
# leader), forced, not just capped. The core sweep runs SWEEP_POINTS.
WIDTH = 16
SWEEP_POINTS = [1, 2, 4, 8, 16]

DATA_TABLE = "nums"
LAMBDA_TABLE = "lambdas_hol"

TOP_LEVEL_LAMBDA = """lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2)"""

# 10 structurally distinct first-order bodies; {x}, {y}, {z} are the input columns.
# Must match the lambdas_hol table in setup.sql.
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


def cross_grid(nthreads: int = WIDTH) -> List[Tuple[int, int, int]]:
    """The two 1D slices the paper plots, end to end: 16 blobs, not the full N x M grid."""
    return ([(d, CUT_LAMBDAS, nthreads) for d in SCALING_DATA]
            + [(CUT_DATA, m, nthreads) for m in SCALING_LAMBDAS if m != CUT_LAMBDAS])


def core_grid() -> List[Tuple[int, int, int]]:
    return [(CORES_DATA, CORES_LAMBDAS, w) for w in SWEEP_POINTS]


# ----------------------------
# Blob builders
# ----------------------------

def build_bench(statements: Iterable[str]) -> str:
    body = "\n\n".join(s.rstrip() for s in statements)
    return f"{body}\n"


def blob_header(nthreads: int, ndata: int, nlambdas: int, setup: Iterable[str],
                table: Optional[str] = None) -> str:
    head = "--SPLIT\n"
    head += f"-- nthreads={nthreads} ndata={ndata} nlambdas={nlambdas}"
    head += f" table={table}\n" if table else "\n"
    for stmt in setup:
        head += f"{stmt}\n"
    head += "--QUERY\n"
    return head


def sql_width_setup(nthreads: int, force_table: Optional[str] = None) -> List[str]:
    """
    A budget of nthreads processes for a plain-SQL query. The leader participates,
    so that is nthreads-1 workers. The budget alone is only a ceiling: the planner
    derives the degree from the relation's page count (run I's planner chose 4-7
    workers under a cap of 33). With force_table the degree is pinned on that table,
    which bypasses compute_parallel_worker(); no planner cost GUC is changed, so the
    planner still decides whether to go parallel at all -- the runner checks it did.
    """
    w = max(nthreads - 1, 0)
    setup = [f"SET max_parallel_workers_per_gather = {w};"]
    if force_table:
        setup.append(f"ALTER TABLE {force_table} SET (parallel_workers = {w});")
    return setup


def operator_width_setup(nthreads: int) -> List[str]:
    """Our operators take their width from the call; this is the outer query's budget."""
    return [f"SET max_parallel_workers_per_gather = {nthreads if nthreads > 1 else 0};"]


def fol_result_expr(idx: int, x: str = "d.x", y: str = "d.y", z: str = "d.z") -> str:
    """
    Pure-SQL body for lambda `idx`, mirroring HOL:
      g(x,y,z,f) = abs(f(x,y,z)) * 0.9 + f(x,y,z)
      result_i   = (g(x,y,z,f_i) + g(z,y,x,f_i)) / 2
    """
    variant = FOL_VARIANTS[idx % len(FOL_VARIANTS)]
    fwd = variant.format(x=x, y=y, z=z)
    rev = variant.format(x=z, y=y, z=x)
    return (
        f"((abs({fwd}) * 0.9 + ({fwd})) + "
        f"(abs({rev}) * 0.9 + ({rev}))) / 2"
    )


def create_apply_statement(
    top_level_lambda: str,
    data_table: str,
    lambda_table: str,
    scaling_level_data: int,
    scaling_level_lambdas: int,
    nthreads: int,
    udf: str = "apply_mt_pw",
    mode: int = 1,
) -> str:
    """A call to the map operator; mode 1 = L3, the fast path (apply_mt_pw_ext.c)."""
    query = blob_header(nthreads, scaling_level_data, scaling_level_lambdas,
                        operator_width_setup(nthreads))
    query += f"select * from {udf}(\n"
    query += f"    {top_level_lambda},\n"
    query += f"    (select x, y, z from {data_table} where id <= {scaling_level_data}),\n"
    query += f"    (select * from {lambda_table} where id <= {scaling_level_lambdas}),\n"
    query += f"    {nthreads}, {mode});\n"
    return query


def _case_arms(nlambdas: int) -> str:
    return "".join(f"    WHEN {i + 1} THEN {fol_result_expr(i)}\n" for i in range(nlambdas))


def create_case_sql_statement(
    data_table: str,
    scaling_level_data: int,
    scaling_level_lambdas: int,
    nthreads: int,
    force_width: bool = False,
) -> str:
    """The primary baseline: the body is selected by a runtime key, as in HOL."""
    header = blob_header(nthreads, scaling_level_data, scaling_level_lambdas,
                         sql_width_setup(nthreads, data_table if force_width else None),
                         table=data_table)
    body = "SELECT\n  l.lambda_id,\n  d.id AS data_id,\n  (CASE l.lambda_id\n"
    body += _case_arms(scaling_level_lambdas)
    body += f"""  END)::float8 AS result
FROM {data_table} d
CROSS JOIN generate_series(1, {scaling_level_lambdas}) AS l(lambda_id)
WHERE d.id <= {scaling_level_data};"""
    return header + body


def create_case_agg_sql_statement(
    data_table: str,
    scaling_level_data: int,
    scaling_level_lambdas: int,
    nthreads: int,
    force_width: bool = False,
) -> str:
    """
    The CASE baseline reduced to one flat average over all N x M results: the
    counterpart of the aggregating operators, which return a single row.
    """
    header = blob_header(nthreads, scaling_level_data, scaling_level_lambdas,
                         sql_width_setup(nthreads, data_table if force_width else None),
                         table=data_table)
    body = "SELECT avg((CASE l.lambda_id\n"
    body += _case_arms(scaling_level_lambdas)
    body += f"""  END)::float8) AS result
FROM {data_table} d
CROSS JOIN generate_series(1, {scaling_level_lambdas}) AS l(lambda_id)
WHERE d.id <= {scaling_level_data};"""
    return header + body


def create_free_lambda_statement(
    data_table: str,
    lambda_table: str,
    scaling_level_data: int,
    scaling_level_lambdas: int,
    nthreads: int,
    aggregate: bool = False,
    pin_plan: bool = False,
) -> str:
    """
    The stored lambdas called directly in plain SQL, no operator. aggregate=True
    returns the flat average, like apply_mt_agg_pw.

    pin_plan=False leaves the join order to the planner, so either table may be the
    parallel scan and both are named in the header. pin_plan=True writes the plan the
    suite measures: left alone, the planner keeps the join -- and every lambda call --
    in the leader, under a Gather that only parallelises the scans. Pinning nums to
    W-1 workers and lambdas_hol to 0 puts the join under the Gather with nums as the
    partial outer side; the session GUCs that complete it (enable_material=off,
    random_page_cost=1.1) are in benchmark.py, and the runner checks the plan shape on
    every blob.
    """
    if pin_plan:
        setup = sql_width_setup(nthreads, data_table)
        setup.append(f"ALTER TABLE {lambda_table} SET (parallel_workers = 0);")
        # Serially (nthreads=1) the planner puts lambdas_hol outer (lambda-major) unless
        # it may materialise the inner side: with enable_material=on it picks
        # NestLoop(nums, Materialize(lambdas_hol)), data-major like every wider blob.
        # Every other blob turns it back off, so it cannot carry over between blobs.
        setup.append(f"SET enable_material = {'on' if nthreads == 1 else 'off'};")
        header = blob_header(nthreads, scaling_level_data, scaling_level_lambdas,
                             setup, table=data_table)
    else:
        header = blob_header(nthreads, scaling_level_data, scaling_level_lambdas,
                             sql_width_setup(nthreads), table=f"{data_table},{lambda_table}")

    expr = "(l.g(d.x, d.y, d.z, l.f) + l.g(d.z, d.y, d.x, l.f)) / 2"
    where = f"WHERE d.id <= {scaling_level_data} AND l.id <= {scaling_level_lambdas};"

    if aggregate:
        body = f"SELECT avg({expr}) AS result\nFROM {data_table} d, {lambda_table} l\n{where}"
    else:
        body = (f"SELECT\n  l.id AS lambda_id,\n  d.id AS data_id,\n  {expr} AS result\n"
                f"FROM {data_table} d, {lambda_table} l\n{where}")
    return header + body


# ----------------------------
# Emitters
# ----------------------------

def _write(out_dir: str, file_name: str, sql: str, to_stdout: bool) -> None:
    if to_stdout:
        sys.stdout.write(f"\n-- >>> {file_name} >>>\n")
        sys.stdout.write(sql)
        return
    out_path = os.path.join(out_dir, file_name)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(sql)
    print(f"[gen] {out_path} ({len(sql):,} bytes)")


def _apply_file(out_dir: str, to_stdout: bool, file_name: str,
                points: List[Tuple[int, int, int]], udf: str) -> None:
    stmts = [create_apply_statement(
                top_level_lambda=TOP_LEVEL_LAMBDA,
                data_table=DATA_TABLE,
                lambda_table=LAMBDA_TABLE,
                scaling_level_data=d,
                scaling_level_lambdas=m,
                nthreads=w,
                udf=udf,
             ) for d, m, w in points]
    _write(out_dir, file_name, build_bench(stmts), to_stdout)


def _sql_file(out_dir: str, to_stdout: bool, file_name: str,
              points: List[Tuple[int, int, int]], maker) -> None:
    stmts = [maker(data_table=DATA_TABLE, scaling_level_data=d,
                   scaling_level_lambdas=m, nthreads=w, force_width=True)
             for d, m, w in points]
    _write(out_dir, file_name, build_bench(stmts), to_stdout)


def _free_file(out_dir: str, to_stdout: bool, file_name: str,
               points: List[Tuple[int, int, int]], aggregate: bool = False) -> None:
    stmts = [create_free_lambda_statement(
                data_table=DATA_TABLE,
                lambda_table=LAMBDA_TABLE,
                scaling_level_data=d,
                scaling_level_lambdas=m,
                nthreads=w,
                aggregate=aggregate,
                pin_plan=True,
             ) for d, m, w in points]
    _write(out_dir, file_name, build_bench(stmts), to_stdout)


# One file per query text; benchmark.py TYPE_SQL_SOURCE maps each type to its file,
# the JIT settings are the type's session overlay.
#
#   grid slices (cross_grid, 16 blobs, WIDTH), streaming:
#     baseline_case  CASE dispatch
#     hol_pw         apply_mt_pw on L3
#     free_lambda    the stored lambdas called in plain SQL, plan pinned
#   core sweep (core_grid, SWEEP_POINTS), aggregating, one row each:
#     baseline_case_agg_cores  avg(CASE ...)
#     agg_cores_pw             apply_mt_agg_pw on L3
#     free_lambda_agg_cores    avg(free lambda calls), plan pinned
GENERATORS = {
    "baseline_case":   lambda o, s: _sql_file(o, s, "benchmark_baseline_case.sql", cross_grid(),
                                              create_case_sql_statement),
    "hol_pw":          lambda o, s: _apply_file(o, s, "benchmark_hol_pw.sql", cross_grid(), "apply_mt_pw"),
    "free_lambda":     lambda o, s: _free_file(o, s, "benchmark_free_lambda.sql", cross_grid()),
    "baseline_case_agg_cores": lambda o, s: _sql_file(o, s, "benchmark_baseline_case_agg_cores.sql",
                                                      core_grid(), create_case_agg_sql_statement),
    "agg_cores_pw":    lambda o, s: _apply_file(o, s, "benchmark_agg_cores_pw.sql", core_grid(), "apply_mt_agg_pw"),
    "free_lambda_agg_cores": lambda o, s: _free_file(o, s, "benchmark_free_lambda_agg_cores.sql",
                                                     core_grid(), aggregate=True),
}


# ----------------------------
# Script
# ----------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Generate the SQL blobs for the HOL benchmarks and their pure-SQL baselines."
    )
    parser.add_argument("--strategies", nargs="*", default=list(GENERATORS),
                        choices=list(GENERATORS),
                        help="Which benchmark files to generate (default: all).")
    parser.add_argument("--out-dir", default=None,
                        help="Output directory (default: ./benchmarks).")
    parser.add_argument("--stdout", action="store_true",
                        help="Write all SQL to stdout instead of files.")
    args = parser.parse_args()

    out_dir = args.out_dir or os.path.join(os.getcwd(), "benchmarks")
    if not args.stdout:
        os.makedirs(out_dir, exist_ok=True)

    for key in args.strategies:
        GENERATORS[key](out_dir, args.stdout)


if __name__ == "__main__":
    main()
