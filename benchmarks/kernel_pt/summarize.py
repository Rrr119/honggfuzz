#!/usr/bin/env python3
"""Summarize honggfuzz coverage-backend benchmark runs.

Reads the per-mode ``stats.csv`` files produced by ``bench_coverage.sh`` and
prints a comparison table (and writes ``summary.csv``/``summary.md``) covering
throughput and final coverage for each feedback backend.
"""

import csv
import os
import sys

# Column order emitted by honggfuzz through --statsfile (see honggfuzz.c).
COLUMNS = [
    "unix_time",
    "last_cov_update",
    "total_exec",
    "exec_per_sec",
    "crashes",
    "unique_crashes",
    "hangs",
    "edge_cov",
    "block_cov",
    "corpus_count",
]

MODE_ORDER = ["soft", "ipt", "bts", "fused", "kernel"]


def parse_stats(path):
    """Return the last numeric record of a honggfuzz statsfile, or None."""
    last = None
    with open(path, newline="") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            values = [v.strip() for v in line.split(",")]
            if len(values) != len(COLUMNS):
                continue
            try:
                last = dict(zip(COLUMNS, [int(v) for v in values]))
            except ValueError:
                continue
    return last


def main(results_dir):
    rows = []
    for mode in MODE_ORDER:
        stats = os.path.join(results_dir, mode, "stats.csv")
        if not os.path.isfile(stats):
            continue
        record = parse_stats(stats)
        if record is None:
            continue
        record["mode"] = mode
        rows.append(record)

    if not rows:
        print("No usable stats.csv files found under %s" % results_dir)
        return 1

    header = [
        "mode",
        "total_exec",
        "exec_per_sec",
        "edge_cov",
        "block_cov",
        "corpus_count",
        "crashes",
    ]

    csv_path = os.path.join(results_dir, "summary.csv")
    with open(csv_path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=header)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row[key] for key in header})

    widths = {key: max(len(key), *(len(str(r[key])) for r in rows)) for key in header}
    md_lines = ["| " + " | ".join(key.ljust(widths[key]) for key in header) + " |"]
    md_lines.append("| " + " | ".join("-" * widths[key] for key in header) + " |")
    for row in rows:
        md_lines.append(
            "| " + " | ".join(str(row[key]).ljust(widths[key]) for key in header) + " |"
        )
    md_path = os.path.join(results_dir, "summary.md")
    with open(md_path, "w") as fh:
        fh.write("\n".join(md_lines) + "\n")

    print("\n".join(md_lines))
    print("\nWrote %s" % csv_path)
    print("Wrote %s" % md_path)

    # Optional soft-vs-fused delta, the key number for feedback fusion.
    by_mode = {row["mode"]: row for row in rows}
    if "soft" in by_mode and "fused" in by_mode:
        soft = by_mode["soft"]
        fused = by_mode["fused"]
        delta = fused["block_cov"] - soft["block_cov"]
        print(
            "\nFusion delta (fused vs. soft block coverage): %+d "
            "(soft=%d fused=%d)" % (delta, soft["block_cov"], fused["block_cov"])
        )
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: summarize.py <results_dir>")
    sys.exit(main(sys.argv[1]))
