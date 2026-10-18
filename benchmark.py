#!/usr/bin/env python3
"""
Runner for the paper's benchmark suite: the grid slices and the core sweep
(combined_scaling), each type in a fresh, CPU-pinned cluster. The use case has its
own runner (run_usecase_benchmark.py) on the same machinery.

    python3 generate_benchmarks.py           # writes benchmarks/*.sql
    python3 benchmark.py                     # the paper's run: 6 types, -r 20, round robin
    python3 benchmark.py --blob 1 -r 1       # smoke
    python3 benchmark.py --topology local    # on a machine with fewer than 36 CPUs

Results go to results/bench_<stamp>/ (one CSV + conditions_<type>.jsonl per type,
PROVENANCE.md), logs to bench_logs/bench_<stamp>/.
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
import threading
import subprocess
import sys
import time
from dataclasses import dataclass, replace
from typing import Any, Dict, List, Optional, Set, Tuple

import psycopg
from psycopg.errors import DiskFull


# -------------------------
# Config
# -------------------------

@dataclass(frozen=True)
class RunnerConfig:
    repo_dir: str = "hol-lambdas"
    base_port: int = 5433
    dbname: str = "bench"

    # runs: the paper's protocol, 2 warmups + 20 measured runs per blob, 1 untimed
    # verify run. Figures read the per-blob minimum (server_ms_min): the host's CPU
    # clock switches between turbo and base, so repeat times are bimodal.
    repeats: int = 20
    repeats_cores: int = 20
    warmup_runs: int = 2
    # Measured runs in rounds over all blobs of a type instead of back to back per
    # blob, so a stretch of base clock is spread over all blobs instead of covering one.
    round_robin: bool = True
    wait_ready_s: float = 60.0

    # CPU topology: physical cores, each with its HT sibling at +hyperthreading_offset.
    # The driver (this script and its sampler) gets driver_cores; postgres gets the
    # pg_ncores physical cores from pg_first_core on, for every blob of every type.
    hyperthreading_offset: int = 18
    driver_cores: Tuple[int, ...] = (0, 1)
    pg_first_core: int = 2
    pg_ncores: int = 16
    # allow blobs wider than postgres' cpuset (smoke tests on small machines only)
    oversubscribe: bool = False

    # file layout
    benchmarks_dir: str = "benchmarks"
    setup_scripts_dir: str = "setup-scripts"


CFG = RunnerConfig()

SPLIT_MARKER = re.compile(r"^\s*--\s*SPLIT\s*$")

# CPU topologies. "server" is the paper's machine: 36 CPUs = 18 physical cores with
# the HT sibling at +18; postgres gets cores 2-17 (logical 2-17, 20-35), the driver
# cores 0 and 1 (0, 1, 18, 19). "local" fits a 12-CPU machine and runs the 16-wide
# blobs oversubscribed, for smoke tests only: its timings mean nothing.
#
# Pinning is only a fence, not a width control: every blob carries its own width in
# its SQL (thread argument, max_parallel_workers_per_gather, parallel_workers), so the
# cpuset is the same for every blob and postgres is never restarted to change it.
TOPOLOGIES: Dict[str, Dict[str, Any]] = {
    "server": {"hyperthreading_offset": 18, "driver_cores": (0, 1), "pg_first_core": 2, "pg_ncores": 16},
    "local":  {"hyperthreading_offset": 6,  "driver_cores": (5,),   "pg_first_core": 0, "pg_ncores": 5,
               "oversubscribe": True},
}

# Benchmark types: exactly the paper's. Every blob runs at generate_benchmarks.WIDTH
# = 16 processes on both sides, forced (the core sweep runs SWEEP_POINTS).
#
#   grid slices (combined_scaling a/c), streaming N x M rows:
#     baseline_case_jitoff     CASE dispatch, JIT off
#     free_lambda_jitoff       stored lambdas called in plain SQL, JIT off, plan pinned
#                              so the calls run in the workers (FREE_PLAN)
#     hol_pw_jitnoopt          the map operator (apply_mt_pw) on L3, lambdas compiled
#                              without optimisation and inlining
#   core sweep (combined_scaling b), the same three as one aggregated row each:
#     baseline_case_agg_cores_jitoff, free_lambda_agg_cores_jitoff, agg_cores_pw_jitnoopt
#   use case (usecase_benchmark), aggregated, run by run_usecase_benchmark.py:
#     usecase_case_jitoff, usecase_map_pw_jitnoopt
GRID_TYPES = ["baseline_case_jitoff", "free_lambda_jitoff", "hol_pw_jitnoopt"]
CORE_TYPES = ["baseline_case_agg_cores_jitoff", "free_lambda_agg_cores_jitoff",
              "agg_cores_pw_jitnoopt"]
USECASE_TYPES = ["usecase_case_jitoff", "usecase_map_pw_jitnoopt"]
DEFAULT_TYPES = GRID_TYPES + CORE_TYPES
ALL_TYPES = DEFAULT_TYPES + USECASE_TYPES

# The generated query file of each type: benchmarks/benchmark_<source>.sql
TYPE_SQL_SOURCE: Dict[str, str] = {
    "baseline_case_jitoff": "baseline_case",
    "free_lambda_jitoff": "free_lambda",
    "hol_pw_jitnoopt": "hol_pw",
    "baseline_case_agg_cores_jitoff": "baseline_case_agg_cores",
    "free_lambda_agg_cores_jitoff": "free_lambda_agg_cores",
    "agg_cores_pw_jitnoopt": "agg_cores_pw",
    "usecase_case_jitoff": "usecase_case",
    "usecase_map_pw_jitnoopt": "usecase_map_pw",
}

# Ordinary-SQL types: parallelism comes from a Gather and the leader participates, so a
# blob of width W asks for W-1 workers (generate_benchmarks.py sql_width_setup).
FREE_TYPES = [t for t in ALL_TYPES if t.startswith("free_lambda")]
SQL_TYPES = [t for t in ALL_TYPES if t.startswith(("baseline_case", "usecase_case"))] + FREE_TYPES

# Types that run on parallel workers launched by our own operator (apply_mt_pw /
# apply_mt_agg_pw). Their workers never appear in the plan; the operator's own
# shortfall WARNING and pg_stat_activity are what see them.
PW_TYPES = [t for t in ALL_TYPES if t not in SQL_TYPES]

# Core sweeps: swept over the width at one (N, M).
CORE_SWEEP_TYPES = CORE_TYPES

# Session overlays. -1 means "never" for the three jit_*_above_cost knobs.
JIT_OFF = {"jit": "off"}
# The pw operators compile their lambdas themselves (jit_force_compile_expr needs only
# jit=on), with the outer query's JIT flags; jit_above_cost=1e10 keeps the outer query
# uncompiled, so the lambdas compile unoptimised and uninlined.
PW_NOOPT = {"jit": "on", "jit_above_cost": "1e10",
            "jit_optimize_above_cost": "-1", "jit_inline_above_cost": "-1"}
# The free-lambda plan, together with the blob's setup lines (nums at W-1 workers,
# lambdas_hol at 0). enable_material=off keeps the join a plain nested loop under the
# Gather. random_page_cost=1.1 (cached data) stops the planner from preferring
# NestLoop(lambdas_hol, Gather(nums)) at small M, which puts every call in the leader.
# Planner costs only; the runner checks the shape on every blob (check_free_plan).
FREE_PLAN = {"enable_material": "off", "random_page_cost": "1.1"}

TYPE_SESSION_SETTINGS: Dict[str, Dict[str, str]] = {
    "baseline_case_jitoff": JIT_OFF,
    "free_lambda_jitoff": {**FREE_PLAN, **JIT_OFF},
    "hol_pw_jitnoopt": PW_NOOPT,
    "baseline_case_agg_cores_jitoff": JIT_OFF,
    "free_lambda_agg_cores_jitoff": {**FREE_PLAN, **JIT_OFF},
    "agg_cores_pw_jitnoopt": PW_NOOPT,
    "usecase_case_jitoff": JIT_OFF,
    "usecase_map_pw_jitnoopt": PW_NOOPT,
}

# One line per type for the provenance file and the conditions records.
CONTENDER: Dict[str, str] = {
    "baseline_case_jitoff": "CASE, JIT off",
    "free_lambda_jitoff": "free lambdas, JIT off, plan pinned",
    "hol_pw_jitnoopt": "apply_mt_pw L3 (mode 1), no optimise, no inline",
    "baseline_case_agg_cores_jitoff": "avg(CASE), JIT off",
    "free_lambda_agg_cores_jitoff": "avg(free lambdas), JIT off, plan pinned",
    "agg_cores_pw_jitnoopt": "apply_mt_agg_pw L3 (mode 1), no optimise, no inline",
    "usecase_case_jitoff": "avg(CASE), JIT off",
    "usecase_map_pw_jitnoopt": "apply_mt_agg_pw L3 (mode 1), no optimise, no inline",
}


# -------------------------
# PostgreSQL server settings  <-- EDIT KNOBS HERE
# -------------------------
# Applied cluster-wide as `-c key=value` at server startup (see start_postgres)
PG_SETTINGS: Dict[str, str] = {
    # JIT (required: loads the lambda/LLVM dependency)
    "shared_preload_libraries": "llvmjit",

    # Logging
    "log_error_verbosity": "verbose",
    "log_line_prefix": "%m [%p] ",
    "log_temp_files": "0",

    # Autovacuum OFF. The tables are built once per type and never updated while
    # measuring, so there is nothing for it to do except take CPU from the pinned
    # cpuset the postmaster (and therefore every autovacuum worker) is bound to,
    # and re-run autoanalyze mid-blob, which moves plans out from under the
    # explicit ANALYZE done right after setup.
    "autovacuum": "off",

    # Durability OFF 
    "fsync": "off",
    "synchronous_commit": "off",
    "full_page_writes": "off",

    # Memory / temp
    # The operator's output tuplestore is sized by work_mem, so this decides whether
    # the largest slice point spills. 8GB covers 80,000 x 350 = 28M output rows
    # (1.3-1.8 GB at 48-64 B per tuple) with room to spare.
    #
    # work_mem is per node per worker, not a global budget -- PostgreSQL has no
    # such GUC. A 33-worker Gather that sorts or hashes could in principle reach
    # 33 x 8GB. It does not here: every plan in the suite is projection + avg with
    # no Sort or HashAggregate node. Re-check this if a plan ever grows one.
    "work_mem": "8GB",
    "hash_mem_multiplier": "1.0",
    "maintenance_work_mem": "8GB",
    # DSM segments come out of this area, reserved at startup, instead of being created
    # (zero-filled) and unmapped per query. The pw operators' result tuples live in one
    # (N x M x 48 B, 1.3 GB at 80,000 x 350), which saves them about a quarter.
    # Cluster-wide, so the SQL types get it too.
    "min_dynamic_shared_memory": "4GB",
    # Shared root fs with ~23 GB free; spill must fail as a query error, not fill the
    # disk. 6GB was the old value and did not actually protect anything: the limit is
    # PER PROCESS, so a 33-worker Gather could reach ~200 GB. Nothing in the suite
    # spills at all -- no plan here has a Sort or HashAggregate node -- so 1GB is
    # still ~1000x any legitimate need and fails a runaway almost immediately.
    "temp_file_limit": "1GB",

    # Safety net for an unattended multi-hour run: a hung query must become a logged
    # error, not a lost night. The slowest point of the suite takes about 9 s (the
    # serial free-lambda point of the core sweep), so 300 s still catches a hang
    # inside five minutes.
    #
    # Do NOT add idle_in_transaction_session_timeout here. The runner holds one
    # open transaction for the whole blob (autocommit is off) and is idle in it
    # between the 13 runs, so any such timeout would kill the connection mid-blob.
    "statement_timeout": "300s",
    "lock_timeout": "30s",

    # Planner
    "plan_cache_mode": "force_custom_plan",

    # Free-lambda body cache (lambda_cache.c). One entry per lambda combination per
    # call site; a query over M stored lambdas builds about 2M combinations, so 1000
    # holds the largest grid point (M=350). Bodies are JIT-compiled as soon as they
    # are built (0) whenever the query is JIT-compiled; open_conn sets -1 (never)
    # for sessions with jit=off.
    "custom_lambda_cache_size": "1000",
    "custom_lambda_jit_after_uses": "0",

    # Parallel query 
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
    """The driver's physical cores and their HT siblings."""
    return {c + k for c in cfg.driver_cores for k in (0, cfg.hyperthreading_offset)}


