#!/usr/bin/env bash
# FASTQ parser benchmark: BlazeSeq vs needletail, seq_io, kseq.
# Generates 3GB synthetic FASTQ on a ramfs mount, runs each parser with hyperfine.
# Run from repository root: ./benchmark/fastq-parser/run_benchmarks.sh
# Requires: pixi, hyperfine, cargo, gcc or clang. On Linux: sudo for ramfs mount/umount.

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
if ! check_cmd gcc && ! check_cmd clang; then
    missing+=(gcc or clang)
fi

if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing required tool(s): ${missing[*]}"
    echo "  pixi:        https://pixi.sh"
    echo "  hyperfine:   https://github.com/sharkdp/hyperfine (e.g. cargo install hyperfine -> ~/.cargo/bin)"
    echo "  Rust:        https://rustup.rs (cargo, rustc -> ~/.cargo/bin)"
    echo "  C compiler:  gcc or clang"
    echo "PATH used: $PATH"
    exit 1
fi

# --- Ramfs mount (minimize disk I/O; no swap) ---
BENCH_DIR=$(mktemp -d)
BENCH_FILE="${BENCH_DIR}/blazeseq_bench_1g.fastq"
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
            BENCH_DIR="/dev/shm/blazeseq_bench_$$"
            mkdir -p "$BENCH_DIR"
            BENCH_FILE="${BENCH_DIR}/blazeseq_bench_1g.fastq"
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

# --- Build Rust runners (native CPU for consistent benchmarks) ---
export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}"
echo "Building needletail_runner ..."
(cd "$SCRIPT_DIR/needletail_runner" && cargo build --release) || {
    echo "Failed to build needletail_runner. Check Rust toolchain and dependencies."
    exit 1
}
echo "Building seq_io_runner ..."
(cd "$SCRIPT_DIR/seq_io_runner" && cargo build --release) || {
    echo "Failed to build seq_io_runner. Check Rust toolchain and dependencies."
    exit 1
}

# --- Build kseq runner ---
CC=""
command -v gcc >/dev/null 2>&1 && CC=gcc
command -v clang >/dev/null 2>&1 && CC=clang
if [ -z "$CC" ]; then
    echo "A C compiler (gcc or clang) is required for the kseq runner."
    exit 1
fi
echo "Building kseq_runner ..."
(cd "$SCRIPT_DIR/kseq_runner" && $CC -O3 -o kseq_runner main.c) || {
    echo "Failed to build kseq_runner. Check C toolchain."
    exit 1
}

# --- Build BlazeSeq runner (Mojo binary) ---
BLAZESEQ_BIN="$SCRIPT_DIR/run_blazeseq"
echo "Building BlazeSeq runner ..."
if ! pixi run mojo build -I . -o "$BLAZESEQ_BIN" "$SCRIPT_DIR/run_blazeseq.mojo"; then
    echo "Failed to build BlazeSeq runner. Check Mojo toolchain and blazeseq package."
    exit 1
fi

# --- Optional: verify all parsers agree on record/base count (non-fatal) ---
echo "Verifying parser outputs..."
ref=""
for cmd_label in "BlazeSeq" "needletail" "seq_io" "kseq"; do
    case "$cmd_label" in
        BlazeSeq)     out=$("$BLAZESEQ_BIN" "$BENCH_FILE" 2>/dev/null) || out="" ;;
        needletail)   out=$("$SCRIPT_DIR/needletail_runner/target/release/needletail_runner" "$BENCH_FILE" 2>/dev/null) || out="" ;;
        seq_io)       out=$("$SCRIPT_DIR/seq_io_runner/target/release/seq_io_runner" "$BENCH_FILE" 2>/dev/null) || out="" ;;
        kseq)         out=$("$SCRIPT_DIR/kseq_runner/kseq_runner" "$BENCH_FILE" 2>/dev/null) || out="" ;;
    esac
    out=$(echo "$out" | tail -1)
    if [ -z "$out" ]; then
        echo "Warning: $cmd_label produced no output (runner may have failed)"
    elif [ -z "$ref" ]; then
        ref="$out"
    fi
    if [ -n "$out" ] && [ "$out" != "$ref" ]; then
        echo "Warning: $cmd_label output '$out' differs from reference '$ref'"
    fi
done
echo "Reference counts: ${ref:- (none; one or more runners failed)}"

# --- CPU benchmark environment (Linux: governor, turbo, pin to BENCH_CPUS) ---
cpu_bench_setup

# --- Hyperfine ---
echo "Running hyperfine (warmup=2, runs=5) ..."
hyperfine_cmd \
    --warmup 2 \
    --runs 15 \
    --export-markdown "$REPO_ROOT/benchmark_results.md" \
    --export-json "$REPO_ROOT/benchmark_results.json" \
    -n BlazeSeq    "$BLAZESEQ_BIN $BENCH_FILE" \
    -n needletail  "$SCRIPT_DIR/needletail_runner/target/release/needletail_runner $BENCH_FILE" \
    -n seq_io      "$SCRIPT_DIR/seq_io_runner/target/release/seq_io_runner $BENCH_FILE" \
    -n kseq        "$SCRIPT_DIR/kseq_runner/kseq_runner $BENCH_FILE"

echo "Results written to benchmark_results.md and benchmark_results.json"

# Plot results to assets/
if command -v python >/dev/null 2>&1; then
    python "$REPO_ROOT/benchmark/scripts/plot_benchmark_results.py" --repo-root "$REPO_ROOT" --assets-dir "$REPO_ROOT/assets" --json "$REPO_ROOT/benchmark_results.json" 2>/dev/null || true
fi
