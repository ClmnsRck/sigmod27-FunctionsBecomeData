#!/usr/bin/env python3
"""Phase timing of the map operator (combined_timing figure).

    python3 additional-tests/timing/run_ptime.py              # the paper's run
    python3 additional-tests/timing/run_ptime.py --smoke      # 1 round, 2+2 points
    python3 additional-tests/timing/agg_ptime.py results/timing_<stamp>

Builds an instrumented copy of apply_mt_pw (make_ptime.py) next to its results, starts
its own cluster with benchmark.py's server settings and CPU fence, and measures:
  panels a/b  apply_mt_pw_ptime over 10k..100k rows of nums_smol (100k x 7 floats, seed
              0.42) x 12 lambdas (4 first-order x 3 second-order),
  panel c     apply_mt_agg_pw_ptime over 50k rows x 20 lambdas (4 x 5), with the lambda
              body repeated 1..50 times.
L3 (mode 1), 16 workers, hol_pw_jitnoopt session settings (PW_NOOPT). 10 measured rounds
after one warm-up, points shuffled per round; the installed operator runs interleaved in
a second backend, as a check that the stamps cost nothing. Writes records.jsonl (one
line per query) to results/timing_<stamp>/.
"""
import argparse, json, os, random, shutil, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, ROOT)
import benchmark as B
import psycopg

OUT = ""
SO = ""
RUNS = 10
WIDTH = 16
NDATA = [10000, 20000, 30000, 40000, 50000, 60000, 70000, 80000, 90000, 100000]
REPEATS = list(range(1, 51))
TOP = ("lambda(a:[x:float, y:float, z:float],\n"
       "       b:[f:(float,float->float),\n"
       "          g:(float,float,float,(float,float->float)->float)])")
BODY = "b.g(a.x, a.y, a.z, b.f) + a.z"

# filled in by main() once the instrumented library's path is known
SETUP = """
SELECT setseed(0.42);
drop table if exists nums_smol;
create UNLOGGED table nums_smol(x float not null, y float not null, z float not null, a float not null,
                                b float not null, c float not null, d float not null);
insert into nums_smol (x, y, z, a, b, c, d)
select random()::float, random()::float, random()::float, random()::float,
       random()::float, random()::float, random()::float
from generate_series(1, 100000);

create or replace function apply_mt_pw_ptime("lambda", lambdatable, lambdatable, int, int)
returns setof record as '{SO}', 'apply_mt_pw_ptime' language C STRICT;
create or replace function apply_mt_agg_pw_ptime("lambda", lambdatable, lambdatable, int, int)
returns setof record as '{SO}', 'apply_mt_agg_pw_ptime' language C STRICT;
create or replace function apply_mt_pw("lambda", lambdatable, lambdatable, int, int)
returns setof record as '$libdir/apply_mt_pw_ext.so', 'apply_mt_pw' language C STRICT;
create or replace function apply_mt_agg_pw("lambda", lambdatable, lambdatable, int, int)
returns setof record as '$libdir/apply_mt_pw_ext.so', 'apply_mt_agg_pw' language C STRICT;

create table lambdas_order_1 (f lambda(float8, float8 -> float8) not null, description TEXT);
create table lambdas_order_2 (g lambda(float8, float8, float8, (float8, float8 -> float8) -> float8) not null,
                              description TEXT);
insert into lambdas_order_1 values
(lambda(x, y)(log(x + 1.0) + exp(y)), 'First-Order: Log-Exp transform'),
(lambda(x, y)(abs(x - y)), 'First-Order: Absolute difference'),
(lambda(x, y)(x^2 + y^2), 'First-Order: Euclidean norm squared'),
(lambda(x, y)(exp(x/10.0) + exp(y/10.0)), 'First-Order: Exp-Check');
-- panels a/b: three second-order lambdas
insert into lambdas_order_2 values
(lambda(x, y, z, f)(f(x, y) * z), 'Second-Order: Weighted lambda eval'),
(lambda(x, y, z, f)(z * f(y, x)^2), 'Second-Order: Quadratic lambda eval'),
(lambda(x, y, z, f)(f(x, y) - exp(z/10.0)), 'Second-Order: Exp-Check');
create table lambdas_table_helper12 as select f, g from lambdas_order_1 cross join lambdas_order_2;
-- panel c: all five
insert into lambdas_order_2 values
(lambda(x, y, z, f)(f(y, y) - f(z, z)), 'Second-Order: Diagonal diff'),
(lambda(x, y, z, f)(f(x + z, y) + sin(z)), 'Second-Order: Lambda + sine mod');
create table lambdas_table_helper20 as select f, g from lambdas_order_1 cross join lambdas_order_2;
ANALYZE;
"""