def postgres_cpuset(cfg: RunnerConfig) -> Set[int]:
    """Every CPU postgres may use: pg_ncores physical cores and their HT siblings."""
    cores = range(cfg.pg_first_core, cfg.pg_first_core + cfg.pg_ncores)
    return {c + k for c in cores for k in (0, cfg.hyperthreading_offset)}


def check_topology(cfg: RunnerConfig, ncpu: int) -> None:
    """
    Refuse a layout where the driver and postgres overlap (that would contaminate
    every measurement silently) or that names CPUs this machine does not have.
    """
    drv, pg = python_cpuset(cfg), postgres_cpuset(cfg)
    if drv & pg:
        raise ValueError(f"driver and postgres share CPUs {sorted(drv & pg)}")
    missing = sorted(c for c in drv | pg if c >= ncpu)
    if missing:
        raise ValueError(f"CPUs {missing} do not exist (machine has {ncpu})")


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


def open_conn(dsn: str, extra_settings: Optional[Dict[str, str]] = None,
              notices: Optional[List[str]] = None) -> psycopg.Connection:
    """
    Connection-level settings that matter for repeatability and to match your benchmark intent.

    `extra_settings` is the per-type overlay from TYPE_SESSION_SETTINGS. It is applied
    last so a type can override a default (notably `jit`). `notices`, if given,
    collects every server notice/warning as "SEVERITY: message".
    """
    conn = psycopg.connect(dsn)
    conn.prepare_threshold = None
    if notices is not None:
        conn.add_notice_handler(
            lambda d: notices.append(f"{d.severity}: {d.message_primary}"))

    with conn.cursor() as cur:
        cur.execute("SET client_min_messages = warning;")
        cur.execute("SET jit = on;")
        cur.execute("SET plan_cache_mode = force_custom_plan;")
        cur.execute("SET temp_tablespaces = benchtemp;")
        cur.execute("SET synchronous_commit = off;")
        cur.execute("SET extra_float_digits = 3;")
        for key, value in with_lambda_cache_jit(extra_settings or {}).items():
            cur.execute(f"SET {key} = {value};")
    return conn


def with_lambda_cache_jit(settings: Dict[str, str]) -> Dict[str, str]:
    """
    A session overlay plus custom_lambda_jit_after_uses = -1 (never) when it turns
    jit off: cached lambda bodies are interpreted then anyway. With jit on, the
    cluster default from PG_SETTINGS (0, compile at build) applies.
    """
    if settings.get("jit") == "off" and "custom_lambda_jit_after_uses" not in settings:
        return {**settings, "custom_lambda_jit_after_uses": "-1"}
    return settings


# -------------------------
# Benchmark blob parsing
# -------------------------

