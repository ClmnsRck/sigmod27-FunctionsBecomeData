#!/usr/bin/env python3
"""
Turn a benchmark run into the comparisons the paper needs.

Reads results/<run_id>/*.csv (benchmark.py) and conditions_<type>.jsonl, and, when
given, the matching use-case run. Writes report.md next to the results.

  python3 report.py                          # newest run under results/
  python3 report.py results/bench_...        # a specific run
  python3 report.py results/bench_... results/usecase_...

Every number is the per-blob MINIMUM of the measured runs, which is what the paper's
figures plot (the threaded series are bimodal in host CPU frequency); the median is
shown beside it where it matters.
"""

from __future__ import annotations

import csv
import json
import os
import statistics as st
import sys
from typing import Dict, List, Tuple

Key = Tuple[int, int, int]     # (ndata, nlambdas, nthreads)
Stat = Dict[str, Dict[Key, float]]


def newest_run(root: str = "results") -> str:
    runs = [os.path.join(root, d) for d in os.listdir(root)
            if d.startswith("bench_") and os.path.isdir(os.path.join(root, d))]
    if not runs:
        sys.exit(f"no bench_* directories under {root}/")
    return max(runs, key=os.path.getmtime)


def load(result_root: str) -> Tuple[Stat, Stat]:
    """(minima, medians): type -> {(ndata, nlambdas, nthreads): ms}."""
    mins: Stat = {}
    meds: Stat = {}
    for fn in sorted(os.listdir(result_root)):
        if not fn.endswith(".csv"):
            continue
        with open(os.path.join(result_root, fn), newline="", encoding="utf-8") as fh:
            rows = [r for r in csv.DictReader(fh) if r.get("run_kind") == "measure"]
        if not rows:
            continue
        type_ = rows[0]["type"]
        buckets: Dict[Key, List[float]] = {}
        for r in rows:
            k = (int(r["ndata"]), int(r["nlambdas"]), int(r["nthreads"]))
            buckets.setdefault(k, []).append(float(r["server_ms"]))
        mins[type_] = {k: min(v) for k, v in buckets.items()}
        meds[type_] = {k: st.median(v) for k, v in buckets.items()}
    return mins, meds


def load_conditions(result_root: str) -> Dict[str, List[dict]]:
    out: Dict[str, List[dict]] = {}
    for fn in sorted(os.listdir(result_root)):
        if fn.startswith("conditions_") and fn.endswith(".jsonl"):
            with open(os.path.join(result_root, fn), encoding="utf-8") as fh:
                recs = [json.loads(l) for l in fh if l.strip()]
            if recs:
                out[recs[0]["type"]] = recs
    return out


def ratio_table(mins: Stat, meds: Stat, num: str, den: str, title: str,
                note: str = "") -> List[str]:
    """den / num, i.e. 'how many times faster is num than den'."""
    if num not in mins or den not in mins:
        return [f"### {title}", "", f"_missing: {num if num not in mins else den}_", ""]
    keys = sorted(set(mins[num]) & set(mins[den]))
    if not keys:
        return [f"### {title}", "", "_no overlapping points_", ""]
    out = [f"### {title}", ""] + ([note, ""] if note else [])
    out += [f"| rows | lambdas | threads | {num} ms | {den} ms | speedup (min) | speedup (median) |",
            "|---:|---:|---:|---:|---:|---:|---:|"]
    for k in keys:
        a, b = mins[num][k], mins[den][k]
        am, bm = meds[num][k], meds[den][k]
        out.append(f"| {k[0]:,} | {k[1]} | {k[2]} | {a:,.1f} | {b:,.1f} | **{b/a:.2f}x** | {bm/am:.2f}x |")
    sp = [mins[den][k] / mins[num][k] for k in keys]
    out += ["", f"min {min(sp):.2f}x / median {st.median(sp):.2f}x / max {max(sp):.2f}x "
                f"(above 1 = {num} faster; wins at {sum(s > 1 for s in sp)}/{len(sp)} points)", ""]
    return out


