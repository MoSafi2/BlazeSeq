#!/usr/bin/env bash
# Consolidated FASTQ-parser benchmark launcher.
#
# Modes:
#   plain           -> benchmark_results.md/json (plain FASTQ)
#   gzip            -> benchmark_results_gzip.md/json (decompress + parse, multi-threaded BlazeSeq)
#   gzip-single    -> benchmark_results_gzip_single.md/json (single-threaded comparison)
#   batch-vs-paraseq -> benchmark_results_batch_vs_paraseq.md/json (batch parsing vs record-set parsers)
#
# Usage (from repo root):
#   ./benchmark/fastq-parser/run_benchmarks.sh --mode plain --ramfs
#   ./benchmark/fastq-parser/run_benchmarks.sh --mode gzip --ramfs --threads 8
#   ./benchmark/fastq-parser/run_benchmarks.sh --mode gzip-single --ramfs
#   ./benchmark/fastq-parser/run_benchmarks.sh --mode batch-vs-paraseq --ramfs --batch-size 4096
#
# Arguments:
#   --mode <plain|gzip|gzip-single|batch-vs-paraseq>   (default: plain)
#   --ramfs | --tmpfs                                  (default: tmpfs)
#   --input <path>                                    (use an existing FASTQ instead of generating synthetic)
#   --threads <N>                                      (gzip modes only; BlazeSeq rapidgzip parallelism)
#   --batch-size <N>                                  (batch-vs-paraseq only)
#
# Environment variables (all optional):
#   FASTQ_SIZE_GB            (default: 3)
#   WARMUP_RUNS              (default: 3)
#   HYPERFINE_RUNS           (default: 15)
#   GZIP_BLAZESEQ_THREADS    (default: 4; gzip modes only, unless overridden by --threads)
#   GZIP_BENCH_PARALLELISM  (if set to 1 or "single", forces gzip-single when mode is gzip*)
#   BATCH_SIZE               (default: 4096; used for batch-vs-paraseq unless overridden by --batch-size)
#   FASTQ_INPUT             same as `--input`
#
# Python integration / stdout contract:
# - This script writes all human/log output to stderr.
# - At the end it prints exactly ONE JSON object to stdout to support `subprocess` usage.
# - Example (parsing stdout JSON):
#   python - <<'PY'
#   import json, subprocess
#   p = subprocess.run(
#     ["./benchmark/fastq-parser/run_benchmarks.sh", "--mode", "plain", "--ramfs"],
#     text=True, capture_output=True, check=True
#   )
#   obj = json.loads(p.stdout)  # <-- machine-readable summary
#   print(obj["output_json"])
#   PY
#
# Output files (stable names for plotting / downstream automation):
#   plain:           benchmark_results.md + benchmark_results.json
#   gzip:            benchmark_results_gzip.md + benchmark_results_gzip.json
#   gzip-single:    benchmark_results_gzip_single.md + benchmark_results_gzip_single.json
#   batch-vs-paraseq: benchmark_results_batch_vs_paraseq.md + benchmark_results_batch_vs_paraseq.json

set -euo pipefail

# Route all stdout to stderr; write the final JSON summary to the original stdout FD (3).
exec 3>&1
exec 1>&2

MODE="plain"
BENCH_FS="tmpfs"
THREADS=""
BATCH_SIZE="${BATCH_SIZE:-4096}"
INPUT_PATH="${FASTQ_INPUT:-}"
input_source="synthetic"

while [ $# -gt 0 ]; do
    case "$1" in
        --mode)
            MODE="${2:?--mode requires a value (plain|gzip|gzip-single|batch-vs-paraseq)}"
            shift 2
            ;;
        --ramfs)
            BENCH_FS="ramfs"
            shift
            ;;
        --tmpfs)
            BENCH_FS="tmpfs"
            shift
            ;;
        --threads)
            THREADS="${2:?--threads requires a value}"
            shift 2
            ;;
        --batch-size)
            BATCH_SIZE="${2:?--batch-size requires a value}"
            shift 2
            ;;
        --input)
            INPUT_PATH="${2:?--input requires a value}"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