def q_map(fn, n):
    return (f"SELECT count(*) FROM {fn}(\n{TOP}\n  ({BODY}),\n"
            f"  (SELECT * FROM nums_smol LIMIT {n}),\n  (SELECT * FROM lambdas_table_helper12),\n"
            f"  {WIDTH}, 1);")


def q_agg(fn, r, select="count(*)"):
    body = " + ".join(f"({BODY})" for _ in range(r))
    return (f"SELECT {select} FROM {fn}(\n{TOP}\n  ({body}),\n"
            f"  (SELECT * FROM nums_smol LIMIT 50000),\n  (SELECT * FROM lambdas_table_helper20),\n"
            f"  {WIDTH}, 1);")


def parse(notices):
    chunks = [n for n in notices if "TIMING_RESULTS_MARKER" in n]
    assert len(chunks) == 1, notices
    rec = {}
    for line in chunks[0].splitlines()[2:-1]:
        k, v = line.strip().split("=", 1)
        v = v.replace(" us", "")
        rec[k] = float(v) if "." in v else int(v)
    return rec


def connect(dsn, notices):
    conn = psycopg.connect(dsn, autocommit=True)
    conn.prepare_threshold = None
    conn.add_notice_handler(lambda d: notices.append(d.message_primary))
    with conn.cursor() as cur:
        for k, v in {"client_min_messages": "notice", "plan_cache_mode": "force_custom_plan",
                     "synchronous_commit": "off", "extra_float_digits": "3",
                     "max_parallel_workers_per_gather": str(WIDTH),
                     "custom_lambda_debugging_var": "off", **B.PW_NOOPT}.items():
            cur.execute(f"SET {k} = {v};")
    return conn


