#!/usr/bin/env bash
# Consolidated FASTQ-parser benchmark launcher.
#
# Env-driven worker (no CLI args).
#
# Dispatch is performed by `benchmark/fastq-parser/bench.py`, which sets:
#   BENCH_WORKLOAD        (parser | batch_vs_paraseq)
#   BENCH_FORMAT          (plain | gz)   [batch_vs_paraseq requires plain]
#   BENCH_WORKER_MODE     (plain | gzip | batch-vs-paraseq)
#   BENCH_GZIP_THREADS    (gzip parallelism; threads==1 selects single-thread gzip)
#   BENCH_FS              (tmpfs | ramfs)
#   BENCH_INPUT_PATH     (optional; existing FASTQ file path)
#   BENCH_FASTQ_SIZE_GB  (default: 3; used when BENCH_INPUT_PATH is empty)
#   BENCH_WARMUP_RUNS     (default: 3)
#   BENCH_HYPERFINE_RUNS   (default: 15)
#   BENCH_BATCH_SIZE     (default: 4096; used for batch_vs_paraseq)
#   DISABLE_HYPERTHREADING (best-effort; disables SMT when available, requires sudo)
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
#   parser/plain:                 benchmark_results.md + benchmark_results.json
#   parser/gz + threads==1:      benchmark_results_gzip_single.md + benchmark_results_gzip_single.json
#   parser/gz + threads!=1:      benchmark_results_gzip.md + benchmark_results_gzip.json
#   batch_vs_paraseq:            benchmark_results_batch_vs_paraseq.md + benchmark_results_batch_vs_paraseq.json

set -euo pipefail

# Route all stdout to stderr; write the final JSON summary to the original stdout FD (3).
exec 3>&1
exec 1>&2

if [ "$#" -gt 0 ]; then
    echo "run_benchmarks.sh is env-driven only; unexpected args: $*" >&2
    exit 2
fi

input_source="synthetic"

BENCH_WORKLOAD="${BENCH_WORKLOAD:?BENCH_WORKLOAD must be set to 'parser' or 'batch_vs_paraseq'}"
BENCH_FORMAT="${BENCH_FORMAT:-plain}" # parser only; batch_vs_paraseq requires 'plain'
BENCH_FS="${BENCH_FS:-tmpfs}"

BENCH_INPUT_PATH="${BENCH_INPUT_PATH:-}"
BENCH_GZIP_THREADS="${BENCH_GZIP_THREADS:-4}"

BATCH_SIZE="${BENCH_BATCH_SIZE:-4096}"

INPUT_PATH="${BENCH_INPUT_PATH}"

# bench.py should set BENCH_WORKER_MODE; for compatibility we keep a small fallback mapping
# when running with raw env vars.
BENCH_WORKER_MODE="${BENCH_WORKER_MODE:-}"
if [ -z "${BENCH_WORKER_MODE}" ]; then
    case "${BENCH_WORKLOAD}" in
        parser)
            case "${BENCH_FORMAT}" in
                plain) BENCH_WORKER_MODE="plain" ;;
                gz) BENCH_WORKER_MODE="gzip" ;;
                *)
                    echo "Invalid BENCH_FORMAT='${BENCH_FORMAT}' (expected 'plain' or 'gz')" >&2
                    exit 2
                    ;;
            esac
            ;;
        batch_vs_paraseq)
            if [ "${BENCH_FORMAT}" != "plain" ]; then
                echo "batch_vs_paraseq requires BENCH_FORMAT=plain (got '${BENCH_FORMAT}')" >&2
                exit 2
            fi
            BENCH_WORKER_MODE="batch-vs-paraseq"
            ;;
        *)
            echo "Invalid BENCH_WORKLOAD='${BENCH_WORKLOAD}' (expected 'parser' or 'batch_vs_paraseq')" >&2
            exit 2
            ;;
    esac
fi

case "${BENCH_WORKER_MODE}" in
    plain|gzip|batch-vs-paraseq) ;;
    *)
        echo "Invalid BENCH_WORKER_MODE='${BENCH_WORKER_MODE}' (expected 'plain' | 'gzip' | 'batch-vs-paraseq')" >&2
        exit 2
        ;;
esac

FASTQ_IS_GZ=0
if [ -n "${INPUT_PATH}" ] && [[ "${INPUT_PATH}" == *.gz ]]; then
    FASTQ_IS_GZ=1
fi

# Fail fast on clearly wrong combinations to avoid long runner builds.
if [ "${FASTQ_IS_GZ}" = "1" ] && [ "${BENCH_WORKER_MODE}" = "plain" ]; then
    echo "Input looks gzipped (*.gz) but worker is BENCH_FORMAT=plain. Use BENCH_FORMAT=gz (bench.py dispatches this automatically)." >&2
    exit 2
