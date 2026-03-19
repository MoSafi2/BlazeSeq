"""Generate synthetic FASTQ to a file for benchmarking.

Writes a configurable-size synthetic FASTQ (same format as used in other
BlazeSeq benchmarks) to the given path. Used by run_benchmarks.sh so the
file can be placed on a tmpfs mount.

Usage:
    pixi run mojo run -I . benchmark/fastq-parser/generate_synthetic_fastq.mojo <output_path> [size_gb]
    size_gb defaults to 1.
"""

from std.sys import argv
from std.pathlib import Path
from blazeseq.CONSTS import GB
from blazeseq.utils import (
    generate_synthetic_fastq_to_writer,
    compute_num_reads_for_size,
)
from blazeseq.io.buffered import buffered_writer_for_file


fn main() raises:
    var args = argv()
    if len(args) < 2:
        print("Usage: generate_synthetic_fastq.mojo <output_path> [size_gb]")
        return

    var output_path = args[1]
    var size_gb: Float64 = 1.0
    if len(args) >= 3:
        size_gb = atof(args[2])
    if size_gb <= 0:
        print("size_gb must be positive")
        return

    var target_size = Int(size_gb * Float64(GB))
    var num_reads = compute_num_reads_for_size(target_size, 100, 100)
    print(t"Generating {num_reads} reads (~{size_gb} GB)...")
    var writer = buffered_writer_for_file(
        Path(output_path), capacity=4 * 1024 * 1024
    )
    generate_synthetic_fastq_to_writer(
        writer, num_reads, 100, 100, 33, 73, "generic"
    )
    writer.flush()
    print(t"Wrote {output_path}")
