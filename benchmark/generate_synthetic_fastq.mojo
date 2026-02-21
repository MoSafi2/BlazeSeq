"""Generate synthetic FASTQ to a file for benchmarking.

Writes a configurable-size synthetic FASTQ (same format as used in other
BlazeSeq benchmarks) to the given path. Used by run_benchmarks.sh so the
file can be placed on a tmpfs mount.

Usage:
    pixi run mojo run -I . benchmark/generate_synthetic_fastq.mojo <output_path> [size_gb]
    size_gb defaults to 1.
"""

from sys import argv
from pathlib import Path
from blazeseq.CONSTS import GB
from blazeseq.utils import generate_synthetic_fastq_buffer, compute_num_reads_for_size
from blazeseq.io.buffered import buffered_writer_for_file

fn main() raises:
    var args = argv()
    if len(args) < 2:
        print("Usage: generate_synthetic_fastq.mojo <output_path> [size_gb]")
        return

    var output_path = args[1]
    var size_gb: Int = 1
    if len(args) >= 3:
        size_gb = atol(args[2])
    if size_gb <= 0:
        print("size_gb must be positive")
        return

    var target_size = size_gb * GB
    var num_reads = compute_num_reads_for_size(target_size, 100, 100)
    print("Generating ", num_reads, " reads (~", size_gb, " GB)...")
    var data = generate_synthetic_fastq_buffer(
        num_reads, 100, 100, 33, 73, "generic"
    )
    print("Buffer size: ", len(data), " bytes")

    var writer = buffered_writer_for_file(Path(output_path), capacity=4 * 1024 * 1024)
    writer.write_bytes(data)
    writer.flush()
    print("Wrote ", output_path)
