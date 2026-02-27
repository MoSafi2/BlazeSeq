#!/usr/bin/env python3
"""
Plot hyperfine benchmark results as column (bar) charts with error bars.

Reads JSON exported by hyperfine (--export-json), produces one figure per file,
and saves plots under the assets directory. Uses mean ± stddev for bars and
annotations. For throughput benchmark, also generates a GB/s figure.
"""

from __future__ import annotations

import argparse
import json
import re
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

# Distinct colors for each bar (one per benchmark)
BAR_COLORS = [
    "#2e86ab",
    "#a23b72",
    "#f18f01",
    "#c73e1d",
    "#3b1f2b",
    "#95c623",
    "#1b4965",
    "#5c4d7d",
]

# Data size in GB for throughput calculation (parser and throughput benchmarks use 3 GB)
DATA_SIZE_GB = 3.0


def get_version(repo_root: Path) -> str:
    """Read BlazeSeq version from pixi.toml."""
    pixi = repo_root / "pixi.toml"
    if not pixi.exists():
        return "unknown"
    try:
        text = pixi.read_text(encoding="utf-8")
        m = re.search(r'^version\s*=\s*["\']?([\d.]+)', text, re.MULTILINE)
        return m.group(1) if m else "unknown"
    except (OSError, AttributeError):
        return "unknown"


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


def reads_to_millions_str(reads: int) -> str:
    """Format read count as millions with one decimal (e.g. 14758000 -> '14.8M')."""
    if reads <= 0:
        return "0M"
    millions = reads / 1e6
    if millions >= 1000:
        return f"{millions / 1000:.1f}B"
    if millions >= 1:
        return f"{millions:.1f}M"
    return f"{millions:.1f}M"


def build_setup_text(
    basename: str,
    *,
    runs: int | None = None,
    size_gb: float | None = None,
    reads: int | None = None,
    ramfs: bool = True,
) -> str:
    """Build setup description for the graph from optional runs, size_gb, reads."""
    parts = []
    if size_gb is not None:
        parts.append(f"{size_gb:.0f} GB FASTQ")
    if reads is not None:
        parts.append(f"{reads_to_millions_str(reads)} reads")
    if runs is not None:
        parts.append(f"{runs} runs")
    if ramfs and basename in ("parser_plain", "parser_gzip"):
        parts.append("ramfs")
    return ", ".join(parts) if parts else ""


def setup_text_for_basename(basename: str) -> str:
    """Short (3–5 word) test setup description for the graph (fallback when no args)."""
    if basename in ("parser_plain", "parser_gzip"):
        return "3 GB FASTQ, 5 runs, ramfs"
    if basename == "throughput":
        return "3 GB synthetic FASTQ, 5 runs"
    return ""


def plot_one(
    results: list[dict],
    title: str,
    out_path: Path,
    *,
    ylabel: str = "Time (seconds)",
    capsize: int = 5,
    version: str = "",
    setup_text: str = "",
) -> None:
    """Plot one benchmark result set as a column chart with error bars and annotations."""
    # Sort by mean time (fastest on the left)
    results = sorted(results, key=lambda r: r["mean"])

    names = [r["command"] for r in results]
    means = np.array([r["mean"] for r in results])
    stddevs = np.array([r.get("stddev", 0.0) for r in results])

    n = len(names)
    x = np.arange(n)
    width = 0.6
    colors = [BAR_COLORS[i % len(BAR_COLORS)] for i in range(n)]

    fig, ax = plt.subplots(figsize=(max(6, n * 1.2), 5))
    bars = ax.bar(x, means, width, yerr=stddevs, capsize=capsize, color=colors, edgecolor="black", linewidth=0.8)

    title_line = title
    if version:
        title_line += f"  (v{version})"
    ax.set_title(title_line, fontsize=13, fontweight="bold")
    if setup_text:
        ax.set_xlabel(setup_text, fontsize=9, color="gray", style="italic")
    ax.set_ylabel(ylabel, fontsize=11)
    ax.set_xticks(x)
    ax.set_xticklabels(names, rotation=45, ha="right")
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    # Annotate each bar with relative speedup vs slowest (largest mean time)
    slowest = float(max(means)) if len(means) else 0.0
    for i, mean in enumerate(means):
        if slowest > 0:
            factor = slowest / float(mean)
            label = f"{factor:.2f}x"
        else:
            label = "1.00x"
        std = float(stddevs[i]) if i < len(stddevs) else 0.0
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


