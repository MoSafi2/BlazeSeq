#!/usr/bin/env bash
# Throughput benchmark: BlazeSeq batches vs records vs ref_records.
# Generates 3GB synthetic FASTQ on a ramfs mount, runs each mode with hyperfine.
# Run from repository root: ./benchmark/throughput/run_throughput_benchmarks.sh [--ramfs|--tmpfs]
# Requires: pixi, hyperfine. On Linux: sudo for ramfs/tmpfs mount/umount.

set -e

# --- Mount type: --ramfs (default) or --tmpfs ---
BENCH_FS="ramfs"
while [ $# -gt 0 ]; do
    case "$1" in
        --ramfs) BENCH_FS="ramfs"; shift ;;
        --tmpfs) BENCH_FS="tmpfs"; shift ;;
        *) break ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Ensure common tool install locations are on PATH
export PATH="${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"
if [ -n "${CONDA_PREFIX}" ] && [ -d "${CONDA_PREFIX}/bin" ]; then
    export PATH="${CONDA_PREFIX}/bin:${PATH}"
fi
if [ -n "${MAMBA_ROOT_PREFIX}" ] && [ -d "${MAMBA_ROOT_PREFIX}/bin" ]; then
    export PATH="${MAMBA_ROOT_PREFIX}/bin:${PATH}"
fi

# --- Toolchain checks ---
missing=()
check_cmd() { command -v "$1" >/dev/null 2>&1; }
check_cmd pixi      || missing+=(pixi)
check_cmd hyperfine || missing+=(hyperfine)

if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing required tool(s): ${missing[*]}"
    echo "  pixi:      https://pixi.sh"
    echo "  hyperfine: https://github.com/sharkdp/hyperfine (e.g. cargo install hyperfine)"
    echo "PATH used: $PATH"
    exit 1
fi

# --- Hyperfine configuration ---
# Number of warmup runs and measured runs; override via env:
#   WARMUP_RUNS=1 HYPERFINE_RUNS=10 ./benchmark/throughput/run_throughput_benchmarks.sh
WARMUP_RUNS="${WARMUP_RUNS:-3}"
HYPERFINE_RUNS="${HYPERFINE_RUNS:-15}"

# --- CPU pinning configuration (Linux only, optional) ---
# Default: pin benchmarks to core 0; override with BENCH_CPUS=0-3,1,3, etc.
BENCH_CPUS="${BENCH_CPUS:-0}"

hyperfine_cmd() {
    if [ "$(uname -s)" = "Linux" ] && command -v taskset >/dev/null 2>&1; then
        taskset -c "$BENCH_CPUS" hyperfine "$@"
    else
        hyperfine "$@"
    fi
}

# --- Ramfs/tmpfs mount (minimize disk I/O; no swap) ---
BENCH_DIR=$(mktemp -d)
BENCH_FILE="${BENCH_DIR}/throughput_bench_3g.fastq"
MOUNTED=0

cleanup_mount() {
    if [ "$MOUNTED" = 1 ]; then
        if ! sudo umount "$BENCH_DIR" 2>/dev/null; then
            echo "Warning: Failed to unmount $BENCH_DIR. Please run: sudo umount $BENCH_DIR && rmdir $BENCH_DIR"
        else
            rmdir "$BENCH_DIR" 2>/dev/null || true
        fi
    else
        rm -rf "$BENCH_DIR"
    fi
}
trap cleanup_mount EXIT

case "$(uname -s)" in
    Linux)
        if [ "$BENCH_FS" = "tmpfs" ]; then
            _mount_cmd="sudo mount -t tmpfs -o size=5G tmpfs $BENCH_DIR"
        else
            _mount_cmd="sudo mount -t ramfs ramfs $BENCH_DIR"
        fi
        if $_mount_cmd 2>/dev/null; then
            MOUNTED=1
            sudo chown "$(id -u):$(id -g)" "$BENCH_DIR"
        else
            echo "Failed to mount $BENCH_FS on $BENCH_DIR. Ensure sudo is available."
            echo "Fallback: using /dev/shm (no mount)."
            rmdir "$BENCH_DIR" 2>/dev/null || true
            BENCH_DIR="/dev/shm/blazeseq_throughput_bench_$$"
            mkdir -p "$BENCH_DIR"
            BENCH_FILE="${BENCH_DIR}/throughput_bench_3g.fastq"
        fi
        ;;
    Darwin)
        echo "macOS: using temporary directory (not a ramdisk). See Benchmarking.md for ramdisk setup."
        ;;
    *)
        echo "Unknown OS: using temporary directory."
        ;;
esac

# --- Generate 3GB synthetic FASTQ ---
echo "Generating 3GB synthetic FASTQ at $BENCH_FILE ..."
if ! pixi run mojo run -I . "$SCRIPT_DIR/../fastq-parser/generate_synthetic_fastq.mojo" "$BENCH_FILE" 3; then
    echo "Failed to generate 3GB FASTQ at $BENCH_FILE (check space on mounted ramfs)."
    exit 1
fi

# --- Build BlazeSeq throughput runner ---
RUNNER_BIN="$SCRIPT_DIR/run_throughput_blazeseq"
echo "Building throughput runner ..."
if ! pixi run mojo build -I . -o "$RUNNER_BIN" "$SCRIPT_DIR/run_throughput_blazeseq.mojo"; then
    echo "Failed to build run_throughput_blazeseq. Check Mojo toolchain and blazeseq package."
    exit 1
fi

# --- Optional: verify all modes agree on record/base count (non-fatal) ---
echo "Verifying mode outputs..."
ref=""
for mode in batches records ref_records; do
    out=$("$RUNNER_BIN" "$BENCH_FILE" "$mode" 2>/dev/null) || out=""
    if [ -z "$out" ]; then
        echo "Warning: $mode produced no output"
    elif [ -z "$ref" ]; then
        ref="$out"
    fi
    if [ -n "$out" ] && [ "$out" != "$ref" ]; then
        echo "Warning: $mode output '$out' differs from reference '$ref'"
    fi
done
echo "Reference counts: ${ref:- (none; one or more runs failed)}"

# --- Hyperfine ---
echo "Running hyperfine (warmup=${WARMUP_RUNS}, runs=${HYPERFINE_RUNS}) ..."
hyperfine_cmd \
    --warmup "${WARMUP_RUNS}" \
    --runs "${HYPERFINE_RUNS}" \
    --export-markdown "$REPO_ROOT/throughput_benchmark_results.md" \
    --export-json "$REPO_ROOT/throughput_benchmark_results.json" \
    -n batches     "$RUNNER_BIN $BENCH_FILE batches" \
    -n records     "$RUNNER_BIN $BENCH_FILE records" \
    -n ref_records "$RUNNER_BIN $BENCH_FILE ref_records"

echo ""
echo "Results written to throughput_benchmark_results.md and throughput_benchmark_results.json"

# Plot results to assets/ (repo root is parent of benchmark/); inject runs, size-gb, reads
REPO_ROOT_FOR_PLOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if command -v python >/dev/null 2>&1; then
    RECORDS="${ref%% *}"
    python "$REPO_ROOT_FOR_PLOT/benchmark/scripts/plot_benchmark_results.py" --repo-root "$REPO_ROOT_FOR_PLOT" --assets-dir "$REPO_ROOT_FOR_PLOT/assets" --json "$REPO_ROOT_FOR_PLOT/benchmark/throughput_benchmark_results.json" --runs "${HYPERFINE_RUNS}" --size-gb 3 --reads "${RECORDS:-0}" 2>/dev/null || true
fi