# Back-compat: allow `run_benchmarks.sh --mode gzip ... <threads>` (used by older pixi invocations).
if [ -z "${THREADS}" ] && [ "${MODE}" = "gzip" ] && [ -n "${1:-}" ]; then
    case "$1" in
        ''|*[!0-9]*)
            ;;
        *)
            THREADS="$1"
            shift
            ;;
    esac
fi

# Back-compat: older gzip single-thread selection relied on this env var.
if [ "${GZIP_BENCH_PARALLELISM:-}" = "1" ] || [ "${GZIP_BENCH_PARALLELISM:-}" = "single" ]; then
    if [ "${MODE}" = "gzip" ] || [ "${MODE}" = "gzip-single" ]; then
        MODE="gzip-single"
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# Source CPU benchmark setup (performance governor, disable turbo, taskset) on Linux
# shellcheck source=../scripts/cpu_bench_setup.sh
source "$SCRIPT_DIR/../scripts/cpu_bench_setup.sh"

# Ensure common tool install locations are on PATH (e.g. when script runs non-interactively)
export PATH="${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"
# If CONDA_PREFIX or MAMBA_ROOT_PREFIX is set (e.g. from pixi shell), prefer that env's bin
if [ -n "${CONDA_PREFIX:-}" ] && [ -d "${CONDA_PREFIX}/bin" ]; then
    export PATH="${CONDA_PREFIX}/bin:${PATH}"
fi
if [ -n "${MAMBA_ROOT_PREFIX:-}" ] && [ -d "${MAMBA_ROOT_PREFIX}/bin" ]; then
    export PATH="${MAMBA_ROOT_PREFIX}/bin:${PATH}"
fi

check_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- Toolchain checks ---
missing=()
check_cmd pixi      || missing+=(pixi)
check_cmd hyperfine || missing+=(hyperfine)
check_cmd cargo     || missing+=(cargo)
check_cmd rustc     || missing+=(rustc)

case "${MODE}" in
    plain)
        if ! check_cmd gcc && ! check_cmd clang; then
            missing+=(gcc or clang)
        fi
        ;;
    gzip|gzip-single)
        check_cmd gcc   || missing+=(gcc)
        check_cmd gzip  || missing+=(gzip)
        ;;
    batch-vs-paraseq)
        # No C compiler required (all runners are Rust/Mojo).
        ;;
    *)
        echo "Unknown --mode: ${MODE}" >&2
        exit 2
        ;;
esac

if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing required tool(s): ${missing[*]}" >&2
    echo "  pixi:        https://pixi.sh" >&2
    echo "  hyperfine:   https://github.com/sharkdp/hyperfine" >&2
    echo "  Rust:        https://rustup.rs (cargo, rustc -> ~/.cargo/bin)" >&2
    echo "  C compiler:  gcc or clang (plain mode / kseq)" >&2
    echo "PATH used: $PATH" >&2
    exit 1
fi

# --- Hyperfine configuration ---
WARMUP_RUNS="${WARMUP_RUNS:-3}"
HYPERFINE_RUNS="${HYPERFINE_RUNS:-15}"

# --- FASTQ size (GB) ---
FASTQ_SIZE_GB="${FASTQ_SIZE_GB:-3}"

# Use stable temp names for easier debugging when sudo/mount isn't available.
BENCH_FILE_BASENAME="blazeseq_bench_${FASTQ_SIZE_GB}g.fastq"
BENCH_DIR_PREFIX="blazeseq_bench"
case "${MODE}" in
    batch-vs-paraseq)
        BENCH_FILE_BASENAME="blazeseq_batch_vs_paraseq_${FASTQ_SIZE_GB}g.fastq"
        BENCH_DIR_PREFIX="blazeseq_batch_vs_paraseq"
        ;;
    gzip|gzip-single)
        BENCH_DIR_PREFIX="blazeseq_bench_gzip"
        ;;
esac

# --- Ramfs/tmpfs mount (minimize disk I/O; no swap) ---
BENCH_DIR="$(mktemp -d)"
BENCH_FILE="${BENCH_DIR}/${BENCH_FILE_BASENAME}"
MOUNTED=0