def plot_throughput_gbps(
    results: list[dict],
    data_size_gb: float,
    out_path: Path,
    *,
    version: str = "",
    setup_text: str = "",
) -> None:
    """Plot throughput in GB/s (data_size_gb / time_s) with error bars from time stddev."""
    # Sort by mean time so highest throughput (smallest time) appears on the left
    results = sorted(results, key=lambda r: r["mean"])

    names = [r["command"] for r in results]
    means_s = np.array([r["mean"] for r in results])
    stddevs_s = np.array([r.get("stddev", 0.0) for r in results])

    # GB/s = data_size_gb / time_s; uncertainty via delta method: d(rate) ≈ rate * (stddev/mean)
    rates = data_size_gb / means_s
    rate_errs = rates * (stddevs_s / means_s)

    n = len(names)
    x = np.arange(n)
    width = 0.6
    colors = [BAR_COLORS[i % len(BAR_COLORS)] for i in range(n)]

    fig, ax = plt.subplots(figsize=(max(6, n * 1.2), 5))
    ax.bar(x, rates, width, yerr=rate_errs, capsize=5, color=colors, edgecolor="black", linewidth=0.8)

    title_line = "BlazeSeq throughput (GB/s)"
    if version:
        title_line += f"  (v{version})"
    ax.set_title(title_line, fontsize=13, fontweight="bold")
    if setup_text:
        ax.set_xlabel(setup_text, fontsize=9, color="gray", style="italic")
    ax.set_ylabel("Throughput (GB/s)", fontsize=11)
    ax.set_xticks(x)
    ax.set_xticklabels(names, rotation=45, ha="right")
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    # Annotate each bar with throughput ± stddev (GB/s) on top
    for i, (rate, err) in enumerate(zip(rates, rate_errs)):
        label = f"{rate:.2f} ± {err:.2f}"
        ax.annotate(
            label,
            xy=(i, rate + err),
            xytext=(0, 6),
            textcoords="offset points",
            ha="center",
            va="bottom",
            fontsize=9,
            fontweight="medium",
        )

    ax.set_ylim(0, max(rates + rate_errs) * 1.25 if len(rates) else 1)
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
    parser.add_argument("--runs", type=int, default=None, help="Number of hyperfine runs (displayed on plot)")
    parser.add_argument("--size-gb", type=float, default=None, help="Data size in GB (displayed on plot)")
    parser.add_argument("--reads", type=int, default=None, help="Number of reads/records (displayed as millions to 1 sig digit)")
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    assets_dir = (args.assets_dir or repo_root / "assets").resolve()

    if args.json_paths:
        json_paths = [p.resolve() if not p.is_absolute() else p for p in args.json_paths]
    else:
        json_paths = [repo_root / rel for rel in DEFAULT_JSON_PATHS]

    version = get_version(repo_root)
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
        if args.runs is not None or args.size_gb is not None or args.reads is not None:
            setup_text = build_setup_text(
                basename,
                runs=args.runs,
                size_gb=args.size_gb,
                reads=args.reads,
                ramfs=basename in ("parser_plain", "parser_gzip"),
            )
        else:
            setup_text = setup_text_for_basename(basename)
        out_path = assets_dir / f"{basename}.png"
        plot_one(results, title, out_path, version=version, setup_text=setup_text)
        print(f"Wrote {out_path}")
        plotted += 1
        # Throughput benchmark: also generate GB/s figure
        if basename == "throughput":
            gbps_path = assets_dir / "throughput_gbps.png"
            data_size_gb = args.size_gb if args.size_gb is not None else DATA_SIZE_GB
            plot_throughput_gbps(
                results,
                data_size_gb,
                gbps_path,
                version=version,
                setup_text=setup_text,
            )
            print(f"Wrote {gbps_path}")
            plotted += 1

    if plotted == 0:
        print("No benchmark JSON files found or plotted.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
