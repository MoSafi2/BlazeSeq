#!/usr/bin/env bash
# FASTA parser benchmark: BlazeSeq vs needletail vs noodles.
# Generates synthetic FASTA on a tmpfs/ramfs mount (default 1GB; set FASTA_SIZE_GB), runs each parser with hyperfine.
# Run from repository root: ./benchmark/fasta-parser/run_benchmarks.sh [--ramfs|--tmpfs]
# Requires: pixi, hyperfine, cargo, rustc. On Linux: sudo for ramfs/tmpfs mount/umount.

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

# Source CPU benchmark setup (performance governor, disable turbo, taskset) on Linux
# shellcheck source=../scripts/cpu_bench_setup.sh
source "$SCRIPT_DIR/../scripts/cpu_bench_setup.sh"

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
check_cmd pixi       || missing+=(pixi)
check_cmd hyperfine  || missing+=(hyperfine)
check_cmd cargo      || missing+=(cargo)
check_cmd rustc      || missing+=(rustc)

if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing required tool(s): ${missing[*]}"
    echo "  pixi:       https://pixi.sh"
    echo "  hyperfine:  https://github.com/sharkdp/hyperfine (e.g. cargo install hyperfine -> ~/.cargo/bin)"
    echo "  Rust:       https://rustup.rs (cargo, rustc -> ~/.cargo/bin)"
    echo "PATH used: $PATH"
    exit 1
fi

# --- Hyperfine configuration ---
# Override via env: WARMUP_RUNS=1 HYPERFINE_RUNS=10 ./benchmark/fasta-parser/run_benchmarks.sh
WARMUP_RUNS="${WARMUP_RUNS:-3}"
HYPERFINE_RUNS="${HYPERFINE_RUNS:-15}"

# --- FASTA size (GB) ---
# Override via env: FASTA_SIZE_GB=2 ./benchmark/fasta-parser/run_benchmarks.sh
FASTA_SIZE_GB="${FASTA_SIZE_GB:-1}"

# --- Ramfs/tmpfs mount (minimize disk I/O; no swap) ---
BENCH_DIR=$(mktemp -d)
BENCH_FILE="${BENCH_DIR}/blazeseq_bench_fasta_${FASTA_SIZE_GB}g.fasta"
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
        if [ "$BENCH_FS" = "tmpfs" ]; then
            _mount_cmd="sudo mount -t tmpfs -o size=$((FASTA_SIZE_GB + 1))G tmpfs $BENCH_DIR"
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
            BENCH_DIR="/dev/shm/blazeseq_fasta_bench_$$"
            mkdir -p "$BENCH_DIR"
            BENCH_FILE="${BENCH_DIR}/blazeseq_bench_fasta_${FASTA_SIZE_GB}g.fasta"
        fi
        ;;
    Darwin)
        echo "macOS: using temporary directory (not a ramdisk). See Benchmarking.md for ramdisk setup."
        ;;
    *)
        echo "Unknown OS: using temporary directory."
        ;;
esac

# --- Generate synthetic FASTA (avg 2000 bp/record, 200–3800 bp range, 60 bp lines) ---
echo "Generating ${FASTA_SIZE_GB}GB synthetic FASTA at $BENCH_FILE ..."
if ! pixi run mojo run -I . "$SCRIPT_DIR/generate_synthetic_fasta.mojo" "$BENCH_FILE" "$FASTA_SIZE_GB"; then
    echo "Failed to generate ${FASTA_SIZE_GB}GB FASTA at $BENCH_FILE (check space on mounted $BENCH_FS)."
    exit 1
fi

# --- Build Rust runners ---
export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}"
echo "Building needletail_fasta_runner ..."
(cd "$SCRIPT_DIR/needletail_runner" && cargo build --release) || {
    echo "Failed to build needletail_fasta_runner. Check Rust toolchain and dependencies."
    exit 1
}
NEEDLETAIL_BIN="$SCRIPT_DIR/needletail_runner/target/release/needletail_fasta_runner"

echo "Building noodles_fasta_runner ..."
(cd "$SCRIPT_DIR/noodles_runner" && cargo build --release) || {
    echo "Failed to build noodles_fasta_runner. Check Rust toolchain and dependencies."
    exit 1
}
NOODLES_BIN="$SCRIPT_DIR/noodles_runner/target/release/noodles_fasta_runner"

# --- Build BlazeSeq FASTA runner ---
BLAZESEQ_BIN="$SCRIPT_DIR/run_blazeseq_fasta"
echo "Building BlazeSeq FASTA runner ..."
if ! pixi run mojo build -I . -o "$BLAZESEQ_BIN" "$SCRIPT_DIR/run_blazeseq_fasta.mojo"; then
    echo "Failed to build BlazeSeq FASTA runner. Check Mojo toolchain and blazeseq package."
    exit 1
fi

# --- Verify both parsers agree on record/base count (non-fatal) ---
echo "Verifying parser outputs..."
ref=""
for cmd_label in "BlazeSeq" "needletail" "noodles"; do
    case "$cmd_label" in
        BlazeSeq)   out=$("$BLAZESEQ_BIN" "$BENCH_FILE" 2>/dev/null) || out="" ;;
        needletail) out=$("$NEEDLETAIL_BIN" "$BENCH_FILE" 2>/dev/null) || out="" ;;
        noodles)    out=$("$NOODLES_BIN" "$BENCH_FILE" 2>/dev/null) || out="" ;;
    esac
    out=$(echo "$out" | tail -1)
    if [ -z "$out" ]; then
        echo "Warning: $cmd_label produced no output (runner may have failed)"
    elif [ -z "$ref" ]; then
        ref="$out"
        echo "  $cmd_label: $out"
    else
        echo "  $cmd_label: $out"
        if [ "$out" != "$ref" ]; then
            echo "Warning: $cmd_label output '$out' differs from reference '$ref'"
        fi
    fi
done
echo "Reference counts: ${ref:-(none; one or more runners failed)}"

# --- CPU benchmark environment (Linux: governor, turbo, pin to BENCH_CPUS) ---
cpu_bench_setup

# --- Hyperfine ---
echo "Running hyperfine (warmup=${WARMUP_RUNS}, runs=${HYPERFINE_RUNS}) ..."
hyperfine_cmd \
    --warmup "${WARMUP_RUNS}" \
    --runs "${HYPERFINE_RUNS}" \
    --export-markdown "$REPO_ROOT/benchmark_results_fasta.md" \
    --export-json "$REPO_ROOT/benchmark_results_fasta.json" \
    -n BlazeSeq   "$BLAZESEQ_BIN $BENCH_FILE" \
    -n needletail "$NEEDLETAIL_BIN $BENCH_FILE" \
    -n noodles    "$NOODLES_BIN $BENCH_FILE"

echo "Results written to benchmark_results_fasta.md and benchmark_results_fasta.json"

# Plot results
if command -v python >/dev/null 2>&1; then
    RECORDS="${ref%% *}"
    python "$REPO_ROOT/benchmark/scripts/plot_benchmark_results.py" \
        --repo-root "$REPO_ROOT" \
        --assets-dir "$REPO_ROOT/assets" \
        --json "$REPO_ROOT/benchmark_results_fasta.json" \
        --runs "${HYPERFINE_RUNS}" \
        --size-gb "$FASTA_SIZE_GB" \
        --reads "${RECORDS:-0}" 2>/dev/null || true
fi
