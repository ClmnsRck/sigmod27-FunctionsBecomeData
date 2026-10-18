#!/usr/bin/env python3
"""
Turn a benchmark run (and a use-case run) into the CSVs the paper's figures read.

    python3 results/publish_to_paper.py bench_<stamp> --usecase-run usecase_<stamp>

Writes, under --out (default results/paper_csv/<run_id>/), with --prefix (default
"bic", the prefix of the published figures' data):
  combined_scaling (a)/(c): <prefix>_<type>_agg_nlambdas_100.csv, _agg_ndata_80000.csv
                            for hol_pw_jitnoopt, baseline_case_jitoff, free_lambda_jitoff
  combined_scaling (b):     <prefix>_<type>_agg.csv for agg_cores_pw_jitnoopt,
                            baseline_case_agg_cores_jitoff, free_lambda_agg_cores_jitoff
  usecase_benchmark:        <prefix>_usecase_data_scaling.csv, _model_scaling.csv
Copy them into the paper's bm_results/ to rebuild the figures from a new run.
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path
from typing import Dict, List

import pandas as pd

from agg_bench_results import aggregate

RESULTS = Path(__file__).resolve().parent

# Straight copies of the aggregated curves (agg_bench_results.py).
COPY_FILES = [
    f"{t}_agg_{cut}.csv"
    for t in ("hol_pw_jitnoopt", "baseline_case_jitoff", "free_lambda_jitoff")
    for cut in ("nlambdas_100", "ndata_80000")
] + [
    f"{t}_agg.csv"
    for t in ("agg_cores_pw_jitnoopt", "baseline_case_agg_cores_jitoff", "free_lambda_agg_cores_jitoff")
]

# Use-case sweeps, mirroring generate_usecase_benchmarks.py.
USECASE_MODELS_PIN = 100     # nmodels held fixed while ndata scales
USECASE_NDATA_PIN = 10000    # ndata held fixed while nmodels scales

# column label in the published CSV -> benchmark type
USECASE_TYPES = {
    "pwnoopt": "usecase_map_pw_jitnoopt",
    "caseoff": "usecase_case_jitoff",
}


def _usecase_cuts(usecase_dir: Path) -> Dict[str, pd.DataFrame]:
    frames: List[pd.DataFrame] = []
    for label, type_name in USECASE_TYPES.items():
        matches = sorted(usecase_dir.glob(f"*_{type_name}.csv"))
        if not matches:
            raise SystemExit(f"no use-case CSV for type {type_name} in {usecase_dir}")
        df = pd.read_csv(matches[0])
        df = df[df["run_kind"].str.lower() == "measure"]  # excludes warmup and verify
        frames.append(
            df.groupby(["ndata", "nlambdas"])["server_ms"]
            .agg(["mean", "median", "min"])
            .reset_index()
            .rename(columns={"nlambdas": "nmodels", "mean": f"{label}_ms_mean",
                             "median": f"{label}_ms_median", "min": f"{label}_ms_min"})
        )

    merged = frames[0]
    for f in frames[1:]:
        merged = merged.merge(f, on=["ndata", "nmodels"])
    merged = merged[["ndata", "nmodels"] + [
        f"{label}_ms_{stat}" for stat in ("mean", "median", "min") for label in USECASE_TYPES]]

    data_cut = merged[merged["nmodels"] == USECASE_MODELS_PIN].sort_values("ndata")
    model_cut = merged[merged["ndata"] == USECASE_NDATA_PIN].sort_values("nmodels")
    return {"usecase_data_scaling.csv": data_cut, "usecase_model_scaling.csv": model_cut}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_id", help="main run under results/, e.g. bench_20261016_020051")
    ap.add_argument("--usecase-run", default=None, help="use-case run under results/, e.g. usecase_20261016_023213")
    ap.add_argument("--prefix", default="bic", help="file name prefix (default: bic)")
    ap.add_argument("--out", type=Path, default=None,
                    help="output directory (default: results/paper_csv/<run_id>)")
    args = ap.parse_args()

    run_dir = RESULTS / args.run_id
    out_dir = args.out or RESULTS / "paper_csv" / args.run_id
    out_dir.mkdir(parents=True, exist_ok=True)

    agg_dir = aggregate(run_dir)
    written: List[str] = []
    missing: List[str] = []
    for name in COPY_FILES:
        src = agg_dir / name
        if not src.is_file():
            missing.append(name)    # a partial run (--blob) misses whole slices
            continue
        shutil.copyfile(src, out_dir / f"{args.prefix}_{name}")
        written.append(f"{args.prefix}_{name}")

    if args.usecase_run:
        for name, df in _usecase_cuts(RESULTS / args.usecase_run).items():
            df.to_csv(out_dir / f"{args.prefix}_{name}", index=False)
            written.append(f"{args.prefix}_{name}")

    print(f"[ok] wrote {len(written)} files to {out_dir}:")
    for n in written:
        print(f"  - {n}")
    if missing:
        print(f"[warn] not in this run (partial run?), skipped: {', '.join(missing)}")
    if not written:
        raise SystemExit("nothing to publish")


if __name__ == "__main__":
    main()
