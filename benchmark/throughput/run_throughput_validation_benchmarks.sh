#!/usr/bin/env bash
# Throughput benchmark: validation regimes across batches/records/views.
# Generates 3GB synthetic FASTQ on a tmpfs/ramfs mount and runs all 9
# mode x validation combinations with hyperfine.
#
# Run from repository root:
#   ./benchmark/throughput/run_throughput_validation_benchmarks.sh [--ramfs|--tmpfs]

set -e

# --- Mount type: tmpfs (default) or --ramfs/--tmpfs ---
BENCH_FS="tmpfs"
while [ $# -gt 0 ]; do
    case "$1" in
        --ramfs) BENCH_FS="ramfs"; shift ;;
        --tmpfs) BENCH_FS="tmpfs"; shift ;;
        *) break ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
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
    echo "  hyperfine: https://github.com/sharkdp/hyperfine"
    echo "PATH used: $PATH"
    exit 1
fi

# --- Hyperfine configuration ---
WARMUP_RUNS="${WARMUP_RUNS:-3}"
HYPERFINE_RUNS="${HYPERFINE_RUNS:-15}"

# --- CPU pinning configuration (Linux only, optional) ---
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
BENCH_FILE="${BENCH_DIR}/throughput_validation_bench_3g.fastq"
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
            BENCH_DIR="/dev/shm/blazeseq_throughput_validation_bench_$$"
            mkdir -p "$BENCH_DIR"
            BENCH_FILE="${BENCH_DIR}/throughput_validation_bench_3g.fastq"
        fi
        ;;
    Darwin)
        echo "macOS: using temporary directory (not a ramdisk)."
        ;;
    *)
        echo "Unknown OS: using temporary directory."
        ;;
esac

# --- Generate 3GB synthetic FASTQ ---
echo "Generating 3GB synthetic FASTQ at $BENCH_FILE ..."
if ! pixi run mojo run -I . "benchmark/fastq-parser/generate_synthetic_fastq.mojo" "$BENCH_FILE" 3; then
    echo "Failed to generate 3GB FASTQ at $BENCH_FILE (check space on mounted ramfs)."
    exit 1
fi

# --- Build validation throughput runner ---
RUNNER_BIN="$SCRIPT_DIR/run_throughput_validation_blazeseq"
echo "Building validation throughput runner ..."
if ! pixi run mojo build -I . -o "$RUNNER_BIN" "$SCRIPT_DIR/run_throughput_validation_blazeseq.mojo"; then
    echo "Failed to build run_throughput_validation_blazeseq.mojo."
    exit 1
fi

# --- Optional output consistency check (non-fatal) ---
echo "Verifying mode/validation outputs..."
ref=""
for mode in batches records views; do
    for validation in none ascii ascii_quality; do
        out=$("$RUNNER_BIN" "$BENCH_FILE" "$mode" "$validation" 2>/dev/null) || out=""
        if [ -z "$out" ]; then
            echo "Warning: $mode/$validation produced no output"
        elif [ -z "$ref" ]; then
            ref="$out"
        fi
        if [ -n "$out" ] && [ "$out" != "$ref" ]; then
            echo "Warning: $mode/$validation output '$out' differs from reference '$ref'"
        fi
    done
done
echo "Reference counts: ${ref:- (none; one or more runs failed)}"

# --- Hyperfine (9 combinations) ---
RESULTS_MD="$REPO_ROOT/throughput_validation_benchmark_results.md"
RESULTS_JSON="$REPO_ROOT/throughput_validation_benchmark_results.json"

echo "Running hyperfine (warmup=${WARMUP_RUNS}, runs=${HYPERFINE_RUNS}) ..."
hyperfine_cmd \
    --warmup "${WARMUP_RUNS}" \
    --runs "${HYPERFINE_RUNS}" \
    --export-markdown "$RESULTS_MD" \
    --export-json "$RESULTS_JSON" \
    -n "batches/none"          "$RUNNER_BIN $BENCH_FILE batches none" \
    -n "batches/ascii"         "$RUNNER_BIN $BENCH_FILE batches ascii" \
    -n "batches/ascii_quality" "$RUNNER_BIN $BENCH_FILE batches ascii_quality" \
    -n "records/none"          "$RUNNER_BIN $BENCH_FILE records none" \
    -n "records/ascii"         "$RUNNER_BIN $BENCH_FILE records ascii" \
    -n "records/ascii_quality" "$RUNNER_BIN $BENCH_FILE records ascii_quality" \
    -n "views/none"      "$RUNNER_BIN $BENCH_FILE views none" \
    -n "views/ascii"     "$RUNNER_BIN $BENCH_FILE views ascii" \
    -n "views/ascii_quality" "$RUNNER_BIN $BENCH_FILE views ascii_quality"

echo ""
echo "Results written to throughput_validation_benchmark_results.md and throughput_validation_benchmark_results.json"

# --- Plot grouped results ---
if command -v python >/dev/null 2>&1; then
    RECORDS="${ref%% *}"
    python "$REPO_ROOT/benchmark/scripts/plot_benchmark_results.py" \
        --repo-root "$REPO_ROOT" \
        --assets-dir "$REPO_ROOT/assets" \
        --json "$RESULTS_JSON" \
        --runs "${HYPERFINE_RUNS}" \
        --size-gb 3 \
        --reads "${RECORDS:-0}" 2>/dev/null || true
fi
