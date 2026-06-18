#!/usr/bin/env python3
"""
Generate SQL blobs for the K-Means comparison (kmeans_v2 UDF vs pure-SQL
kmeans_sql_iter). Self-contained additional test: writes the two benchmark
files next to this script. Run with run_kmeans_benchmark.py.
"""

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


def create_kmeans_udf_statement(
    ndata: int,
    k: int,
    nthreads_marker: str,
    maxit: int,
    num_cores: int = 17,
) -> str:
    """
    Benchmark statement for the kmeans_v2 UDF.
    num_cores controls CPU pinning; k is stored in the nlambdas CSV column.
    """
    query = "--SPLIT\n"
    query += f"-- {num_cores} {ndata} {k}\n"
    query += (
        f"SELECT * FROM kmeans_v2(\n"
        f"    (SELECT x, y FROM kmeans_points  WHERE id  <= {ndata}),\n"
        f"    (SELECT cx, cy FROM kmeans_centroids WHERE cid <= {k}),\n"
        f"    lambda(p:[px:float8, py:float8], c:[cx:float8, cy:float8])"
        f"((p.px - c.cx)^2 + (p.py - c.cy)^2),\n"
        f"    {nthreads_marker}, {maxit});\n"
    )
    return query


def create_kmeans_sql_statement(
    ndata: int,
    k: int,
    maxit: int,
    num_cores: int = 17,
) -> str:
    """
    Benchmark statement for the pure-SQL (plpgsql) kmeans_sql_iter function.
    """
    query = "--SPLIT\n"
    query += f"-- {num_cores} {ndata} {k}\n"
    query += f"SELECT * FROM kmeans_sql_iter({ndata}, {k}, {maxit});\n"
    return query


# ----------------------------
# Script
# ----------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Generate K-Means benchmark SQL blobs (kmeans_v2 UDF vs pure SQL)."
    )
    parser.add_argument("--stdout", action="store_true", help="Write all SQL to stdout instead of files.")
    args = parser.parse_args()

    out_dir = os.path.dirname(os.path.abspath(__file__))

    KMEANS_MAXIT = 20
    scaling_ndata_km = [10000, 30000, 50000, 80000]
    scaling_k        = [5, 10, 20]

    # --------------- K-MEANS UDF BENCHMARK ----------------
    file_name = "benchmark_kmeans_udf.sql"
    stmts: List[str] = []
    for ndata in scaling_ndata_km:
        for k in scaling_k:
            stmts.append(
                create_kmeans_udf_statement(
                    ndata=ndata,
                    k=k,
                    nthreads_marker="NTHREADS_MARKER",
                    maxit=KMEANS_MAXIT,
                    num_cores=17,
                )
            )
    final_sql = build_bench(stmts)
    if args.stdout:
        sys.stdout.write(f"\n-- >>> {file_name} >>>\n")
        sys.stdout.write(final_sql)
    else:
        with open(os.path.join(out_dir, file_name), "w", encoding="utf-8") as f:
            f.write(final_sql)

    # --------------- K-MEANS SQL BENCHMARK ----------------
    file_name = "benchmark_kmeans_sql.sql"
    stmts = []
    for ndata in scaling_ndata_km:
        for k in scaling_k:
            stmts.append(
                create_kmeans_sql_statement(
                    ndata=ndata,
                    k=k,
                    maxit=KMEANS_MAXIT,
                    num_cores=17,
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
