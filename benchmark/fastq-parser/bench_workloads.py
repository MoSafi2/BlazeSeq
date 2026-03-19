from __future__ import annotations

import json
from pathlib import Path

from bench import run_benchmark_once


REPO_ROOT = Path(__file__).resolve().parents[2]


def _write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj), encoding="utf-8")


def run_plain_benchmarks() -> dict[float, dict]:
    print("Running plain benchmarks...")
    fastq_sizes_gb = [0.01, 0.1, 0.5, 1, 3, 5, 10]
    results: dict[float, dict] = {}
    for size in fastq_sizes_gb:
        results[size] = run_benchmark_once(
            workload="parser",
            input_path=None,
            format_requested="plain",
            fs="tmpfs",
            gzip_threads=1,
            fastq_size_gb=size,
            runs=5,
            warmup_runs=2,
            batch_size=4096,
            disable_hyperthreading=False,
            plot=False,
            write_artifacts=False,
        )

    _write_json(REPO_ROOT / "benchmark/bench_results/benchmark_results_plain_1_thread.json", results)
    return results


def run_gzip_benchmarks() -> dict[float, dict]:
    print("Running gzip benchmarks...")
    fastq_sizes_gb = [0.01, 0.1, 0.5, 1, 3, 5, 10]
    results: dict[float, dict] = {}
    for size in fastq_sizes_gb:
        results[size] = run_benchmark_once(
            workload="parser",
            input_path=None,
            format_requested="gz",
            fs="tmpfs",
            gzip_threads=4,
            fastq_size_gb=size,
            runs=5,
            warmup_runs=2,
            batch_size=4096,
            disable_hyperthreading=False,
            plot=False,
            write_artifacts=False,
        )

    _write_json(REPO_ROOT / "benchmark/bench_results/benchmark_results_gzipped_4_threads.json", results)
    return results


def run_gzip_thread_scaling_benchmarks() -> dict[int, dict]:
    print("Running gzip thread scaling benchmarks...")
    results: dict[int, dict] = {}
    for threads in [1, 2, 4, 8, 16]:
        results[threads] = run_benchmark_once(
            workload="parser",
            input_path=None,
            format_requested="gz",
            fs="tmpfs",
            gzip_threads=threads,
            fastq_size_gb=0.0,
            runs=5,
            warmup_runs=2,
            batch_size=4096,
            disable_hyperthreading=False,
            plot=False,
            write_artifacts=False,
        )

    _write_json(
        REPO_ROOT / "benchmark/bench_results/benchmark_results_gzipped_thread_scaling.json",
        results,
    )
    return results


def run_real_dataset_benchmarks(file_path: Path) -> dict:
    print("Running real dataset benchmarks...")
    return run_benchmark_once(
        workload="parser",
        input_path=file_path,
        format_requested="auto",
        fs="tmpfs",
        gzip_threads=1,
        fastq_size_gb=0.0,
        runs=5,
        warmup_runs=2,
        batch_size=4096,
        disable_hyperthreading=False,
        plot=False,
        write_artifacts=False,
    )


if __name__ == "__main__":
    # Kept for convenience during local experiments.
    run_plain_benchmarks()