@dataclass(frozen=True)
class BenchChunk:
    idx: int
    ncores: int             # physical cores postgres may use (the same for every blob)
    ndata: int
    nlambdas: int
    nthreads: int           # the width the blob's SQL asks for
    tables: Tuple[str, ...] # SQL types: the tables a parallel scan may run over
    setup: Tuple[str, ...]  # run once per blob, untimed, before the warmups
    sql: str                # the timed statement


QUERY_MARKER = re.compile(r"^\s*--\s*QUERY\s*$")


def parse_chunk_header(line: str) -> Tuple[int, int, int, Tuple[str, ...]]:
    """
    Header format:  -- nthreads=<W> ndata=<N> nlambdas=<M> [table=<name>[,<name>...]]

    The old positional form (-- <cores> <ndata> <nlambdas>) meant a core count the
    runner turned into a cpuset and 2x threads. It is rejected rather than guessed
    at, so a stale benchmarks/ directory fails loudly instead of running at the
    wrong width.
    """
    s = line.strip()
    if s.startswith("--"):
        s = s[2:].strip()
    fields = dict(p.split("=", 1) for p in s.split() if "=" in p)
    try:
        tables = tuple(t for t in fields.get("table", "").split(",") if t)
        return int(fields["nthreads"]), int(fields["ndata"]), int(fields["nlambdas"]), tables
    except (KeyError, ValueError):
        raise ValueError(f"Bad --SPLIT header {line!r}: expected "
                         f"'-- nthreads=<W> ndata=<N> nlambdas=<M>'. "
                         f"Regenerate with generate_benchmarks.py.") from None


def split_benchmark_file(path: str, cfg: RunnerConfig) -> List[BenchChunk]:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    chunks: List[BenchChunk] = []
    i = 0
    blob_idx = 0
    pg_cpus = len(postgres_cpuset(cfg))

    while i < len(lines):
        if not SPLIT_MARKER.match(lines[i]):
            i += 1
            continue

        i += 1
        if i >= len(lines):
            raise ValueError(f"{path}: --SPLIT at EOF without header")
        header_line = lines[i]
        i += 1

        nthreads, ndata, nlambdas, tables = parse_chunk_header(header_line)
        if nthreads < 1 or (nthreads > pg_cpus and not cfg.oversubscribe):
            raise ValueError(f"{path}: blob asks for {nthreads} threads, postgres has "
                             f"{pg_cpus} CPUs: {header_line!r}")

        buf: List[str] = []
        while i < len(lines) and not SPLIT_MARKER.match(lines[i]):
            buf.append(lines[i])
            i += 1

        # setup lines up to --QUERY, one statement per line; the timed SQL after it
        q = next((k for k, l in enumerate(buf) if QUERY_MARKER.match(l)), None)
        if q is None:
            raise ValueError(f"{path}: blob {header_line.strip()!r} has no --QUERY line. "
                             f"Regenerate with generate_benchmarks.py.")
        setup = tuple(l.strip() for l in buf[:q]
                      if l.strip() and not l.strip().startswith("--"))

        sql = "".join(buf[q + 1:]).strip()
        if not sql:
            raise ValueError(f"{path}: empty SQL blob after header {header_line!r}")
        if "NTHREADS_MARKER" in sql:
            raise ValueError(f"{path}: NTHREADS_MARKER left in blob {header_line.strip()!r}; "
                             f"the width must be written into the SQL. Regenerate.")

        sql = sql.rstrip().rstrip(";")

        blob_idx += 1
        chunks.append(BenchChunk(
            idx=blob_idx,
            ncores=cfg.pg_ncores,
            ndata=ndata,
            nlambdas=nlambdas,
            nthreads=nthreads,
            tables=tables,
            setup=setup,
            sql=sql,
        ))

    if not chunks:
        raise ValueError(f"{path}: no --SPLIT blobs found")

    return chunks


# -------------------------
# Timing
# -------------------------

def plan_worker_counts(plan_obj) -> Tuple[int, int]:
    """
    (workers_planned, workers_launched) summed over every Gather / Gather Merge
    in the plan, or (0, 0) when the plan has none.

    Only meaningful for types whose parallelism comes from PostgreSQL. Our own
    operators launch their workers inside the UDF, so their plan is serial and
    this is 0 for them by construction -- that is what the verification run and
    sample_worker_peak() are for.
    """
    planned = launched = 0

    def walk(node):
        nonlocal planned, launched
        if node.get("Node Type") in ("Gather", "Gather Merge"):
            planned += int(node.get("Workers Planned", 0) or 0)
            launched += int(node.get("Workers Launched", 0) or 0)
        for child in node.get("Plans", []) or []:
            walk(child)

    try:
        walk((plan_obj or [{}])[0]["Plan"])
    except (KeyError, IndexError, TypeError):
        return 0, 0
    return planned, launched


class WorkerSampler:
    """
    Polls pg_stat_activity on a side connection for the peak number of backends
    whose leader is our benchmark backend, i.e. how many worker processes the
    query ACTUALLY got.

    This exists because neither of the two things we already record proves it:
    the plan only shows workers PostgreSQL launched through a Gather (nothing for
    apply_mt_pw), and `nthreads` is only what the blob's SQL asks for.

    Only used on the verification run, never during a timed one -- the sampler is
    another backend inside the same cpuset, and a core sweep is exactly the
    measurement that would notice.
    """

    def __init__(self, dsn: str, leader_pid: int, interval_s: float = 0.002):
        self.dsn = dsn
        self.leader_pid = leader_pid
        self.interval_s = interval_s
        self.peak = 0
        self.error: Optional[str] = None
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def _loop(self) -> None:
        try:
            with psycopg.connect(self.dsn, autocommit=True) as conn:
                with conn.cursor() as cur:
                    while not self._stop.is_set():
                        cur.execute(
                            "SELECT count(*) FROM pg_stat_activity WHERE leader_pid = %s",
                            (self.leader_pid,),
                        )
                        row = cur.fetchone()
                        if row and row[0] > self.peak:
                            self.peak = int(row[0])
                        self._stop.wait(self.interval_s)
        except Exception as exc:            # never let sampling break a run
            self.error = str(exc)

    def __enter__(self) -> "WorkerSampler":
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5.0)


def expected_worker_procs(type_: str, ch: "BenchChunk") -> Tuple[int, str]:
    """
    (expected worker processes, human-readable reason)

    The convention the whole suite is calibrated on: every type ends up with
    ch.nthreads processes doing work.
      - SQL types get nthreads-1 workers, because the leader participates.
      - pw types get nthreads workers and an idle leader.
    """
    if type_ in SQL_TYPES:
        if ch.nthreads <= 1:
            return 0, "serial blob: leader only, no Gather"
        return ch.nthreads - 1, "Gather workers + participating leader"
    if type_ in PW_TYPES:
        # apply_mt_pw floors nworkers at 1 and the leader never processes a job, so
        # even the 1-thread blob runs one worker.
        if ch.nthreads <= 1:
            return 1, "operator floors nworkers at 1; leader does not participate"
        if ch.nlambdas < ch.nthreads:
            # L3: a job is one whole lambda, so M is the ceiling
            return ch.nlambdas, f"self-capped at num_jobs={ch.nlambdas}"
        return ch.nthreads, "operator-launched parallel workers"
    return 0, "no worker processes"


# The operator reports a launch shortfall as a WARNING ("N of M parallel workers
# launched"); with client_min_messages=warning it reaches the notice handler that
# open_conn installs, so its silence is the operator's own confirmation that every
# worker it asked for started.
PW_LAUNCH_RE = re.compile(r"apply_mt_pw: (\d+) of (\d+) parallel workers launched")

# The sampler polls pg_stat_activity every 2 ms, so on a short query it can miss a
# worker that started late or finished early. Re-sampling on a shortfall costs one
# untimed query each.
VERIFY_RESAMPLES = 4


