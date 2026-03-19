from typing import Literal
import subprocess
import threading
import json
from pathlib import Path
from os import environ

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


PROJ_PATH = Path("/home/mohamed/Documents/Projects/BlazeSeq")


def run_benchmarks(
    mode: Literal["plain", "gzip", "gzip-single", "batch-vs-paraseq"],
    fs: Literal["tmpfs", "ramfs"],
    fastq_size: float,
    runs: int,
    warmup: int,
    threads: int,
    batchsize: int,
    disable_hyperthreading: bool,
    input_file: Path | None = None,
):
    # --- Environment setup ---
    environ["FASTQ_SIZE_GB"] = str(fastq_size)
    environ["HYPERFINE_RUNS"] = str(runs)
    environ["WARMUP_RUNS"] = str(warmup)
    environ["GZIP_BLAZESEQ_THREADS"] = str(threads)
    if disable_hyperthreading:
        environ["DISABLE_HYPERTHREADING"] = "1"
    else:
        environ["DISABLE_HYPERTHREADING"] = "0"

    # --- Command construction ---
    cmd = [
        str(PROJ_PATH / "benchmark/fastq-parser/run_benchmarks.sh"),
        "--mode",
        mode,
        f"--{fs}",
        "--batch-size",
        str(batchsize),
    ]

    if input_file:
        cmd.extend(["--input", str(input_file)])

    # --- Spawn process ---
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,  # JSON only
        stderr=subprocess.PIPE,  # logs only
        text=True,
        bufsize=1,
    )

    stdout_buffer = []
    stderr_done = threading.Event()

    # --- Thread: capture stdout (JSON) ---
    def read_stdout():
        try:
            data = process.stdout.read()
            if data:
                stdout_buffer.append(data)
        finally:
            process.stdout.close()

    # --- Thread: stream stderr (logs) ---
    def stream_stderr():
        try:
            for line in iter(process.stderr.readline, ""):
                print(line, end="", flush=True)  # real-time log output
        finally:
            process.stderr.close()
            stderr_done.set()

    t_out = threading.Thread(target=read_stdout, daemon=True)
    t_err = threading.Thread(target=stream_stderr, daemon=True)

    t_out.start()
    t_err.start()

    # --- Wait for process completion ---
    process.wait()

    # Ensure all output is consumed
    t_out.join()
    t_err.join()

    if process.returncode != 0:
        raise subprocess.CalledProcessError(process.returncode, cmd)

    # --- Parse JSON safely ---
    full_stdout = "".join(stdout_buffer).strip()

    if not full_stdout:
        raise RuntimeError("No JSON output received from benchmark script")

    try:
        result = json.loads(full_stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Failed to parse JSON output:\n{full_stdout}") from e

    return result


def run_plain_benchmarks():
    print("Running plain benchmarks...")
    SYNTH_PLAIN_DICT = {
        "mode": "plain",
        "fs": "tmpfs",
        "fastq_size": 0,
        "runs": 5,
        "warmup": 2,
        "threads": 1,
        "batchsize": 4096,
        "disable_hyperthreading": False,
        "input_file": None,
    }
    # [0.01, 0.1, 0.5, 1, 3, 5, 10]
    FASTQ_SIZES_GB = [0.01, 0.1, 0.5, 1, 3, 5, 10]
    RESULTS_PLAIN: dict[int, dict[str, str]] = {}
    for size in FASTQ_SIZES_GB:
        SYNTH_PLAIN_DICT["fastq_size"] = size
        result = run_benchmarks(**SYNTH_PLAIN_DICT)
        RESULTS_PLAIN[size] = result

    with open(
        PROJ_PATH / "benchmark/bench_results/benchmark_results_plain_1_thread.json",
        "w",
    ) as f:
        json.dump(RESULTS_PLAIN, f)


if __name__ == "__main__":
    run_plain_benchmarks()
