#!/usr/bin/env python3
"""
Higher-order lambda benchmarks runner
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple

import psycopg
from psycopg.errors import DiskFull, OperationalError


# -------------------------
# Config
# -------------------------

@dataclass(frozen=True)
class RunnerConfig:
    repo_dir: str = "../../hol-lambdas"
    base_port: int = 5433
    dbname: str = "bench"

    # runs
    repeats: int = 10
    warmup_runs: int = 2
    wait_ready_s: float = 60.0

    # CPU topology
    hyperthreading_offset: int = 18
    reserved_core: int = 17
    best_effort_cores: int = 17

    nthreads_marker: str = "NTHREADS_MARKER"

    # file layout
    benchmarks_dir: str = "."
    setup_scripts_dir: str = "."


CFG = RunnerConfig()

SPLIT_MARKER = re.compile(r"^\s*--\s*SPLIT\s*$")


# -------------------------
# PostgreSQL server settings  ←←← EDIT KNOBS HERE
# -------------------------
# Applied cluster-wide as `-c key=value` at server startup (see start_postgres),
# so they actually stick for the measured benchmark connection. This replaces the
# old tune.sql, whose session-level SETs ran in a throwaway psql and never reached
# the benchmark connection.
PG_SETTINGS: Dict[str, str] = {
    # JIT (required: loads the lambda/LLVM dependency)
    "shared_preload_libraries": "llvmjit",

    # Logging
    "log_error_verbosity": "verbose",
    "log_line_prefix": "%m [%p] ",
    "log_temp_files": "0",

    # Durability OFF — benchmark only, never use on real data
    "fsync": "off",
    "synchronous_commit": "off",
    "full_page_writes": "off",

    # Memory / temp
    "work_mem": "2GB",
    "hash_mem_multiplier": "1.0",
    "maintenance_work_mem": "8GB",
    "temp_file_limit": "75GB",

    # Planner
    "plan_cache_mode": "force_custom_plan",

    # Parallel query — lets the pure-SQL baseline parallelise *if the planner chooses
    # to*. apply_mt is PARALLEL UNSAFE, so the HOL side is unaffected. Worker budget
    # matches apply_mt's nthreads (= 2*cores = 34 at full width); size gates dropped so
    # small scaling points can parallelise too; cost knobs (parallel_setup_cost /
    # parallel_tuple_cost) left at defaults → parallelism is enabled, not forced.
    "max_worker_processes": "40",
    "max_parallel_workers": "34",
    "max_parallel_workers_per_gather": "34",
    "min_parallel_table_scan_size": "0",
    "min_parallel_index_scan_size": "0",
}


# -------------------------
# CPU pinning helpers
# -------------------------

def python_cpuset(cfg: RunnerConfig) -> Set[int]:
    return {cfg.reserved_core, cfg.reserved_core + cfg.hyperthreading_offset}


def best_effort_cpuset(cfg: RunnerConfig) -> Set[int]:
    lo = set(range(0, cfg.reserved_core))
    hi = set(range(cfg.hyperthreading_offset, cfg.hyperthreading_offset + cfg.reserved_core))
    return lo | hi


def cpuset_for_physical_cores(cfg: RunnerConfig, num_cores: int) -> Set[int]:
    if num_cores < 1:
        raise ValueError("num_cores must be >= 1")
    if num_cores > cfg.best_effort_cores:
        raise ValueError(
            f"num_cores must be <= {cfg.best_effort_cores} "
            f"(core {cfg.reserved_core} reserved for OS/Python)"
        )
    lo = set(range(0, num_cores))
    hi = set(range(cfg.hyperthreading_offset, cfg.hyperthreading_offset + num_cores))
    return lo | hi


# -------------------------
# Shell / Postgres helpers
# -------------------------

def run(cmd: List[str], *, check: bool = False, stdout=None, stderr=None, text: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, stdout=stdout, stderr=stderr, text=text)


def bin_path(repo: str, exe: str) -> str:
    p = os.path.abspath(os.path.join(repo, "install", "bin", exe))
    if not (os.path.isfile(p) and os.access(p, os.X_OK)):
        raise FileNotFoundError(f"{exe} not found/executable at {p}")
    return p


def psql_args(psql: str, port: int, db: str) -> List[str]:
    return [
        psql, "-X",
        "-h", "127.0.0.1",
        "-p", str(port),
        "-d", db,
        "-v", "ON_ERROR_STOP=1",
        "--set", "VERBOSITY=verbose",
        "--pset", "pager=off",
    ]


def wait_ready(psql: str, port: int, *, db: str = "postgres", timeout: float = CFG.wait_ready_s) -> bool:
    t0 = time.time()
    while time.time() - t0 < timeout:
        r = run(psql_args(psql, port, db) + ["-c", "SELECT 1;"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if r.returncode == 0:
            return True
        time.sleep(0.2)
    return False


def log_tail(path: str, n: int = 250) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return "".join(f.readlines()[-n:])
    except Exception as e:
        return f"[could not read {path}: {e}]"


def parse_postmaster_pid(datadir: str) -> Optional[int]:
    f = os.path.join(datadir, "postmaster.pid")
    if not os.path.isfile(f):
        return None
    try:
        with open(f, "r") as fh:
            s = fh.readline().strip()
            return int(s) if s.isdigit() else None
    except Exception:
        return None


def stop_if_running(datadir: str) -> None:
    pid = parse_postmaster_pid(datadir)
    if pid is None:
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except Exception:
        pass
    for _ in range(200):
        if not os.path.exists(os.path.join(datadir, "postmaster.pid")):
            return
        time.sleep(0.1)
    try:
        os.kill(pid, signal.SIGKILL)
    except Exception:
        pass


def reset_pgdata(initdb_bin: str, datadir: str) -> None:
    stop_if_running(datadir)
    shutil.rmtree(datadir, ignore_errors=True)
    os.makedirs(datadir, exist_ok=True)
    run([initdb_bin, "-D", datadir, "-A", "trust", "-E", "UTF8", "--no-locale"], check=True)


def start_postgres(
    postgres_bin: str,
    datadir: str,
    port: int,
    backend_log_path: str,
    cpu_set: Set[int],
    cfg: RunnerConfig,
) -> Tuple[subprocess.Popen, Any]:
    """
    Start postgres pinned to cpu_set. 
    """
    logfh = open(backend_log_path, "ab")
    cmd = [postgres_bin, "-D", datadir, "-p", str(port)]
    for key, val in PG_SETTINGS.items():
        cmd += ["-c", f"{key}={val}"]

    def preexec():
        os.setsid()
        if hasattr(os, "sched_setaffinity"):
            os.sched_setaffinity(0, cpu_set)

    proc = subprocess.Popen(cmd, stdout=logfh, stderr=subprocess.STDOUT, preexec_fn=preexec)
    return proc, logfh


def stop_postgres(proc: Optional[subprocess.Popen], logfh: Any) -> None:
    try:
        if proc is not None:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            proc.wait(timeout=20)
    except Exception:
        try:
            if proc is not None:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            pass
    try:
        logfh.close()
    except Exception:
        pass


def open_conn(dsn: str) -> psycopg.Connection:
    """
    Connection-level settings that matter for repeatability and to match your benchmark intent.
    """
    conn = psycopg.connect(dsn)
    conn.prepare_threshold = None

    with conn.cursor() as cur:
        cur.execute("SET client_min_messages = warning;")
        cur.execute("SET jit = on;")
        cur.execute("SET plan_cache_mode = force_custom_plan;")
        cur.execute("SET temp_tablespaces = benchtemp;")
        cur.execute("SET synchronous_commit = off;")
        cur.execute("SET extra_float_digits = 3;")
    return conn


# -------------------------
# Benchmark blob parsing
# -------------------------

@dataclass(frozen=True)
class BenchChunk:
    idx: int
    ncores: int
    ndata: int
    nlambdas: int
    nthreads: int
    cpu_set: Set[int]
    sql: str


def parse_chunk_header(line: str) -> Tuple[int, int, int]:
    """
    Header format:  -- <cores> <ndata> <nlambdas>
    """
    s = line.strip()
    if s.startswith("--"):
        s = s[2:].strip()
    parts = s.split()
    if len(parts) != 3:
        raise ValueError(f"Bad --SPLIT header (expected 3 ints): {line!r}")
    a, b, c = (int(parts[0]), int(parts[1]), int(parts[2]))
    return a, b, c


def chunk_resources(cfg: RunnerConfig, a: int) -> Tuple[int, int, Set[int]]:
    """
    Your encoding:
      a <= 0    => 1 core, 1 thread
      a >= best => all best-effort cores, 2 threads/core
      else      => a cores, 2 threads/core (hyperthreads included)
    """
    if a <= 0:
        return 1, 1, {0}
    if a >= cfg.best_effort_cores:
        ncores = cfg.best_effort_cores
        nthreads = 2 * ncores
        return ncores, nthreads, set(best_effort_cpuset(cfg))
    ncores = a
    nthreads = 2 * a
    return ncores, nthreads, cpuset_for_physical_cores(cfg, a)


def split_benchmark_file(path: str, cfg: RunnerConfig) -> List[BenchChunk]:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    chunks: List[BenchChunk] = []
    i = 0
    blob_idx = 0

    while i < len(lines):
        if not SPLIT_MARKER.match(lines[i]):
            i += 1
            continue

        i += 1
        if i >= len(lines):
            raise ValueError(f"{path}: --SPLIT at EOF without header")
        header_line = lines[i]
        i += 1

        a, ndata, nlambdas = parse_chunk_header(header_line)
        ncores, nthreads, cpu_set = chunk_resources(cfg, a)

        buf: List[str] = []
        while i < len(lines) and not SPLIT_MARKER.match(lines[i]):
            buf.append(lines[i])
            i += 1

        sql = "".join(buf).strip()
        if not sql:
            raise ValueError(f"{path}: empty SQL blob after header {header_line!r}")

        sql = sql.rstrip().rstrip(";")

        if cfg.nthreads_marker in sql:
            sql = sql.replace(cfg.nthreads_marker, str(nthreads))

        blob_idx += 1
        chunks.append(BenchChunk(
            idx=blob_idx,
            ncores=ncores,
            ndata=ndata,
            nlambdas=nlambdas,
            nthreads=nthreads,
            cpu_set=cpu_set,
            sql=sql,
        ))

    if not chunks:
        raise ValueError(f"{path}: no --SPLIT blobs found")

    return chunks


# -------------------------
# Timing
# -------------------------

def run_explain(conn: psycopg.Connection, sql: str, fe) -> Tuple[float, float, Optional[dict]]:
    """
    Returns:
      (server_execution_ms_from_explain, client_roundtrip_ms, jit_section_or_none)
    """
    q = f"EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) {sql};"
    with conn.cursor() as cur:
        t0 = time.perf_counter()
        cur.execute(q, prepare=False)
        row = cur.fetchone()
        t1 = time.perf_counter()

    rt_ms = (t1 - t0) * 1000.0
    plan = row[0] if row else None

    if isinstance(plan, str):
        try:
            plan_obj = json.loads(plan)
        except Exception:
            plan_obj = None
        payload = plan
    else:
        plan_obj = plan
        try:
            payload = json.dumps(plan_obj, indent=2)
        except Exception:
            payload = str(plan_obj)

    try:
        fe.write("\n[EXPLAIN JSON BEGIN]\n")
        fe.write(payload)
        if not payload.endswith("\n"):
            fe.write("\n")
        fe.write("[EXPLAIN JSON END]\n")
        fe.flush()
    except Exception:
        pass

    root = (plan_obj or [{}])[0]
    return float(root.get("Execution Time", 0.0)), rt_ms, root.get("JIT")


def extract_jit_timing(jit_info: Optional[dict]) -> Tuple[float, float, float, float, float]:
    """
    Pull the five JIT timing fields (all in ms) out of the JIT section returned
    by EXPLAIN ANALYZE FORMAT JSON.  Returns NaN for each missing field so CSV
    consumers can distinguish "JIT ran but field missing" from "JIT did not run".
    """
    nan = float("nan")
    if not jit_info:
        return nan, nan, nan, nan, nan
    timing = jit_info.get("Timing", {}) if isinstance(jit_info, dict) else {}
    return (
        float(timing.get("Generation",  nan)),
        float(timing.get("Inlining",    nan)),
        float(timing.get("Optimization",nan)),
        float(timing.get("Emission",    nan)),
        float(timing.get("Total",       nan)),
    )


# -------------------------
# Benchmark execution
# -------------------------

def required_paths(cfg: RunnerConfig, type_: str) -> Tuple[str, str]:
    setup_sql = os.path.join(cfg.setup_scripts_dir, "setup_usecase.sql")

    if type_ == "usecase_map":
        bench_sql = os.path.join(cfg.benchmarks_dir, "benchmark_usecase_map.sql")
    elif type_ == "usecase_sql":
        bench_sql = os.path.join(cfg.benchmarks_dir, "benchmark_usecase_sql.sql")
    else:
        raise ValueError(f"Unknown type {type_!r} (expected usecase_map|usecase_sql)")

    for p in (setup_sql, bench_sql):
        if not os.path.isfile(p):
            raise FileNotFoundError(f"Missing required file: {p}")

    return setup_sql, bench_sql


def benchmark_repo_test(
    cfg: RunnerConfig,
    type_: str,
    port: int,
    blob_index: Optional[int],
    bench_root: str,
    result_root: str,
    repeats: int,
) -> None:
    repo = cfg.repo_dir
    name = os.path.basename(os.path.abspath(repo))

    postgres = bin_path(repo, "postgres")
    initdb = bin_path(repo, "initdb")
    psql = bin_path(repo, "psql")

    base = os.path.abspath(repo)
    datadir = os.path.join(base, "pgdata")
    tempdir = os.path.join(base, "pgdata-temp")

    backend_log = os.path.join(bench_root, f"backend_{type_}.log")
    frontend_log = os.path.join(bench_root, f"frontend_{type_}.log")

    setup_sql, bench_sql = required_paths(cfg, type_)

    chunks = split_benchmark_file(bench_sql, cfg)

    current_cpu_set: Set[int] = set(best_effort_cpuset(cfg))

    dsn = f"host=127.0.0.1 port={port} dbname={cfg.dbname}"

    with open(frontend_log, "w", buffering=1, encoding="utf-8") as fe:
        proc: Optional[subprocess.Popen] = None
        logfh: Any = None
        conn: Optional[psycopg.Connection] = None

        try:
            print(f"[setup] {name}:{type_} — reset cluster")
            reset_pgdata(initdb, datadir)

            proc, logfh = start_postgres(postgres, datadir, port, backend_log, current_cpu_set, cfg)
            print(f"[start] {name}:{type_} — backend launched (port {port})")

            if not wait_ready(psql, port, db="postgres", timeout=cfg.wait_ready_s):
                fe.write("\n--- backend log (tail) ---\n")
                fe.write(log_tail(backend_log) + "\n")
                raise RuntimeError("server did not become ready")

            shutil.rmtree(tempdir, ignore_errors=True)
            os.makedirs(tempdir, exist_ok=True)

            # Create DB + tablespace
            run(psql_args(psql, port, "postgres") + ["-c", f"CREATE DATABASE {cfg.dbname};"],
                check=True, stdout=fe, stderr=fe)
            run(psql_args(psql, port, cfg.dbname) + ["-c", "DROP TABLESPACE IF EXISTS benchtemp;"],
                check=True, stdout=fe, stderr=fe)
            run(psql_args(psql, port, cfg.dbname) + ["-c", f"CREATE TABLESPACE benchtemp LOCATION '{tempdir}';"],
                check=True, stdout=fe, stderr=fe)
            print(f"[init ] {name}:{type_} — database+tablespace ready")

            # Apply setup once per fresh cluster (server GUCs come from PG_SETTINGS)
            run(psql_args(psql, port, cfg.dbname) + ["-f", setup_sql], check=True, stdout=fe, stderr=fe)
            print(f"[setup] {name}:{type_} — {os.path.basename(setup_sql)} applied")

            # (Important for repeatability) make sure planner stats are stable.
            # If setup.sql already ANALYZEs, this is cheap; if it doesn’t, it fixes plan wobble.
            run(psql_args(psql, port, cfg.dbname) + ["-c", "ANALYZE;"], check=True, stdout=fe, stderr=fe)

            os.makedirs(result_root, exist_ok=True)
            csv_path = os.path.join(result_root, f"{name}_{type_}.csv")

            with open(csv_path, "w", newline="", encoding="utf-8") as out_fh:
                writer = csv.writer(out_fh)
                writer.writerow([
                    "repo", "type",
                    "blob",
                    "ncores", "ndata", "nlambdas", "nthreads",
                    "run_kind",  # warmup|measure
                    "server_ms", "roundtrip_ms",
                    "jit_generation_ms", "jit_inlining_ms",
                    "jit_optimization_ms", "jit_emission_ms", "jit_total_ms",
                ])

                conn = open_conn(dsn)

                for ch in chunks:
                    if blob_index is not None and ch.idx != blob_index:
                        continue

                    # If CPU pinning changes, restart postgres to re-pin reliably.
                    if ch.cpu_set != current_cpu_set:
                        print(f"[pin  ] {name}:{type_} blob {ch.idx} — restart Postgres for CPU pinning")
                        try:
                            if conn is not None:
                                conn.close()
                        except Exception:
                            pass
                        conn = None

                        stop_postgres(proc, logfh)
                        proc, logfh = start_postgres(postgres, datadir, port, backend_log, ch.cpu_set, cfg)
                        current_cpu_set = set(ch.cpu_set)

                        if not wait_ready(psql, port, db="postgres", timeout=cfg.wait_ready_s):
                            fe.write("\n--- backend log (tail) ---\n")
                            fe.write(log_tail(backend_log) + "\n")
                            raise RuntimeError("server did not become ready after restart")

                        conn = open_conn(dsn)

                    print(
                        f"[run  ] {name}:{type_} blob {ch.idx} "
                        f"cores={ch.ncores} data={ch.ndata} lambdas={ch.nlambdas} threads={ch.nthreads}"
                    )

                    server_times: List[float] = []
                    rt_times: List[float] = []

                    try:
                        total = repeats + cfg.warmup_runs
                        for run_i in range(1, total + 1):
                            server_ms, rt_ms, jit_info = run_explain(conn, ch.sql, fe)

                            kind = "warmup" if run_i <= cfg.warmup_runs else "measure"

                            if kind == "measure":
                                server_times.append(server_ms)
                                rt_times.append(rt_ms)

                            jit_gen, jit_inl, jit_opt, jit_emi, jit_tot = extract_jit_timing(jit_info)

                            # record every run (so you can debug warmups too)
                            writer.writerow([
                                name, type_,
                                ch.idx,
                                ch.ncores, ch.ndata, ch.nlambdas, ch.nthreads,
                                kind,
                                f"{server_ms:.3f}", f"{rt_ms:.3f}",
                                f"{jit_gen:.3f}", f"{jit_inl:.3f}",
                                f"{jit_opt:.3f}", f"{jit_emi:.3f}", f"{jit_tot:.3f}",
                            ])

                            if kind == "warmup":
                                print(f"[warm] {name}:{type_} blob {ch.idx} run {run_i} (ignored)")
                            else:
                                print(f"[meas] {name}:{type_} blob {ch.idx} run {run_i} server={server_ms:.3f}ms rt={rt_ms:.3f}ms jit={jit_tot:.1f}ms")

                    except DiskFull:
                        fe.write("\n--- backend log (tail) ---\n")
                        fe.write(log_tail(backend_log) + "\n")
                        fe.write(f"[error] ENOSPC at blob {ch.idx} (cores={ch.ncores} data={ch.ndata} lambdas={ch.nlambdas})\n")
                        fe.flush()
                        print(f"[error] {name}:{type_} ENOSPC at blob {ch.idx} — see frontend log")
                        break

                    except OperationalError as e:
                        fe.write("\n--- backend log (tail) ---\n")
                        fe.write(log_tail(backend_log) + "\n")
                        fe.write(f"[fail ] OperationalError at blob {ch.idx}: {e}\n")
                        fe.flush()
                        raise

                    med_server = statistics.median(server_times) if server_times else float("nan")
                    med_rt = statistics.median(rt_times) if rt_times else float("nan")

                    print(f"[done ] {name}:{type_} blob {ch.idx} — median server={med_server:.3f}ms, median rt={med_rt:.3f}ms")
                    fe.write(f"[done ] blob {ch.idx} — median server={med_server:.3f}ms, median rt={med_rt:.3f}ms\n")
                    fe.flush()

            print(f"[save ] {name}:{type_} → {csv_path}")
            fe.write(f"[save ] → {csv_path}\n")
            fe.flush()

            # Cleanup: drop objects to keep logs tidy
            run(psql_args(psql, port, "postgres") + ["-c", f"DROP DATABASE IF EXISTS {cfg.dbname} WITH (FORCE);"],
                check=True, stdout=fe, stderr=fe)
            run(psql_args(psql, port, "postgres") + ["-c", "DROP TABLESPACE IF EXISTS benchtemp;"],
                check=True, stdout=fe, stderr=fe)

        except Exception as e:
            print(f"[fail ] {name}:{type_} — {e}")
            raise
        finally:
            try:
                if conn is not None:
                    conn.close()
            except Exception:
                pass
            try:
                stop_postgres(proc, logfh)
            except Exception:
                pass
            shutil.rmtree(tempdir, ignore_errors=True)
            shutil.rmtree(datadir, ignore_errors=True)
            os.makedirs(datadir, exist_ok=True)


# -------------------------
# Main
# -------------------------

def main() -> None:
    # pin python first (as you did before) :contentReference[oaicite:3]{index=3}
    if hasattr(os, "sched_setaffinity"):
        os.sched_setaffinity(0, python_cpuset(CFG))

    ap = argparse.ArgumentParser(description="Run HOL benchmarks in fresh clusters.")
    ap.add_argument("--blob", type=int, default=None,
                    help="Run only the N-th --SPLIT blob (1-based). Default: all.")
    ap.add_argument("-r", "--repeats", type=int, default=CFG.repeats,
                    help=f"How many measured runs per blob? (default {CFG.repeats})")
    ap.add_argument("--types", nargs="*", default=["usecase_map", "usecase_sql"],
                    help="Which benchmark sets to run: usecase_map usecase_sql (default: all)")
    ap.add_argument("--port", type=int, default=CFG.base_port,
                    help=f"Base port to use (default {CFG.base_port})")
    args = ap.parse_args()

    if not os.path.isdir(CFG.repo_dir):
        print(f"Missing repo dir: {CFG.repo_dir}", file=sys.stderr)
        sys.exit(1)

    os.makedirs("bench_logs", exist_ok=True)
    os.makedirs("results", exist_ok=True)

    run_id = time.strftime("bench_%Y%m%d_%H%M%S")
    bench_root = os.path.join("bench_logs", run_id)
    result_root = os.path.join("results", run_id)
    os.makedirs(bench_root, exist_ok=True)
    os.makedirs(result_root, exist_ok=True)

    print(f"[bench] logs:    {bench_root}")
    print(f"[bench] results: {result_root}")

    t0 = time.perf_counter()
    for type_ in args.types:
        benchmark_repo_test(
            CFG,
            type_=type_,
            port=args.port,
            blob_index=args.blob,
            bench_root=bench_root,
            result_root=result_root,
            repeats=args.repeats,
        )

    t1 = time.perf_counter()
    print(f"[bench] Total Runtime: {(t1 - t0) * 1000.0:.1f} ms")


if __name__ == "__main__":
    main()
