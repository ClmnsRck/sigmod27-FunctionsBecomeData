#!/usr/bin/env python3
import os, re, csv, time, signal, shutil, subprocess, json, statistics
from typing import List, Dict, Optional, Tuple, Any, Set

import psycopg
from psycopg.errors import DiskFull, OperationalError


# =========================
# Benchmark settings
# =========================
REPO = "../../hol-lambdas/"
BASELINE_BENCH = "parallelism_benchmark_pure.sql"
TUNE_FILE      = "tune_parallelism.sql"
SETUP_FILE     = "setup_parallelism.sql"
CHUNK_FILE     = "../../benchmarks/benchmark_cores.sql"

BASE_PORT    = 5433
BM_REPEATS   = 10
DBNAME       = "bench"
WAIT_READY_S = 60.0
WARM_UP_RUNS = 2

BACKEND_LOG  = "backend.log"
FRONTEND_LOG = "frontend.log"

BASELINE_CSV = "baseline_results.csv"
CORESCALE_CSV = "corescaling_results.csv"

HYPERTHREADING_OFFSET = 18
RESERVED_CORE = 17

PYTHON_CPUSET: Set[int] = {RESERVED_CORE, RESERVED_CORE + HYPERTHREADING_OFFSET}  # {17,35}
BEST_EFFORT_CPUSET: Set[int] = (
    set(range(0, RESERVED_CORE)) |
    set(range(HYPERTHREADING_OFFSET, HYPERTHREADING_OFFSET + RESERVED_CORE))
)  # 0-16,18-34

BEST_EFFORT_CORES = 17
NTHREADS_MARKER = "NTHREADS_MARKER"

SPLIT_MARKER = re.compile(r"^\s*--\s*SPLIT\s*$")

CSV_HEADER = [
    "repo", "phase",
    "ncores", "ndata", "nlambdas", "nthreads",
    "run_idx",
    "server_ms", "roundtrip_ms",
]


# =========================
# Helpers
# =========================
def run(cmd: List[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, **kw)

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
        "--pset", "pager=off",
    ]

