#!/usr/bin/env python3
"""
Result-equivalence test (NOT a timing benchmark).

Goal: leave no room to argue that HOL and the pure-SQL baseline compute
different things. We take the *first blob* of each generated benchmark
(benchmarks/benchmark_hol.sql vs benchmark_baseline.sql, and the cores pair),
run both against the freshly built PostgreSQL, and check that they produce the
*same result values* for the same input -- within a floating-point tolerance,
never with exact `=` on floats.

How the comparison avoids FP pitfalls and ordering pitfalls:
  * HOL emits (x, y, z, result); the baseline emits (lambda_id, data_id, result).
    We key both on the data coordinates (x,y,z), which are the *stored* float8
    values copied through unchanged on both sides -> bit-identical, so equality
    join on them is exact and safe (no arithmetic was applied to the keys).
  * Result *values* are compared with a relative/absolute tolerance, never `=`.
  * Lambda ordering is irrelevant: within each data point we sort the M result
    values on both sides and compare the i-th vs i-th. Equal multisets per data
    point => identical computation, regardless of emission order or threading.
  * We also assert no unmatched rows (FULL OUTER JOIN), so cardinalities match.

PASS iff: 0 unmatched rows AND max_rel <= TOL_REL for every pair. With the
denominator clamped to >= 1, max_rel is true relative error for |value|>=1 and
(stricter) absolute error for |value|<1, so one threshold covers both.

Usage:
    python3 run_equivalence.py              # data/lambda pair (10k x 50)
    python3 run_equivalence.py --with-cores # also the 8M-row cores pair
                                            # (80k x 100; needs several GB of
                                            #  temp disk for the two materialised
                                            #  result sets + join)

The default (data/lambda) pair already exercises all 10 distinct FOL variants
(50 lambdas = 5 full cycles of 10) through the identical apply_mt and baseline
SQL, so it is sufficient to prove value-equivalence. The cores pair only repeats
the same 10 variants over more rows; it is opt-in because it is disk-heavy.
"""
import os
import re
import sys
import time
import signal
import shutil
import argparse
import subprocess

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
HERE       = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT  = os.path.abspath(os.path.join(HERE, "..", ".."))


def _find_pg_repo() -> str:
    # the PostgreSQL fork is checked out as "hol-postgres" (server) or
    # "hol-lambdas" (local); pick whichever has a built install.
    for name in ("hol-postgres", "hol-lambdas"):
        cand = os.path.join(REPO_ROOT, name)
        if os.path.isfile(os.path.join(cand, "install", "bin", "postgres")):
            return cand
    # fall back to the conventional name so the error message is sensible
    return os.path.join(REPO_ROOT, "hol-lambdas")


PG_REPO    = os.environ.get("PG_REPO") or _find_pg_repo()
SETUP_SQL  = os.path.join(REPO_ROOT, "setup-scripts", "setup.sql")
BENCH_DIR  = os.path.join(REPO_ROOT, "benchmarks")

PORT       = 5457
DBNAME     = "equiv"
DATADIR    = os.path.join(HERE, "pgdata_equiv")
BACKEND_LOG = os.path.join(HERE, "backend.log")
WAIT_READY_S = 60.0

NTHREADS_MARKER = "NTHREADS_MARKER"
NTHREADS_FOR_TEST = "8"        # result is independent of thread count
TOL_REL = 1e-9                 # pass threshold on (clamped) relative error

SPLIT_RE = re.compile(r"^\s*--\s*SPLIT\s*$", re.MULTILINE)

# (label, hol_file, baseline_file)
PAIRS = [
    ("data/lambda (first blob: 10k tuples, 50 lambdas)",
     "benchmark_hol.sql", "benchmark_baseline.sql"),
    ("cores (first blob: 80k tuples, 100 lambdas)",
     "benchmark_cores.sql", "benchmark_baseline_cores.sql"),
]


# --------------------------------------------------------------------------
# Server helpers
# --------------------------------------------------------------------------
def bin_path(exe: str) -> str:
    p = os.path.join(PG_REPO, "install", "bin", exe)
    if not (os.path.isfile(p) and os.access(p, os.X_OK)):
        sys.exit(f"ERROR: missing built binary {p}\n"
                 f"Build the project first (./build_helper.sh).")
    return p


def psql(args, **kw):
    cmd = [bin_path("psql"), "-h", "127.0.0.1", "-p", str(PORT), "-d", DBNAME,
           "-v", "ON_ERROR_STOP=1", "-X", "-q"] + args
    return subprocess.run(cmd, **kw)


def reset_datadir():
    stop_any()
    shutil.rmtree(DATADIR, ignore_errors=True)
    os.makedirs(DATADIR, exist_ok=True)
    subprocess.run([bin_path("initdb"), "-D", DATADIR, "-A", "trust",
                    "-E", "UTF8", "--no-locale"],
                   check=True, stdout=subprocess.DEVNULL)


