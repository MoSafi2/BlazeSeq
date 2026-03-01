#!/usr/bin/env bash
# In-memory throughput benchmark: BlazeSeq batched vs records vs ref_records.
# Generates ~3 GB synthetic FASTQ in process, reads via MemoryReader (no disk I/O).
# Runs each mode multiple times, captures parse_seconds from Mojo output, writes
# JSON for plotting (no hyperfine).
# Run from repository root: ./benchmark/throughput/run_throughput_memory_benchmarks.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

export PATH="${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"
if [ -n "${CONDA_PREFIX}" ] && [ -d "${CONDA_PREFIX}/bin" ]; then
    export PATH="${CONDA_PREFIX}/bin:${PATH}"
fi
if [ -n "${MAMBA_ROOT_PREFIX}" ] && [ -d "${MAMBA_ROOT_PREFIX}/bin" ]; then
    export PATH="${MAMBA_ROOT_PREFIX}/bin:${PATH}"
fi

check_cmd() { command -v "$1" >/dev/null 2>&1; }
if ! check_cmd pixi; then
    echo "Missing required tool: pixi (https://pixi.sh)"
    exit 1
fi

SIZE_GB="${SIZE_GB:-3}"
BENCH_RUNS="${BENCH_RUNS:-5}"

# Build in-memory throughput runner
RUNNER_BIN="$SCRIPT_DIR/run_throughput_memory_blazeseq"
echo "Building in-memory throughput runner ..."
if ! pixi run mojo build -I . -o "$RUNNER_BIN" "$SCRIPT_DIR/run_throughput_memory_blazeseq.mojo"; then
    echo "Failed to build run_throughput_memory_blazeseq.mojo"
    exit 1
fi

RESULTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_JSON="$RESULTS_DIR/throughput_memory_benchmark_results.json"
RESULTS_MD="$RESULTS_DIR/throughput_memory_benchmark_results.md"
RAW_TIMES=$(mktemp)
trap 'rm -f "$RAW_TIMES"' EXIT

echo "Running each mode ${BENCH_RUNS} times (size_gb=${SIZE_GB}), capturing parse_seconds from Mojo ..."
for mode in batched records ref_records; do
    for run in $(seq 1 "$BENCH_RUNS"); do
        out=$("$RUNNER_BIN" "$SIZE_GB" "$mode" 2>/dev/null) || true
        parse_s=$(echo "$out" | grep "^parse_seconds:" | sed 's/parse_seconds: *//')
        if [ -n "$parse_s" ]; then
            echo "$mode $parse_s" >> "$RAW_TIMES"
        fi
    done
done

# Build hyperfine-compatible JSON from Mojo parse_seconds (mean + stddev per mode)
python3 << PYEOF
import json
import sys
from pathlib import Path

raw_path = "$RAW_TIMES"
out_json = "$RESULTS_JSON"
out_md = "$RESULTS_MD"
size_gb = float("$SIZE_GB")
runs = int("$BENCH_RUNS")

times_by_mode = {}
with open(raw_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        mode, s = parts
        try:
            t = float(s)
        except ValueError:
            continue
        times_by_mode.setdefault(mode, []).append(t)

results = []
for mode in ("batched", "records", "ref_records"):
    vals = times_by_mode.get(mode, [])
    if not vals:
        mean = stddev = 0.0
    else:
        n = len(vals)
        mean = sum(vals) / n
        if n > 1:
            variance = sum((x - mean) ** 2 for x in vals) / (n - 1)
            stddev = variance ** 0.5
        else:
            stddev = 0.0
    results.append({"command": mode, "mean": mean, "stddev": stddev})

data = {"results": results}
with open(out_json, "w") as f:
    json.dump(data, f, indent=2)
print(f"Wrote {out_json}")

# Simple markdown table
lines = [
    "| Mode | Mean (s) | Std dev (s) | Throughput (GB/s) |",
    "|------|----------|-------------|-------------------|",
]
for r in sorted(results, key=lambda x: x["mean"]):
    mean = r["mean"]
    std = r["stddev"]
    gbps = size_gb / mean if mean > 0 else 0
    lines.append(f"| {r['command']} | {mean:.4f} | {std:.4f} | {gbps:.2f} |")
with open(out_md, "w") as f:
    f.write("In-memory throughput (parse_seconds from Mojo)\n\n")
    f.write(f"Size: {size_gb} GB, {runs} runs per mode.\n\n")
    f.write("\n".join(lines))
    f.write("\n")
print(f"Wrote {out_md}")
PYEOF

echo ""
echo "Results: $RESULTS_JSON and $RESULTS_MD"

# Plot using Mojo-derived timing
ref=""
for mode in batched records ref_records; do
    out=$("$RUNNER_BIN" "$SIZE_GB" "$mode" 2>/dev/null) || true
    first_line=$(echo "$out" | head -n1)
    [ -n "$first_line" ] && ref="${ref:-$first_line}"
done
RECORDS="${ref%% *}"

if command -v python3 >/dev/null 2>&1; then
    python3 "$REPO_ROOT/benchmark/scripts/plot_benchmark_results.py" \
        --repo-root "$REPO_ROOT" --assets-dir "$REPO_ROOT/assets" \
        --json "$RESULTS_JSON" \
        --runs "$BENCH_RUNS" --size-gb "$SIZE_GB" --reads "${RECORDS:-0}" 2>/dev/null || true
fi
