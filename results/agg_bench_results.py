#!/usr/bin/env python3
"""
Aggregate benchmark CSVs (cores + hol + baseline) into 1D scaling results.
"""

from __future__ import annotations

import argparse
import os
import shutil
from pathlib import Path
from typing import List, Optional

import pandas as pd


# =========================
# Hardcoded pins (edit here)
# =========================
PIN_NLAMBDAS_FOR_NDATA_SCALING = 100   # used for hol/baseline "scale ndata"
PIN_NDATA_FOR_NLAMBDAS_SCALING = 10000  # used for hol/baseline "scale nlambdas"


# =========================
# Core logic
# =========================
REQUIRED_COLS = [
    "repo", "type", "blob",
    "ncores", "ndata", "nlambdas", "nthreads",
    "run_kind",
    "server_ms", "roundtrip_ms",
]

GROUP_COLS = [
    "repo", "type", "blob",
    "ncores", "ndata", "nlambdas", "nthreads",
]

# All benchmark types the runner can emit. Used for longest-match file lookup so
# that 'cores' never captures 'baseline_cores' (whose filename ends in _cores.csv).
ALL_TYPES = ["hol", "baseline", "cores", "baseline_cores"]


def _read_csv_strict(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path)

    missing = [c for c in REQUIRED_COLS if c not in df.columns]
    if missing:
        raise ValueError(
            f"{path.name}: missing columns {missing}. "
            f"Have: {list(df.columns)}"
        )

    # normalize types
    for c in ["blob", "ncores", "ndata", "nlambdas", "nthreads"]:
        df[c] = pd.to_numeric(df[c], errors="raise").astype("int64")

    for c in ["server_ms", "roundtrip_ms"]:
        df[c] = pd.to_numeric(df[c], errors="raise").astype("float64")

    df["run_kind"] = df["run_kind"].astype(str)
    df["repo"] = df["repo"].astype(str)
    df["type"] = df["type"].astype(str)

    return df


def _drop_warmups(df: pd.DataFrame) -> pd.DataFrame:
    # keep everything that is NOT warmup
    return df[df["run_kind"].str.lower() != "warmup"].copy()


def _aggregate_repeats(df: pd.DataFrame) -> pd.DataFrame:
    """
    Group by scenario columns and collapse repeats.
    Keeps scenario columns and outputs median/mean + count.
    """
    if df.empty:
        return df

    g = df.groupby(GROUP_COLS, dropna=False, sort=True)

    out = g.agg(
        runs=("server_ms", "count"),
        server_ms_median=("server_ms", "median"),
        server_ms_mean=("server_ms", "mean"),
        roundtrip_ms_median=("roundtrip_ms", "median"),
        roundtrip_ms_mean=("roundtrip_ms", "mean"),
    ).reset_index()

    # make output stable/readable
    out = out.sort_values(["type", "ncores", "nlambdas", "ndata", "blob"]).reset_index(drop=True)
    return out