cleanup_mount() {
    if [ "$MOUNTED" = 1 ]; then
        if ! sudo umount "$BENCH_DIR" 2>/dev/null; then
            echo "Warning: Failed to unmount $BENCH_DIR. Please run: sudo umount $BENCH_DIR && rmdir $BENCH_DIR" >&2
        else
            rmdir "$BENCH_DIR" 2>/dev/null || true
        fi
    else
        rm -rf "$BENCH_DIR"
    fi
}
trap 'cleanup_mount; cpu_bench_teardown >&2' EXIT

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
            echo "Failed to mount $BENCH_FS on $BENCH_DIR. Ensure sudo is available." >&2
            echo "Fallback: using /dev/shm (no mount)." >&2
            rmdir "$BENCH_DIR" 2>/dev/null || true
            BENCH_DIR="/dev/shm/${BENCH_DIR_PREFIX}_$$"
            mkdir -p "$BENCH_DIR"
            BENCH_FILE="${BENCH_DIR}/${BENCH_FILE_BASENAME}"
        fi
        ;;
    Darwin)
        echo "macOS: using temporary directory (not a ramdisk). See Benchmarking.md for ramdisk setup." >&2
        ;;
    *)
        echo "Unknown OS: using temporary directory." >&2
        ;;
esac

ref=""
output_stem=""
output_json=""
output_md=""
threads_used=""

set_output_files() {
    # Keep JSON/MD filenames aligned by deriving them from one stem.
    local stem="$1"
    output_stem="$stem"
    output_md="$REPO_ROOT/${output_stem}.md"
    output_json="$REPO_ROOT/${output_stem}.json"
}

