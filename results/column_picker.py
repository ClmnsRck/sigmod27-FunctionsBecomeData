#!/usr/bin/env python3
from __future__ import annotations

import csv
import sys
from pathlib import Path
from typing import List, Dict, Any


def read_rows(path: Path) -> tuple[List[str], List[Dict[str, str]]]:
    with path.open("r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None:
            raise SystemExit("CSV has no header row.")
        fieldnames = list(reader.fieldnames)
        rows = list(reader)
    return fieldnames, rows


def unique_values(rows: List[Dict[str, str]], col: str) -> List[str]:
    vals = sorted({r.get(col, "") for r in rows})
    vals = [v for v in vals if v != ""]
    return vals


def try_sort_numeric(values: List[str]) -> List[str]:
    try:
        nums = [float(v) for v in values]
    except ValueError:
        return values
    paired = sorted(zip(nums, values), key=lambda x: x[0])
    return [v for _, v in paired]


def prompt_choice(options: List[str], prompt: str) -> str:
    if not options:
        raise SystemExit("No options available for selection.")
    while True:
        print(prompt)
        for i, opt in enumerate(options, 1):
            print(f"  [{i}] {opt}")
        s = input("Enter number: ").strip()
        try:
            idx = int(s)
            if 1 <= idx <= len(options):
                return options[idx - 1]
        except ValueError:
            pass
        print("Invalid choice, try again.\n")


def main(argv: List[str]) -> int:
    if len(argv) < 2:
        print(f"Usage: {argv[0]} <input.csv> [col1 col2]", file=sys.stderr)
        print("Default columns: nlambdas ndata", file=sys.stderr)
        return 2

    in_path = Path(argv[1])
    if not in_path.exists():
        print(f"File not found: {in_path}", file=sys.stderr)
        return 2

    col1 = argv[2] if len(argv) >= 3 else "nlambdas"
    col2 = argv[3] if len(argv) >= 4 else "ndata"

    fieldnames, rows = read_rows(in_path)

    candidate_cols = [c for c in [col1, col2] if c in fieldnames]
    if not candidate_cols:
        print("None of the requested columns exist in the CSV header.", file=sys.stderr)
        print(f"Header columns: {fieldnames}", file=sys.stderr)
        return 2

    if len(candidate_cols) == 2:
        chosen_col = prompt_choice(candidate_cols, "Which dimension (column) do you want to filter by?")
    else:
        chosen_col = candidate_cols[0]
        print(f"Only '{chosen_col}' exists — filtering by that.\n")

    vals = unique_values(rows, chosen_col)
    if not vals:
        print(f"No values found for column '{chosen_col}' (maybe empty?).", file=sys.stderr)
        return 2

    vals = try_sort_numeric(vals)
    chosen_val = prompt_choice(vals, f"Pick the value to keep for '{chosen_col}':")

    filtered = [r for r in rows if r.get(chosen_col, "") == chosen_val]
    if not filtered:
        print("No rows matched (unexpected).", file=sys.stderr)
        return 2

    out_path = in_path.with_name(f"{in_path.stem}_only_{chosen_col}_{chosen_val}{in_path.suffix}")
    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(filtered)

    print(f"\nWrote {len(filtered)} rows to: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
