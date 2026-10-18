#!/usr/bin/env python3
"""
Result-equivalence test (NOT a timing benchmark).

Goal: leave no room to argue that HOL and the pure-SQL baseline compute
different things. Each pair names a generated benchmark on each side and a blob
index; both are run against the freshly built PostgreSQL and checked to produce
the *same result values* for the same input -- within a floating-point
tolerance, never with exact `=` on floats.

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
    python3 run_equivalence.py              # every pair below
    python3 run_equivalence.py --exact      # tolerant per-row join for HOL-vs-SQL pairs

The pairs are named by benchmark TYPE (benchmark.py), so each side runs the very
query file and session overlay the timed run uses. Two kinds of check:
  * streaming pairs, bit-identical checksums: the map operator vs CASE, and the free
    lambdas vs CASE (matched on (lambda_id, data_id)), at 10k x 100 and 80k x 350;
  * aggregating scalars (core sweep at width 8, use case at 10k x 100): every type's
    single avg() against the CASE one, relative tolerance TOL_REL -- the summation
    order differs between a Gather's partial aggregates and the operator's per-job
    sums, so these are close, not bit-identical.
10k x 100 exercises all 10 distinct FOL variants; 80k x 350 is the largest slice point,
where CASE has 350 arms and the operator compiles 350 bodies.
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


PG_REPO    = os.environ.get("PG_REPO") or os.path.join(REPO_ROOT, "hol-lambdas")
SETUP_SQL  = os.path.join(REPO_ROOT, "setup-scripts", "setup.sql")
BENCH_DIR  = os.path.join(REPO_ROOT, "benchmarks")

PORT       = 5457
DBNAME     = "equiv"
DATADIR    = os.path.join(HERE, "pgdata_equiv")
BACKEND_LOG = os.path.join(HERE, "backend.log")
WAIT_READY_S = 60.0

TOL_REL = 1e-9                 # pass threshold on (clamped) relative error

SPLIT_RE = re.compile(r"^\s*--\s*SPLIT\s*$", re.MULTILINE)
QUERY_RE = re.compile(r"^\s*--\s*QUERY\s*$", re.MULTILINE)

# The type registry is benchmark.py's, so file names and session overlays cannot
# drift from what the timed runs use.
sys.path.insert(0, REPO_ROOT)
import benchmark as B                      # noqa: E402

# Grid blobs (generate_benchmarks.cross_grid): 1 = 10k x 100, 16 = 80k x 350.
# Core sweep (SWEEP_POINTS 1,2,4,8,16): 4 = width 8. Use case: 1 = 10k x 100.
G_SMALL, G_LARGE, CORE_W8, UC_FIRST = 1, 16, 4, 1

# streaming pairs: (label, left type, left kind, right type, right kind, blob)
#   kind "hol" -> emits (x, y, z, result)
#   kind "sql" -> emits (lambda_id, data_id, result)
# hol vs sql joins data_id back to nums for the coordinates; sql vs sql compares
# (lambda_id, data_id, result) directly.
PAIRS = [
    ("map vs CASE (10k x 100)", "hol_pw_jitnoopt", "hol", "baseline_case_jitoff", "sql", G_SMALL),
    ("map vs CASE (80k x 350)", "hol_pw_jitnoopt", "hol", "baseline_case_jitoff", "sql", G_LARGE),
    ("free lambdas vs CASE (10k x 100)", "free_lambda_jitoff", "sql", "baseline_case_jitoff", "sql", G_SMALL),
    ("free lambdas vs CASE (80k x 350)", "free_lambda_jitoff", "sql", "baseline_case_jitoff", "sql", G_LARGE),
]

# aggregating scalars: (label, reference type, [types], blob)
SCALARS = [
    ("core sweep, width 8 (80k x 100)", "baseline_case_agg_cores_jitoff",
     ["free_lambda_agg_cores_jitoff", "agg_cores_pw_jitnoopt"], CORE_W8),
    ("use case (10k x 100)", "usecase_case_jitoff", ["usecase_map_pw_jitnoopt"], UC_FIRST),
]


def type_file(type_: str) -> str:
    return os.path.join(BENCH_DIR, f"benchmark_{B.TYPE_SQL_SOURCE.get(type_, type_)}.sql")


def type_settings(type_: str, setup: list) -> str:
    """The type's session overlay (as open_conn applies it) plus the blob's own setup lines."""
    gucs = B.with_lambda_cache_jit(B.TYPE_SESSION_SETTINGS.get(type_, {}))
    return "".join(f"set {k} = {v};\n" for k, v in gucs.items()) + "".join(l + "\n" for l in setup)


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
           "-c", "work_mem=1GB",
           # the main suite's free-lambda cache settings (benchmark.py PG_SETTINGS)
           "-c", "custom_lambda_cache_size=1000",
           "-c", "custom_lambda_jit_after_uses=0"]
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
def nth_blob(path: str, index: int = 1):
    """1-based blob from a generated file: (setup lines, the statement after --QUERY).
    The setup lines are replayed so each side runs the plan its timed run uses."""
    with open(path, "r", encoding="utf-8") as f:
        parts = SPLIT_RE.split(f.read())
    blobs = [p.strip() for p in parts if p.strip()]
    if len(blobs) < index:
        sys.exit(f"ERROR: {path} has {len(blobs)} blobs, wanted {index}")
    halves = QUERY_RE.split(blobs[index - 1], maxsplit=1)
    if len(halves) != 2:
        sys.exit(f"ERROR: {path} blob {index} has no --QUERY line; regenerate the benchmarks")
    setup = [l.strip() for l in halves[0].splitlines()
             if l.strip() and not l.strip().startswith("--")]
    return setup, halves[1].strip().rstrip(";")


# --------------------------------------------------------------------------
# Comparison SQL for one pair
# --------------------------------------------------------------------------
def _normalise(blob: str, kind: str) -> str:
    """Bring either side to (x, y, z, result)."""
    if kind == "hol":
        return blob
    # baseline emits (lambda_id, data_id, result); recover the data coordinates
    # (x,y,z) by joining data_id back to nums (the *stored* float8 values).
    return (f"select n.x as x, n.y as y, n.z as z, b.result as result\n"
            f"from (\n{blob}\n) b\njoin nums n on n.id = b.data_id")


def checksum_side_sql(blob: str, kind: str, settings: str = "", by_ids: bool = False) -> str:
    """
    One side's fingerprint, as its own statement.

    Deliberately NOT combined with the other side: a query that both calls apply_mt
    and contains a JIT-compiled SQL expression fails with "failed to JIT: evalexpr_*"
    (the UDF's internal JIT and the query's own JIT collide). Each side alone is fine,
    so we run them separately and compare in Python. That also keeps this disk-free --
    no temp tables, no join, both sides just stream through aggregates.

    hashfloat8 summed as numeric is exact and order-independent, so equal fingerprints
    mean bit-identical results, independent of row order or thread count. by_ids
    weights each hash by its (lambda_id, data_id) position, so a right value in the
    wrong cell also fails -- used when both sides emit the ids.

    A HOL side is materialised into a temp table first and fingerprinted from there:
    with forced JIT thresholds (L3 runs with jit_above_cost=0) the wrapping aggregate
    would itself be JIT-compiled in the same statement as the operator call.
    """
    head = "set jit = on;\nload 'llvmjit.so';\n" + settings
    if by_ids:
        fp = ("select count(*), coalesce(sum(hashfloat8(result)::numeric "
              "* (lambda_id::numeric * 1000003 + data_id)),0), "
              "coalesce(min(result),0), coalesce(max(result),0) from (\n" + blob + "\n) q")
        return head + fp
    fp = ("select count(*), coalesce(sum(hashfloat8(result)::numeric),0), "
          "coalesce(min(result),0), coalesce(max(result),0) from ")
    if kind == "hol":
        return (head + "create temp table side_res as\n" + blob + ";\n"
                + "reset all;\n" + fp + "side_res")
    return head + fp + "(\n" + _normalise(blob, kind) + "\n) q"


def run_checksum(label: str, left_blob: str, right_blob: str, right_kind: str,
                 left_settings: str = "", right_settings: str = "",
                 left_kind: str = "hol") -> bool:
    sides = {}
    by_ids = left_kind == "sql" and right_kind == "sql"
    for name, blob, kind, settings in (("left", left_blob, left_kind, left_settings),
                                       ("right", right_blob, right_kind, right_settings)):
        r = psql(["-tAF", "|", "-c", checksum_side_sql(blob, kind, settings, by_ids)],
                 capture_output=True, text=True)
        if r.returncode != 0:
            err = [l for l in (r.stderr or "").splitlines() if l.strip()]
            print(f"EQUIV ERROR [{label}]: {name} side failed: {err[-1] if err else 'unknown'}")
            return False
        line = [l for l in (r.stdout or "").strip().splitlines() if "|" in l]
        if not line:
            print(f"EQUIV ERROR [{label}]: {name} side produced no fingerprint")
            return False
        n, h, lo, hi = line[-1].split("|")
        sides[name] = (int(n), h.strip(), lo, hi)

    (ln, lh, llo, lhi), (rn, rh, rlo, rhi) = sides["left"], sides["right"]
    if ln != rn:
        print(f"EQUIV FAIL [{label}]: row counts differ ({ln:,} vs {rn:,})")
        return False
    if lh != rh:
        print(f"EQUIV FAIL [{label}]: value checksums differ "
              f"({lh} vs {rh}); ranges [{llo},{lhi}] vs [{rlo},{rhi}]. "
              f"Rerun with --exact for a tolerant per-row diff.")
        return False
    print(f"EQUIV PASS [{label}]: {ln:,} rows, bit-identical (checksum {lh})")
    return True


def run_scalar(label: str, ref: str, others: list, blob: int) -> bool:
    """Every aggregating type's single result against the reference type's."""
    vals = {}
    for t in [ref] + others:
        setup, sql = nth_blob(type_file(t), blob)
        r = psql(["-tA", "-c", "set jit = on;\nload 'llvmjit.so';\n"
                  + type_settings(t, setup) + sql + ";"], capture_output=True, text=True)
        out = [l for l in (r.stdout or "").splitlines() if l.strip()]
        if r.returncode != 0 or not out:
            err = [l for l in (r.stderr or "").splitlines() if l.strip()]
            print(f"EQUIV ERROR [{label}]: {t} failed: {err[-1] if err else 'no output'}")
            return False
        try:
            vals[t] = float(out[-1].split("|")[-1])
        except ValueError:
            print(f"EQUIV ERROR [{label}]: {t} returned {out[-1]!r}")
            return False
    ok = True
    for t in others:
        rel = abs(vals[t] - vals[ref]) / max(abs(vals[ref]), 1.0)
        good = rel <= TOL_REL
        ok = ok and good
        print(f"EQUIV {'PASS' if good else 'FAIL'} [{label}]: {t} {vals[t]!r} vs {ref} "
              f"{vals[ref]!r}, rel err {rel:.2e} (tol {TOL_REL})")
    return ok


def comparison_sql(label: str, hol_blob: str, base_blob: str, right_kind: str = "sql") -> str:
    base_norm = _normalise(base_blob, right_kind)
    return f"""
