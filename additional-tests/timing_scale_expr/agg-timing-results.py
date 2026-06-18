#!/usr/bin/env python3
import csv
from collections import defaultdict
from statistics import median

MARKER = "TIMING_RESULTS_MARKER"

def find_chunks(text: str) -> list[str]:
    chunks = []
    i = 0
    mlen = len(MARKER)
    while True:
        a = text.find(MARKER, i)
        if a == -1:
            break
        b = text.find(MARKER, a + mlen)
        if b == -1:
            break
        chunks.append(text[a + mlen : b])
        i = b + mlen
    return chunks

def clean_value(s: str):
    s = s.strip().rstrip(",;")
    if s.endswith("us"):
        s = s[:-2].strip()
    try:
        return int(s)
    except ValueError:
        pass
    try:
        return float(s)
    except ValueError:
        return s

def parse_chunk(chunk: str) -> dict:
    rec = {}
    for line in chunk.splitlines():
        line = line.strip()
        if not line:
            continue

        if "=" in line:
            k, v = line.split("=", 1)
        elif ":" in line:
            k, v = line.split(":", 1)
        else:
            continue

        v = v.strip()
        if not v:
            continue

        key = k.strip().lower().replace(" ", "_")
        rec[key] = clean_value(v)
    return rec

def write_csv(path: str, rows: list[dict], fieldnames: list[str]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fieldnames})

def pick_group_keys(rows: list[dict]) -> list[str]:
    """
    Prefer grouping by body size / repeat count if available.
    Falls back to num_tuples_data if not.
    """
    candidate_keys = [
        "body_repeat",     # recommended
        "expr_repeat",
        "repeat_body",
        "body_size",
        "expr_size",
    ]
    present = {k for r in rows for k in r.keys()}
    for k in candidate_keys:
        if k in present:
            return [k]
    return ["num_tuples_data"]

def main() -> None:
    input_file = "bench-timing_agg-logs.txt"
    raw_csv = "bench_timing_agg_raw.csv"
    agg_csv = "bench_timing_agg_agg.csv"

    text = open(input_file, "r", encoding="utf-8", errors="replace").read()
    rows = [parse_chunk(c) for c in find_chunks(text)]
    rows = [r for r in rows if r]

    if not rows:
        print("No timing chunks found.")
        return

    # derived convenience column
    for r in rows:
        total = r.get("total")
        remat = r.get("rematerialize_output")
        if isinstance(total, (int, float)) and isinstance(remat, (int, float)):
            r["total_minus_rematerialize"] = total - remat

    # raw csv
    drop_keys = {"nthreads", "num_cols_data", "num_tuples_lambdas", "num_tuples_result", "queuecap"}
    all_keys = sorted({k for r in rows for k in r} - drop_keys)
    write_csv(raw_csv, rows, all_keys)

    # aggregate csv
    group_keys = pick_group_keys(rows)
    groups = defaultdict(list)
    for r in rows:
        groups[tuple(r.get(k, "") for k in group_keys)].append(r)

    numeric_keys = [
        k for k in all_keys
        if k not in group_keys and any(isinstance(r.get(k), (int, float)) for r in rows)
    ]

    # inject is included in eval timing in your design, so exclude it from the sum check
    subcols_for_sum = ["prep", "materialize_input", "eval", "rematerialize_output"]

    agg_rows = []
    for gk, rs in sorted(groups.items(), key=lambda x: x[0]):
        out = {k: v for k, v in zip(group_keys, gk)}
        out["n"] = len(rs)

        # median per numeric key
        for k in numeric_keys:
            vals = [r[k] for r in rs if isinstance(r.get(k), (int, float))]
            if vals:
                out[k + "_median"] = median(vals)

        agg_rows.append(out)

        total_m = out.get("total_median")
        if isinstance(total_m, (int, float)):
            parts = []
            for c in subcols_for_sum:
                v = out.get(c + "_median")
                if isinstance(v, (int, float)):
                    parts.append(v)

            if parts:
                s = sum(parts)
                diff = total_m - s
                rel = diff / total_m if total_m != 0 else 0.0

                # nicer label depending on group key
                label = group_keys[0]
                print(
                    f"[check] {label}={out.get(label)} "
                    f"total_median={total_m:.0f}us sum(parts)={s:.0f}us "
                    f"diff={diff:.0f}us rel={rel:+.2%}"
                )
            else:
                print(f"[check] group={gk} missing subcols for sum check")

    agg_fields = group_keys + ["n"] + [f"{k}_median" for k in numeric_keys]
    write_csv(agg_csv, agg_rows, agg_fields)

    print(f"[ok] parsed_rows={len(rows)}")
    print(f"[ok] group_keys={group_keys}")
    print(f"[ok] wrote {raw_csv} and {agg_csv}")

if __name__ == "__main__":
    main()
