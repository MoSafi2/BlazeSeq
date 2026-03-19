from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import tempfile
from pathlib import Path
from typing import Literal

Format = Literal["plain", "gz"]
Workload = Literal["parser", "batch_vs_paraseq"]

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKER_SCRIPT = REPO_ROOT / "benchmark/fastq-parser/run_benchmarks.sh"
PLOT_SCRIPT = REPO_ROOT / "benchmark/scripts/plot_benchmark_results.py"


def infer_format_from_input_path(input_path: Path) -> Format:
    p = str(input_path).lower()
    if p.endswith(".gz"):
        return "gz"
    if p.endswith(".fastq") or p.endswith(".fq"):
        return "plain"
    raise ValueError(
        f"Unrecognized FASTQ extension for '{input_path}'. "
        "Expected .fastq/.fq (plain) or .fastq.gz/.fq.gz/.gz (gzipped)."
    )


def resolve_effective_format(
    *,
    workload: Workload,
    input_path: Path | None,
    format_requested: Literal["auto", "plain", "gz"],
) -> Format:
    if workload == "batch_vs_paraseq":
        if input_path is not None and infer_format_from_input_path(input_path) != "plain":
            raise ValueError("batch_vs_paraseq does not support gz inputs.")
        return "plain"

    if input_path is not None:
        # Extension dispatch always wins (requested format is overridden).
        return infer_format_from_input_path(input_path)

    # Synthetic generation.
    if format_requested == "auto":
        return "plain"
    if format_requested in ("plain", "gz"):
        return format_requested
    raise ValueError(f"Invalid format_requested='{format_requested}'")