def wait_ready(psql: str, port: int, db: str = "postgres", timeout: float = WAIT_READY_S) -> bool:
    t0 = time.time()
    while time.time() - t0 < timeout:
        r = run(psql_args(psql, port, db) + ["-c", "SELECT 1;"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if r.returncode == 0:
            return True
        time.sleep(0.2)
    return False

def cpuset_for_physical_cores(num_cores: int) -> Set[int]:
    if num_cores < 1:
        raise ValueError("num_cores must be >= 1")
    if num_cores > BEST_EFFORT_CORES:
        raise ValueError(f"num_cores must be <= {BEST_EFFORT_CORES} (core {RESERVED_CORE} reserved)")
    lo = set(range(0, num_cores))
    hi = set(range(HYPERTHREADING_OFFSET, HYPERTHREADING_OFFSET + num_cores))
    return lo | hi

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
    for _ in range(100):
        if not os.path.exists(os.path.join(datadir, "postmaster.pid")):
            break
        time.sleep(0.1)
    if os.path.exists(os.path.join(datadir, "postmaster.pid")):
        try:
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass

def reset_pgdata(initdb_bin: str, datadir: str) -> None:
    stop_if_running(datadir)
    shutil.rmtree(datadir, ignore_errors=True)
    os.makedirs(datadir, exist_ok=True)
    run([initdb_bin, "-D", datadir, "-A", "trust", "-E", "UTF8", "--no-locale"], check=True)

def start_postgres(postgres_bin: str, datadir: str, port: int,
                  backend_log_path: str, cpu_set: Optional[Set[int]]) -> Tuple[subprocess.Popen, Any]:
    logfh = open(backend_log_path, "ab")

    cmd = [
        postgres_bin, "-D", datadir, "-p", str(port),
        "-c", "shared_preload_libraries=llvmjit",
        "-c", "log_error_verbosity=verbose",
        "-c", "fsync=off",
        "-c", "synchronous_commit=off",
        "-c", "full_page_writes=off",
    ]

    def preexec():
        os.setsid()
        if cpu_set is not None and hasattr(os, "sched_setaffinity"):
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
        if logfh is not None:
            logfh.close()
    except Exception:
        pass

def load_chunks(path: str) -> List[Dict[str, Any]]:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    chunks: List[Dict[str, Any]] = []
    i = 0
    while i < len(lines):
        if not SPLIT_MARKER.match(lines[i]):
            i += 1
            continue

        i += 1  # header line
        if i >= len(lines):
            break
        header = lines[i].strip()
        i += 1

        header = header[2:].strip() if header.startswith("--") else header
        a_s, b_s, c_s = header.split()
        a, b, c = int(a_s), int(b_s), int(c_s)

        if a <= 0:
            cpu_set = {0}
            ncores = 1
            nthreads = 1
        elif a >= BEST_EFFORT_CORES:
            cpu_set = set(BEST_EFFORT_CPUSET)
            ncores = BEST_EFFORT_CORES
            nthreads = 2 * BEST_EFFORT_CORES
        else:
            cpu_set = cpuset_for_physical_cores(a)
            ncores = a
            nthreads = 2 * a

        buf: List[str] = []
        while i < len(lines) and not SPLIT_MARKER.match(lines[i]):
            buf.append(lines[i])
            i += 1

        sql = "".join(buf).strip().rstrip(";")
        if NTHREADS_MARKER in sql:
            sql = sql.replace(NTHREADS_MARKER, str(nthreads))

        chunks.append({
            "ncores": ncores,
            "ndata": b,
            "nlambdas": c,
            "nthreads": nthreads,
            "cpu_set": cpu_set,
            "sql": sql,
        })

    if not chunks:
        raise RuntimeError(f"No chunks found in {path} (missing '-- SPLIT' markers?)")

    return chunks

def read_single_query_file(path: str) -> str:
    sql = open(path, "r", encoding="utf-8").read().strip()
    if sql.endswith(";"):
        sql = sql[:-1].rstrip()
    if not sql:
        raise RuntimeError(f"{path} is empty")
    return sql

def run_explain(conn, sql: str) -> Tuple[float, float]:
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
            plan = json.loads(plan)
        except Exception:
            plan = None

    root = (plan or [{}])[0]
    server_ms = float(root.get("Execution Time", 0.0))
    return server_ms, rt_ms


# =========================
# Main benchmark
# =========================
def benchmark(repo: str, port: int, repeats: int) -> None:
    name = os.path.basename(os.path.abspath(repo))
    postgres = bin_path(repo, "postgres")
    initdb   = bin_path(repo, "initdb")
    psql     = bin_path(repo, "psql")

    base    = os.path.abspath(repo)
    datadir = os.path.join(base, "pgdata")
    tempdir = os.path.join(base, "pgdata-temp")

    open(BACKEND_LOG, "wb").close()
    open(FRONTEND_LOG, "w").close()
    for p in (BASELINE_CSV, CORESCALE_CSV):
        if os.path.exists(p):
            os.remove(p)

    baseline_sql = read_single_query_file(BASELINE_BENCH)
    chunks       = load_chunks(CHUNK_FILE)

    current_cpu_set: Optional[Set[int]] = None

    def open_conn() -> psycopg.Connection:
        dsn = f"host=127.0.0.1 port={port} dbname={DBNAME}"
        conn = psycopg.connect(dsn)
        conn.prepare_threshold = None
        with conn.cursor() as cur:
            cur.execute("SET client_min_messages = warning;")
            cur.execute("SET jit = on;")
            cur.execute("SET plan_cache_mode = force_custom_plan;")
            cur.execute("SET temp_tablespaces = benchtemp;")
        return conn

    with open(FRONTEND_LOG, "w", buffering=1, encoding="utf-8") as fe:
        proc = None
        logfh = None
        conn: Optional[psycopg.Connection] = None

        try:
            fe.write(f"[setup] reset cluster: {name}\n")
            reset_pgdata(initdb, datadir)

            # ---- start postgres UNPINNED for baseline ----
            proc, logfh = start_postgres(postgres, datadir, port, BACKEND_LOG, cpu_set=None)
            current_cpu_set = None
            fe.write(f"[start] postgres up on port {port}\n")

            if not wait_ready(psql, port):
                raise RuntimeError("server did not become ready")

            shutil.rmtree(tempdir, ignore_errors=True)
            os.makedirs(tempdir, exist_ok=True)

            # DB + tablespace
            run(psql_args(psql, port, "postgres") + ["-c", f"CREATE DATABASE {DBNAME};"],
                check=True, stdout=fe, stderr=fe)
            run(psql_args(psql, port, DBNAME) + ["-c", "DROP TABLESPACE IF EXISTS benchtemp;"],
                check=True, stdout=fe, stderr=fe)
            run(psql_args(psql, port, DBNAME) + ["-c", f"CREATE TABLESPACE benchtemp LOCATION '{tempdir}';"],
                check=True, stdout=fe, stderr=fe)

            # Tune + setup once
            fe.write("[tune ] applying tune file\n")
            run(psql_args(psql, port, DBNAME) + ["-f", TUNE_FILE], check=True, stdout=fe, stderr=fe)

            fe.write("[setup] applying setup file\n")
            run(psql_args(psql, port, DBNAME) + ["-f", SETUP_FILE], check=True, stdout=fe, stderr=fe)

            conn = open_conn()

            # --- baseline CSV ---
            with open(BASELINE_CSV, "w", newline="", encoding="utf-8") as f_base:
                w_base = csv.writer(f_base)
                w_base.writerow(CSV_HEADER)

                fe.write("[base ] running baseline once\n")

                server_ms, rt_ms = run_explain(conn, baseline_sql)
                fe.write(f"[base ] server={server_ms:.3f} ms rt={rt_ms:.3f} ms\n")

                w_base.writerow([
                    name, "baseline",
                    BEST_EFFORT_CORES, 0, 0, 0,
                    1,
                    f"{server_ms:.3f}", f"{rt_ms:.3f}",
                ])

                with conn.cursor() as cur:
                    cur.execute("RESET max_parallel_workers_per_gather;")
                    cur.execute("RESET max_parallel_workers;")
                    cur.execute("RESET parallel_leader_participation;")

            # --- corescaling CSV ---
            with open(CORESCALE_CSV, "w", newline="", encoding="utf-8") as f_core:
                w_core = csv.writer(f_core)
                w_core.writerow(CSV_HEADER)

                fe.write("[run  ] running corescaling chunks\n")

                for idx, ch in enumerate(chunks, 1):
                    desired_cpu_set = set(ch["cpu_set"])
                    need_restart = (current_cpu_set is None) or (desired_cpu_set != current_cpu_set)
                    if need_restart:
                        fe.write(f"[pin  ] restart postgres for cores={ch['ncores']} (apply affinity)\n")
                        try:
                            if conn is not None:
                                conn.close()
                        except Exception:
                            pass
                        conn = None

                        stop_postgres(proc, logfh)
                        proc, logfh = start_postgres(postgres, datadir, port, BACKEND_LOG, cpu_set=desired_cpu_set)
                        current_cpu_set = set(desired_cpu_set)

                        if not wait_ready(psql, port):
                            raise RuntimeError("server did not become ready after restart")

                        conn = open_conn()

                    fe.write(
                        f"[run  ] chunk {idx}: cores={ch['ncores']} data={ch['ndata']} lambdas={ch['nlambdas']} "
                        f"pthread={ch['nthreads']}\n"
                    )

                    for r in range(1, WARM_UP_RUNS + 1):
                        _s, _rt = run_explain(conn, ch["sql"])
                        fe.write(f"[warm ] chunk {idx} run {r} (ignored)\n")

                    server_times: List[float] = []
                    rt_times: List[float] = []

                    for r in range(1, repeats + 1):
                        try:
                            s_ms, rt_ms = run_explain(conn, ch["sql"])
                        except DiskFull:
                            fe.write("[error] ENOSPC\n")
                            raise
                        except OperationalError as e:
                            fe.write(f"[error] OperationalError: {e}\n")
                            raise

                        server_times.append(s_ms)
                        rt_times.append(rt_ms)

                        fe.write(f"[meas ] chunk {idx} run {r}: server={s_ms:.3f} ms rt={rt_ms:.3f} ms\n")
                        w_core.writerow([
                            name, "corescaling",
                            ch["ncores"], ch["ndata"], ch["nlambdas"], ch["nthreads"],
                            r,
                            f"{s_ms:.3f}", f"{rt_ms:.3f}",
                        ])

                    fe.write(
                        f"[done ] chunk {idx}: med_server={statistics.median(server_times):.3f} ms "
                        f"med_rt={statistics.median(rt_times):.3f} ms\n"
                    )

            fe.write(f"[save ] baseline -> {BASELINE_CSV}\n")
            fe.write(f"[save ] cores    -> {CORESCALE_CSV}\n")

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


def main():
    if hasattr(os, "sched_setaffinity"):
        os.sched_setaffinity(0, PYTHON_CPUSET)

    t0 = time.perf_counter()
    benchmark(REPO, BASE_PORT, BM_REPEATS)
    t1 = time.perf_counter()
    print(f"[bench] done in {(t1 - t0):.3f}s")
    print(f"[bench] logs: {BACKEND_LOG}, {FRONTEND_LOG}")
    print(f"[bench] csv : {BASELINE_CSV}, {CORESCALE_CSV}")

if __name__ == "__main__":
    main()
