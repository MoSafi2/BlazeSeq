#!/usr/bin/env python3
"""
Plot hyperfine benchmark results as column (bar) charts with error bars.

Reads JSON exported by hyperfine (--export-json), produces one figure per file,
and saves plots under the assets directory. Uses mean ± stddev for bars and
annotations.

Usage:
  python plot_benchmark_results.py [--repo-root DIR] [--assets-dir DIR] [--json PATH ...]
  If no --json paths are given, looks for standard benchmark JSON files under repo-root.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np
except ImportError as e:
    print("Error: matplotlib and numpy are required. Install with: pip install matplotlib numpy", file=sys.stderr)
    sys.exit(1)


# Default relative paths from repo root for known benchmark result files
DEFAULT_JSON_PATHS = [
    "benchmark_results.json",
    "benchmark_results_gzip.json",
    "benchmark/throughput_benchmark_results.json",
]


def load_hyperfine_json(path: Path) -> list[dict] | None:
    """Load hyperfine JSON and return the 'results' list, or None on error."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data.get("results")
    except (OSError, json.JSONDecodeError, KeyError) as e:
        print(f"Warning: Could not load {path}: {e}", file=sys.stderr)
        return None


def format_time(seconds: float) -> str:
    """Format seconds as human-readable string (e.g. 12.3s or 1.2ms)."""
    if seconds >= 1:
        return f"{seconds:.2f}s"
    if seconds >= 1e-3:
        return f"{seconds * 1e3:.1f}ms"
    return f"{seconds * 1e6:.0f}µs"


def plot_one(
    results: list[dict],
    title: str,
    out_path: Path,
    *,
    ylabel: str = "Time (seconds)",
    bar_color: str = "#2e86ab",
    capsize: int = 5,
) -> None:
    """Plot one benchmark result set as a column chart with error bars and annotations."""
    names = [r["command"] for r in results]
    means = np.array([r["mean"] for r in results])
    stddevs = np.array([r.get("stddev", 0.0) for r in results])

    n = len(names)
    x = np.arange(n)
    width = 0.6

    fig, ax = plt.subplots(figsize=(max(6, n * 1.2), 5))
    bars = ax.bar(x, means, width, yerr=stddevs, capsize=capsize, color=bar_color, edgecolor="black", linewidth=0.8)

    ax.set_ylabel(ylabel, fontsize=11)
    ax.set_title(title, fontsize=13, fontweight="bold")
    ax.set_xticks(x)
    ax.set_xticklabels(names, rotation=45, ha="right")
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    # Annotate each bar with mean ± stddev
    for i, (mean, std) in enumerate(zip(means, stddevs)):
        label = format_time(mean)
        if std > 0:
            label += f"\n± {format_time(std)}"
        ax.annotate(
            label,
            xy=(i, mean + std),
            xytext=(0, 6),
            textcoords="offset points",
            ha="center",
            va="bottom",
            fontsize=9,
            fontweight="medium",
        )

    ax.set_ylim(0, max(means + stddevs) * 1.25 if len(means) else 1)
    plt.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)


def output_basename(json_path: Path) -> str:
    """Derive output plot basename from JSON path (e.g. benchmark_results -> parser_plain)."""
    stem = json_path.stem
    if stem == "benchmark_results":
        return "parser_plain"
    if stem == "benchmark_results_gzip":
        return "parser_gzip"
    if stem == "throughput_benchmark_results":
        return "throughput"
    return stem


def title_for_basename(basename: str) -> str:
    """Human-readable title for the plot."""
    if basename == "parser_plain":
        return "FASTQ parser benchmark (plain)"
    if basename == "parser_gzip":
        return "FASTQ parser benchmark (gzip)"
    if basename == "throughput":
        return "BlazeSeq throughput: batched vs records vs ref_records"
    return basename.replace("_", " ").title()


def main() -> int:
    parser = argparse.ArgumentParser(description="Plot hyperfine benchmark results as column charts.")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd(), help="Repository root (default: cwd)")
    parser.add_argument("--assets-dir", type=Path, default=None, help="Output directory for plots (default: repo_root/assets)")
    parser.add_argument("--json", type=Path, action="append", dest="json_paths", help="Path(s) to hyperfine JSON (default: standard files)")
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    assets_dir = (args.assets_dir or repo_root / "assets").resolve()

    if args.json_paths:
        json_paths = [p.resolve() if not p.is_absolute() else p for p in args.json_paths]
    else:
        json_paths = [repo_root / rel for rel in DEFAULT_JSON_PATHS]

    plotted = 0
    for json_path in json_paths:
        if not json_path.exists():
            print(f"Skipping (not found): {json_path}", file=sys.stderr)
            continue
        results = load_hyperfine_json(json_path)
        if not results:
            continue
        basename = output_basename(json_path)
        title = title_for_basename(basename)
        out_path = assets_dir / f"{basename}.png"
        plot_one(results, title, out_path)
        print(f"Wrote {out_path}")
        plotted += 1

    if plotted == 0:
        print("No benchmark JSON files found or plotted.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