case "${MODE}" in
    plain)
        set_output_files "benchmark_results"

        if [ -n "$INPUT_PATH" ]; then
            input_source="provided"
            BENCH_FILE="$INPUT_PATH"
            echo "Using provided FASTQ for plain mode: $BENCH_FILE" >&2
        else
            echo "Generating ${FASTQ_SIZE_GB}GB synthetic FASTQ at $BENCH_FILE ..."
            if ! pixi run mojo run -I . "$SCRIPT_DIR/generate_synthetic_fastq.mojo" "$BENCH_FILE" "$FASTQ_SIZE_GB"; then
                echo "Failed to generate ${FASTQ_SIZE_GB}GB FASTQ at $BENCH_FILE (check space on mounted ramfs)." >&2
                exit 1
            fi
        fi

        # --- Build Rust runners (native CPU for consistent benchmarks) ---
        export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}"
        echo "Building needletail_runner ..."
        (cd "$SCRIPT_DIR/needletail_runner" && cargo build --release) || {
            echo "Failed to build needletail_runner. Check Rust toolchain and dependencies." >&2
            exit 1
        }
        echo "Building seq_io_runner ..."
        (cd "$SCRIPT_DIR/seq_io_runner" && cargo build --release) || {
            echo "Failed to build seq_io_runner. Check Rust toolchain and dependencies." >&2
            exit 1
        }

        # --- Build kseq runner ---
        CC=""
        command -v gcc >/dev/null 2>&1 && CC=gcc
        command -v clang >/dev/null 2>&1 && CC=clang
        if [ -z "$CC" ]; then
            echo "A C compiler (gcc or clang) is required for the kseq runner." >&2
            exit 1
        fi
        echo "Building kseq_runner ..."
        (cd "$SCRIPT_DIR/kseq_runner" && $CC -O3 -o kseq_runner main.c) || {
            echo "Failed to build kseq_runner. Check C toolchain." >&2
            exit 1
        }

        # --- Build BlazeSeq runner (Mojo binary) ---
        BLAZESEQ_BIN="$SCRIPT_DIR/run_blazeseq"
        echo "Building BlazeSeq runner ..."
        if ! pixi run mojo build -I . -o "$BLAZESEQ_BIN" "$SCRIPT_DIR/run_blazeseq.mojo"; then
            echo "Failed to build BlazeSeq runner. Check Mojo toolchain and blazeseq package." >&2
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
        echo "Running hyperfine (warmup=${WARMUP_RUNS}, runs=${HYPERFINE_RUNS}) ..."
        hyperfine_cmd \
            --warmup "${WARMUP_RUNS}" \
            --runs "${HYPERFINE_RUNS}" \
            --export-markdown "$output_md" \
            --export-json "$output_json" \
            -n BlazeSeq    "$BLAZESEQ_BIN $BENCH_FILE" \
            -n needletail  "$SCRIPT_DIR/needletail_runner/target/release/needletail_runner $BENCH_FILE" \
            -n seq_io      "$SCRIPT_DIR/seq_io_runner/target/release/seq_io_runner $BENCH_FILE" \
            -n kseq        "$SCRIPT_DIR/kseq_runner/kseq_runner $BENCH_FILE"

        echo "Results written to $(basename "$output_md") and $(basename "$output_json")"

        # Plot results to assets/ (best-effort)
        if command -v python >/dev/null 2>&1; then
            RECORDS="${ref%% *}"
            python "$REPO_ROOT/benchmark/scripts/plot_benchmark_results.py" \
                --repo-root "$REPO_ROOT" \
                --assets-dir "$REPO_ROOT/assets" \
                --json "$output_json" \
                --runs "${HYPERFINE_RUNS}" \
                --size-gb "$FASTQ_SIZE_GB" \
                --reads "${RECORDS:-0}" >/dev/null 2>/dev/null || true
        fi
        ;;

    gzip|gzip-single)
        if [ "${MODE}" = "gzip-single" ]; then
            set_output_files "benchmark_results_gzip_single"
            GZIP_SINGLE_THREAD=1
            GZIP_BLAZESEQ_THREADS=1
        else
            set_output_files "benchmark_results_gzip"
            GZIP_SINGLE_THREAD=0
            if [ -n "${THREADS}" ]; then
                GZIP_BLAZESEQ_THREADS="$THREADS"
            else
                GZIP_BLAZESEQ_THREADS="${GZIP_BLAZESEQ_THREADS:-4}"
            fi
        fi
        threads_used="$GZIP_BLAZESEQ_THREADS"

        CLEANUP_PLAIN_FASTQ=0
        BENCH_GZ=""
        if [ -n "$INPUT_PATH" ]; then
            if [[ "$INPUT_PATH" == *.gz ]]; then
                input_source="provided"
                BENCH_GZ="$INPUT_PATH"
                echo "Using provided gzip FASTQ for gzip mode: $BENCH_GZ" >&2
            else
                input_source="provided"
                CLEANUP_PLAIN_FASTQ=0
                echo "Compressing provided FASTQ to gzip: $INPUT_PATH -> (temp) $BENCH_DIR/*" >&2
                BENCH_GZ="${BENCH_DIR}/blazeseq_input.fastq.gz"
                if ! gzip -1 -c "$INPUT_PATH" > "${BENCH_GZ}.tmp"; then
                    rm -f "${BENCH_GZ}.tmp" 2>/dev/null || true
                    echo "gzip failed" >&2
                    exit 1
                fi
                mv "${BENCH_GZ}.tmp" "${BENCH_GZ}"
            fi
        else
            echo "Generating ${FASTQ_SIZE_GB}GB synthetic FASTQ at $BENCH_FILE ..."
            if ! pixi run mojo run -I . "$SCRIPT_DIR/generate_synthetic_fastq.mojo" "$BENCH_FILE" "$FASTQ_SIZE_GB"; then
                echo "Failed to generate ${FASTQ_SIZE_GB}GB FASTQ at $BENCH_FILE (check space on mounted ramfs)." >&2
                exit 1
            fi
            CLEANUP_PLAIN_FASTQ=1

            # --- Compress to gzip and remove plain file to free space ---
            echo "Compressing to ${BENCH_FILE}.gz ..."
            if ! gzip -1 -c "$BENCH_FILE" > "${BENCH_FILE}.gz.tmp"; then
                rm -f "${BENCH_FILE}.gz.tmp" 2>/dev/null || true
                echo "gzip failed" >&2
                exit 1
            fi
            mv "${BENCH_FILE}.gz.tmp" "${BENCH_FILE}.gz"
            if [ "$CLEANUP_PLAIN_FASTQ" = "1" ]; then
                rm -f "$BENCH_FILE"
            fi
            BENCH_GZ="${BENCH_FILE}.gz"
        fi

        # --- Build kseq gzip runner (C + zlib) ---
        KSEQ_GZIP_BIN="$SCRIPT_DIR/kseq_runner/kseq_gzip_runner"
        echo "Building kseq_gzip_runner ..."
        if ! (cd "$SCRIPT_DIR/kseq_runner" && gcc -O3 -o kseq_gzip_runner main_gzip.c -lz); then
            echo "Failed to build kseq_gzip_runner. Check gcc and zlib-dev." >&2
            exit 1
        fi

        # --- Build Rust runners (native CPU for consistent benchmarks) ---
        export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}"
        echo "Building needletail_runner ..."
        (cd "$SCRIPT_DIR/needletail_runner" && cargo build --release) || {
            echo "Failed to build needletail_runner. Check Rust toolchain and dependencies." >&2
            exit 1
        }
        echo "Building seq_io_gzip_runner ..."
        (cd "$SCRIPT_DIR/seq_io_runner" && cargo build --release) || {
            echo "Failed to build seq_io_gzip_runner. Check Rust toolchain and dependencies." >&2
            exit 1
        }

        # --- Build BlazeSeq gzip runner (Mojo binary) ---
        BLAZESEQ_GZIP_BIN="$SCRIPT_DIR/run_blazeseq_gzip"
        echo "Building BlazeSeq gzip runner ..."
        if ! pixi run mojo build -I . -o "$BLAZESEQ_GZIP_BIN" "$SCRIPT_DIR/run_blazeseq_gzip.mojo"; then
            echo "Failed to build BlazeSeq gzip runner. Check Mojo toolchain and blazeseq package." >&2
            exit 1
        fi

        # --- Verify all parsers agree on record/base count ---
        if [ "$GZIP_SINGLE_THREAD" = "1" ]; then
            _blazeseq_args="$BENCH_GZ 1"
        else
            _blazeseq_args="$BENCH_GZ $GZIP_BLAZESEQ_THREADS"
        fi

        echo "Verifying parser outputs on $BENCH_GZ ..."
        ref=""
        for cmd_label in "kseq" "seq_io" "needletail" "BlazeSeq"; do
            case "$cmd_label" in
                kseq)       out=$("$KSEQ_GZIP_BIN" "$BENCH_GZ" 2>/dev/null) || out="" ;;
                seq_io)     out=$("$SCRIPT_DIR/seq_io_runner/target/release/seq_io_gzip_runner" "$BENCH_GZ" 2>/dev/null) || out="" ;;
                needletail) out=$("$SCRIPT_DIR/needletail_runner/target/release/needletail_runner" "$BENCH_GZ" 2>/dev/null) || out="" ;;
                BlazeSeq)   out=$("$BLAZESEQ_GZIP_BIN" $_blazeseq_args 2>/dev/null) || out="" ;;
            esac
            out=$(echo "$out" | tail -1)
            if [ -z "$out" ]; then
                echo "Error: $cmd_label produced no output (runner may have failed)" >&2
                exit 1
            fi
            if [ -z "$ref" ]; then
                ref="$out"
            fi
            if [ "$out" != "$ref" ]; then
                echo "Error: $cmd_label output '$out' differs from reference '$ref'" >&2
                exit 1
            fi
        done
        echo "Reference counts: $ref"

        # --- CPU benchmark environment (Linux: governor, turbo; taskset only when single-threaded) ---
        cpu_bench_setup

        # --- Hyperfine ---
        if [ "$GZIP_SINGLE_THREAD" = "1" ]; then
            echo "Running hyperfine (single-threaded, warmup=${WARMUP_RUNS}, runs=${HYPERFINE_RUNS}) ..."
            hyperfine_cmd \
                --warmup "${WARMUP_RUNS}" \
                --runs "${HYPERFINE_RUNS}" \
                --export-markdown "$output_md" \
                --export-json "$output_json" \
                -n kseq      "$KSEQ_GZIP_BIN $BENCH_GZ" \
                -n seq_io    "$SCRIPT_DIR/seq_io_runner/target/release/seq_io_gzip_runner $BENCH_GZ" \
                -n needletail "$SCRIPT_DIR/needletail_runner/target/release/needletail_runner $BENCH_GZ" \
                -n BlazeSeq  "$BLAZESEQ_GZIP_BIN $BENCH_GZ 1"
        else
            echo "Running hyperfine (warmup=${WARMUP_RUNS}, runs=${HYPERFINE_RUNS}) ..."
            hyperfine \
                --warmup "${WARMUP_RUNS}" \
                --runs "${HYPERFINE_RUNS}" \
                --export-markdown "$output_md" \
                --export-json "$output_json" \
                -n kseq      "$KSEQ_GZIP_BIN $BENCH_GZ" \
                -n seq_io    "$SCRIPT_DIR/seq_io_runner/target/release/seq_io_gzip_runner $BENCH_GZ" \
                -n needletail "$SCRIPT_DIR/needletail_runner/target/release/needletail_runner $BENCH_GZ" \
                -n BlazeSeq  "$BLAZESEQ_GZIP_BIN $_blazeseq_args"
        fi

        echo "Results written to $(basename "$output_md") and $(basename "$output_json")"

        # Plot results to assets/ (best-effort)
        if command -v python >/dev/null 2>&1; then
            RECORDS="${ref%% *}"
            PLOT_ARGS=(
                --repo-root "$REPO_ROOT"
                --assets-dir "$REPO_ROOT/assets"
                --json "$output_json"
                --runs "${HYPERFINE_RUNS}"
                --size-gb "$FASTQ_SIZE_GB"
                --reads "${RECORDS:-0}"
                --threads "${GZIP_BLAZESEQ_THREADS}"
            )
            python "$REPO_ROOT/benchmark/scripts/plot_benchmark_results.py" "${PLOT_ARGS[@]}" >/dev/null 2>/dev/null || true
        fi
        ;;

    batch-vs-paraseq)
        set_output_files "benchmark_results_batch_vs_paraseq"

        if [ -n "$INPUT_PATH" ]; then
            input_source="provided"
            BENCH_FILE="$INPUT_PATH"
            echo "Using provided FASTQ for batch-vs-paraseq mode: $BENCH_FILE" >&2
        else
            echo "Generating ${FASTQ_SIZE_GB}GB synthetic FASTQ at $BENCH_FILE ..."
            if ! pixi run mojo run -I . "$SCRIPT_DIR/generate_synthetic_fastq.mojo" "$BENCH_FILE" "$FASTQ_SIZE_GB"; then
                echo "Failed to generate ${FASTQ_SIZE_GB}GB FASTQ at $BENCH_FILE (check space on mounted ramfs)." >&2
                exit 1
            fi
        fi

        # --- Build runners (native CPU for consistent benchmarks) ---
        export RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}"

        echo "Building BlazeSeq batch runner ..."
        BLAZESEQ_BATCH_BIN="$SCRIPT_DIR/run_blazeseq_batch"
        if ! pixi run mojo build -I . -o "$BLAZESEQ_BATCH_BIN" "$SCRIPT_DIR/run_blazeseq_batch.mojo"; then
            echo "Failed to build BlazeSeq batch runner." >&2
            exit 1
        fi

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

            # Output is one line; keep first line only.
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
        echo "Running hyperfine (warmup=${WARMUP_RUNS}, runs=${HYPERFINE_RUNS}) ..."
        hyperfine_cmd \
            --warmup "${WARMUP_RUNS}" \
            --runs "${HYPERFINE_RUNS}" \
            --export-markdown "$output_md" \
            --export-json "$output_json" \
            -n BlazeSeqBatch     "$BLAZESEQ_BATCH_BIN $BENCH_FILE $BATCH_SIZE" \
            -n paraseq            "$PARASEQ_BIN $BENCH_FILE $BATCH_SIZE" \
            -n seq_io_recordset  "$SEQ_IO_RECORDSET_BIN $BENCH_FILE $BATCH_SIZE"

        echo "Results written to $(basename "$output_md") and $(basename "$output_json")"

        # Plot results to assets/ (best-effort)
        if command -v python >/dev/null 2>&1; then
            RECORDS="${ref%% *}"
            python "$REPO_ROOT/benchmark/scripts/plot_benchmark_results.py" \
                --repo-root "$REPO_ROOT" \
                --assets-dir "$REPO_ROOT/assets" \
                --json "$output_json" \
                --runs "${HYPERFINE_RUNS}" \
                --size-gb "$FASTQ_SIZE_GB" \
                --reads "${RECORDS:-0}" >/dev/null 2>/dev/null || true
        fi
        ;;
