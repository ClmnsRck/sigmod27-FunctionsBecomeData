#!/usr/bin/env python3
"""
Aggregate a benchmark run's CSVs into the per-point curves the figures plot: the two
grid slices per type, and one curve over the thread count per core-sweep type.

    python3 results/agg_bench_results.py results/bench_<stamp>
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import List, Optional

import pandas as pd


# =========================
# Hardcoded pins (edit here)
# =========================
PIN_NLAMBDAS_FOR_NDATA_SCALING = 100   # used for hol/baseline "scale ndata"
PIN_NDATA_FOR_NLAMBDAS_SCALING = 80000  # used for hol/baseline "scale nlambdas"


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

# The benchmark types (benchmark.py GRID_TYPES / CORE_TYPES).
SCALING_TYPES = ["baseline_case_jitoff", "free_lambda_jitoff", "hol_pw_jitnoopt"]
CORE_TYPES = ["baseline_case_agg_cores_jitoff", "free_lambda_agg_cores_jitoff",
              "agg_cores_pw_jitnoopt"]
ALL_TYPES = SCALING_TYPES + CORE_TYPES

NON_BENCHMARK_FILES = {"runs.csv"}

# The aggregated CSVs land in results/result_agg/<run_id>/.
OUT_ROOT = Path(__file__).resolve().parent / "result_agg"


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
    # Keep only timed runs. Not "everything that is not warmup": since 2026-08-18
    # the runner also writes a run_kind=verify row per blob (the untimed run that
    # measures the actual worker count), and that one must never reach a median.
    return df[df["run_kind"].str.lower() == "measure"].copy()


def _aggregate_repeats(df: pd.DataFrame) -> pd.DataFrame:
    """
    Group by scenario columns and collapse repeats.
    Keeps scenario columns and outputs median/mean/min + count.

    The minimum is emitted alongside the median because the threaded operators
    have a bimodal repeat distribution above eight threads, where the median
    jumps between the two modes while the minimum is stable to a few ms. Figures
    that plot those curves read `server_ms_min`; everything else reads the median.
    """
    if df.empty:
        return df

    g = df.groupby(GROUP_COLS, dropna=False, sort=True)

    out = g.agg(
        runs=("server_ms", "count"),
        server_ms_median=("server_ms", "median"),
        server_ms_mean=("server_ms", "mean"),
        server_ms_min=("server_ms", "min"),
        roundtrip_ms_median=("roundtrip_ms", "median"),
        roundtrip_ms_mean=("roundtrip_ms", "mean"),
        roundtrip_ms_min=("roundtrip_ms", "min"),
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


def aggregate(in_dir: Path) -> Path:
    """Aggregate one run directory; returns the output directory."""
    in_dir = in_dir.resolve()
    if not in_dir.is_dir():
        raise SystemExit(f"Not a directory: {in_dir}")

    csv_files = sorted(
        f for f in in_dir.glob("*.csv") if f.name not in NON_BENCHMARK_FILES
    )
    if not csv_files:
        raise SystemExit(f"No CSV files found in: {in_dir}")

    out_root = OUT_ROOT / in_dir.name
    out_root.mkdir(parents=True, exist_ok=True)
    for stale in out_root.glob("*.csv"):
        stale.unlink()

    found = {t: _find_one_by_type(csv_files, t) for t in ALL_TYPES}

    if not any(found.values()):
        raise SystemExit(f"No benchmark type found in {in_dir}. "
                         f"Available files: {[f.name for f in csv_files]}")

    skipped: List[str] = []

    # ---- Grid types: two 1D cuts each (scale ndata at pinned M, scale M at pinned ndata).
    for type_name in SCALING_TYPES:
        f = found[type_name]
        if f is None:
            skipped.append(type_name)
            continue
        df = _drop_warmups(_read_csv_strict(f))

        # A type on a reduced grid can miss a pin entirely; write nothing rather
        # than a header-only CSV that a figure would then plot as an empty line.
        by_ndata = df[df["nlambdas"] == PIN_NLAMBDAS_FOR_NDATA_SCALING].copy()
        if by_ndata.empty:
            skipped.append(f"{type_name} (no nlambdas={PIN_NLAMBDAS_FOR_NDATA_SCALING})")
        else:
            _write(
                _aggregate_repeats(by_ndata),
                out_root / f"{type_name}_agg_nlambdas_{PIN_NLAMBDAS_FOR_NDATA_SCALING}.csv"
            )

        by_nlambdas = df[df["ndata"] == PIN_NDATA_FOR_NLAMBDAS_SCALING].copy()
        if by_nlambdas.empty:
            skipped.append(f"{type_name} (no ndata={PIN_NDATA_FOR_NLAMBDAS_SCALING})")
        else:
            _write(
                _aggregate_repeats(by_nlambdas),
                out_root / f"{type_name}_agg_ndata_{PIN_NDATA_FOR_NLAMBDAS_SCALING}.csv"
            )

    # ---- Core-scaling types: one curve over nthreads each.
    for type_name in CORE_TYPES:
        f = found[type_name]
        if f is None:
            skipped.append(type_name)
            continue
        df = _drop_warmups(_read_csv_strict(f))
        _write(_aggregate_repeats(df), out_root / f"{type_name}_agg.csv")

    # quick sanity output (list what was actually written)
    print(f"[ok] input:  {in_dir}")
    print(f"[ok] output: {out_root}")
    print("[ok] wrote:")
    for n in sorted(p.name for p in out_root.glob("*.csv")):
        print(f"  - {out_root / n}")
    if skipped:
        print(f"[warn] not present in this run, skipped: {', '.join(skipped)}")
    return out_root


def main() -> None:
    ap = argparse.ArgumentParser(description="Aggregate a benchmark run into per-point curves.")
    ap.add_argument("input_dir", help="run directory, e.g. results/bench_20261016_020051")
    aggregate(Path(ap.parse_args().input_dir))


if __name__ == "__main__":
    main()