fi
if [ "${FASTQ_IS_GZ}" = "1" ] && [ "${BENCH_WORKER_MODE}" = "batch-vs-paraseq" ]; then
    echo "batch_vs_paraseq does not support gz inputs. Provide a plain FASTQ (bench.py validates this)." >&2
    exit 2
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
check_cmd python   || missing+=(python)

case "${BENCH_WORKER_MODE}" in
    plain)
        if ! check_cmd gcc && ! check_cmd clang; then
            missing+=(gcc or clang)
        fi
        ;;
    gzip)
        check_cmd gcc   || missing+=(gcc)
        check_cmd gzip  || missing+=(gzip)
        ;;
    batch-vs-paraseq)
        # No C compiler required (all runners are Rust/Mojo).
        ;;
    *)
        echo "Unknown BENCH_WORKER_MODE: ${BENCH_WORKER_MODE}" >&2
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
WARMUP_RUNS="${BENCH_WARMUP_RUNS:-3}"
HYPERFINE_RUNS="${BENCH_HYPERFINE_RUNS:-15}"

# --- FASTQ size (GB) ---
FASTQ_SIZE_GB="${BENCH_FASTQ_SIZE_GB:-3}"

# Use stable temp names for easier debugging when sudo/mount isn't available.
BENCH_FILE_BASENAME="blazeseq_bench_${FASTQ_SIZE_GB}g.fastq"
BENCH_DIR_PREFIX="blazeseq_bench"
case "${BENCH_WORKER_MODE}" in
    batch-vs-paraseq)
        BENCH_FILE_BASENAME="blazeseq_batch_vs_paraseq_${FASTQ_SIZE_GB}g.fastq"
        BENCH_DIR_PREFIX="blazeseq_batch_vs_paraseq"
        ;;
    gzip)
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
trap 'cleanup_mount; rm -f "${hyperfine_json_path:-}" 2>/dev/null || true; cpu_bench_teardown >&2' EXIT

case "$(uname -s)" in
    Linux)
        if [ "$BENCH_FS" = "tmpfs" ]; then
            # tmpfs requires an explicit size. We derive it from the requested FASTQ size,
            # then add a small overhead and enforce a minimum to account for buffers/headers.
            TMPFS_MIN_SIZE_GB="${TMPFS_MIN_SIZE_GB:-5}"
            TMPFS_OVERHEAD_GB="${TMPFS_OVERHEAD_GB:-1}"
            TMPFS_SIZE_GB="$(awk "BEGIN {x=${FASTQ_SIZE_GB}+${TMPFS_OVERHEAD_GB}; if (x<${TMPFS_MIN_SIZE_GB}) x=${TMPFS_MIN_SIZE_GB}; printf \"%d\", int(x+0.999999)}")"
            _mount_cmd="sudo mount -t tmpfs -o size=${TMPFS_SIZE_GB}G tmpfs $BENCH_DIR"
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
hyperfine_json_path=""
threads_used=""

