#!/usr/bin/env python3
"""
Aggregate a run_ptime.py run into the two CSVs the combined_timing figure reads.

    python3 additional-tests/timing/agg_ptime.py results/timing_<stamp>

Writes into the run directory:
  v2_timing_pw.csv        panels a/b: per data size, mean/median/min over the measured
                          rounds, in ms (12 lambdas, map operator)
  v2_timing_scale_pw.csv  panel c: per body repeat, median/mean/min, in microseconds
                          (50k rows x 20 lambdas, aggregating operator)
Only the instrumented runs count; round 0 is the warm-up.
"""

import json
import statistics as st
import sys
from pathlib import Path
from typing import Dict, List

import pandas as pd

PHASES = ["prep", "materialize_input", "inject", "eval", "rematerialize_output",
          "readout_full", "readout", "executor_end", "total", "pre_udf", "wall_us"]
KEYS = ["nworkers", "num_tuples_data", "num_tuples_lambdas"]


def load(run_dir: Path) -> List[dict]:
    recs = []
    with open(run_dir / "records.jsonl", encoding="utf-8") as fh:
        for line in fh:
            r = json.loads(line)
            if r.get("variant") == "ptime" and r.get("round", 0) >= 1:
                r["readout_full"] = r["readout"] + r["executor_end"]
                recs.append(r)
    return recs


def aggregate(recs: List[dict], kind: str, scale: float, stats: List[str], xname: str) -> pd.DataFrame:
    rows = []
    for x in sorted({r["x"] for r in recs if r["kind"] == kind}):
        g = [r for r in recs if r["kind"] == kind and r["x"] == x]
        row: Dict[str, float] = {}
        if xname != "num_tuples_data":
            row[xname] = x
        row["n"] = len(g)
        row.update({k: g[0][k] for k in KEYS})
        for p in PHASES:
            vals = [r[p] / scale for r in g]
            for s in stats:
                row[f"{p}_{s}"] = {"mean": st.mean, "median": st.median, "min": min}[s](vals)
        rows.append(row)
    return pd.DataFrame(rows)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    run_dir = Path(sys.argv[1])
    recs = load(run_dir)
    if not recs:
        sys.exit(f"no measured records in {run_dir / 'records.jsonl'}")
    aggregate(recs, "map", 1000.0, ["mean", "median", "min"], "num_tuples_data") \
        .to_csv(run_dir / "v2_timing_pw.csv", index=False)
    aggregate(recs, "agg", 1.0, ["median", "mean", "min"], "body_repeat") \
        .to_csv(run_dir / "v2_timing_scale_pw.csv", index=False)
    print(f"[ok] wrote {run_dir / 'v2_timing_pw.csv'} and {run_dir / 'v2_timing_scale_pw.csv'}")


if __name__ == "__main__":
    main()