def _write(df: pd.DataFrame, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(out_path, index=False)


def _find_one_by_type(files: List[Path], type_name: str, all_types: List[str] = ALL_TYPES) -> Optional[Path]:
    """
    Pick the input file for a given type ('cores', 'hol', 'baseline', 'baseline_cores').
    Matching is exact on the '_<type>.csv' suffix, and a file that belongs to a more
    specific (longer) registered type is excluded — so 'cores' does NOT capture
    'baseline_cores'. Falls back to inspecting the 'type' column.
    """
    longer = [t for t in all_types if t != type_name and t.endswith("_" + type_name)]

    def belongs_to_longer(f: Path) -> bool:
        return any(f.name.endswith(f"_{t}.csv") for t in longer)

    # filename hint: exact '_<type>.csv' suffix, minus more-specific types
    for f in files:
        if f.name.endswith(f"_{type_name}.csv") and not belongs_to_longer(f):
            return f

    # fallback: inspect content (exact match on the 'type' column)
    for f in files:
        try:
            df = pd.read_csv(f, nrows=50)
            if "type" in df.columns and (df["type"].astype(str).str.lower() == type_name).any():
                return f
        except Exception:
            continue

    return None


def main() -> None:
    ap = argparse.ArgumentParser(description="Aggregate benchmark results into 1D scaling CSVs.")
    ap.add_argument(
        "input_dir",
        help="Folder containing benchmark CSVs (e.g., ./results/bench_0127_193000)",
    )
    args = ap.parse_args()

    in_dir = Path(args.input_dir).resolve()
    if not in_dir.is_dir():
        raise SystemExit(f"Not a directory: {in_dir}")

    csv_files = sorted(in_dir.glob("*.csv"))
    if not csv_files:
        raise SystemExit(f"No CSV files found in: {in_dir}")

    out_root = Path.cwd() / "result_agg" / in_dir.name
    if os.path.exists(out_root):
        shutil.rmtree(out_root)
    out_root.mkdir(parents=True, exist_ok=True)

    # identify inputs
    f_cores = _find_one_by_type(csv_files, "cores")
    f_hol = _find_one_by_type(csv_files, "hol")
    f_baseline = _find_one_by_type(csv_files, "baseline")
    f_baseline_cores = _find_one_by_type(csv_files, "baseline_cores")  # optional (Postgres cores line)

    missing = [name for name, f in [("cores", f_cores), ("hol", f_hol), ("baseline", f_baseline)] if f is None]
    if missing:
        raise SystemExit(
            "Could not find required inputs for: "
            + ", ".join(missing)
            + f"\nAvailable files: {[f.name for f in csv_files]}"
        )

    # ---- CORES: aggregate over repeats, grouped by ncores (and the rest, but those are constant anyway)
    df_cores = _drop_warmups(_read_csv_strict(f_cores))
    agg_cores = _aggregate_repeats(df_cores)
    _write(agg_cores, out_root / "cores_agg.csv")

    # ---- HOL: two 1D cuts
    df_hol = _drop_warmups(_read_csv_strict(f_hol))

    hol_by_ndata = df_hol[df_hol["nlambdas"] == PIN_NLAMBDAS_FOR_NDATA_SCALING].copy()
    agg_hol_by_ndata = _aggregate_repeats(hol_by_ndata)
    _write(
        agg_hol_by_ndata,
        out_root / f"hol_agg_nlambdas_{PIN_NLAMBDAS_FOR_NDATA_SCALING}.csv"
    )

    hol_by_nlambdas = df_hol[df_hol["ndata"] == PIN_NDATA_FOR_NLAMBDAS_SCALING].copy()
    agg_hol_by_nlambdas = _aggregate_repeats(hol_by_nlambdas)
    _write(
        agg_hol_by_nlambdas,
        out_root / f"hol_agg_ndata_{PIN_NDATA_FOR_NLAMBDAS_SCALING}.csv"
    )

    # ---- BASELINE: two 1D cuts
    df_base = _drop_warmups(_read_csv_strict(f_baseline))

    base_by_ndata = df_base[df_base["nlambdas"] == PIN_NLAMBDAS_FOR_NDATA_SCALING].copy()
    agg_base_by_ndata = _aggregate_repeats(base_by_ndata)
    _write(
        agg_base_by_ndata,
        out_root / f"baseline_agg_nlambdas_{PIN_NLAMBDAS_FOR_NDATA_SCALING}.csv"
    )

    base_by_nlambdas = df_base[df_base["ndata"] == PIN_NDATA_FOR_NLAMBDAS_SCALING].copy()
    agg_base_by_nlambdas = _aggregate_repeats(base_by_nlambdas)
    _write(
        agg_base_by_nlambdas,
        out_root / f"baseline_agg_ndata_{PIN_NDATA_FOR_NLAMBDAS_SCALING}.csv"
    )

    # ---- BASELINE_CORES: 1D over ncores (PostgreSQL counterpart to 'cores'), if present
    if f_baseline_cores is not None:
        df_bcores = _drop_warmups(_read_csv_strict(f_baseline_cores))
        agg_bcores = _aggregate_repeats(df_bcores)
        _write(agg_bcores, out_root / "baseline_cores_agg.csv")

    # quick sanity output (list what was actually written)
    print(f"[ok] input:  {in_dir}")
    print(f"[ok] output: {out_root}")
    print("[ok] wrote:")
    for n in sorted(p.name for p in out_root.glob("*.csv")):
        print(f"  - {out_root / n}")
    if f_baseline_cores is None:
        print("[warn] no *_baseline_cores.csv found — skipped the PostgreSQL cores curve")


if __name__ == "__main__":
    main()
