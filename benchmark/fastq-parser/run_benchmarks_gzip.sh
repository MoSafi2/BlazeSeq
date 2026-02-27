#!/usr/bin/env bash
# Compressed FASTQ parser benchmark: kseq, seq_io, needletail, BlazeSeq.
# Generates 3GB synthetic FASTQ, compresses to .fastq.gz, runs each parser with hyperfine.
# Run from repository root: ./benchmark/fastq-parser/run_benchmarks_gzip.sh
# Requires: pixi, hyperfine, cargo, gcc, gzip. On Linux: sudo for ramfs mount/umount.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# Source CPU benchmark setup (performance governor, disable turbo, taskset) on Linux
# shellcheck source=../scripts/cpu_bench_setup.sh
source "$SCRIPT_DIR/../scripts/cpu_bench_setup.sh"

# Ensure common tool install locations are on PATH (e.g. when script runs non-interactively)
export PATH="${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"
# If CONDA_PREFIX or MAMBA_ROOT_PREFIX is set (e.g. from pixi shell), prefer that env's bin
if [ -n "${CONDA_PREFIX}" ] && [ -d "${CONDA_PREFIX}/bin" ]; then
    export PATH="${CONDA_PREFIX}/bin:${PATH}"
fi
if [ -n "${MAMBA_ROOT_PREFIX}" ] && [ -d "${MAMBA_ROOT_PREFIX}/bin" ]; then
    export PATH="${MAMBA_ROOT_PREFIX}/bin:${PATH}"
fi

# --- Toolchain checks ---
missing=()
check_cmd() { command -v "$1" >/dev/null 2>&1; }
check_cmd pixi       || missing+=(pixi)
check_cmd hyperfine  || missing+=(hyperfine)
check_cmd cargo      || missing+=(cargo)
check_cmd rustc      || missing+=(rustc)
check_cmd gcc        || missing+=(gcc)
check_cmd gzip       || missing+=(gzip)

if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing required tool(s): ${missing[*]}"
    echo "  pixi:        https://pixi.sh"
    echo "  hyperfine:   https://github.com/sharkdp/hyperfine (e.g. cargo install hyperfine -> ~/.cargo/bin)"
    echo "  Rust:        https://rustup.rs (cargo, rustc -> ~/.cargo/bin)"
    echo "  gcc:         system package (for kseq gzip runner)"
    echo "  gzip:        system package (e.g. gzip)"
    echo "PATH used: $PATH"
    exit 1
fi

# --- Hyperfine configuration ---
# Number of warmup runs and measured runs; override via env:
#   WARMUP_RUNS=1 HYPERFINE_RUNS=10 ./benchmark/fastq-parser/run_benchmarks_gzip.sh
WARMUP_RUNS="${WARMUP_RUNS:-3}"
HYPERFINE_RUNS="${HYPERFINE_RUNS:-15}"

# --- Ramfs mount (minimize disk I/O; no swap) ---
BENCH_DIR=$(mktemp -d)
BENCH_FILE="${BENCH_DIR}/blazeseq_bench_3g.fastq"
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
trap 'cleanup_mount; cpu_bench_teardown' EXIT

case "$(uname -s)" in
    Linux)
        if sudo mount -t ramfs ramfs "$BENCH_DIR" 2>/dev/null; then
            MOUNTED=1
            sudo chown "$(id -u):$(id -g)" "$BENCH_DIR"
        else
            echo "Failed to mount ramfs on $BENCH_DIR. Ensure sudo is available and ramfs is supported."
            echo "Fallback: using /dev/shm (no mount)."
            rmdir "$BENCH_DIR" 2>/dev/null || true
            BENCH_DIR="/dev/shm/blazeseq_bench_gzip_$$"
            mkdir -p "$BENCH_DIR"
            BENCH_FILE="${BENCH_DIR}/blazeseq_bench_3g.fastq"
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
if ! pixi run mojo run -I . "$SCRIPT_DIR/generate_synthetic_fastq.mojo" "$BENCH_FILE" 3; then
    echo "Failed to generate 3GB FASTQ at $BENCH_FILE (check space on mounted ramfs)."
    exit 1
fi

# --- Compress to gzip and remove plain file to free space ---
# Compression level 1; default `bclconvert` compression level.
# https://knowledge.illumina.com/software/general/software-general-reference_material-list/000003710
echo "Compressing to $BENCH_FILE.gz ..."
if ! gzip -1 -c "$BENCH_FILE" > "${BENCH_FILE}.gz.tmp"; then
    rm -f "${BENCH_FILE}.gz.tmp"
    echo "gzip failed" >&2
    exit 1
fi
mv "${BENCH_FILE}.gz.tmp" "${BENCH_FILE}.gz"
rm -f "$BENCH_FILE"
BENCH_GZ="${BENCH_FILE}.gz"

