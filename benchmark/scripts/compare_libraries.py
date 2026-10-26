"""Reproduce CPU parser comparisons using the repository's C/Rust/Mojo runners."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[2]
GIB = 1024**3
RUST_RUNNERS = [
    "fastq-parser/needletail_runner",
    "fastq-parser/seq_io_runner",
    "fastq-parser/paraseq_runner",
    "fastq-parser/seq_io_recordset_runner",
    "fasta-parser/needletail_runner",
    "fasta-parser/noodles_runner",
]
MOJO_RUNNERS = {
    "plain": "fastq-parser/run_blazeseq.mojo",
    "gzip": "fastq-parser/run_blazeseq_gzip.mojo",
    "batch": "fastq-parser/run_blazeseq_batch.mojo",
    "fasta": "fasta-parser/run_blazeseq_fasta.mojo",
    "generate-fastq": "fastq-parser/generate_synthetic_fastq.mojo",
    "generate-fasta": "fasta-parser/generate_synthetic_fasta.mojo",
}


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def run(command, *, cwd=ROOT, env=None):
    print(shlex.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=cwd, env=env, check=True)


def plot_results(groups, path: Path, *, warmups: int, runs: int, cpu: int):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np

    figure, axes = plt.subplots(2, 2, figsize=(15, 10), layout="constrained")
    for axis, (name, group) in zip(axes.flat, groups.items()):
        rows = sorted(group["results"], key=lambda row: row["median"])
        labels = [row["command"] for row in rows]
        medians = np.array([row["median"] for row in rows])
        # Interquartile ranges describe samples; they are not confidence intervals.
        lower = np.array([np.quantile(row["times"], 0.25) for row in rows])
        upper = np.array([np.quantile(row["times"], 0.75) for row in rows])
        colors = [
            "#2463a6" if label.startswith("BlazeSeq") else "#858b92" for label in labels
        ]
        axis.barh(labels, medians, color=colors)
        axis.errorbar(
            medians,
            range(len(rows)),
            xerr=[medians - lower, upper - medians],
            fmt="none",
            ecolor="#333333",
            capsize=3,
        )
        axis.invert_yaxis()
        axis.set_title(
            f"{group['title']}\n{group['uncompressed_input_bytes']/GIB:.2f} GiB uncompressed input"
        )
        axis.set_xlabel("Median wall time (seconds; lower is faster)")
        axis.set_ylabel("Parser / iteration mode")
        axis.spines[["top", "right"]].set_visible(False)
        axis.grid(axis="x", alpha=0.2)
        axis.set_axisbelow(True)
    figure.suptitle("BlazeSeq · Mojo 1.2.0 / MAX 26.7.0 vs C and Rust", fontsize=16)
    figure.supxlabel(
        f"Local Linux CPU {cpu} · {warmups} warmups, {runs} samples · error bars: IQR · blue: BlazeSeq, gray: competitors",
        fontsize=10,
    )
    figure.savefig(path, dpi=160)
    plt.close(figure)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ROOT / "benchmark/results/mojo_1_2_comparison",
    )
    parser.add_argument("--fastq-size-gib", type=float, default=3)
    parser.add_argument("--fasta-size-gib", type=int, default=1)
    parser.add_argument("--warmups", type=int, default=3)
    parser.add_argument("--runs", type=int, default=15)
    parser.add_argument("--cpu", type=int, default=2)
    args = parser.parse_args()
    if (
        args.fastq_size_gib <= 0
        or args.fasta_size_gib <= 0
        or args.runs < 2
        or args.warmups < 0
    ):
        parser.error(
            "Input sizes and runs must be positive; at least two measured runs are required"
        )
    if args.cpu not in os.sched_getaffinity(0):
        parser.error("Requested CPU is outside the process's allowed affinity")
    work = args.work_dir or Path(tempfile.mkdtemp(prefix="blazeseq-libraries-"))
    work = work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    binaries = work / "bin"
    binaries.mkdir(exist_ok=True)
    native_cc = shutil.which("gcc", path="/usr/bin:/bin")
    if native_cc is None:
        raise RuntimeError(
            "A host GCC installation is required for the native C/Rust comparison"
        )
    env = dict(
        os.environ,
        RUSTFLAGS=f"-C target-cpu=native -C linker={native_cc}",
        CARGO_TARGET_DIR=str(work / "rust-target"),
        CC=native_cc,
    )
    # Conda's compiler activation can otherwise mix its old CRT with host libraries.
    for key in ["CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS"]:
        env.pop(key, None)
    for relative in RUST_RUNNERS:
        run(
            ["cargo", "build", "--locked", "--release"],
            cwd=ROOT / "benchmark" / relative,
            env=env,
        )
    for name, relative in MOJO_RUNNERS.items():
        run(
            [
                "pixi",
                "run",
                "--frozen",
                "-e",
                "benchmark",
                "mojo",
                "build",
                "--Werror",
                "-I",
                ".",
                str(ROOT / "benchmark" / relative),
                "-o",
                binaries / name,
            ]
        )
    for name, source in [("kseq", "main.c"), ("kseq-gzip", "main_gzip.c")]:
        command = [
            native_cc,
            "-O3",
            "-march=native",
            "-o",
            binaries / name,
            ROOT / "benchmark/fastq-parser/kseq_runner" / source,
        ]
        if name == "kseq-gzip":
            command.append("-lz")
        run(command, env=env)
    fastq = work / "reads.fastq"
    fasta = work / "reads.fasta"
    gzip = work / "reads.fastq.gz"
    run([binaries / "generate-fastq", fastq, str(args.fastq_size_gib)])
    run([binaries / "generate-fasta", fasta, str(args.fasta_size_gib)])
    with gzip.open("wb") as compressed:
        subprocess.run(
            ["gzip", "-1", "-n", "-c", str(fastq)], stdout=compressed, check=True
        )
    rust = work / "rust-target/release"
    groups = {
        "fastq": {
            "title": "Plain FASTQ",
            "input": fastq,
            "commands": {
                "BlazeSeq masks": [binaries / "plain", fastq, "masks"],
                "BlazeSeq memchr-seq": [binaries / "plain", fastq, "memchr-seq"],
                "needletail": [rust / "needletail_runner", fastq],
                "seq_io": [rust / "seq_io_runner", fastq],
                "kseq (C)": [binaries / "kseq", fastq],
            },
        },
        "gzip": {
            "title": "Gzip FASTQ · single-threaded",
            "input": gzip,
            "commands": {
                "BlazeSeq GZFile": [binaries / "gzip", gzip, "1"],
                "needletail": [rust / "needletail_runner", gzip],
                "seq_io + flate2": [rust / "seq_io_gzip_runner", gzip],
                "kseq + zlib (C)": [binaries / "kseq-gzip", gzip],
            },
        },
        "batches": {
            "title": "FASTQ batches · requested batch size 4096",
            "input": fastq,
            "commands": {
                "BlazeSeq SoA batches": [binaries / "batch", fastq, "4096"],
                "paraseq RecordSet": [rust / "paraseq_runner", fastq, "4096"],
                "seq_io RecordSet": [rust / "seq_io_recordset_runner", fastq, "4096"],
            },
        },
        "fasta": {
            "title": "Multiline FASTA · 200–3800 bases per record",
            "input": fasta,
            "commands": {
                "BlazeSeq records": [binaries / "fasta", fasta],
                "needletail": [rust / "needletail_fasta_runner", fasta],
                "noodles": [rust / "noodles_fasta_runner", fasta],
                "kseq (C)": [binaries / "kseq", fasta],
            },
        },
    }
    versions = {}
    for command in ["mojo", "rustc", "gcc", "hyperfine"]:
        versions[command] = subprocess.check_output(
            [command, "--version"], text=True
        ).splitlines()[0]
    versions["max"] = "26.7.0"
    libraries = {}
    for relative in RUST_RUNNERS:
        lock = tomllib.loads((ROOT / "benchmark" / relative / "Cargo.lock").read_text())
        for package in lock["package"]:
            if package["name"] in [
                "needletail",
                "seq_io",
                "paraseq",
                "noodles",
                "noodles-fasta",
                "flate2",
            ]:
                libraries[package["name"]] = package["version"]
    metadata = {
        "versions": versions,
        "libraries": libraries,
        "platform": platform.platform(),
        "cpu": args.cpu,
        "warmups": args.warmups,
        "runs": args.runs,
        "rust_flags": env["RUSTFLAGS"],
        "c_flags": "-O3 -march=native",
        "mojo_flags": "-O3 (default), native target, --Werror",
        "cpu_settings_changed": False,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "storage": subprocess.check_output(
            ["stat", "-f", "-c", "%T", str(work)], text=True
        ).strip(),
        "warm_cache": True,
        "cpu_state": {
            name: Path(path).read_text().strip()
            for name, path in {
                "governor": f"/sys/devices/system/cpu/cpu{args.cpu}/cpufreq/scaling_governor",
                "no_turbo": "/sys/devices/system/cpu/intel_pstate/no_turbo",
                "smt": "/sys/devices/system/cpu/smt/control",
            }.items()
            if Path(path).exists()
        },
        "worktree_dirty": bool(
            subprocess.check_output(
                ["git", "status", "--porcelain"], cwd=ROOT, text=True
            ).strip()
        ),
        "source_commit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip(),
        "source_worktree_sha256": {
            str(path.relative_to(ROOT)): digest(path)
            for path in sorted((ROOT / "blazeseq").rglob("*.mojo"))
        },
        "kseq_header_sha256": digest(
            ROOT / "benchmark/fastq-parser/kseq_runner/kseq.h"
        ),
        "inputs": {
            path.name: {"bytes": path.stat().st_size, "sha256": digest(path)}
            for path in [fastq, gzip, fasta]
        },
        "notes": [
            "BlazeSeq ASCII/quality validation disabled; libraries retain their structural checks.",
            "BlazeSeq batches copy into SoA buffers; Rust RecordSets retain views into buffers.",
            "seq_io's requested record-set size uses an approximate byte capacity.",
            "Gzip throughput uses uncompressed input bytes. RapidgzipReader currently delegates to single-threaded GZFile.",
            "Synthetic warm-cache CPU parsing measurements, not disk or invalid-input benchmarks.",
        ],
    }
    saved_groups = {}
    for name, group in groups.items():
        expected = None
        actual_counts = {}
        for label, command in group["commands"].items():
            stdout = subprocess.check_output(list(map(str, command)), text=True).strip()
            counts = tuple(map(int, stdout.split()))
            if len(counts) != 2 or min(counts) <= 0:
                raise RuntimeError(f"Invalid counts from {label}: {stdout}")
            expected = expected or counts
            if counts != expected:
                raise RuntimeError(
                    f"Count mismatch in {name}: {label}={counts}, reference={expected}"
                )
            actual_counts[label] = counts
        command = [
            "taskset",
            "-c",
            str(args.cpu),
            "hyperfine",
            "--shell=none",
            "--warmup",
            str(args.warmups),
            "--runs",
            str(args.runs),
            "--export-json",
            str(output / (name + ".json")),
            "--export-markdown",
            str(output / (name + ".md")),
        ]
        for label, runner in group["commands"].items():
            command += ["--command-name", label, shlex.join(map(str, runner))]
        run(command)
        measurements = json.loads((output / (name + ".json")).read_text())
        saved_groups[name] = {
            "title": group["title"],
            "counts": actual_counts,
            "commands": {
                label: list(map(str, value))
                for label, value in group["commands"].items()
            },
            "results": measurements["results"],
            "uncompressed_input_bytes": (fasta if name == "fasta" else fastq)
            .stat()
            .st_size,
        }
        (output / "comparison.json").write_text(
            json.dumps({"metadata": metadata, "groups": saved_groups}, indent=2) + "\n"
        )
    plot_results(
        saved_groups,
        output / "comparison.png",
        warmups=args.warmups,
        runs=args.runs,
        cpu=args.cpu,
    )
    print(f"Validated comparisons and raw samples: {output}", flush=True)


if __name__ == "__main__":
    main()
