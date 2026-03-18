#!/usr/bin/env bash
# FASTQ parser benchmark: BlazeSeq batch parsing vs external record-set parsers.
#
# Compares (single-threaded):
# - BlazeSeq: FastqParser.batches(batch_size)
# - paraseq: RecordSet.fill + record_set.iter()
# - seq_io: Reader::read_record_set_exact + iterating the filled RecordSet
#
# Generates synthetic FASTQ on a tmpfs/ramfs mount (default 3GB; set FASTQ_SIZE_GB),
# builds runners, then runs hyperfine.
#
# Run from repository root:
#   ./benchmark/fastq-parser/run_benchmarks_batch_vs_paraseq.sh [--ramfs|--tmpfs]
#
# Optional environment:
#   FASTQ_SIZE_GB=3
#   BATCH_SIZE=4096
#   WARMUP_RUNS=3
#   HYPERFINE_RUNS=15

set -e

# --- Mount type: tmpfs (default) or --ramfs/--tmpfs ---
BENCH_FS="tmpfs"
BATCH_SIZE="${BATCH_SIZE:-4096}"

while [ $# -gt 0 ]; do
    case "$1" in
        --ramfs) BENCH_FS="ramfs"; shift ;;
        --tmpfs) BENCH_FS="tmpfs"; shift ;;
        --batch-size)
            if [ -n "$2" ]; then BATCH_SIZE="$2"; shift 2; else shift; fi
            ;;
        *) break ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# Source CPU benchmark setup (performance governor, disable turbo, taskset) on Linux
# shellcheck source=../scripts/cpu_bench_setup.sh
source "$SCRIPT_DIR/../scripts/cpu_bench_setup.sh"

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
    exit 1
fi

# --- Hyperfine configuration ---
WARMUP_RUNS="${WARMUP_RUNS:-3}"
HYPERFINE_RUNS="${HYPERFINE_RUNS:-15}"

# --- FASTQ size (GB) ---
FASTQ_SIZE_GB="${FASTQ_SIZE_GB:-3}"

# --- Ramfs/tmpfs mount (minimize disk I/O; no swap) ---
BENCH_DIR=$(mktemp -d)
BENCH_FILE="${BENCH_DIR}/blazeseq_batch_vs_paraseq_${FASTQ_SIZE_GB}g.fastq"
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
            BENCH_DIR="/dev/shm/blazeseq_batch_vs_paraseq_$$"
            mkdir -p "$BENCH_DIR"
            BENCH_FILE="${BENCH_DIR}/blazeseq_batch_vs_paraseq_${FASTQ_SIZE_GB}g.fastq"
        fi
        ;;
    Darwin)
        echo "macOS: using temporary directory (not a ramdisk)."
        ;;
    *)
        echo "Unknown OS: using temporary directory."
        ;;
esac

echo "Generating ${FASTQ_SIZE_GB}GB synthetic FASTQ at $BENCH_FILE ..."
pixi run mojo run -I . "$SCRIPT_DIR/generate_synthetic_fastq.mojo" "$BENCH_FILE" "$FASTQ_SIZE_GB"

# --- Build runners (native CPU for consistent benchmarks) ---
export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}"

echo "Building BlazeSeq batch runner ..."
BLAZESEQ_BATCH_BIN="$SCRIPT_DIR/run_blazeseq_batch"
pixi run mojo build -I . -o "$BLAZESEQ_BATCH_BIN" "$SCRIPT_DIR/run_blazeseq_batch.mojo"

echo "Building paraseq_runner ..."
(cd "$SCRIPT_DIR/paraseq_runner" && cargo build --release)
PARASEQ_BIN="$SCRIPT_DIR/paraseq_runner/target/release/paraseq_runner"

echo "Building seq_io_recordset_runner ..."
(cd "$SCRIPT_DIR/seq_io_recordset_runner" && cargo build --release)
SEQ_IO_RECORDSET_BIN="$SCRIPT_DIR/seq_io_recordset_runner/target/release/seq_io_recordset_runner"

# --- CPU benchmark environment (Linux: governor, turbo, pin to BENCH_CPUS) ---
cpu_bench_setup

# --- Optional: verify all parsers agree on record/base count (non-fatal) ---
echo "Verifying parser outputs..."
ref=""

for cmd_label in "BlazeSeqBatch" "paraseq" "seq_io_recordset"; do
    case "$cmd_label" in
        BlazeSeqBatch)
            out=$("$BLAZESEQ_BATCH_BIN" "$BENCH_FILE" "$BATCH_SIZE" 2>/dev/null || true)
            ;;
        paraseq)
            out=$("$PARASEQ_BIN" "$BENCH_FILE" "$BATCH_SIZE" 2>/dev/null || true)
            ;;
        seq_io_recordset)
            out=$("$SEQ_IO_RECORDSET_BIN" "$BENCH_FILE" "$BATCH_SIZE" 2>/dev/null || true)
            ;;
    esac

    # Output is one line; keep first line only
    out="$(printf "%s" "$out" | awk 'NR==1{print; exit}')"
    if [ -z "$out" ]; then
        echo "Warning: $cmd_label produced no output (runner may have failed)"
        continue
    fi
    if [ -z "$ref" ]; then
        ref="$out"
    elif [ "$out" != "$ref" ]; then
        echo "Warning: $cmd_label output '$out' differs from reference '$ref'"
    fi
done

echo "Reference counts: ${ref:- (none; one or more runners failed)}"

# --- Hyperfine ---
OUT_JSON="$REPO_ROOT/benchmark_results_batch_vs_paraseq.json"
OUT_MD="$REPO_ROOT/benchmark_results_batch_vs_paraseq.md"

echo "Running hyperfine (warmup=${WARMUP_RUNS}, runs=${HYPERFINE_RUNS}) ..."
hyperfine_cmd \
    --warmup "${WARMUP_RUNS}" \
    --runs "${HYPERFINE_RUNS}" \
    --export-markdown "$OUT_MD" \
    --export-json "$OUT_JSON" \
    -n BlazeSeqBatch     "$BLAZESEQ_BATCH_BIN $BENCH_FILE $BATCH_SIZE" \
    -n paraseq            "$PARASEQ_BIN $BENCH_FILE $BATCH_SIZE" \
    -n seq_io_recordset  "$SEQ_IO_RECORDSET_BIN $BENCH_FILE $BATCH_SIZE"

echo "Results written to $(basename "$OUT_MD") and $(basename "$OUT_JSON")"

# Plot results to assets/ (best-effort)
if command -v python >/dev/null 2>&1; then
    RECORDS="${ref%% *}"
    python "$REPO_ROOT/benchmark/scripts/plot_benchmark_results.py" \
        --repo-root "$REPO_ROOT" \
        --assets-dir "$REPO_ROOT/assets" \
        --json "$OUT_JSON" \
        --runs "${HYPERFINE_RUNS}" \
        --size-gb "$FASTQ_SIZE_GB" \
        --reads "${RECORDS:-0}" 2>/dev/null || true
fi