def sweep_table(mins: Stat, types: List[str]) -> List[str]:
    present = [t for t in types if t in mins]
    if not present:
        return []
    threads = sorted({k[2] for t in present for k in mins[t]})
    out = ["### Core sweep (minima, ms)", "",
           "| type | " + " | ".join(f"{n}t" for n in threads) + " | 1t / best |",
           "|---" + "|---:" * (len(threads) + 1) + "|"]
    for t in present:
        by_w = {k[2]: v for k, v in mins[t].items()}
        cells = [f"{by_w[n]:,.0f}" if n in by_w else "-" for n in threads]
        scal = f"{by_w[min(by_w)] / min(by_w.values()):.2f}x" if by_w else "-"
        out.append(f"| {t} | " + " | ".join(cells) + f" | **{scal}** |")
    return out + [""]


def conditions_table(conds: Dict[str, List[dict]]) -> List[str]:
    if not conds:
        return []
    out = ["## Run conditions (from the verify runs)", "",
           "| type | blobs | all ok | workers launched | JIT options seen | JIT functions | jit / max_par |",
           "|---|---:|:---:|---|---|---|---|"]
    for t, recs in conds.items():
        ok = all(r.get("ok") for r in recs)
        launched = sorted({str(r["workers"]["launched"]) for r in recs})
        opts = sorted({json.dumps(r["jit_explain"].get("options"), sort_keys=True) for r in recs})
        funcs = sorted({str(r["jit_explain"].get("functions")) for r in recs})
        g = recs[0].get("session", {}).get("gucs", {})
        out.append(f"| {t} | {len(recs)} | {'yes' if ok else '**NO**'} | {','.join(launched)} | "
                   f"{'<br>'.join(opts)} | {','.join(funcs)} | "
                   f"{g.get('jit')} / {g.get('max_parallel_workers_per_gather')} |")
    bad = [(t, r["blob"]) for t, recs in conds.items() for r in recs if not r.get("ok")]
    out += ["", f"blobs failing a width/plan check: {bad or 'none'}", ""]
    return out


def main() -> None:
    result_root = sys.argv[1] if len(sys.argv) > 1 else newest_run()
    uc_root = sys.argv[2] if len(sys.argv) > 2 else None
    run_id = os.path.basename(result_root.rstrip("/"))

    mins, meds = load(result_root)
    if not mins:
        sys.exit(f"no measured rows in {result_root}")
    doc: List[str] = [f"# Benchmark report -- {run_id}", "",
                      f"types present: {', '.join(sorted(mins))}", "",
                      "All numbers are per-blob minima unless a column says median.", ""]

    doc += ["## Grid slices (combined_scaling a/c)", ""]
    doc += ratio_table(mins, meds, "hol_pw_jitnoopt", "baseline_case_jitoff", "map vs CASE")
    doc += ratio_table(mins, meds, "hol_pw_jitnoopt", "free_lambda_jitoff", "map vs free lambdas")
    doc += ratio_table(mins, meds, "free_lambda_jitoff", "baseline_case_jitoff", "free lambdas vs CASE")

    doc += ["## Core sweep (combined_scaling b, all aggregating)", ""]
    doc += sweep_table(mins, ["agg_cores_pw_jitnoopt", "baseline_case_agg_cores_jitoff",
                              "free_lambda_agg_cores_jitoff"])
    doc += ratio_table(mins, meds, "agg_cores_pw_jitnoopt", "baseline_case_agg_cores_jitoff",
                       "Sweep, map vs CASE")

    doc += conditions_table(load_conditions(result_root))

    if uc_root and os.path.isdir(uc_root):
        umins, umeds = load(uc_root)
        doc += [f"## Use case (usecase_benchmark) -- {os.path.basename(uc_root.rstrip('/'))}", ""]
        doc += ratio_table(umins, umeds, "usecase_map_pw_jitnoopt", "usecase_case_jitoff", "map vs CASE")
        doc += conditions_table(load_conditions(uc_root))

    out = os.path.join(result_root, "report.md")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(doc) + "\n")
    print(f"[report] {out}")


if __name__ == "__main__":
    main()