def _run_worker_env(env: dict[str, str]) -> dict:
    cmd = [str(WORKER_SCRIPT)]
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,  # JSON only
        stderr=subprocess.PIPE,  # logs only
        text=True,
        bufsize=1,
        env=env,
    )

    stdout_buffer: list[str] = []

    def read_stdout() -> None:
        try:
            data = process.stdout.read() if process.stdout is not None else ""
            if data:
                stdout_buffer.append(data)
        finally:
            if process.stdout is not None:
                process.stdout.close()

    def stream_stderr() -> None:
        try:
            if process.stderr is None:
                return
            for line in iter(process.stderr.readline, ""):
                print(line, end="", file=sys.stderr, flush=True)
        finally:
            if process.stderr is not None:
                process.stderr.close()

    t_out = threading.Thread(target=read_stdout, daemon=True)
    t_err = threading.Thread(target=stream_stderr, daemon=True)
    t_out.start()
    t_err.start()

    process.wait()
    t_out.join()
    t_err.join()

    if process.returncode != 0:
        raise subprocess.CalledProcessError(process.returncode, cmd)

    full_stdout = "".join(stdout_buffer).strip()
    if not full_stdout:
        raise RuntimeError("No JSON output received from benchmark worker")

    try:
        return json.loads(full_stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Failed to parse worker JSON output:\n{full_stdout}") from e


def validate_result(
    result: dict,
    *,
    expected_workload: Workload,
    expected_format: Format,
    expected_gzip_threads: int,
) -> None:
    for k in ("workload", "format", "counts", "hyperfine_json"):
        if k not in result:
            raise RuntimeError(f"Worker JSON missing key '{k}'. Got keys: {sorted(result.keys())}")

    if result["workload"] != expected_workload:
        raise RuntimeError(
            f"Worker JSON workload mismatch: expected {expected_workload}, got {result['workload']}"
        )
    if result["format"] != expected_format:
        raise RuntimeError(f"Worker JSON format mismatch: expected {expected_format}, got {result['format']}")

    counts = result["counts"]
    if not isinstance(counts, dict) or "records" not in counts or "base_pairs" not in counts:
        raise RuntimeError("Worker JSON counts must include 'records' and 'base_pairs'")

    if expected_format == "gz":
        gz_threads = result.get("gzip_threads", None)
        if gz_threads is None:
            raise RuntimeError("Worker JSON missing gzip_threads for gz benchmark")
        if int(gz_threads) != int(expected_gzip_threads):
            raise RuntimeError(f"gzip_threads mismatch: expected {expected_gzip_threads}, got {gz_threads}")
    else:
        if result.get("gzip_threads", None) is not None:
            raise RuntimeError("Expected gzip_threads to be null/None for plain benchmark")


def expected_artifact_stem(
    *,
    workload: Workload,
    effective_format: Format,
    gzip_threads: int,
) -> str:
    if workload == "batch_vs_paraseq":
        return "benchmark_results_batch_vs_paraseq"
    if effective_format == "plain":
        return "benchmark_results"
    # effective_format == "gz"
    return "benchmark_results_gzip_single" if int(gzip_threads) == 1 else "benchmark_results_gzip"


def run_benchmark_once(
    *,
    workload: Workload,
    input_path: Path | None,
    format_requested: Literal["auto", "plain", "gz"],
    fs: Literal["tmpfs", "ramfs"],
    gzip_threads: int,
    fastq_size_gb: float,
    runs: int,
    warmup_runs: int,
    batch_size: int,
    disable_hyperthreading: bool,
    plot: bool,
    write_artifacts: bool,
) -> dict:
    effective_format = resolve_effective_format(
        workload=workload,
        input_path=input_path,
        format_requested=format_requested,
    )

    if workload == "batch_vs_paraseq":
        worker_mode: Literal["plain", "gzip", "batch-vs-paraseq"] = "batch-vs-paraseq"
    elif effective_format == "plain":
        worker_mode = "plain"
    else:
        worker_mode = "gzip"

    env = dict(os.environ)
    env.update(
        {
            "BENCH_WORKLOAD": workload,
            "BENCH_FORMAT": effective_format,
            "BENCH_WORKER_MODE": worker_mode,
            "BENCH_FS": fs,
            "BENCH_FASTQ_SIZE_GB": str(fastq_size_gb),
            "BENCH_WARMUP_RUNS": str(warmup_runs),
            "BENCH_HYPERFINE_RUNS": str(runs),
            "BENCH_GZIP_THREADS": str(gzip_threads),
            "BENCH_BATCH_SIZE": str(batch_size),
            "DISABLE_HYPERTHREADING": "1" if disable_hyperthreading else "0",
        }
    )

    if input_path is not None:
        env["BENCH_INPUT_PATH"] = str(input_path)
    else:
        env.pop("BENCH_INPUT_PATH", None)

    result = _run_worker_env(env)
    validate_result(
        result,
        expected_workload=workload,
        expected_format=effective_format,
        expected_gzip_threads=gzip_threads,
    )

    if plot:
        counts = result.get("counts", {}) or {}
        records = counts.get("records", None)
        threads = gzip_threads if effective_format == "gz" else None

        stem = expected_artifact_stem(
            workload=workload, effective_format=effective_format, gzip_threads=gzip_threads
        )

        hyperfine_json = result["hyperfine_json"]
        with tempfile.TemporaryDirectory(prefix="fastq_parser_plot_") as td:
            tmp_json_path = Path(td) / f"{stem}.json"
            tmp_json_path.write_text(json.dumps(hyperfine_json), encoding="utf-8")

            cmd: list[str] = [
                sys.executable,
                str(PLOT_SCRIPT),
                "--repo-root",
                str(REPO_ROOT),
                "--assets-dir",
                str(REPO_ROOT / "assets"),
                "--json",
                str(tmp_json_path),
                "--runs",
                str(runs),
                "--size-gb",
                str(fastq_size_gb),
            ]
            if records is not None:
                cmd += ["--reads", str(records)]
            if threads is not None:
                cmd += ["--threads", str(threads)]

            try:
                p = subprocess.run(
                    cmd,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                if p.returncode != 0:
                    print(
                        f"Warning: plotting failed (exit {p.returncode}). stderr: {p.stderr.strip()}",
                        file=sys.stderr,
                    )
            except Exception as e:
                print(f"Warning: plotting exception: {e}", file=sys.stderr)

    if write_artifacts:
        stem = expected_artifact_stem(
            workload=workload, effective_format=effective_format, gzip_threads=gzip_threads
        )
        out_path = REPO_ROOT / f"{stem}.json"
        out_path.write_text(json.dumps(result["hyperfine_json"]), encoding="utf-8")
    return result


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Dispatcher/validator for FASTQ parser benchmarks.")
    sub = p.add_subparsers(dest="cmd", required=True)

    run_p = sub.add_parser("run", help="Run a single benchmark.")
    run_p.add_argument("--workload", choices=["parser", "batch_vs_paraseq"], default="parser")
    run_p.add_argument("--input", type=Path, default=None, help="Optional FASTQ path.")
    run_p.add_argument("--format", choices=["auto", "plain", "gz"], default="auto", help="Synthetic format.")
    run_p.add_argument("--fs", choices=["tmpfs", "ramfs"], default="ramfs")
    run_p.add_argument("--gzip-threads", type=int, default=4, help="Only used for gz benchmarks.")
    run_p.add_argument("--fastq-size-gb", type=float, default=3.0)
    run_p.add_argument("--warmup-runs", type=int, default=3)
    run_p.add_argument("--runs", type=int, default=15)
    run_p.add_argument("--batch-size", type=int, default=4096)
    run_p.add_argument("--disable-hyperthreading", action="store_true")
    run_p.add_argument("--plot", action="store_true", help="Generate plots (best-effort) after successful run.")
    run_p.add_argument(
        "--write-artifacts",
        action="store_true",
        help="Write stable benchmark JSON artifacts (<stem>.json) to repo root.",
    )

    return p


def main() -> int:
    args = build_arg_parser().parse_args()
    if args.cmd == "run":
        result = run_benchmark_once(
            workload=args.workload,  # type: ignore[arg-type]
            input_path=args.input,
            format_requested=args.format,  # type: ignore[arg-type]
            fs=args.fs,  # type: ignore[arg-type]
            gzip_threads=args.gzip_threads,
            fastq_size_gb=args.fastq_size_gb,
            runs=args.runs,
            warmup_runs=args.warmup_runs,
            batch_size=args.batch_size,
            disable_hyperthreading=bool(args.disable_hyperthreading),
            plot=bool(args.plot),
            write_artifacts=bool(args.write_artifacts),
        )
        print(json.dumps(result))
        return 0

    raise RuntimeError(f"Unknown command: {args.cmd}")


if __name__ == "__main__":
    raise SystemExit(main())