# --- Build kseq gzip runner (C + zlib) ---
KSEQ_GZIP_BIN="$SCRIPT_DIR/kseq_runner/kseq_gzip_runner"
echo "Building kseq_gzip_runner ..."
if ! (cd "$SCRIPT_DIR/kseq_runner" && gcc -O3 -o kseq_gzip_runner main_gzip.c -lz); then
    echo "Failed to build kseq_gzip_runner. Check gcc and zlib-dev."
    exit 1
fi

# --- Build Rust runners (native CPU for consistent benchmarks) ---
export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}"
echo "Building needletail_runner ..."
(cd "$SCRIPT_DIR/needletail_runner" && cargo build --release) || {
    echo "Failed to build needletail_runner. Check Rust toolchain and dependencies."
    exit 1
}
echo "Building seq_io_gzip_runner ..."
(cd "$SCRIPT_DIR/seq_io_runner" && cargo build --release) || {
    echo "Failed to build seq_io_gzip_runner. Check Rust toolchain and dependencies."
    exit 1
}

# --- Build BlazeSeq gzip runner (Mojo binary) ---
BLAZESEQ_GZIP_BIN="$SCRIPT_DIR/run_blazeseq_gzip"
echo "Building BlazeSeq gzip runner ..."
if ! pixi run mojo build -I . -o "$BLAZESEQ_GZIP_BIN" "$SCRIPT_DIR/run_blazeseq_gzip.mojo"; then
    echo "Failed to build BlazeSeq gzip runner. Check Mojo toolchain and blazeseq package."
    exit 1
fi

# --- Verify all parsers agree on record/base count ---
echo "Verifying parser outputs on $BENCH_GZ ..."
ref=""
for cmd_label in "kseq" "seq_io" "needletail" "BlazeSeq"; do
    case "$cmd_label" in
        kseq)       out=$("$KSEQ_GZIP_BIN" "$BENCH_GZ" 2>/dev/null) || out="" ;;
        seq_io)     out=$("$SCRIPT_DIR/seq_io_runner/target/release/seq_io_gzip_runner" "$BENCH_GZ" 2>/dev/null) || out="" ;;
        needletail) out=$("$SCRIPT_DIR/needletail_runner/target/release/needletail_runner" "$BENCH_GZ" 2>/dev/null) || out="" ;;
        BlazeSeq)   out=$("$BLAZESEQ_GZIP_BIN" "$BENCH_GZ" 2>/dev/null) || out="" ;;
    esac
    out=$(echo "$out" | tail -1)
    if [ -z "$out" ]; then
        echo "Error: $cmd_label produced no output (runner may have failed)"
        exit 1
    fi
    if [ -z "$ref" ]; then
        ref="$out"
    fi
    if [ "$out" != "$ref" ]; then
        echo "Error: $cmd_label output '$out' differs from reference '$ref'"
        exit 1
    fi
done
echo "Reference counts: $ref"

# --- CPU benchmark environment (Linux: governor, turbo; no taskset so rapidgzip can use multiple cores) ---
cpu_bench_setup

# --- Hyperfine (plain hyperfine, no core pinning: BlazeSeq uses rapidgzip which is multi-core) ---
echo "Running hyperfine (warmup=${WARMUP_RUNS}, runs=${HYPERFINE_RUNS}) ..."
hyperfine \
    --warmup "${WARMUP_RUNS}" \
    --runs "${HYPERFINE_RUNS}" \
    --export-markdown "$REPO_ROOT/benchmark_results_gzip.md" \
    --export-json "$REPO_ROOT/benchmark_results_gzip.json" \
    -n kseq      "$KSEQ_GZIP_BIN $BENCH_GZ" \
    -n seq_io    "$SCRIPT_DIR/seq_io_runner/target/release/seq_io_gzip_runner $BENCH_GZ" \
    -n needletail "$SCRIPT_DIR/needletail_runner/target/release/needletail_runner $BENCH_GZ" \
    -n BlazeSeq   "$BLAZESEQ_GZIP_BIN $BENCH_GZ"

echo "Results written to benchmark_results_gzip.md and benchmark_results_gzip.json"

# Plot results to assets/ (inject runs, size-gb, reads for plot subtitle)
if command -v python >/dev/null 2>&1; then
    RECORDS="${ref%% *}"
    PLOT_JSON="$REPO_ROOT/benchmark_results_gzip.json"
    python "$REPO_ROOT/benchmark/scripts/plot_benchmark_results.py" \
        --repo-root "$REPO_ROOT" \
        --assets-dir "$REPO_ROOT/assets" \
        --json "$PLOT_JSON" \
        --runs "${HYPERFINE_RUNS}" \
        --size-gb 3 \
        --reads "${RECORDS:-0}" \
        2>/dev/null || true
fi