esac

# ---- Machine-readable summary (stdout JSON only) ----
records_val="null"
base_pairs_val="null"
if [ -n "$ref" ] && [[ "$ref" == *" "* ]]; then
    records_val="${ref%% *}"
    base_pairs_val="${ref#* }"
fi

if command -v python >/dev/null 2>&1; then
    OUT_MODE="${MODE}" OUT_MD="${output_md}" OUT_JSON="${output_json}" REF="${ref:-}" \
    WARMUP="${WARMUP_RUNS}" RUNS="${HYPERFINE_RUNS}" SIZE_GB="${FASTQ_SIZE_GB}" \
    BENCH_FS="${BENCH_FS}" THREADS_USED="${threads_used}" RECORDS="${records_val}" BASE_PAIRS="${base_pairs_val}" \
    INPUT_SOURCE="${input_source}" INPUT_PATH="${INPUT_PATH:-}" \
    python - <<'PY' >&3
import json, os
mode = os.environ["OUT_MODE"]
output_md = os.environ["OUT_MD"]
output_json = os.environ["OUT_JSON"]
ref = os.environ.get("REF", "")
warmup_runs = int(os.environ["WARMUP"])
runs = int(os.environ["RUNS"])
size_gb = float(os.environ["SIZE_GB"])
bench_fs = os.environ["BENCH_FS"]
threads_used = os.environ.get("THREADS_USED", "") or None
input_source = os.environ.get("INPUT_SOURCE", "")
input_path = os.environ.get("INPUT_PATH", "") or None