def stop_any():
    # best-effort stop of a previous instance on this datadir
    pgctl = os.path.join(PG_REPO, "install", "bin", "pg_ctl")
    if os.path.isdir(DATADIR) and os.path.isfile(pgctl):
        subprocess.run([pgctl, "-D", DATADIR, "stop", "-m", "immediate"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def start_postgres():
    logfh = open(BACKEND_LOG, "ab")
    cmd = [bin_path("postgres"), "-D", DATADIR, "-p", str(PORT),
           "-c", "listen_addresses=127.0.0.1",
           "-c", "shared_preload_libraries=llvmjit",
           "-c", "fsync=off", "-c", "synchronous_commit=off",
           "-c", "full_page_writes=off",
           "-c", "work_mem=1GB"]
    proc = subprocess.Popen(cmd, stdout=logfh, stderr=subprocess.STDOUT,
                            preexec_fn=os.setsid)
    return proc, logfh


def stop_postgres(proc, logfh):
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        proc.wait(timeout=20)
    except Exception:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            pass
    try:
        logfh.close()
    except Exception:
        pass


def wait_ready():
    deadline = time.time() + WAIT_READY_S
    psqlbin = bin_path("psql")
    while time.time() < deadline:
        r = subprocess.run([psqlbin, "-h", "127.0.0.1", "-p", str(PORT),
                            "-d", "postgres", "-tAc", "select 1"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if r.returncode == 0:
            return True
        time.sleep(0.5)
    return False


# --------------------------------------------------------------------------
# Blob extraction
# --------------------------------------------------------------------------
def first_blob(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        parts = SPLIT_RE.split(f.read())
    blobs = [p.strip() for p in parts if p.strip()]
    if not blobs:
        sys.exit(f"ERROR: no SQL blobs in {path}")
    sql = blobs[0].rstrip().rstrip(";")
    return sql.replace(NTHREADS_MARKER, NTHREADS_FOR_TEST)


# --------------------------------------------------------------------------
# Comparison SQL for one pair
# --------------------------------------------------------------------------
def comparison_sql(label: str, hol_blob: str, base_blob: str) -> str:
    return f"""
\\echo '==================================================================='
\\echo '>>> {label}'
set jit = on;
load 'llvmjit.so';

drop table if exists hol_res;
drop table if exists base_res;

-- HOL emits columns (x, y, z, result)
create temp table hol_res as
{hol_blob};

-- baseline emits (lambda_id, data_id, result); recover the data coordinates
-- (x,y,z) by joining data_id back to nums (the *stored* float8 values).
create temp table base_res as
select n.x as x, n.y as y, n.z as z, b.result as result
from (
{base_blob}
) b
join nums n on n.id = b.data_id;

-- per-data-point sorted-vector comparison (order-independent, FP-tolerant)
with h as (
  select x, y, z, result,
         row_number() over (partition by x, y, z order by result, ctid) as rn
  from hol_res
),
b as (
  select x, y, z, result,
         row_number() over (partition by x, y, z order by result, ctid) as rn
  from base_res
),
j as (
  select h.result as hr, b.result as br
  from h full outer join b using (x, y, z, rn)
)
select
  (select count(*) from hol_res)  as hol_rows,
  (select count(*) from base_res) as base_rows,
  count(*) filter (where hr is null or br is null) as unmatched,
  coalesce(max(abs(hr - br)), 0)                                    as max_abs_err,
  coalesce(max(abs(hr - br) / greatest(abs(hr), abs(br), 1.0)), 0)  as max_rel_err
into temp cmp
from j;

select * from cmp;

do $$
declare r record;
begin
  select * into r from cmp;
  if r.hol_rows <> r.base_rows then
    raise exception 'EQUIV FAIL [{label}]: row counts differ (HOL=%, baseline=%)',
      r.hol_rows, r.base_rows;
  end if;
  if r.unmatched <> 0 then
    raise exception 'EQUIV FAIL [{label}]: % unmatched rows', r.unmatched;
  end if;
  if r.max_rel_err > {TOL_REL} then
    raise exception 'EQUIV FAIL [{label}]: max_rel_err=% exceeds tol={TOL_REL} (max_abs_err=%)',
      r.max_rel_err, r.max_abs_err;
  end if;
  raise notice 'EQUIV PASS [{label}]: % rows, max_abs_err=%, max_rel_err=% (tol={TOL_REL})',
    r.hol_rows, r.max_abs_err, r.max_rel_err;
end $$;
"""


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="HOL vs SQL result-equivalence test.")
    ap.add_argument("--with-cores", action="store_true",
                    help="also run the 8M-row cores pair (disk-heavy).")
    args = ap.parse_args()

    pairs = PAIRS if args.with_cores else PAIRS[:1]
    for _, hol_f, base_f in pairs:
        for f in (hol_f, base_f):
            p = os.path.join(BENCH_DIR, f)
            if not os.path.isfile(p):
                sys.exit(f"ERROR: {p} missing -- run `python3 generate_benchmarks.py` "
                         f"in the repo root first.")

    proc = logfh = None
    try:
        print("[*] init + start postgres ...")
        reset_datadir()
        proc, logfh = start_postgres()
        if not wait_ready():
            sys.exit("ERROR: postgres did not become ready")

        subprocess.run([bin_path("createdb"), "-h", "127.0.0.1", "-p", str(PORT),
                        DBNAME], check=True)

        print(f"[*] loading setup ({SETUP_SQL}) ...")
        r = psql(["-f", SETUP_SQL], stdout=subprocess.DEVNULL)
        if r.returncode != 0:
            sys.exit("ERROR: setup.sql failed")

        all_ok = True
        for label, hol_f, base_f in pairs:
            hol_blob = first_blob(os.path.join(BENCH_DIR, hol_f))
            base_blob = first_blob(os.path.join(BENCH_DIR, base_f))
            sql = comparison_sql(label, hol_blob, base_blob)
            r = psql(["-f", "-"], input=sql, text=True)
            if r.returncode != 0:
                all_ok = False

        print("\n" + ("=" * 67))
        if all_ok:
            print("RESULT: PASS -- HOL and SQL baseline produce identical results "
                  "(within FP tolerance).")
            rc = 0
        else:
            print("RESULT: FAIL -- see the EQUIV FAIL message(s) above.")
            rc = 1
        print("=" * 67)
        return rc
    finally:
        if proc is not None:
            stop_postgres(proc, logfh)


if __name__ == "__main__":
    sys.exit(main())