# The outer (partial) side every free-lambda plan is pinned to: data-major, nums
# outer (generate_benchmarks.create_free_lambda_statement). Serially the planner
# would pick lambdas_hol outer; enable_material=on on the 1-thread blob gives
# NestLoop(nums, Materialize(lambdas_hol)) instead. The check below records a note
# if a serial plan comes out lambda-major anyway.
def free_outer(type_: str) -> str:
    return "nums"


def check_free_plan(plan_obj: Any, outer_rel: str = "nums",
                    parallel: bool = True) -> Optional[str]:
    """
    None if a free-lambda plan has the shape its type is pinned to, otherwise what is
    wrong. parallel: a Gather on top (under the Finalize Aggregate for the aggregating
    form), directly over the Nested Loop -- so the calls run in the workers. Serial: the
    Nested Loop under at most an Aggregate. Either way the loop's outer side must be
    outer_rel. "Workers Launched" cannot tell any of this: a leader-only plan launches
    its full complement too, and its workers return rows (the scan).
    """
    try:
        p = (plan_obj[0] if isinstance(plan_obj, list) else plan_obj)["Plan"]
    except Exception:
        return "no plan"
    if parallel:
        if p.get("Node Type") == "Aggregate" and p.get("Partial Mode") == "Finalize":
            p = (p.get("Plans") or [{}])[0]
        if p.get("Node Type") != "Gather":
            return f"top node is {p.get('Node Type')}"
        p = (p.get("Plans") or [{}])[0]
    if p.get("Node Type") == "Aggregate":
        p = (p.get("Plans") or [{}])[0]
    if p.get("Node Type") != "Nested Loop":
        return f"expected a Nested Loop, got {p.get('Node Type')}"
    outer = (p.get("Plans") or [{}])[0]
    if outer.get("Relation Name") != outer_rel:
        return f"outer side is {outer.get('Relation Name')}, pinned to {outer_rel}"
    return None


# The settings that define a type, snapshotted per blob from the live session so the
# conditions file records what the server actually used, not what we meant to set.
CONDITION_GUCS = [
    "jit", "jit_above_cost", "jit_inline_above_cost", "jit_optimize_above_cost",
    "parallel_setup_cost", "parallel_tuple_cost", "max_parallel_workers_per_gather",
    "max_parallel_workers", "max_worker_processes", "min_parallel_table_scan_size",
    "min_parallel_index_scan_size", "parallel_leader_participation",
    "enable_material", "random_page_cost", "work_mem",
    "hash_mem_multiplier", "plan_cache_mode", "custom_lambda_cache_size",
    "custom_lambda_jit_after_uses",
]


def session_snapshot(conn: psycopg.Connection, tables: Tuple[str, ...]) -> Dict[str, Any]:
    snap: Dict[str, Any] = {}
    with conn.cursor() as cur:
        cur.execute("SELECT name, setting FROM pg_settings WHERE name = ANY(%s)",
                    (CONDITION_GUCS,))
        snap["gucs"] = {k: v for k, v in cur.fetchall()}
        snap["reloptions"] = {}
        for t in tables:
            cur.execute("SELECT reloptions FROM pg_class WHERE relname = %s", (t,))
            row = cur.fetchone()
            snap["reloptions"][t] = row[0] if row else None
    return snap


def workers_with_rows(plan_obj) -> Tuple[int, int]:
    """
    (workers that processed at least one row, workers reported at all).

    Needs EXPLAIN VERBOSE: only then does a parallel-aware node carry a "Workers"
    array with each worker's own Actual Rows. Without it the counts are folded
    into the node total and a worker that did nothing is invisible.

    This is the check "Workers Launched" cannot make. free_lambda is the standing
    example -- its workers launch and then process zero rows, so every
    launched-vs-requested test passes while the query is effectively serial.

    Rows are counted only at nodes BELOW the aggregates: a Partial Aggregate emits
    its one row whether or not anything reached it, so counting it would call an
    idle worker busy.
    """
    # A worker appears once per parallel-aware NODE, so counting entries counts
    # nodes x workers -- 15 workers over 4 nodes read as 60. Identify workers by
    # their number instead: worker 3 at the scan is worker 3 at the aggregate.
    active: Set[int] = set()
    seen: Set[int] = set()

    def walk(node):
        counts = node.get("Node Type") not in ("Aggregate", "Gather", "Gather Merge")
        for w in node.get("Workers", []) or []:
            num = w.get("Worker Number")
            if num is None:
                continue
            seen.add(int(num))
            if counts and float(w.get("Actual Rows", 0) or 0) > 0:
                active.add(int(num))
        for child in node.get("Plans", []) or []:
            walk(child)

    try:
        walk((plan_obj or [{}])[0]["Plan"])
    except (KeyError, IndexError, TypeError):
        return 0, 0
    return len(active), len(seen)


def run_explain(conn: psycopg.Connection, sql: str, fe,
                verbose: bool = False,
                timing: bool = False) -> Tuple[float, float, Optional[dict], int, int, Any]:
    """
    Returns:
      (server_execution_ms_from_explain, client_roundtrip_ms, jit_section_or_none,
       workers_planned, workers_launched, plan_obj)

    verbose=True adds per-worker row counts to the plan, at the price of a much
    larger EXPLAIN payload. timing=True turns per-node timing on, which is the only
    way PostgreSQL prints the JIT section's "Timing" group (explain.c: `es->analyze &&
    es->timing`). Both are for the untimed verification run only: per-node clock
    reads would distort a timed run.
    """
    # No BUFFERS: it diffs the buffer counters on every node call, i.e. per row, which
    # adds ~10% to apply_mt_pw and ~2% to the SQL types.
    opts = (f"ANALYZE{', VERBOSE' if verbose else ''}, "
            f"TIMING {'ON' if timing else 'OFF'}, FORMAT JSON")
    q = f"EXPLAIN ({opts}) {sql};"
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
    wp, wl = plan_worker_counts(plan_obj)
    # PG 17 nests Generation as {"Deform": .., "Total": ..}; extract_jit_timing wants
    # flat numbers, so fold any nested group to its Total.
    jit = root.get("JIT")
    if isinstance(jit, dict) and isinstance(jit.get("Timing"), dict):
        jit = {**jit, "Timing": {k: (v.get("Total", float("nan")) if isinstance(v, dict) else v)
                                 for k, v in jit["Timing"].items()}}
    return float(root.get("Execution Time", 0.0)), rt_ms, jit, wp, wl, plan_obj