\\echo '==================================================================='
\\echo '>>> {label}  [exact/tolerant]'
set jit = on;
load 'llvmjit.so';

drop table if exists hol_res;
drop table if exists base_res;

-- HOL emits columns (x, y, z, result)
create temp table hol_res as
{hol_blob};

create temp table base_res as
{base_norm};

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
    ap.add_argument("--exact", action="store_true",
                    help="tolerant join comparison instead of the streaming checksum for the "
                         "HOL-vs-SQL pairs. Materialises both result sets -- needs real disk.")
    args = ap.parse_args()

    needed = {t for p in PAIRS for t in (p[1], p[3])} | {t for _, r, o, _ in SCALARS for t in [r] + o}
    for t in sorted(needed):
        if not os.path.isfile(type_file(t)):
            sys.exit(f"ERROR: {type_file(t)} missing -- run generate_benchmarks.py and "
                     f"generate_usecase_benchmarks.py in the repo root first.")

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
        for label, left_t, left_kind, right_t, right_kind, blob in PAIRS:
            print("=" * 67)
            print(f">>> {label}  [{left_t} vs {right_t}, blob {blob}]")
            l_setup, left_blob = nth_blob(type_file(left_t), blob)
            r_setup, right_blob = nth_blob(type_file(right_t), blob)
            if args.exact and left_kind == "hol" and right_kind == "sql":
                sql = comparison_sql(label, left_blob, right_blob, right_kind)
                r = psql(["-f", "-"], input=sql, text=True)
                ok = (r.returncode == 0)
            else:
                ok = run_checksum(label, left_blob, right_blob, right_kind,
                                  type_settings(left_t, l_setup),
                                  type_settings(right_t, r_setup),
                                  left_kind=left_kind)
            all_ok = all_ok and ok
        for label, ref, others, blob in SCALARS:
            print("=" * 67)
            print(f">>> {label}  [{len(others)} types vs {ref}, blob {blob}]")
            all_ok = run_scalar(label, ref, others, blob) and all_ok

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
