#!/usr/bin/env python3
import sys
import csv
import math
import statistics
from pathlib import Path

FILES = ["corescaling_results.csv", "baseline_results.csv"]
DROP_COLS = {"run_idx"}

INT_COLS = ["ncores", "nthreads", "ndata", "nlambdas"]
COPY_COLS = ["ndata", "nlambdas"]
GROUP_COLS = ["ncores", "nthreads"]

def _as_float(x: str):
    if x is None:
        return None
    x = str(x).strip()
    if x == "":
        return None
    try:
        v = float(x)
        if not math.isfinite(v):
            return None
        return v
    except ValueError:
        return None


def _as_int(x: str):
    v = _as_float(x)
    if v is None:
        return None
    # accept "4" or "4.0" etc.
    return int(v)


def aggregate_one(csv_path: Path) -> Path:
    with csv_path.open(newline="") as f:
        r = csv.DictReader(f)
        fieldnames = r.fieldnames or []
        rows = list(r)

    # decide which group cols to use: present AND not entirely empty
    group_cols = []
    for c in GROUP_COLS:
        if c in fieldnames and any((row.get(c, "").strip() != "") for row in rows):
            group_cols.append(c)

    if not group_cols:
        raise ValueError(f"{csv_path.name}: need non-empty 'ncores' and/or 'nthreads'. Have: {fieldnames}")

    copy_cols = [c for c in COPY_COLS if c in fieldnames]

    # candidate metric cols = everything else (excluding group/copy/drop)
    skip = set(group_cols) | set(copy_cols) | set(DROP_COLS)
    metric_candidates = [c for c in fieldnames if c not in skip]

    # keep only metric columns that have at least one numeric value
    metric_cols = []
    for c in metric_candidates:
        if any(_as_float(row.get(c, "")) is not None for row in rows):
            metric_cols.append(c)

    # aggregation buckets
    # key -> {"copy": {col: int_or_None}, "vals": {metric: [floats...]}}
    groups = {}

    for row in rows:
        # ignore dropped cols implicitly by not using them

        # build group key (must be ints)
        key = []
        for c in group_cols:
            iv = _as_int(row.get(c, ""))
            if iv is None:
                raise ValueError(f"{csv_path.name}: group column '{c}' has empty/non-numeric value in row: {row}")
            key.append(iv)
        key = tuple(key)

        g = groups.setdefault(key, {"copy": {}, "vals": {m: [] for m in metric_cols}})

        # copy cols (ints)
        for c in copy_cols:
            iv = _as_int(row.get(c, ""))
            # allow missing, but if present it must be consistent
            if c not in g["copy"]:
                g["copy"][c] = iv
            else:
                if iv is not None and g["copy"][c] is not None and iv != g["copy"][c]:
                    print(
                        f"[warn] {csv_path.name}: inconsistent {c} in group {key}: "
                        f"{g['copy'][c]} vs {iv}",
                        file=sys.stderr,
                    )

        # metric values (floats)
        for m in metric_cols:
            fv = _as_float(row.get(m, ""))
            if fv is not None:
                g["vals"][m].append(fv)

    # output header
    out_fields = list(group_cols) + copy_cols
    for m in metric_cols:
        out_fields.append(f"{m}_mean")
        out_fields.append(f"{m}_median")

    out_path = csv_path.with_name(f"{csv_path.stem}_agg.csv")
    with out_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=out_fields)
        w.writeheader()

        for key in sorted(groups.keys()):
            g = groups[key]
            out_row = {}

            # group cols as ints (no .0)
            for i, c in enumerate(group_cols):
                out_row[c] = str(key[i])

            # copy cols as ints (no .0) if present
            for c in copy_cols:
                v = g["copy"].get(c, None)
                out_row[c] = "" if v is None else str(int(v))

            # metrics
            for m in metric_cols:
                vals = g["vals"][m]
                if vals:
                    out_row[f"{m}_mean"] = str(sum(vals) / len(vals))
                    out_row[f"{m}_median"] = str(statistics.median(vals))
                else:
                    out_row[f"{m}_mean"] = ""
                    out_row[f"{m}_median"] = ""

            w.writerow(out_row)

    return out_path


def main() -> None:
    cwd = Path.cwd()
    for name in FILES:
        path = cwd / name
        if not path.exists():
            print(f"[error] Missing file in CWD: {name}", file=sys.stderr)
            continue

        out = aggregate_one(path)
        print(f"[ok] {name} -> {out.name}")


if __name__ == "__main__":
    main()