def extract_jit_timing(jit_info: Optional[dict]) -> Tuple[float, float, float, float, float]:
    """
    Pull the five JIT timing fields (in ms) out of the JIT section returned
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
    setup_sql = os.path.join(cfg.setup_scripts_dir, "setup.sql")

    if type_ not in ALL_TYPES:
        raise ValueError(f"Unknown type {type_!r} (expected one of {'|'.join(ALL_TYPES)})")

    # JIT-experiment types have no .sql of their own -- they differ from their source
    # type only in session GUCs, so they must read byte-identical query text.
    sql_type = TYPE_SQL_SOURCE.get(type_, type_)
    bench_sql = os.path.join(cfg.benchmarks_dir, f"benchmark_{sql_type}.sql")

    for p in (setup_sql, bench_sql):
        if not os.path.isfile(p):
            raise FileNotFoundError(f"Missing required file: {p}")

    return setup_sql, bench_sql


def parse_blob_spec(spec: Optional[str]) -> Optional[Set[int]]:
    """"1", "3-7", "1,4,9-12" -> set of blob indices. None = all."""
    if not spec:
        return None
    out: Set[int] = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, hi = part.split("-", 1)
            out.update(range(int(lo), int(hi) + 1))
        else:
            out.add(int(part))
    if not out:
        raise ValueError(f"Empty blob spec: {spec!r}")
    return out


def verify_blob(conn: psycopg.Connection, dsn: str, type_: str, ch: "BenchChunk", fe,
                exp_workers: int, exp_why: str,
                notices: List[str]) -> Tuple[Dict[str, Any], List[Tuple[bool, str]]]:
    """
    The untimed verification run of one blob: what the query actually got.

    Returns the conditions record (written to conditions_<type>.jsonl) and a list of
    (hard, note). A hard note is a blob that did not run the configuration it claims:
      - Gather types (SQL, free lambdas): the plan's own planned and launched counts
        are the authority, and a worker that launched but processed no row means the blob was parallel
        on paper only.
      - pw types: the operator's shortfall WARNING is the launch authority (silence
        = all launched); pg_stat_activity is re-sampled on a shortfall, because a 2 ms
        poll misses workers on short queries.
      - free lambdas: the plan has to put the calls under the Gather (check_free_plan).
    """
    with conn.cursor() as cur:
        cur.execute("SELECT pg_backend_pid()")
        leader_pid = int(cur.fetchone()[0])
    with WorkerSampler(dsn, leader_pid) as sampler:
        v_ms, v_rt, v_jit, v_wp, v_wl, v_plan = run_explain(conn, ch.sql, fe,
                                                            verbose=True, timing=True)
    observed = sampler.peak
    resamples = 0
    is_pw = type_ in PW_TYPES
    while is_pw and not sampler.error and observed < exp_workers and resamples < VERIFY_RESAMPLES:
        resamples += 1
        with WorkerSampler(dsn, leader_pid) as sampler:
            run_explain(conn, ch.sql, fe, verbose=True)
        observed = max(observed, sampler.peak)
    v_active, v_reported = workers_with_rows(v_plan)

    shortfalls = [int(m.group(1)) for m in (PW_LAUNCH_RE.search(n) for n in notices) if m]
    op_launched = (min(shortfalls) if shortfalls else exp_workers) if is_pw else None
    launched = op_launched if is_pw else v_wl

    tag = f"{os.path.basename(os.path.abspath(CFG.repo_dir))}:{type_} blob {ch.idx}"
    notes: List[Tuple[bool, str]] = []
    if is_pw:
        ok = launched == exp_workers
        src = "operator (no shortfall warning)" if not shortfalls else "operator WARNING"
    else:
        ok = v_wp == exp_workers and v_wl == exp_workers
        src = "plan"
    if ok:
        notes.append((False, f"[workers] {tag} -- {src}: {launched} worker processes as expected "
                             f"({exp_why}); sampler peak {observed}"
                             + (f" after {resamples} re-sample(s)" if resamples else "")))
    else:
        notes.append((True, f"[WORKERS] {tag} -- asked for {ch.nthreads} threads, expected "
                            f"{exp_workers} worker processes ({exp_why}); plan planned={v_wp} "
                            f"launched={v_wl}; operator {op_launched}; sampler peak {observed}"))
    if v_reported > 0 and v_active == 0:
        notes.append((True, f"[WORKERS] {tag} -- {v_reported} worker(s) in the plan but NONE "
                            f"processed a row: parallel on paper only"))
    elif not is_pw and exp_workers > 0 and v_active < exp_workers:
        # a worker that launched and got no rows is width that was paid for and not used
        notes.append((True, f"[WORKERS] {tag} -- only {v_active} of {exp_workers} workers "
                            f"processed a row"))
    shape_err = (check_free_plan(v_plan, free_outer(type_), exp_workers > 0)
                 if type_ in FREE_TYPES else None)
    if shape_err and exp_workers > 0:
        notes.append((True, f"[WORKERS] {tag} -- free-lambda plan not as pinned: {shape_err}"))
    elif shape_err:
        notes.append((False, f"[note] {tag} -- serial free-lambda plan, cannot be pinned: {shape_err}"))
    if sampler.error:
        notes.append((False, f"[warn] {tag} -- worker sampling failed: {sampler.error}"))

    try:
        snap = session_snapshot(conn, ("nums", "lambdas_hol"))
    except Exception as exc:
        snap = {"error": str(exc)}
    jg, ji, jo, je, jt = extract_jit_timing(v_jit)
    jit = v_jit if isinstance(v_jit, dict) else {}
    cond = {
        "type": type_, "contender": CONTENDER.get(type_, type_),
        "sql_source": TYPE_SQL_SOURCE.get(type_, type_),
        "blob": ch.idx, "ndata": ch.ndata, "nlambdas": ch.nlambdas, "nthreads": ch.nthreads,
        "setup": list(ch.setup), "session": snap,
        "workers": {"expected": exp_workers, "why": exp_why, "planned": v_wp,
                    "launched": launched, "launched_plan": v_wl,
                    "launched_operator": op_launched, "observed_peak": observed,
                    "resamples": resamples, "active_with_rows": v_active,
                    "reported_in_plan": v_reported},
        "free_plan_error": shape_err,
        "free_outer": free_outer(type_) if type_ in FREE_TYPES else None,
        "jit_explain": {"functions": jit.get("Functions"), "options": jit.get("Options"),
                        "generation_ms": jg, "inlining_ms": ji, "optimization_ms": jo,
                        "emission_ms": je, "total_ms": jt},
        "notices": list(notices),
        "verify_ms": v_ms, "verify_rt_ms": v_rt, "_jit": v_jit,
        "ok": not any(h for h, _ in notes),
    }
    return cond, notes


def benchmark_repo_test(
    cfg: RunnerConfig,
    type_: str,
    port: int,
    blob_filter: Optional[Set[int]],
    bench_root: str,
    result_root: str,
    repeats: int,
    strict_workers: bool = False,
) -> List[str]:
    """Returns the when/where/why line of every blob that failed, for the run summary."""
    repo = cfg.repo_dir
    name = os.path.basename(os.path.abspath(repo))

    # every blob whose verification run did not get the worker count it asked for
    worker_failures: List[str] = []
    # every blob that raised, with when/where/why -- surfaced again at the end of the
    # run so a hole in the grid is never silent
    blob_failures: List[str] = []

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

    pg_cpu_set: Set[int] = postgres_cpuset(cfg)

    dsn = f"host=127.0.0.1 port={port} dbname={cfg.dbname}"

    with open(frontend_log, "w", buffering=1, encoding="utf-8") as fe:
        proc: Optional[subprocess.Popen] = None
        logfh: Any = None
        conn: Optional[psycopg.Connection] = None
        cond_fh: Any = None

        try:
            print(f"[setup] {name}:{type_} -- reset cluster")
            reset_pgdata(initdb, datadir)

            proc, logfh = start_postgres(postgres, datadir, port, backend_log, pg_cpu_set, cfg)
            print(f"[start] {name}:{type_} -- backend launched (port {port})")

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
            print(f"[init ] {name}:{type_} -- database+tablespace ready")

            # Apply setup once per fresh cluster (server GUCs come from PG_SETTINGS)
            run(psql_args(psql, port, cfg.dbname) + ["-f", setup_sql], check=True, stdout=fe, stderr=fe)
            print(f"[setup] {name}:{type_} -- {os.path.basename(setup_sql)} applied")

            # make sure planner stats are stable.
            run(psql_args(psql, port, cfg.dbname) + ["-c", "ANALYZE;"], check=True, stdout=fe, stderr=fe)

            os.makedirs(result_root, exist_ok=True)
            csv_path = os.path.join(result_root, f"{name}_{type_}.csv")

            # Per-type GUC overlay (JIT experiment); empty for every other type.
            session_settings = TYPE_SESSION_SETTINGS.get(type_, {})
            if session_settings:
                rendered = ", ".join(f"{k}={v}" for k, v in session_settings.items())
                print(f"[guc  ] {name}:{type_} -- session overlay: {rendered}")
                fe.write(f"\n-- session overlay for {type_}: {rendered}\n")

            with open(csv_path, "w", newline="", encoding="utf-8") as out_fh:
                writer = csv.writer(out_fh)
                writer.writerow([
                    "repo", "type",
                    "blob",
                    "ncores", "ndata", "nlambdas", "nthreads",
                    "run_kind",  # warmup|verify|measure
                    "server_ms", "roundtrip_ms",
                    "jit_generation_ms", "jit_inlining_ms",
                    "jit_optimization_ms", "jit_emission_ms", "jit_total_ms",
                    # what the query actually got, as opposed to what nthreads asked
                    # for. workers_planned/launched come from the plan's Gather nodes
                    # (0 for our operators, which launch inside the UDF);
                    # workers_observed is the pg_stat_activity peak and is only
                    # filled in on the run_kind=verify run.
                    "workers_expected", "workers_planned", "workers_launched",
                    "workers_observed", "workers_active",
                ])

                notices: List[str] = []
                conn = open_conn(dsn, session_settings, notices)
                # one JSON line per blob: the conditions a reader needs to trust a number
                cond_fh = open(os.path.join(result_root, f"conditions_{type_}.jsonl"),
                               "w", encoding="utf-8")

                # Per blob: its state across the passes below.
                blobs: List[Dict[str, Any]] = []

                def emit(b: Dict[str, Any], kind: str, server_ms: float, rt_ms: float, jit_info,
                         wp: int, wl: int, observed, active=None) -> float:
                    ch = b["ch"]
                    jit_gen, jit_inl, jit_opt, jit_emi, jit_tot = extract_jit_timing(jit_info)
                    writer.writerow([
                        name, type_,
                        ch.idx,
                        ch.ncores, ch.ndata, ch.nlambdas, ch.nthreads,
                        kind,
                        f"{server_ms:.3f}", f"{rt_ms:.3f}",
                        f"{jit_gen:.3f}", f"{jit_inl:.3f}",
                        f"{jit_opt:.3f}", f"{jit_emi:.3f}", f"{jit_tot:.3f}",
                        b["exp_workers"], wp, wl,
                        "" if observed is None else observed,
                        "" if active is None else active,
                    ])
                    return jit_tot

                def apply_setup(ch: BenchChunk) -> None:
                    # The blob's own width setup (budget, and for SQL types the degree
                    # pinned on the scanned table). Run inside the blob's try, so a
                    # statement that fails is a blob failure on record rather than a
                    # blob that silently runs at the wrong width.
                    with conn.cursor() as cur:
                        for stmt in ch.setup:
                            cur.execute(stmt)
                            fe.write(f"-- setup: {stmt}\n")

                def measure(b: Dict[str, Any], run_i: int) -> None:
                    ch = b["ch"]
                    server_ms, rt_ms, jit_info, wp, wl, _plan = run_explain(conn, ch.sql, fe)
                    b["server_times"].append(server_ms)
                    b["rt_times"].append(rt_ms)
                    jit_tot = emit(b, "measure", server_ms, rt_ms, jit_info, wp, wl, None)
                    print(f"[meas] {name}:{type_} blob {ch.idx} run {run_i} server={server_ms:.3f}ms rt={rt_ms:.3f}ms jit={jit_tot:.1f}ms")

                def fail(b: Dict[str, Any], run_i: int, exc: Exception) -> bool:
                    """Records a blob failure; False when the whole type has to stop."""
                    nonlocal conn
                    ch = b["ch"]
                    b["failed"] = True
                    # One blob failing is not a reason to lose the ones after it.
                    # Log when, where and why, then carry on with the next blob.
                    # Rows already written for this blob stay in the CSV, so it
                    # simply shows up with `runs` < repeats rather than vanishing.
                    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
                    why = f"{type(exc).__name__}: {exc}".strip()
                    note = (f"[BLOBFAIL] {stamp}  {name}:{type_} blob {ch.idx} "
                            f"(cores={ch.ncores} data={ch.ndata} lambdas={ch.nlambdas} "
                            f"threads={ch.nthreads})  on run {run_i}/{repeats + cfg.warmup_runs}"
                            f"  measured {len(b['server_times'])} of {repeats}  --  {why}")
                    print(note)
                    fe.write("\n--- backend log (tail) ---\n")
                    fe.write(log_tail(backend_log) + "\n")
                    fe.write(note + "\n")
                    fe.flush()
                    blob_failures.append(note)

                    # The failed statement aborted the transaction, and a plain
                    # rollback would revert every session SET made in open_conn --
                    # `jit=off` among them, which would silently move later blobs
                    # to a different evaluator. Reconnecting re-applies them.
                    try:
                        if conn is not None:
                            conn.close()
                    except Exception:
                        pass
                    try:
                        conn = open_conn(dsn, session_settings, notices)
                    except Exception as reconnect_exc:
                        note = (f"[BLOBFAIL] {stamp}  {name}:{type_} -- could not reconnect "
                                f"after blob {ch.idx}: {reconnect_exc}. Abandoning this type.")
                        print(note); fe.write(note + "\n"); fe.flush()
                        blob_failures.append(note)
                        return False

                    # ENOSPC is the one failure worth giving up the type for: the
                    # root fs is shared and sits near full, later blobs are larger,
                    # and retrying just refills it. Every other error moves on.
                    if isinstance(exc, DiskFull):
                        note = (f"[BLOBFAIL] {stamp}  {name}:{type_} -- ENOSPC, skipping the "
                                f"remaining blobs of this type (disk is shared).")
                        print(note); fe.write(note + "\n"); fe.flush()
                        blob_failures.append(note)
                        return False
                    return True

                # Pass 1, per blob: setup, warmups and the verify run; without
                # round_robin also its measured runs, back to back.
                for ch in chunks:
                    if blob_filter is not None and ch.idx not in blob_filter:
                        continue

                    print(
                        f"[run  ] {name}:{type_} blob {ch.idx} "
                        f"cores={ch.ncores} data={ch.ndata} lambdas={ch.nlambdas} threads={ch.nthreads}"
                    )

                    exp_workers, exp_why = expected_worker_procs(type_, ch)
                    b = {"ch": ch, "exp_workers": exp_workers, "server_times": [], "rt_times": [],
                         "cond": {}, "failed": False}
                    blobs.append(b)
                    notices.clear()     # a launch-shortfall warning belongs to this blob only
                    run_i = 0

                    try:
                        apply_setup(ch)

                        total = (0 if cfg.round_robin else repeats) + cfg.warmup_runs
                        for run_i in range(1, total + 1):
                            if run_i > cfg.warmup_runs:
                                measure(b, run_i)
                            else:
                                server_ms, rt_ms, jit_info, wp, wl, _plan = run_explain(conn, ch.sql, fe)
                                emit(b, "warmup", server_ms, rt_ms, jit_info, wp, wl, None)
                                print(f"[warm] {name}:{type_} blob {ch.idx} run {run_i} (ignored)")

                            # One extra, untimed run right after the warmups (warmups are
                            # always >= 1 here, so it always fires). It is the only place
                            # the actual worker count is measured rather than assumed, and
                            # the only run with per-node timing, i.e. JIT timing.
                            if run_i == max(cfg.warmup_runs, 1):
                                cond, notes = verify_blob(conn, dsn, type_, ch, fe,
                                                          exp_workers, exp_why, notices)
                                b["cond"] = cond
                                emit(b, "verify", cond["verify_ms"], cond["verify_rt_ms"],
                                     cond["_jit"], cond["workers"]["planned"],
                                     cond["workers"]["launched"],
                                     cond["workers"]["observed_peak"],
                                     cond["workers"]["active_with_rows"])
                                for hard, note in notes:
                                    print(note); fe.write(note + "\n"); fe.flush()
                                    if hard:
                                        worker_failures.append(note)
                    except Exception as exc:
                        if not fail(b, run_i, exc):
                            break

                # Pass 2, round_robin only: the measured runs in rounds, one per blob
                # per round, so a slow stretch of the host (CPU clock) is spread over
                # all blobs instead of covering some of them whole.
                if cfg.round_robin:
                    for r in range(repeats):
                        run_i = cfg.warmup_runs + r + 1
                        for b in blobs:
                            if b["failed"]:
                                continue
                            try:
                                apply_setup(b["ch"])
                                measure(b, run_i)
                            except Exception as exc:
                                if not fail(b, run_i, exc):
                                    break
                        else:
                            continue
                        break

                # Pass 3, per blob: what a reader needs to trust its numbers.
                for b in blobs:
                    ch, cond = b["ch"], b["cond"]
                    server_times, rt_times = b["server_times"], b["rt_times"]
                    if cond and not b["failed"]:
                        cond.pop("_jit", None)
                        cond.update({
                            "min_ms": min(server_times) if server_times else None,
                            "median_ms": statistics.median(server_times) if server_times else None,
                            "first_ms": server_times[0] if server_times else None,
                            "measured": len(server_times),
                            "round_robin": cfg.round_robin,
                        })
                        cond_fh.write(json.dumps(cond, default=str) + "\n")
                        cond_fh.flush()
                    if b["failed"]:
                        continue

                    med_server = statistics.median(server_times) if server_times else float("nan")
                    med_rt = statistics.median(rt_times) if rt_times else float("nan")

                    print(f"[done ] {name}:{type_} blob {ch.idx} -- median server={med_server:.3f}ms, median rt={med_rt:.3f}ms")
                    fe.write(f"[done ] blob {ch.idx} -- median server={med_server:.3f}ms, median rt={med_rt:.3f}ms\n")
                    fe.flush()

            print(f"[save ] {name}:{type_} -> {csv_path}")
            fe.write(f"[save ] -> {csv_path}\n")

            if blob_failures:
                head = (f"[BLOBFAIL] {name}:{type_} -- {len(blob_failures)} blob(s) did not complete. "
                        f"Their rows are short or missing in {os.path.basename(csv_path)}.")
                print(head)
                fe.write(head + "\n")
                for line in blob_failures:
                    fe.write("  " + line + "\n")
                fe.flush()

            if worker_failures:
                head = (f"[WORKERS] {name}:{type_} -- {len(worker_failures)} blob(s) did NOT run at "
                        f"the requested width or plan. Their numbers are not the configuration they claim.")
                print(head)
                fe.write(head + "\n")
                for line in worker_failures:
                    fe.write("  " + line + "\n")
                if strict_workers:
                    fe.flush()
                    raise RuntimeError(head)
            else:
                ok = f"[workers] {name}:{type_} -- every blob ran at the requested width"
                print(ok)
                fe.write(ok + "\n")
            fe.flush()

            # Cleanup: drop objects to keep logs tidy
            run(psql_args(psql, port, "postgres") + ["-c", f"DROP DATABASE IF EXISTS {cfg.dbname} WITH (FORCE);"],
                check=True, stdout=fe, stderr=fe)
            run(psql_args(psql, port, "postgres") + ["-c", "DROP TABLESPACE IF EXISTS benchtemp;"],
                check=True, stdout=fe, stderr=fe)

            # Worker failures are returned too, so the run exits non-zero and run_all.sh
            # records the stage as failed -- but they never abort the type (unless
            # --strict-workers), so every other blob's numbers are still measured.
            return blob_failures + worker_failures

        except Exception as e:
            print(f"[fail ] {name}:{type_} -- {e}")
            raise
        finally:
            try:
                if conn is not None:
                    conn.close()
            except Exception:
                pass
            if cond_fh is not None:
                cond_fh.close()
            try:
                stop_postgres(proc, logfh)
            except Exception:
                pass
            shutil.rmtree(tempdir, ignore_errors=True)
            shutil.rmtree(datadir, ignore_errors=True)
            os.makedirs(datadir, exist_ok=True)


# -------------------------
# Provenance
# -------------------------

def _md5(path: str) -> str:
    import hashlib
    try:
        with open(path, "rb") as fh:
            return hashlib.md5(fh.read()).hexdigest()
    except OSError:
        return "missing"


def _git(repo: str, *args: str) -> str:
    try:
        return subprocess.run(["git", "-C", repo, *args], capture_output=True,
                              text=True, timeout=30).stdout.strip()
    except Exception as exc:
        return f"(git failed: {exc})"


def write_provenance(result_root: str, cfg: RunnerConfig, types: List[str],
                     sql_dir: Optional[str] = None) -> None:
    """
    PROVENANCE.md + provenance.json in the result directory: which commit of this
    repository (engine and harness are one tree), which uncommitted changes, the md5s
    of the engine binaries and the generators, which settings and which query file
    every type ran. An uncommitted edit is invisible in the commit hash, hence the
    diff md5s, split into engine (hol-lambdas/) and harness.
    """
    import hashlib
    import platform
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(cfg.repo_dir)
    eng = os.path.relpath(repo, here)
    is_git = _git(here, "rev-parse", "--is-inside-work-tree") == "true"
    eng_diff = _git(here, "diff", "--", eng) if is_git else ""
    har_diff = _git(here, "diff", "--", ".", f":!{eng}") if is_git else ""
    sql_dir = sql_dir or cfg.benchmarks_dir
    prov = {
        "created": time.strftime("%Y-%m-%d %H:%M:%S"),
        "host": platform.node(),
        "commit": (_git(here, "log", "-1", "--format=%H %cd %s", "--date=short")
                   if is_git else "not a git checkout"),
        "engine": {
            "path": repo,
            "uncommitted": _git(here, "status", "--short", "--untracked-files=no", "--", eng).splitlines()
                           if is_git else [],
            "diff_md5": hashlib.md5(eng_diff.encode()).hexdigest(),
            "postgres_md5": _md5(bin_path(repo, "postgres")),
            "llvmjit_md5": _md5(os.path.join(repo, "install", "lib", "postgresql", "llvmjit.so")),
            "apply_mt_pw_ext_md5": _md5(os.path.join(repo, "install", "lib", "postgresql", "apply_mt_pw_ext.so")),
        },
        "harness": {
            "uncommitted": _git(here, "status", "--short", "--untracked-files=no", "--", ".", f":!{eng}").splitlines()
                           if is_git else [],
            "diff_md5": hashlib.md5(har_diff.encode()).hexdigest(),
            "benchmark_py_md5": _md5(os.path.join(here, "benchmark.py")),
            "generate_benchmarks_py_md5": _md5(os.path.join(here, "generate_benchmarks.py")),
            "generate_usecase_benchmarks_py_md5": _md5(os.path.join(here, "generate_usecase_benchmarks.py")),
        },
        "topology": {"postgres_cpus": sorted(postgres_cpuset(cfg)),
                     "driver_cpus": sorted(python_cpuset(cfg))},
        "protocol": {"warmups": cfg.warmup_runs, "repeats": cfg.repeats,
                     "repeats_cores": cfg.repeats_cores, "round_robin": cfg.round_robin,
                     "verify": "1 untimed run after the warmups, EXPLAIN VERBOSE + TIMING ON"},
        "pg_settings": dict(PG_SETTINGS),
        "types": {t: {"contender": CONTENDER.get(t, t),
                      "sql": f"benchmark_{TYPE_SQL_SOURCE.get(t, t)}.sql",
                      "sql_md5": _md5(os.path.join(sql_dir, f"benchmark_{TYPE_SQL_SOURCE.get(t, t)}.sql")),
                      "session": TYPE_SESSION_SETTINGS.get(t, {})} for t in types},
    }
    os.makedirs(result_root, exist_ok=True)
    with open(os.path.join(result_root, "provenance.json"), "w", encoding="utf-8") as fh:
        json.dump(prov, fh, indent=2)
    e, h = prov["engine"], prov["harness"]
    md = [f"# Provenance -- {os.path.basename(result_root)}", "",
          f"- created {prov['created']} on {prov['host']}",
          f"- commit `{prov['commit']}`",
          f"- engine: postgres md5 `{e['postgres_md5']}`, llvmjit.so md5 `{e['llvmjit_md5']}`, "
          f"apply_mt_pw_ext.so md5 `{e['apply_mt_pw_ext_md5']}`; uncommitted: "
          f"{', '.join(e['uncommitted']) or 'none'} (diff md5 `{e['diff_md5']}`)",
          f"- harness uncommitted: {', '.join(h['uncommitted']) or 'none'} (diff md5 `{h['diff_md5']}`)",
          f"- postgres CPUs {prov['topology']['postgres_cpus']}, driver CPUs {prov['topology']['driver_cpus']}",
          f"- {cfg.warmup_runs} warmups, {cfg.repeats} measured (core sweeps {cfg.repeats_cores}), "
          f"+1 untimed verify, round robin {'on' if cfg.round_robin else 'off'}", "",
          "| type | contender | query file | session overlay |", "|---|---|---|---|"]
    for t, v in prov["types"].items():
        ov = ", ".join(f"{k}={x}" for k, x in v["session"].items()) or "(defaults)"
        md.append(f"| `{t}` | {v['contender']} | `{v['sql']}` | {ov} |")
    with open(os.path.join(result_root, "PROVENANCE.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(md) + "\n")


# -------------------------
# Main
# -------------------------

def add_run_args(ap: argparse.ArgumentParser, types: List[str], default_types: List[str]) -> None:
    """The arguments benchmark.py and run_usecase_benchmark.py share."""
    ap.add_argument("--blob", default=None, metavar="SPEC",
                    help="Which --SPLIT blobs to run, 1-based: '5', '3-7', '1,4,9-12'. Default: all.")
    ap.add_argument("-r", "--repeats", type=int, default=None, metavar="N",
                    help=f"Measured runs per blob (default {CFG.repeats}); "
                         f"{CFG.warmup_runs} warmups and 1 untimed verify run on top.")
    ap.add_argument("--types", nargs="*", default=default_types, choices=types,
                    help=f"Which types to run, in this order (default: {' '.join(default_types)})")
    ap.add_argument("--topology", choices=sorted(TOPOLOGIES), default="server",
                    help="CPU layout to pin against (default: server)")
    ap.add_argument("--port", type=int, default=CFG.base_port,
                    help=f"Port of the benchmark cluster (default {CFG.base_port})")
    ap.add_argument("--strict-workers", action="store_true",
                    help="Abort a type as soon as a blob does not get the worker count it "
                         "requested, instead of only reporting it.")
    ap.add_argument("--round-robin", action=argparse.BooleanOptionalAction, default=CFG.round_robin,
                    help="Measured runs in rounds over all blobs of a type instead of back to "
                         "back per blob (default: on).")


def make_cfg(args: argparse.Namespace, **overrides: Any) -> RunnerConfig:
    """RunnerConfig from the shared arguments; exits on a topology this machine cannot run."""
    repeats = CFG.repeats if args.repeats is None else args.repeats
    repeats_cores = CFG.repeats_cores if args.repeats is None else args.repeats
    if getattr(args, "repeats_cores", None) is not None:
        repeats_cores = args.repeats_cores
    cfg = replace(CFG, repeats=repeats, repeats_cores=repeats_cores,
                  round_robin=args.round_robin, **TOPOLOGIES[args.topology], **overrides)
    try:
        check_topology(cfg, os.cpu_count() or 0)
    except ValueError as exc:
        print(f"Topology {args.topology!r}: {exc}. "
              f"Use --topology {'local' if args.topology == 'server' else 'server'}.", file=sys.stderr)
        sys.exit(1)
    if not os.path.isdir(cfg.repo_dir):
        print(f"Missing repo dir: {cfg.repo_dir}", file=sys.stderr)
        sys.exit(1)
    return cfg


def run_types(cfg: RunnerConfig, args: argparse.Namespace, run_id: str, tag: str = "bench") -> None:
    """Every type of args.types in a fresh cluster each; exits non-zero on any failure."""
    if hasattr(os, "sched_setaffinity"):
        os.sched_setaffinity(0, python_cpuset(cfg))

    bench_root = os.path.join("bench_logs", run_id)
    result_root = os.path.join("results", run_id)
    os.makedirs(bench_root, exist_ok=True)
    os.makedirs(result_root, exist_ok=True)
    blob_filter = parse_blob_spec(args.blob)

    print(f"[{tag}] logs:     {bench_root}")
    print(f"[{tag}] results:  {result_root}")
    print(f"[{tag}] topology: {args.topology}  postgres CPUs {sorted(postgres_cpuset(cfg))}"
          f"  driver CPUs {sorted(python_cpuset(cfg))}")
    if cfg.oversubscribe:
        print(f"[{tag}] WARNING: topology {args.topology!r} runs blobs wider than postgres' "
              f"CPUs -- a smoke test, the timings mean nothing")
    print(f"[{tag}] types:    {' '.join(args.types)}")
    print(f"[{tag}] blobs:    {args.blob or 'all'}  repeats={cfg.repeats}"
          f"  core sweeps={cfg.repeats_cores}  round robin={'on' if cfg.round_robin else 'off'}"
          f"  (+{cfg.warmup_runs} warmups and 1 untimed verify per blob)")
    write_provenance(result_root, cfg, args.types)

    t0 = time.perf_counter()
    failures: List[str] = []
    for type_ in args.types:
        type_repeats = cfg.repeats_cores if type_ in CORE_SWEEP_TYPES else cfg.repeats
        try:
            failures += benchmark_repo_test(
                cfg,
                type_=type_,
                port=args.port,
                blob_filter=blob_filter,
                bench_root=bench_root,
                result_root=result_root,
                repeats=type_repeats,
                strict_workers=args.strict_workers,
            )
        except Exception as exc:
            # A type can still die outright -- initdb, a server that will not start,
            # --strict-workers. Say when, where and why, then start the next type.
            stamp = time.strftime("%Y-%m-%d %H:%M:%S")
            note = (f"[TYPEFAIL] {stamp}  {type_} abandoned after "
                    f"{(time.perf_counter() - t0) / 60:.1f} min of the run  --  "
                    f"{type(exc).__name__}: {exc}")
            print(note, file=sys.stderr)
            failures.append(note)

    print(f"[{tag}] total runtime {(time.perf_counter() - t0) / 60:.1f} min")
    if failures:
        print(f"\n[{tag}] {len(failures)} failure(s) during this run:")
        for line in failures:
            print("  " + line)
        print(f"[{tag}] Everything else completed; the CSVs above are usable.")
        # non-zero so run_all.sh records the stage as failed
        sys.exit(1)


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Run the paper's benchmark suite (grid slices + core sweep), each type in "
                    "a fresh cluster. The defaults are the paper's run.")
    add_run_args(ap, DEFAULT_TYPES, DEFAULT_TYPES)
    ap.add_argument("--repeats-cores", type=int, default=None, metavar="N",
                    help=f"Measured runs per blob for the core sweeps only (default "
                         f"{CFG.repeats_cores}, or -r)")
    args = ap.parse_args()
    cfg = make_cfg(args)
    run_types(cfg, args, time.strftime("bench_%Y%m%d_%H%M%S"))


if __name__ == "__main__":
    main()