records_raw = os.environ.get("RECORDS", "null")
base_pairs_raw = os.environ.get("BASE_PAIRS", "null")

def parse_num(x):
    if x == "null" or x is None or x == "":
        return None
    try:
        return int(x)
    except ValueError:
        return None

records = parse_num(records_raw)
base_pairs = parse_num(base_pairs_raw)

hyperfine_results = None
try:
    with open(output_json, "r", encoding="utf-8") as f:
        data = json.load(f)
    hyperfine_results = data.get("results")
except Exception:
    hyperfine_results = None

summary = {
    "mode": mode,
    "bench_fs": bench_fs,
    "fastq_size_gb": size_gb,
    "warmup_runs": warmup_runs,
    "runs": runs,
    "threads_used": threads_used,
    "input_source": input_source,
    "input_path": input_path,
    "counts": {
        "records": records,
        "base_pairs": base_pairs,
        "raw_ref": ref if ref else None,
    },
    "output_md": output_md,
    "output_json": output_json,
    "hyperfine_results": hyperfine_results,
}

print(json.dumps(summary))
PY
else
    # Minimal JSON summary without hyperfine_results payload.
    raw_ref_json="null"
    if [ -n "${ref}" ]; then
        # Assumes ref has no embedded quotes (runner output is numeric "records base_pairs").
        raw_ref_json="\"${ref}\""
    fi
    python_missing_stub="{\"mode\":\"${MODE}\",\"bench_fs\":\"${BENCH_FS}\",\"fastq_size_gb\":${FASTQ_SIZE_GB},\"warmup_runs\":${WARMUP_RUNS},\"runs\":${HYPERFINE_RUNS},\"threads_used\":\"${threads_used}\",\"counts\":{\"records\":${records_val},\"base_pairs\":${base_pairs_val},\"raw_ref\":${raw_ref_json}},\"output_md\":\"${output_md}\",\"output_json\":\"${output_json}\"}"
    echo "$python_missing_stub" >&3
fi