case "${BENCH_WORKER_MODE}" in
    plain)
        hyperfine_json_path="$(mktemp -t hyperfine_fastq_parser_plain_XXXX.json)"

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
            --export-json "$hyperfine_json_path" \
            -n BlazeSeq    "$BLAZESEQ_BIN $BENCH_FILE" \
            -n needletail  "$SCRIPT_DIR/needletail_runner/target/release/needletail_runner $BENCH_FILE" \
            -n seq_io      "$SCRIPT_DIR/seq_io_runner/target/release/seq_io_runner $BENCH_FILE" \
            -n kseq        "$SCRIPT_DIR/kseq_runner/kseq_runner $BENCH_FILE"

        echo "Worker produced hyperfine JSON at ${hyperfine_json_path}"
        ;;

    gzip)
        hyperfine_json_path="$(mktemp -t hyperfine_fastq_parser_gzip_XXXX.json)"
        if [ "${BENCH_GZIP_THREADS}" = "1" ]; then
            GZIP_SINGLE_THREAD=1
            GZIP_BLAZESEQ_THREADS=1
        else
            GZIP_SINGLE_THREAD=0
            GZIP_BLAZESEQ_THREADS="${BENCH_GZIP_THREADS:-4}"
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
                --export-json "$hyperfine_json_path" \
                -n kseq      "$KSEQ_GZIP_BIN $BENCH_GZ" \
                -n seq_io    "$SCRIPT_DIR/seq_io_runner/target/release/seq_io_gzip_runner $BENCH_GZ" \
                -n needletail "$SCRIPT_DIR/needletail_runner/target/release/needletail_runner $BENCH_GZ" \
                -n BlazeSeq  "$BLAZESEQ_GZIP_BIN $BENCH_GZ 1"
        else
            echo "Running hyperfine (warmup=${WARMUP_RUNS}, runs=${HYPERFINE_RUNS}) ..."
            hyperfine \
                --warmup "${WARMUP_RUNS}" \
                --runs "${HYPERFINE_RUNS}" \
                --export-json "$hyperfine_json_path" \
                -n kseq      "$KSEQ_GZIP_BIN $BENCH_GZ" \
                -n seq_io    "$SCRIPT_DIR/seq_io_runner/target/release/seq_io_gzip_runner $BENCH_GZ" \
                -n needletail "$SCRIPT_DIR/needletail_runner/target/release/needletail_runner $BENCH_GZ" \
                -n BlazeSeq  "$BLAZESEQ_GZIP_BIN $_blazeseq_args"
        fi

        echo "Worker produced hyperfine JSON at ${hyperfine_json_path}"
        ;;

    batch-vs-paraseq)
        hyperfine_json_path="$(mktemp -t hyperfine_fastq_parser_batch_XXXX.json)"

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
            --export-json "$hyperfine_json_path" \
            -n BlazeSeqBatch     "$BLAZESEQ_BATCH_BIN $BENCH_FILE $BATCH_SIZE" \
            -n paraseq            "$PARASEQ_BIN $BENCH_FILE $BATCH_SIZE" \
            -n seq_io_recordset  "$SEQ_IO_RECORDSET_BIN $BENCH_FILE $BATCH_SIZE"

        echo "Worker produced hyperfine JSON at ${hyperfine_json_path}"
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
    OUT_WORKLOAD="${BENCH_WORKLOAD}" OUT_FORMAT="${BENCH_FORMAT}" HYPERFINE_JSON_PATH="${hyperfine_json_path}" REF="${ref:-}" \
    WARMUP="${WARMUP_RUNS}" RUNS="${HYPERFINE_RUNS}" SIZE_GB="${FASTQ_SIZE_GB}" \
    BENCH_FS="${BENCH_FS}" GZIP_THREADS="${threads_used}" RECORDS="${records_val}" BASE_PAIRS="${base_pairs_val}" \
    INPUT_SOURCE="${input_source}" INPUT_PATH="${INPUT_PATH:-}" \
    python - <<'PY' >&3
import json, os
workload = os.environ["OUT_WORKLOAD"]
fmt = os.environ["OUT_FORMAT"]
hyperfine_json_path = os.environ["HYPERFINE_JSON_PATH"]
ref = os.environ.get("REF", "")
warmup_runs = int(os.environ["WARMUP"])
runs = int(os.environ["RUNS"])
size_gb = float(os.environ["SIZE_GB"])
bench_fs = os.environ["BENCH_FS"]
gzip_threads_raw = os.environ.get("GZIP_THREADS", "") or ""
gzip_threads = int(gzip_threads_raw) if gzip_threads_raw.strip() else None
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

hyperfine_json = None
hyperfine_results = None
with open(hyperfine_json_path, "r", encoding="utf-8") as f:
    hyperfine_json = json.load(f)
hyperfine_results = hyperfine_json.get("results") if isinstance(hyperfine_json, dict) else None

summary = {
    "workload": workload,
    "format": fmt,
    "bench_fs": bench_fs,
    "fastq_size_gb": size_gb,
    "warmup_runs": warmup_runs,
    "runs": runs,
    "gzip_threads": gzip_threads,
    "input_source": input_source,
    "input_path": input_path,
    "counts": {
        "records": records,
        "base_pairs": base_pairs,
        "raw_ref": ref if ref else None,
    },
    "hyperfine_json": hyperfine_json,
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
    python_missing_stub=\"{\\\"workload\\\":\\\"${BENCH_WORKLOAD}\\\",\\\"format\\\":\\\"${BENCH_FORMAT}\\\",\\\"bench_fs\\\":\\\"${BENCH_FS}\\\",\\\"fastq_size_gb\\\":${FASTQ_SIZE_GB},\\\"warmup_runs\\\":${WARMUP_RUNS},\\\"runs\\\":${HYPERFINE_RUNS},\\\"gzip_threads\\\":${threads_used:-null},\\\"counts\\\":{\\\"records\\\":${records_val},\\\"base_pairs\\\":${base_pairs_val},\\\"raw_ref\\\":${raw_ref_json}},\\\"hyperfine_json\\\":null,\\\"hyperfine_results\\\":null}\"
    echo "$python_missing_stub" >&3
fi