def leader_cpu_khz(pid):
    try:
        s = open(f"/proc/{pid}/stat").read()
        cpu = int(s[s.rindex(")") + 2:].split()[36])
        return cpu, int(open(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq/scaling_cur_freq").read())
    except OSError:
        return -1, -1


def timed(conn, sql):
    with conn.cursor() as cur:
        cur.execute("DISCARD PLANS;")
        t0 = time.monotonic_ns()
        cur.execute(sql)
        row = cur.fetchone()
        t1 = time.monotonic_ns()
    return row[0], (t1 - t0) / 1000.0


def build_ptime_so(repo: str) -> None:
    """The instrumented operator, compiled with the exact flags of hol-lambdas/src/ext."""
    here = os.path.dirname(os.path.abspath(__file__))
    src = os.path.join(OUT, "apply_mt_pw_ptime_ext.c")
    subprocess.run([sys.executable, os.path.join(here, "make_ptime.py"),
                    os.path.join(repo, "src", "ext", "apply_mt_pw_ext.c"), src], check=True)
    rule = "ptime_so: ; $(CC) -O2 -fPIC $(CPPFLAGS) $(CFLAGS) -I../include -shared -o $(PTIME_SO) $(PTIME_SRC)"
    subprocess.run(["make", "-s", "-C", os.path.join(repo, "src", "ext"), "--eval", rule, "ptime_so",
                    f"PTIME_SO={SO}", f"PTIME_SRC={src}"], check=True)


def main():
    global OUT, SO, RUNS, NDATA, REPEATS
    ap = argparse.ArgumentParser(description="Phase timing of the map operator (combined_timing figure).")
    ap.add_argument("--out", default=None, help="output directory (default: results/timing_<stamp>)")
    ap.add_argument("-r", "--runs", type=int, default=RUNS, help=f"measured rounds (default {RUNS})")
    ap.add_argument("--topology", choices=sorted(B.TOPOLOGIES), default="server")
    ap.add_argument("--smoke", action="store_true", help="1 round, two points per panel")
    args = ap.parse_args()
    os.chdir(ROOT)
    OUT = os.path.abspath(args.out or os.path.join("results", time.strftime("timing_%Y%m%d_%H%M%S")))
    SO = os.path.join(OUT, "apply_mt_pw_ptime_ext.so")
    RUNS = 1 if args.smoke else args.runs
    if args.smoke:
        NDATA, REPEATS = [10000, 20000], [1, 2]
    os.makedirs(OUT, exist_ok=True)
    print(f"[timing] output: {OUT}", flush=True)

    cfg = B.replace(B.CFG, **B.TOPOLOGIES[args.topology])
    B.check_topology(cfg, os.cpu_count() or 0)
    os.sched_setaffinity(0, B.python_cpuset(cfg))
    build_ptime_so(cfg.repo_dir)
    repo = cfg.repo_dir
    postgres, initdb, psql = (B.bin_path(repo, x) for x in ("postgres", "initdb", "psql"))
    datadir = os.path.join(OUT, "pgdata")
    port = cfg.base_port
    out = open(os.path.join(OUT, "records.jsonl"), "w", buffering=1)
    B.reset_pgdata(initdb, datadir)
    proc, logfh = B.start_postgres(postgres, datadir, port, os.path.join(OUT, "backend.log"),
                                   B.postgres_cpuset(cfg), cfg)
    try:
        assert B.wait_ready(psql, port), "postgres not ready"
        B.run(B.psql_args(psql, port, "postgres") + ["-v", "ON_ERROR_STOP=1", "-q", "-c", SETUP.format(SO=SO)],
              check=True, stdout=subprocess_devnull())
        dsn = f"host=127.0.0.1 port={port} dbname=postgres"
        nt, npl = [], []
        ct, cp = connect(dsn, nt), connect(dsn, npl)
        meta = {"settings": {}, "so": SO}
        with ct.cursor() as cur:
            for g in ("jit", "jit_above_cost", "jit_optimize_above_cost", "jit_inline_above_cost",
                      "min_dynamic_shared_memory", "work_mem", "max_parallel_workers", "max_worker_processes"):
                cur.execute(f"SHOW {g};"); meta["settings"][g] = cur.fetchone()[0]
            cur.execute("SELECT version();"); meta["version"] = cur.fetchone()[0]
        out.write(json.dumps({"meta": meta}) + "\n")

        # equivalence: timed copy == installed operator, bit for bit
        eq = {}
        for n in (10000, 100000):
            sel = lambda fn: (f"SELECT count(*), sum(hashfloat8(result)::numeric), sum(result) FROM {fn}(\n{TOP}\n"
                              f"  ({BODY}),\n  (SELECT * FROM nums_smol LIMIT {n}),\n"
                              f"  (SELECT * FROM lambdas_table_helper12),\n  {WIDTH}, 1);")
            with ct.cursor() as cur:
                cur.execute(sel("apply_mt_pw_ptime")); a = cur.fetchone()
            with cp.cursor() as cur:
                cur.execute(sel("apply_mt_pw")); b = cur.fetchone()
            eq[f"map_{n}"] = [str(a), str(b), a == b]
        for r in (1, 25, 50):
            with ct.cursor() as cur:
                cur.execute(q_agg("apply_mt_agg_pw_ptime", r, "result::text")); a = cur.fetchone()
            with cp.cursor() as cur:
                cur.execute(q_agg("apply_mt_agg_pw", r, "result::text")); b = cur.fetchone()
            eq[f"agg_r{r}"] = [a[0], b[0], a == b]
        nt.clear(); npl.clear()
        out.write(json.dumps({"equivalence": eq}) + "\n")
        print("equivalence", json.dumps(eq), flush=True)

        points = [("map", n) for n in NDATA] + [("agg", r) for r in REPEATS]
        rng = random.Random(42)
        for rnd in range(RUNS + 1):            # round 0 = warm-up, discarded
            order = points[:]
            rng.shuffle(order)
            for kind, v in order:
                pair = [("ptime", ct, nt), ("plain", cp, npl)]
                if (rnd + v) % 2:
                    pair.reverse()
                for variant, conn, notes in pair:
                    if kind == "map":
                        sql = q_map("apply_mt_pw_ptime" if variant == "ptime" else "apply_mt_pw", v)
                    else:
                        sql = q_agg("apply_mt_agg_pw_ptime" if variant == "ptime" else "apply_mt_agg_pw", v)
                    notes.clear()
                    cnt, wall_us = timed(conn, sql)
                    cpu, khz = leader_cpu_khz(conn.info.backend_pid)
                    rec = {"round": rnd, "kind": kind, "x": v, "variant": variant, "count": cnt,
                           "wall_us": wall_us, "leader_cpu": cpu, "leader_khz": khz}
                    if variant == "ptime":
                        rec.update(parse(notes))
                    elif notes:
                        rec["notices"] = list(notes)
                    out.write(json.dumps(rec) + "\n")
            print(f"round {rnd} done {time.strftime('%H:%M:%S')}", flush=True)
        ct.close(); cp.close()
    finally:
        B.stop_postgres(proc, logfh)
        shutil.rmtree(datadir, ignore_errors=True)
    print("DONE", flush=True)


def subprocess_devnull():
    import subprocess
    return subprocess.DEVNULL


if __name__ == "__main__":
    main()
